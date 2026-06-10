import Cocoa
import CLua
import Lua
import os.log

private let USERDATA_TAG = "hs.spotlight"
private let ITEM_UD_TAG  = "hs.spotlight.item"
private let GROUP_UD_TAG = "hs.spotlight.group"

private var refTable: Int32 = LUA_NOREF
private var moduleSearchQueue: OperationQueue?

// MARK: - Support Functions and Classes

private class HSMetadataQuery: NSObject {
    var metadataSearch: NSMetadataQuery
    var callbackRef: Int32 = LUA_NOREF
    var selfPushCount: Int32 = 0
    var wantComplete: Bool = true
    var wantProgress: Bool = false
    var wantStart: Bool = false
    var wantUpdate: Bool = false

    override init() {
        metadataSearch = NSMetadataQuery()
        super.init()

        if moduleSearchQueue == nil { moduleSearchQueue = OperationQueue() }
        metadataSearch.operationQueue = moduleSearchQueue

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(queryDidFinish(_:)),
                       name: .NSMetadataQueryDidFinishGathering, object: metadataSearch)
        nc.addObserver(self, selector: #selector(queryDidStart(_:)),
                       name: .NSMetadataQueryDidStartGathering, object: metadataSearch)
        nc.addObserver(self, selector: #selector(queryDidUpdate(_:)),
                       name: .NSMetadataQueryDidUpdate, object: metadataSearch)
        nc.addObserver(self, selector: #selector(queryProgress(_:)),
                       name: .NSMetadataQueryGatheringProgress, object: metadataSearch)
    }

    @objc func queryDidFinish(_ notification: Notification) {
        if callbackRef != LUA_NOREF && wantComplete { doCallback(for: "didFinish", with: notification) }
    }

    @objc func queryDidStart(_ notification: Notification) {
        if callbackRef != LUA_NOREF && wantStart { doCallback(for: "didStart", with: notification) }
    }

    @objc func queryDidUpdate(_ notification: Notification) {
        if callbackRef != LUA_NOREF && wantUpdate { doCallback(for: "didUpdate", with: notification) }
    }

    @objc func queryProgress(_ notification: Notification) {
        if callbackRef != LUA_NOREF && wantProgress { doCallback(for: "inProgress", with: notification) }
    }

    func doCallback(for message: String, with notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.callbackRef != LUA_NOREF else { return }
            let L = lua_getCurrentState()!
            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(self.callbackRef))
            pushHSMetadataQuery(L, obj: self)
            lua_pushany(L, message as NSString)
            lua_pushany(L, notification.userInfo as NSDictionary?)
            if lua_pcall(L, 3, 0, 0) != LUA_OK { lua_pop(L, 1) }
        }
    }
}

// MARK: - Helpers

private func get_queryFromUserdata(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> HSMetadataQuery {
    let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
    return Unmanaged<HSMetadataQuery>.fromOpaque(ptr.load(as: UnsafeRawPointer.self)).takeUnretainedValue()
}

private func get_groupFromUserdata(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> NSMetadataQueryResultGroup {
    let ptr = luaL_checkudata(L, idx, GROUP_UD_TAG)!
    return Unmanaged<NSMetadataQueryResultGroup>.fromOpaque(ptr.load(as: UnsafeRawPointer.self)).takeUnretainedValue()
}

private func get_itemFromUserdata(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> NSMetadataItem {
    let ptr = luaL_checkudata(L, idx, ITEM_UD_TAG)!
    return Unmanaged<NSMetadataItem>.fromOpaque(ptr.load(as: UnsafeRawPointer.self)).takeUnretainedValue()
}

// MARK: - Module Functions

/// hs.spotlight.new() -> spotlightObject
/// Constructor
/// Creates a new spotlightObject to use for Spotlight searches.
private func spotlight_new(_ L: LuaState) throws -> CInt {
    pushHSMetadataQuery(L, obj: HSMetadataQuery())
    return 1
}

/// hs.spotlight.newWithin(spotlightObject) -> spotlightObject
/// Constructor
/// Creates a new spotlightObject that limits its searches to the current results of another spotlightObject.
private func spotlight_searchWithin(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let query = get_queryFromUserdata(L, at: 1)

    let newQuery = HSMetadataQuery()
    query.metadataSearch.disableUpdates()
    newQuery.metadataSearch.searchItems = query.metadataSearch.results
    query.metadataSearch.enableUpdates()

    pushHSMetadataQuery(L, obj: newQuery)
    return 1
}

// MARK: - Module Methods

// wrapped in init.lua
private func spotlight_searchScopes(_ L: LuaState) throws -> CInt {
    let query = get_queryFromUserdata(L, at: 1)

    if lua_gettop(L) == 1 {
        pushSpotlightValue(L, query.metadataSearch.searchScopes as NSArray)
    } else {
        var newScopes: [Any] = []
        var errorMessage: String?
        guard let items = lua_tovalue(L, at: 2) else {
            errorMessage = "unexpected type conversion error"
            throw LuaCallError("bad argument #2 (\(errorMessage!))")
        }
        let itemsArray: [Any]
        if let arr = items as? [Any] {
            itemsArray = arr
        } else {
            itemsArray = [items]
        }
        for (idx, obj) in itemsArray.enumerated() {
            if let str = obj as? String {
                newScopes.append((str as NSString).expandingTildeInPath)
            } else if let url = obj as? URL {
                guard url.isFileURL else {
                    errorMessage = "index \(idx + 1) does not represent a file URL"
                    break
                }
                newScopes.append(url)
            } else if let dict = obj as? [String: Any], let urlString = dict["url"] as? String {
                guard let url = URL(string: urlString), url.isFileURL else {
                    errorMessage = "index \(idx + 1) does not represent a file URL"
                    break
                }
                newScopes.append(url)
            } else {
                errorMessage = "index \(idx + 1) is not a path string or a file URL"
                break
            }
        }
        if let err = errorMessage {
            throw LuaCallError("bad argument #2 (\(err))")
        }
        query.metadataSearch.searchScopes = newScopes
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.spotlight:setCallback(fn) -> spotlightObject
/// Method
/// Set or remove the callback function for the Spotlight search object.
private func spotlight_callback(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let query = get_queryFromUserdata(L, at: 1)

    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, query.callbackRef)


    query.callbackRef = LUA_NOREF
    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        query.callbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
    }
    lua_pushvalue(L, 1)
    return 1
}

// wrapped in init.lua
private func spotlight_callbackMessages(_ L: LuaState) throws -> CInt {
    let query = get_queryFromUserdata(L, at: 1)

    if lua_gettop(L) == 1 {
        lua_newtable(L)
        if query.wantComplete { lua_pushstring(L, "didFinish");  lua_rawseti(L, -2, luaL_len(L, -2) + 1) }
        if query.wantStart    { lua_pushstring(L, "didStart");   lua_rawseti(L, -2, luaL_len(L, -2) + 1) }
        if query.wantUpdate   { lua_pushstring(L, "didUpdate");  lua_rawseti(L, -2, luaL_len(L, -2) + 1) }
        if query.wantProgress { lua_pushstring(L, "inProgress"); lua_rawseti(L, -2, luaL_len(L, -2) + 1) }
    } else {
        var items: [Any]
        if let str = lua_tovalue(L, at: 2) as? String {
            items = [str]
        } else if let arr = lua_tovalue(L, at: 2) as? [Any] {
            items = arr
        } else {
            throw LuaCallError("bad argument #2 (expected string or array of strings)")
        }
        let validMessages = ["didFinish", "didStart", "didUpdate", "inProgress"]
        for (idx, obj) in items.enumerated() {
            guard let str = obj as? String else {
                throw LuaCallError("bad argument #2 (index \(idx + 1) is not a string)")
            }
            if !validMessages.contains(str) {
                throw LuaCallError("bad argument #2 (index \(idx + 1) must be one of '\(validMessages.joined(separator: "', '"))')")
            }
        }
        let strs = items.compactMap { $0 as? String }
        query.wantComplete = strs.contains("didFinish")
        query.wantStart    = strs.contains("didStart")
        query.wantUpdate   = strs.contains("didUpdate")
        query.wantProgress = strs.contains("inProgress")
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.spotlight:updateInterval([interval]) -> number | spotlightObject
/// Method
/// Get or set the time interval at which the spotlightObject will send "didUpdate" messages during the initial gathering phase.
private func spotlight_updateInterval(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let query = get_queryFromUserdata(L, at: 1)

    if lua_gettop(L) == 1 {
        lua_pushnumber(L, query.metadataSearch.notificationBatchingInterval)
    } else {
        query.metadataSearch.notificationBatchingInterval = lua_tonumber(L, 2)
        lua_pushvalue(L, 1)
    }
    return 1
}

// wrapped in init.lua
private func spotlight_sortDescriptors(_ L: LuaState) throws -> CInt {
    let query = get_queryFromUserdata(L, at: 1)

    if lua_gettop(L) == 1 {
        pushSpotlightValue(L, query.metadataSearch.sortDescriptors as NSArray)
    } else {
        var newDescriptors: [NSSortDescriptor] = []
        var errorMessage: String?
        guard let hopefuls = lua_tovalue(L, at: 2) else {
            throw LuaCallError("bad argument #2 (unexpected type conversion error)")
        }
        let items: [Any]
        if let arr = hopefuls as? [Any] { items = arr } else { items = [hopefuls] }
        for (idx, obj) in items.enumerated() {
            if let sd = obj as? NSSortDescriptor {
                newDescriptors.append(sd)
            } else if let str = obj as? String {
                newDescriptors.append(NSSortDescriptor(key: str, ascending: true))
            } else if let dict = obj as? [String: Any], let key = dict["key"] as? String {
                let ascending = dict["ascending"] as? Bool ?? true
                newDescriptors.append(NSSortDescriptor(key: key, ascending: ascending))
            } else {
                errorMessage = "expected string or NSSortDescriptor table at index \(idx + 1)"
                break
            }
        }
        if let err = errorMessage {
            throw LuaCallError("bad argument #2 (\(err))")
        }
        query.metadataSearch.sortDescriptors = newDescriptors
        lua_pushvalue(L, 1)
    }
    return 1
}

// wrapped in init.lua
private func spotlight_valueListAttributes(_ L: LuaState) throws -> CInt {
    let query = get_queryFromUserdata(L, at: 1)

    if lua_gettop(L) == 1 {
        pushSpotlightValue(L, query.metadataSearch.valueListAttributes as NSArray)
    } else {
        var newAttributes: [String]
        if let str = lua_tovalue(L, at: 2) as? String {
            newAttributes = [str]
        } else if let arr = lua_tovalue(L, at: 2) as? [String] {
            newAttributes = arr
        } else {
            throw LuaCallError("bad argument #2 (expected an array of attribute strings)")
        }
        query.metadataSearch.valueListAttributes = newAttributes
        lua_pushvalue(L, 1)
    }
    return 1
}

// wrapped in init.lua
private func spotlight_groupingAttributes(_ L: LuaState) throws -> CInt {
    let query = get_queryFromUserdata(L, at: 1)

    if lua_gettop(L) == 1 {
        pushSpotlightValue(L, query.metadataSearch.groupingAttributes as NSArray?)
    } else {
        var newAttributes: [String]
        if let str = lua_tovalue(L, at: 2) as? String {
            newAttributes = [str]
        } else if let arr = lua_tovalue(L, at: 2) as? [String] {
            newAttributes = arr
        } else {
            throw LuaCallError("bad argument #2 (expected an array of attribute strings)")
        }
        query.metadataSearch.groupingAttributes = newAttributes
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.spotlight:start() -> spotlightObject
/// Method
/// Begin the gathering phase of a Spotlight query.
private func spotlight_start(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let query = get_queryFromUserdata(L, at: 1)

    if query.metadataSearch.isStarted && !query.metadataSearch.isStopped {
        os_log(.info, "%{public}s", "query already started")
    } else {
        if query.metadataSearch.predicate != nil {
            query.metadataSearch.operationQueue?.addOperation {
                query.metadataSearch.start()
            }
        } else {
            throw LuaCallError("no query defined")
        }
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.spotlight:stop() -> spotlightObject
/// Method
/// Stop the Spotlight query.
private func spotlight_stop(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let query = get_queryFromUserdata(L, at: 1)

    if query.metadataSearch.isStarted && !query.metadataSearch.isStopped {
        query.metadataSearch.stop()
    } else {
        os_log(.info, "%{public}s", "query not running")
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.spotlight:isRunning() -> boolean
/// Method
/// Returns a boolean specifying if the query is active or inactive.
private func spotlight_isRunning(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let query = get_queryFromUserdata(L, at: 1)

    lua_pushboolean(L, (query.metadataSearch.isStarted && !query.metadataSearch.isStopped) ? 1 : 0)
    return 1
}

/// hs.spotlight:isGathering() -> boolean
/// Method
/// Returns a boolean specifying whether or not the query is in the active gathering phase.
private func spotlight_isGathering(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let query = get_queryFromUserdata(L, at: 1)

    lua_pushboolean(L, query.metadataSearch.isGathering ? 1 : 0)
    return 1
}

/// hs.spotlight:queryString(query) -> spotlightObject
/// Method
/// Specify the query string for the spotlightObject
private func spotlight_predicate(_ L: LuaState) throws -> CInt {
    let query = get_queryFromUserdata(L, at: 1)

    if lua_gettop(L) == 1 {
        if let pred = query.metadataSearch.predicate {
            lua_pushany(L, (pred as NSPredicate).predicateFormat as NSString)
        } else {
            lua_pushnil(L)
        }
    } else {
        if lua_type(L, 2) == LUA_TNIL {
            query.metadataSearch.predicate = nil
        } else {
            let predicateStr = lua_tovalue(L, at: 2) as! String
            let queryPredicate = NSPredicate(format: predicateStr)
            query.metadataSearch.predicate = queryPredicate
        }
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.spotlight:count() -> integer
/// Method
/// Returns the number of results for the spotlightObject's query
private func spotlight_resultCount(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let query = get_queryFromUserdata(L, at: 1)

    lua_pushinteger(L, lua_Integer(query.metadataSearch.resultCount))
    return 1
}

/// hs.spotlight:resultAtIndex(index) -> spotlightItemObject
/// Method
/// Returns the spotlightItemObject at the specified index of the spotlightObject
private func spotlight_resultAtIndex(_ L: LuaState) throws -> CInt {
    let query = get_queryFromUserdata(L, at: 1)

    let index = lua_tointeger(L, 2)
    let count = query.metadataSearch.resultCount
    if index < 1 || index > lua_Integer(count) {
        if count == 0 {
            throw LuaCallError("bad argument #2 (result set is empty)")
        } else {
            throw LuaCallError("bad argument #2 (index must be between 1 and \(count) inclusive)")
        }
    }
    query.metadataSearch.disableUpdates()
    let item = query.metadataSearch.result(at: Int(index - 1)) as! NSMetadataItem
    query.metadataSearch.enableUpdates()
    pushNSMetadataItem(L, obj: item)
    return 1
}

/// hs.spotlight:valueLists() -> table
/// Method
/// Returns the value list summaries for the Spotlight query
private func spotlight_valueLists(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let query = get_queryFromUserdata(L, at: 1)

    pushSpotlightValue(L, query.metadataSearch.valueLists as NSDictionary)
    return 1
}

/// hs.spotlight:groupedResults() -> table
/// Method
/// Returns the grouped results for a Spotlight query.
private func spotlight_groupedResults(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let query = get_queryFromUserdata(L, at: 1)

    pushSpotlightValue(L, query.metadataSearch.groupedResults as NSArray)
    return 1
}

// MARK: - Module Group Methods

/// hs.spotlight.group:attribute() -> string
private func group_attribute(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, GROUP_UD_TAG)
    let resultGroup = get_groupFromUserdata(L, at: 1)
    lua_pushany(L, resultGroup.attribute as NSString)
    return 1
}

/// hs.spotlight.group:value() -> value
private func group_value(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, GROUP_UD_TAG)
    let resultGroup = get_groupFromUserdata(L, at: 1)
    pushSpotlightValue(L, resultGroup.value as? NSObject)
    return 1
}

/// hs.spotlight.group:count() -> integer
private func group_resultCount(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, GROUP_UD_TAG)
    let resultGroup = get_groupFromUserdata(L, at: 1)
    lua_pushinteger(L, lua_Integer(resultGroup.resultCount))
    return 1
}

/// hs.spotlight.group:resultAtIndex(index) -> spotlightItemObject
private func group_resultAtIndex(_ L: LuaState) throws -> CInt {
    let resultGroup = get_groupFromUserdata(L, at: 1)

    let index = lua_tointeger(L, 2)
    let count = resultGroup.resultCount
    if index < 1 || index > lua_Integer(count) {
        if count == 0 {
            throw LuaCallError("bad argument #2 (result set is empty)")
        } else {
            throw LuaCallError("bad argument #2 (index must be between 1 and \(count) inclusive)")
        }
    }
    pushSpotlightValue(L, resultGroup.result(at: Int(index - 1)) as? NSObject)
    return 1
}

/// hs.spotlight.group:subgroups() -> table
private func group_subgroups(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, GROUP_UD_TAG)
    let resultGroup = get_groupFromUserdata(L, at: 1)
    pushSpotlightValue(L, resultGroup.subgroups as NSArray?)
    return 1
}

// MARK: - Module Item Methods

/// hs.spotlight.item:attributes() -> table
private func item_attributes(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, ITEM_UD_TAG)
    let item = get_itemFromUserdata(L, at: 1)
    pushSpotlightValue(L, item.attributes as NSArray)
    return 1
}

/// hs.spotlight.item:valueForAttribute(attribute) -> value
private func item_valueForAttribute(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, ITEM_UD_TAG)

    luaL_checktype(L, 2, LUA_TSTRING)
    let item = get_itemFromUserdata(L, at: 1)
    let attribute = lua_tovalue(L, at: 2) as! String
    pushSpotlightValue(L, item.value(forAttribute: attribute) as? NSObject)
    return 1
}

// MARK: - Module Constants

/// hs.spotlight.definedSearchScopes[]
/// Constant
/// A table of key-value pairs describing predefined search scopes for Spotlight queries
private func push_searchScopes(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_newtable(L)
    lua_pushany(L, NSMetadataQueryUserHomeScope as NSString);                              lua_setfield(L, -2, "userHome")
    lua_pushany(L, NSMetadataQueryLocalComputerScope as NSString);                         lua_setfield(L, -2, "localComputer")
    lua_pushany(L, NSMetadataQueryNetworkScope as NSString);                               lua_setfield(L, -2, "network")
    lua_pushany(L, NSMetadataQueryUbiquitousDocumentsScope as NSString);                   lua_setfield(L, -2, "iCloudDocuments")
    lua_pushany(L, NSMetadataQueryUbiquitousDataScope as NSString);                        lua_setfield(L, -2, "iCloudData")
    lua_pushany(L, NSMetadataQueryAccessibleUbiquitousExternalDocumentsScope as NSString);  lua_setfield(L, -2, "iCloudExternalDocuments")
    lua_pushany(L, NSMetadataQueryIndexedLocalComputerScope as NSString);                  lua_setfield(L, -2, "indexedLocalComputer")
    lua_pushany(L, NSMetadataQueryIndexedNetworkScope as NSString);                        lua_setfield(L, -2, "indexedNetwork")
    return 1
}

/// hs.spotlight.commonAttributeKeys[]
/// Constant
/// A list of defined attribute keys as discovered in the macOS 10.12 SDK framework headers.
private func push_commonAttributeKeys(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_newtable(L)

    let keys: [String] = [
        kMDItemFSHasCustomIcon as String, kMDItemFSInvisible as String,
        kMDItemFSIsExtensionHidden as String, kMDItemFSIsStationery as String,
        kMDItemFSLabel as String, kMDItemFSNodeCount as String,
        kMDItemFSOwnerGroupID as String, kMDItemFSOwnerUserID as String,
        kMDItemHTMLContent as String,
        NSMetadataItemAcquisitionMakeKey, NSMetadataItemAcquisitionModelKey,
        NSMetadataItemAlbumKey, NSMetadataItemAltitudeKey,
        NSMetadataItemApertureKey, NSMetadataItemAppleLoopDescriptorsKey,
        NSMetadataItemAppleLoopsKeyFilterTypeKey, NSMetadataItemAppleLoopsLoopModeKey,
        NSMetadataItemAppleLoopsRootKeyKey, NSMetadataItemApplicationCategoriesKey,
        NSMetadataItemAttributeChangeDateKey, NSMetadataItemAudiencesKey,
        NSMetadataItemAudioBitRateKey, NSMetadataItemAudioChannelCountKey,
        NSMetadataItemAudioEncodingApplicationKey, NSMetadataItemAudioSampleRateKey,
        NSMetadataItemAudioTrackNumberKey, NSMetadataItemAuthorAddressesKey,
        NSMetadataItemAuthorEmailAddressesKey, NSMetadataItemAuthorsKey,
        NSMetadataItemBitsPerSampleKey, NSMetadataItemCameraOwnerKey,
        NSMetadataItemCFBundleIdentifierKey, NSMetadataItemCityKey,
        NSMetadataItemCodecsKey, NSMetadataItemColorSpaceKey,
        NSMetadataItemCommentKey, NSMetadataItemComposerKey,
        NSMetadataItemContactKeywordsKey, NSMetadataItemContentCreationDateKey,
        NSMetadataItemContentModificationDateKey, NSMetadataItemContentTypeKey,
        NSMetadataItemContentTypeTreeKey, NSMetadataItemContributorsKey,
        NSMetadataItemCopyrightKey, NSMetadataItemCountryKey,
        NSMetadataItemCoverageKey, NSMetadataItemCreatorKey,
        NSMetadataItemDateAddedKey, NSMetadataItemDeliveryTypeKey,
        NSMetadataItemDescriptionKey, NSMetadataItemDirectorKey,
        NSMetadataItemDisplayNameKey, NSMetadataItemDownloadedDateKey,
        NSMetadataItemDueDateKey, NSMetadataItemDurationSecondsKey,
        NSMetadataItemEditorsKey, NSMetadataItemEmailAddressesKey,
        NSMetadataItemEncodingApplicationsKey, NSMetadataItemExecutableArchitecturesKey,
        NSMetadataItemExecutablePlatformKey, NSMetadataItemEXIFGPSVersionKey,
        NSMetadataItemEXIFVersionKey, NSMetadataItemExposureModeKey,
        NSMetadataItemExposureProgramKey, NSMetadataItemExposureTimeSecondsKey,
        NSMetadataItemExposureTimeStringKey, NSMetadataItemFinderCommentKey,
        NSMetadataItemFlashOnOffKey, NSMetadataItemFNumberKey,
        NSMetadataItemFocalLength35mmKey, NSMetadataItemFocalLengthKey,
        NSMetadataItemFontsKey, NSMetadataItemFSContentChangeDateKey,
        NSMetadataItemFSCreationDateKey, NSMetadataItemFSNameKey,
        NSMetadataItemFSSizeKey, NSMetadataItemGenreKey,
        NSMetadataItemGPSAreaInformationKey, NSMetadataItemGPSDateStampKey,
        NSMetadataItemGPSDestBearingKey, NSMetadataItemGPSDestDistanceKey,
        NSMetadataItemGPSDestLatitudeKey, NSMetadataItemGPSDestLongitudeKey,
        NSMetadataItemGPSDifferentalKey, NSMetadataItemGPSDOPKey,
        NSMetadataItemGPSMapDatumKey, NSMetadataItemGPSMeasureModeKey,
        NSMetadataItemGPSProcessingMethodKey, NSMetadataItemGPSStatusKey,
        NSMetadataItemGPSTrackKey, NSMetadataItemHasAlphaChannelKey,
        NSMetadataItemHeadlineKey, NSMetadataItemIdentifierKey,
        NSMetadataItemImageDirectionKey, NSMetadataItemInformationKey,
        NSMetadataItemInstantMessageAddressesKey, NSMetadataItemInstructionsKey,
        NSMetadataItemIsApplicationManagedKey, NSMetadataItemIsGeneralMIDISequenceKey,
        NSMetadataItemIsLikelyJunkKey, NSMetadataItemISOSpeedKey,
        NSMetadataItemIsUbiquitousKey, NSMetadataItemKeySignatureKey,
        NSMetadataItemKeywordsKey, NSMetadataItemKindKey,
        NSMetadataItemLanguagesKey, NSMetadataItemLastUsedDateKey,
        NSMetadataItemLatitudeKey, NSMetadataItemLayerNamesKey,
        NSMetadataItemLensModelKey, NSMetadataItemLongitudeKey,
        NSMetadataItemLyricistKey, NSMetadataItemMaxApertureKey,
        NSMetadataItemMediaTypesKey, NSMetadataItemMeteringModeKey,
        NSMetadataItemMusicalGenreKey, NSMetadataItemMusicalInstrumentCategoryKey,
        NSMetadataItemMusicalInstrumentNameKey, NSMetadataItemNamedLocationKey,
        NSMetadataItemNumberOfPagesKey, NSMetadataItemOrganizationsKey,
        NSMetadataItemOrientationKey, NSMetadataItemOriginalFormatKey,
        NSMetadataItemOriginalSourceKey, NSMetadataItemPageHeightKey,
        NSMetadataItemPageWidthKey, NSMetadataItemParticipantsKey,
        NSMetadataItemPathKey, NSMetadataItemPerformersKey,
        NSMetadataItemPhoneNumbersKey, NSMetadataItemPixelCountKey,
        NSMetadataItemPixelHeightKey, NSMetadataItemPixelWidthKey,
        NSMetadataItemProducerKey, NSMetadataItemProfileNameKey,
        NSMetadataItemProjectsKey, NSMetadataItemPublishersKey,
        NSMetadataItemRecipientAddressesKey, NSMetadataItemRecipientEmailAddressesKey,
        NSMetadataItemRecipientsKey, NSMetadataItemRecordingDateKey,
        NSMetadataItemRecordingYearKey, NSMetadataItemRedEyeOnOffKey,
        NSMetadataItemResolutionHeightDPIKey, NSMetadataItemResolutionWidthDPIKey,
        NSMetadataItemRightsKey, NSMetadataItemSecurityMethodKey,
        NSMetadataItemSpeedKey, NSMetadataItemStarRatingKey,
        NSMetadataItemStateOrProvinceKey, NSMetadataItemStreamableKey,
        NSMetadataItemSubjectKey, NSMetadataItemTempoKey,
        NSMetadataItemTextContentKey, NSMetadataItemThemeKey,
        NSMetadataItemTimeSignatureKey, NSMetadataItemTimestampKey,
        NSMetadataItemTitleKey, NSMetadataItemTotalBitRateKey,
        NSMetadataItemURLKey, NSMetadataItemVersionKey,
        NSMetadataItemVideoBitRateKey, NSMetadataItemWhereFromsKey,
        NSMetadataItemWhiteBalanceKey,
        NSMetadataUbiquitousItemContainerDisplayNameKey,
        NSMetadataUbiquitousItemDownloadingErrorKey,
        NSMetadataUbiquitousItemDownloadingStatusCurrent,
        NSMetadataUbiquitousItemDownloadingStatusDownloaded,
        NSMetadataUbiquitousItemDownloadingStatusKey,
        NSMetadataUbiquitousItemDownloadingStatusNotDownloaded,
        NSMetadataUbiquitousItemDownloadRequestedKey,
        NSMetadataUbiquitousItemHasUnresolvedConflictsKey,
        NSMetadataUbiquitousItemIsDownloadingKey,
        NSMetadataUbiquitousItemIsExternalDocumentKey,
        NSMetadataUbiquitousItemIsUploadedKey,
        NSMetadataUbiquitousItemIsUploadingKey,
        NSMetadataUbiquitousItemPercentDownloadedKey,
        NSMetadataUbiquitousItemPercentUploadedKey,
        NSMetadataUbiquitousItemUploadingErrorKey,
        NSMetadataUbiquitousItemURLInLocalContainerKey,
    ]
    for key in keys {
        lua_pushany(L, key as NSString)
        lua_rawseti(L, -2, luaL_len(L, -2) + 1)
    }
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions

private func pushSpotlightValue(_ L: UnsafeMutablePointer<lua_State>!, _ value: Any?, depth: Int = 0) {
    guard depth < 50 else {
        lua_pushnil(L)
        return
    }

    guard let value else {
        lua_pushnil(L)
        return
    }

    if let query = value as? HSMetadataQuery {
        pushHSMetadataQuery(L, obj: query)
    } else if let group = value as? NSMetadataQueryResultGroup {
        pushNSMetadataQueryResultGroup(L, obj: group)
    } else if let item = value as? NSMetadataItem {
        pushNSMetadataItem(L, obj: item)
    } else if let descriptor = value as? NSSortDescriptor {
        pushNSSortDescriptor(L, obj: descriptor)
    } else if let tuple = value as? NSMetadataQueryAttributeValueTuple {
        pushNSMetadataQueryAttributeValueTuple(L, obj: tuple, depth: depth + 1)
    } else if let array = value as? NSArray {
        lua_createtable(L, Int32(array.count), 0)
        for item in array {
            pushSpotlightValue(L, item, depth: depth + 1)
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
    } else if let array = value as? [Any] {
        lua_createtable(L, Int32(array.count), 0)
        for item in array {
            pushSpotlightValue(L, item, depth: depth + 1)
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
    } else if let dictionary = value as? NSDictionary {
        lua_createtable(L, 0, Int32(dictionary.count))
        for (key, item) in dictionary {
            lua_pushany(L, key)
            pushSpotlightValue(L, item, depth: depth + 1)
            lua_settable(L, -3)
        }
    } else if let dictionary = value as? [String: Any] {
        lua_createtable(L, 0, Int32(dictionary.count))
        for (key, item) in dictionary {
            lua_pushstring(L, key)
            pushSpotlightValue(L, item, depth: depth + 1)
            lua_settable(L, -3)
        }
    } else {
        lua_pushany(L, value)
    }
}

@discardableResult
private func pushHSMetadataQuery(_ L: UnsafeMutablePointer<lua_State>!, obj: Any!) -> Int32 {
    let value = obj as! HSMetadataQuery
    value.selfPushCount += 1
    let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeRawPointer>.size)!
    valuePtr.storeBytes(of: Unmanaged.passRetained(value).toOpaque(), as: UnsafeRawPointer.self)
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private func toHSMetadataQueryFromLua(_ L: UnsafeMutablePointer<lua_State>!, idx: Int32) -> Any! {
    if luaL_testudata(L, idx, USERDATA_TAG) != nil {
        return get_queryFromUserdata(L, at: idx)
    }
    os_log(.error, "%{public}s", "expected \(USERDATA_TAG) object, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
    return nil
}

@discardableResult
private func pushNSMetadataQueryResultGroup(_ L: UnsafeMutablePointer<lua_State>!, obj: Any!) -> Int32 {
    let value = obj as! NSMetadataQueryResultGroup
    let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeRawPointer>.size)!
    valuePtr.storeBytes(of: Unmanaged.passRetained(value).toOpaque(), as: UnsafeRawPointer.self)
    luaL_getmetatable(L, GROUP_UD_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private func toNSMetadataQueryResultGroupFromLua(_ L: UnsafeMutablePointer<lua_State>!, idx: Int32) -> Any! {
    if luaL_testudata(L, idx, GROUP_UD_TAG) != nil {
        return get_groupFromUserdata(L, at: idx)
    }
    os_log(.error, "%{public}s", "expected \(GROUP_UD_TAG) object, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
    return nil
}

@discardableResult
private func pushNSMetadataItem(_ L: UnsafeMutablePointer<lua_State>!, obj: Any!) -> Int32 {
    let value = obj as! NSMetadataItem
    let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeRawPointer>.size)!
    valuePtr.storeBytes(of: Unmanaged.passRetained(value).toOpaque(), as: UnsafeRawPointer.self)
    luaL_getmetatable(L, ITEM_UD_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private func toNSMetadataItemFromLua(_ L: UnsafeMutablePointer<lua_State>!, idx: Int32) -> Any! {
    if luaL_testudata(L, idx, ITEM_UD_TAG) != nil {
        return get_itemFromUserdata(L, at: idx)
    }
    os_log(.error, "%{public}s", "expected \(ITEM_UD_TAG) object, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
    return nil
}

@discardableResult
private func pushNSSortDescriptor(_ L: UnsafeMutablePointer<lua_State>!, obj: Any!) -> Int32 {
    let descriptor = obj as! NSSortDescriptor
    lua_newtable(L)
    lua_pushany(L, descriptor.key! as NSString); lua_setfield(L, -2, "key")
    lua_pushboolean(L, descriptor.ascending ? 1 : 0); lua_setfield(L, -2, "ascending")
    lua_pushstring(L, "NSSortDescriptor"); lua_setfield(L, -2, "__luaSkinType")
    return 1
}

private func toNSSortDescriptorFromLua(_ L: UnsafeMutablePointer<lua_State>!, idx: Int32) -> Any! {
    let absIdx = lua_absindex(L, idx)
    if lua_type(L, absIdx) == LUA_TSTRING {
        return NSSortDescriptor(key: lua_tovalue(L, at: absIdx) as? String, ascending: true)
    } else if lua_type(L, absIdx) == LUA_TTABLE {
        if lua_getfield(L, absIdx, "key") == LUA_TSTRING {
            let key = lua_tovalue(L, at: -1) as! String
            lua_pop(L, 1)
            var ascending = true
            if lua_getfield(L, absIdx, "ascending") == LUA_TBOOLEAN {
                ascending = lua_toboolean(L, -1) != 0
            }
            lua_pop(L, 1)
            return NSSortDescriptor(key: key, ascending: ascending)
        } else {
            os_log(.error, "%{public}s", "key field missing in NSSortDescriptor table")
            lua_pop(L, 1)
        }
    } else {
        os_log(.error, "%{public}s", "expected string or table describing an NSSortDescriptor, found \(String(cString: lua_typename(L, lua_type(L, absIdx))))")
    }
    return nil
}

@discardableResult
private func pushNSMetadataQueryAttributeValueTuple(_ L: UnsafeMutablePointer<lua_State>!, obj: Any!, depth: Int = 0) -> Int32 {
    let tuple = obj as! NSMetadataQueryAttributeValueTuple
    return pushSpotlightAttributeValueTupleFields(L, attribute: tuple.attribute, count: tuple.count, value: tuple.value, depth: depth)
}

@discardableResult
private func pushSpotlightAttributeValueTupleFields(_ L: UnsafeMutablePointer<lua_State>!, attribute: String, count: Int, value: Any?, depth: Int = 0) -> Int32 {
    lua_newtable(L)
    lua_pushany(L, attribute as NSString); lua_setfield(L, -2, "attribute")
    lua_pushinteger(L, lua_Integer(count)); lua_setfield(L, -2, "count")
    pushSpotlightValue(L, value, depth: depth); lua_setfield(L, -2, "value")
    return 1
}

#if DEBUG
@discardableResult
func pushSpotlightAttributeValueTupleFieldsForTesting(_ L: UnsafeMutablePointer<lua_State>!, attribute: String, count: Int, value: Any?) -> Int32 {
    pushSpotlightAttributeValueTupleFields(L, attribute: attribute, count: count, value: value)
}
#endif

// MARK: - Cosmic Hammer/Lua Infrastructure

private func userdata_tostring(_ L: LuaState) throws -> CInt {
    let obj = get_queryFromUserdata(L, at: 1)
    let title = obj.metadataSearch.predicate?.predicateFormat ?? "<undefined>"
    lua_pushany(L, "\(USERDATA_TAG): \(title) (\(String(describing: Unmanaged.passUnretained(obj).toOpaque())))" as NSString)
    return 1
}

private func userdata_eq(_ L: LuaState) throws -> CInt {
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let obj1 = get_queryFromUserdata(L, at: 1)
        let obj2 = get_queryFromUserdata(L, at: 2)
        lua_pushboolean(L, obj1.isEqual(to: obj2) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func userdata_gc(_ L: LuaState) throws -> CInt {
    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!
    let obj = Unmanaged<HSMetadataQuery>.fromOpaque(ptr.load(as: UnsafeRawPointer.self)).takeRetainedValue()
    obj.selfPushCount -= 1
    if obj.selfPushCount == 0 {
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, obj.callbackRef)

        obj.callbackRef = LUA_NOREF
        let nc = NotificationCenter.default
        nc.removeObserver(obj, name: .NSMetadataQueryDidFinishGathering, object: obj.metadataSearch)
        nc.removeObserver(obj, name: .NSMetadataQueryDidStartGathering, object: obj.metadataSearch)
        nc.removeObserver(obj, name: .NSMetadataQueryDidUpdate, object: obj.metadataSearch)
        nc.removeObserver(obj, name: .NSMetadataQueryGatheringProgress, object: obj.metadataSearch)
        if !obj.metadataSearch.isStopped { obj.metadataSearch.stop() }
    }
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

private func group_userdata_tostring(_ L: LuaState) throws -> CInt {
    let obj = get_groupFromUserdata(L, at: 1)
    let title = obj.attribute
    lua_pushany(L, "\(GROUP_UD_TAG): \(title) (\(String(describing: lua_topointer(L, 1)!)))" as NSString)
    return 1
}

private func group_userdata_eq(_ L: LuaState) throws -> CInt {
    if luaL_testudata(L, 1, GROUP_UD_TAG) != nil && luaL_testudata(L, 2, GROUP_UD_TAG) != nil {
        let obj1 = get_groupFromUserdata(L, at: 1)
        let obj2 = get_groupFromUserdata(L, at: 2)
        lua_pushboolean(L, obj1.isEqual(to: obj2) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func group_userdata_gc(_ L: LuaState) throws -> CInt {
    let ptr = luaL_checkudata(L, 1, GROUP_UD_TAG)!
    let _ = Unmanaged<NSMetadataQueryResultGroup>.fromOpaque(ptr.load(as: UnsafeRawPointer.self)).takeRetainedValue()
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

private func item_userdata_tostring(_ L: LuaState) throws -> CInt {
    let obj = get_itemFromUserdata(L, at: 1)
    let title = obj.value(forAttribute: NSMetadataItemFSNameKey) as? String ?? "<undefined>"
    lua_pushany(L, "\(ITEM_UD_TAG): \(title) (\(String(describing: lua_topointer(L, 1)!)))" as NSString)
    return 1
}

private func item_userdata_eq(_ L: LuaState) throws -> CInt {
    if luaL_testudata(L, 1, ITEM_UD_TAG) != nil && luaL_testudata(L, 2, ITEM_UD_TAG) != nil {
        let obj1 = get_itemFromUserdata(L, at: 1)
        let obj2 = get_itemFromUserdata(L, at: 2)
        lua_pushboolean(L, obj1.isEqual(to: obj2) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func item_userdata_gc(_ L: LuaState) throws -> CInt {
    let ptr = luaL_checkudata(L, 1, ITEM_UD_TAG)!
    let _ = Unmanaged<NSMetadataItem>.fromOpaque(ptr.load(as: UnsafeRawPointer.self)).takeRetainedValue()
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

private func meta_gc(_ L: LuaState) throws -> CInt {
    if let queue = moduleSearchQueue {
        queue.cancelAllOperations()
        queue.waitUntilAllOperationsAreFinished()
        moduleSearchQueue = nil
    }
    return 0
}

// MARK: - Module Entry Point

@_cdecl("luaopen_hs_libspotlight")
public func luaopen_hs_libspotlight(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Create ref table in registry
        lua_newtable(L)
        refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

        // Register userdata metatables
        luaL_newmetatable(L, USERDATA_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")
        L.push(spotlight_searchScopes)
        lua_setfield(L, -2, "searchScopes")
        L.push(spotlight_callback)
        lua_setfield(L, -2, "setCallback")
        L.push(spotlight_callbackMessages)
        lua_setfield(L, -2, "callbackMessages")
        L.push(spotlight_updateInterval)
        lua_setfield(L, -2, "updateInterval")
        L.push(spotlight_sortDescriptors)
        lua_setfield(L, -2, "sortDescriptors")
        L.push(spotlight_groupingAttributes)
        lua_setfield(L, -2, "groupingAttributes")
        L.push(spotlight_valueListAttributes)
        lua_setfield(L, -2, "valueListAttributes")
        L.push(spotlight_start)
        lua_setfield(L, -2, "start")
        L.push(spotlight_stop)
        lua_setfield(L, -2, "stop")
        L.push(spotlight_isRunning)
        lua_setfield(L, -2, "isRunning")
        L.push(spotlight_isGathering)
        lua_setfield(L, -2, "isGathering")
        L.push(spotlight_predicate)
        lua_setfield(L, -2, "queryString")
        L.push(spotlight_resultCount)
        lua_setfield(L, -2, "count")
        L.push(spotlight_resultAtIndex)
        lua_setfield(L, -2, "resultAtIndex")
        L.push(spotlight_valueLists)
        lua_setfield(L, -2, "valueLists")
        L.push(spotlight_groupedResults)
        lua_setfield(L, -2, "groupedResults")
        L.push(userdata_tostring)
        lua_setfield(L, -2, "__tostring")
        L.push(userdata_eq)
        lua_setfield(L, -2, "__eq")
        L.push(userdata_gc)
        lua_setfield(L, -2, "__gc")
        lua_pop(L, 1)

        luaL_newmetatable(L, ITEM_UD_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")
        L.push(item_attributes)
        lua_setfield(L, -2, "attributes")
        L.push(item_valueForAttribute)
        lua_setfield(L, -2, "valueForAttribute")
        L.push(item_userdata_tostring)
        lua_setfield(L, -2, "__tostring")
        L.push(item_userdata_eq)
        lua_setfield(L, -2, "__eq")
        L.push(item_userdata_gc)
        lua_setfield(L, -2, "__gc")
        lua_pop(L, 1)

        luaL_newmetatable(L, GROUP_UD_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")
        L.push(group_attribute)
        lua_setfield(L, -2, "attribute")
        L.push(group_value)
        lua_setfield(L, -2, "value")
        L.push(group_resultCount)
        lua_setfield(L, -2, "count")
        L.push(group_resultAtIndex)
        lua_setfield(L, -2, "resultAtIndex")
        L.push(group_subgroups)
        lua_setfield(L, -2, "subgroups")
        L.push(group_userdata_tostring)
        lua_setfield(L, -2, "__tostring")
        L.push(group_userdata_eq)
        lua_setfield(L, -2, "__eq")
        L.push(group_userdata_gc)
        lua_setfield(L, -2, "__gc")
        lua_pop(L, 1)

        // Create module table
        lua_createtable(L, 0, 2)
        L.push(spotlight_new)
        lua_setfield(L, -2, "new")
        L.push(spotlight_searchWithin)
        lua_setfield(L, -2, "newWithin")

        // Set module metatable (for __gc)
        lua_createtable(L, 0, 1)
        L.push(meta_gc)
        lua_setfield(L, -2, "__gc")
        lua_setmetatable(L, -2)

        let _ = push_searchScopes(L)
        lua_setfield(L, -2, "definedSearchScopes")
        let _ = push_commonAttributeKeys(L)
        lua_setfield(L, -2, "commonAttributeKeys")
    }
}
