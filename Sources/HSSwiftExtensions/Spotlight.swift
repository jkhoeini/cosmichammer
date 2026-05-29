import Cocoa
import CLua
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
            lua_pushany(L, self)
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
private func spotlight_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_pushany(L, HSMetadataQuery())
    return 1
}

/// hs.spotlight.newWithin(spotlightObject) -> spotlightObject
/// Constructor
/// Creates a new spotlightObject that limits its searches to the current results of another spotlightObject.
private func spotlight_searchWithin(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let query = lua_tovalue(L, at: 1) as! HSMetadataQuery

    let newQuery = HSMetadataQuery()
    query.metadataSearch.disableUpdates()
    newQuery.metadataSearch.searchItems = query.metadataSearch.results
    query.metadataSearch.enableUpdates()

    lua_pushany(L, newQuery)
    return 1
}

// MARK: - Module Methods

// wrapped in init.lua
private func spotlight_searchScopes(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let query = lua_tovalue(L, at: 1) as! HSMetadataQuery

    if lua_gettop(L) == 1 {
        lua_pushany(L, query.metadataSearch.searchScopes as NSArray)
    } else {
        var newScopes: [Any] = []
        var errorMessage: String?
        guard let items = lua_tovalue(L, at: 2) else {
            errorMessage = "unexpected type conversion error"
            return luaL_argerror(L, 2, errorMessage!)
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
            return luaL_argerror(L, 2, err)
        }
        query.metadataSearch.searchScopes = newScopes
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.spotlight:setCallback(fn) -> spotlightObject
/// Method
/// Set or remove the callback function for the Spotlight search object.
private func spotlight_callback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let query = lua_tovalue(L, at: 1) as! HSMetadataQuery

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
private func spotlight_callbackMessages(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let query = lua_tovalue(L, at: 1) as! HSMetadataQuery

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
            return luaL_argerror(L, 2, "expected string or array of strings")
        }
        let validMessages = ["didFinish", "didStart", "didUpdate", "inProgress"]
        for (idx, obj) in items.enumerated() {
            guard let str = obj as? String else {
                return luaL_argerror(L, 2, "index \(idx + 1) is not a string")
            }
            if !validMessages.contains(str) {
                return luaL_argerror(L, 2, "index \(idx + 1) must be one of '\(validMessages.joined(separator: "', '"))'")
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
private func spotlight_updateInterval(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let query = lua_tovalue(L, at: 1) as! HSMetadataQuery

    if lua_gettop(L) == 1 {
        lua_pushnumber(L, query.metadataSearch.notificationBatchingInterval)
    } else {
        query.metadataSearch.notificationBatchingInterval = lua_tonumber(L, 2)
        lua_pushvalue(L, 1)
    }
    return 1
}

// wrapped in init.lua
private func spotlight_sortDescriptors(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let query = lua_tovalue(L, at: 1) as! HSMetadataQuery

    if lua_gettop(L) == 1 {
        lua_pushany(L, query.metadataSearch.sortDescriptors as NSArray)
    } else {
        var newDescriptors: [NSSortDescriptor] = []
        var errorMessage: String?
        guard let hopefuls = lua_tovalue(L, at: 2) else {
            return luaL_argerror(L, 2, "unexpected type conversion error")
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
            return luaL_argerror(L, 2, err)
        }
        query.metadataSearch.sortDescriptors = newDescriptors
        lua_pushvalue(L, 1)
    }
    return 1
}

// wrapped in init.lua
private func spotlight_valueListAttributes(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let query = lua_tovalue(L, at: 1) as! HSMetadataQuery

    if lua_gettop(L) == 1 {
        lua_pushany(L, query.metadataSearch.valueListAttributes as NSArray)
    } else {
        var newAttributes: [String]
        if let str = lua_tovalue(L, at: 2) as? String {
            newAttributes = [str]
        } else if let arr = lua_tovalue(L, at: 2) as? [String] {
            newAttributes = arr
        } else {
            return luaL_argerror(L, 2, "expected an array of attribute strings")
        }
        query.metadataSearch.valueListAttributes = newAttributes
        lua_pushvalue(L, 1)
    }
    return 1
}

// wrapped in init.lua
private func spotlight_groupingAttributes(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let query = lua_tovalue(L, at: 1) as! HSMetadataQuery

    if lua_gettop(L) == 1 {
        lua_pushany(L, query.metadataSearch.groupingAttributes as NSArray?)
    } else {
        var newAttributes: [String]
        if let str = lua_tovalue(L, at: 2) as? String {
            newAttributes = [str]
        } else if let arr = lua_tovalue(L, at: 2) as? [String] {
            newAttributes = arr
        } else {
            return luaL_argerror(L, 2, "expected an array of attribute strings")
        }
        query.metadataSearch.groupingAttributes = newAttributes
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.spotlight:start() -> spotlightObject
/// Method
/// Begin the gathering phase of a Spotlight query.
private func spotlight_start(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let query = lua_tovalue(L, at: 1) as! HSMetadataQuery

    if query.metadataSearch.isStarted && !query.metadataSearch.isStopped {
        os_log(.info, "%{public}s", "query already started")
    } else {
        if query.metadataSearch.predicate != nil {
            query.metadataSearch.operationQueue?.addOperation {
                query.metadataSearch.start()
            }
        } else {
            return luaL_error(L, "no query defined")
        }
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.spotlight:stop() -> spotlightObject
/// Method
/// Stop the Spotlight query.
private func spotlight_stop(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let query = lua_tovalue(L, at: 1) as! HSMetadataQuery

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
private func spotlight_isRunning(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let query = lua_tovalue(L, at: 1) as! HSMetadataQuery

    lua_pushboolean(L, (query.metadataSearch.isStarted && !query.metadataSearch.isStopped) ? 1 : 0)
    return 1
}

/// hs.spotlight:isGathering() -> boolean
/// Method
/// Returns a boolean specifying whether or not the query is in the active gathering phase.
private func spotlight_isGathering(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let query = lua_tovalue(L, at: 1) as! HSMetadataQuery

    lua_pushboolean(L, query.metadataSearch.isGathering ? 1 : 0)
    return 1
}

/// hs.spotlight:queryString(query) -> spotlightObject
/// Method
/// Specify the query string for the spotlightObject
private func spotlight_predicate(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let query = lua_tovalue(L, at: 1) as! HSMetadataQuery

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
private func spotlight_resultCount(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let query = lua_tovalue(L, at: 1) as! HSMetadataQuery

    lua_pushinteger(L, lua_Integer(query.metadataSearch.resultCount))
    return 1
}

/// hs.spotlight:resultAtIndex(index) -> spotlightItemObject
/// Method
/// Returns the spotlightItemObject at the specified index of the spotlightObject
private func spotlight_resultAtIndex(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let query = lua_tovalue(L, at: 1) as! HSMetadataQuery

    let index = lua_tointeger(L, 2)
    let count = query.metadataSearch.resultCount
    if index < 1 || index > lua_Integer(count) {
        if count == 0 {
            return luaL_argerror(L, 2, "result set is empty")
        } else {
            return luaL_argerror(L, 2, "index must be between 1 and \(count) inclusive")
        }
    }
    query.metadataSearch.disableUpdates()
    let item = query.metadataSearch.result(at: Int(index - 1)) as! NSMetadataItem
    query.metadataSearch.enableUpdates()
    lua_pushany(L, item)
    return 1
}

/// hs.spotlight:valueLists() -> table
/// Method
/// Returns the value list summaries for the Spotlight query
private func spotlight_valueLists(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let query = lua_tovalue(L, at: 1) as! HSMetadataQuery

    lua_pushany(L, query.metadataSearch.valueLists as NSDictionary)
    return 1
}

/// hs.spotlight:groupedResults() -> table
/// Method
/// Returns the grouped results for a Spotlight query.
private func spotlight_groupedResults(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let query = lua_tovalue(L, at: 1) as! HSMetadataQuery

    lua_pushany(L, query.metadataSearch.groupedResults as NSArray)
    return 1
}

// MARK: - Module Group Methods

/// hs.spotlight.group:attribute() -> string
private func group_attribute(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, GROUP_UD_TAG)
    let resultGroup = lua_tovalue(L, at: 1) as! NSMetadataQueryResultGroup
    lua_pushany(L, resultGroup.attribute as NSString)
    return 1
}

/// hs.spotlight.group:value() -> value
private func group_value(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, GROUP_UD_TAG)
    let resultGroup = lua_tovalue(L, at: 1) as! NSMetadataQueryResultGroup
    lua_pushany(L, resultGroup.value as? NSObject)
    return 1
}

/// hs.spotlight.group:count() -> integer
private func group_resultCount(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, GROUP_UD_TAG)
    let resultGroup = lua_tovalue(L, at: 1) as! NSMetadataQueryResultGroup
    lua_pushinteger(L, lua_Integer(resultGroup.resultCount))
    return 1
}

/// hs.spotlight.group:resultAtIndex(index) -> spotlightItemObject
private func group_resultAtIndex(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let resultGroup = lua_tovalue(L, at: 1) as! NSMetadataQueryResultGroup

    let index = lua_tointeger(L, 2)
    let count = resultGroup.resultCount
    if index < 1 || index > lua_Integer(count) {
        if count == 0 {
            return luaL_argerror(L, 2, "result set is empty")
        } else {
            return luaL_argerror(L, 2, "index must be between 1 and \(count) inclusive")
        }
    }
    lua_pushany(L, resultGroup.result(at: Int(index - 1)) as? NSObject)
    return 1
}

/// hs.spotlight.group:subgroups() -> table
private func group_subgroups(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, GROUP_UD_TAG)
    let resultGroup = lua_tovalue(L, at: 1) as! NSMetadataQueryResultGroup
    lua_pushany(L, resultGroup.subgroups as NSArray?)
    return 1
}

// MARK: - Module Item Methods

/// hs.spotlight.item:attributes() -> table
private func item_attributes(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, ITEM_UD_TAG)
    let item = lua_tovalue(L, at: 1) as! NSMetadataItem
    lua_pushany(L, item.attributes as NSArray)
    return 1
}

/// hs.spotlight.item:valueForAttribute(attribute) -> value
private func item_valueForAttribute(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, ITEM_UD_TAG)

    luaL_checktype(L, 2, LUA_TSTRING)
    let item = lua_tovalue(L, at: 1) as! NSMetadataItem
    let attribute = lua_tovalue(L, at: 2) as! String
    lua_pushany(L, item.value(forAttribute: attribute) as? NSObject)
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

private func pushNSMetadataQueryAttributeValueTuple(_ L: UnsafeMutablePointer<lua_State>!, obj: Any!) -> Int32 {
    let tuple = obj as! NSMetadataQueryAttributeValueTuple
    lua_newtable(L)
    lua_pushany(L, tuple.attribute as NSString); lua_setfield(L, -2, "attribute")
    lua_pushinteger(L, lua_Integer(tuple.count)); lua_setfield(L, -2, "count")
    lua_pushany(L, tuple.value as? NSObject); lua_setfield(L, -2, "value")
    return 1
}

// MARK: - Cosmic Hammer/Lua Infrastructure

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let obj = lua_tovalue(L, at: 1) as! HSMetadataQuery
    let title = obj.metadataSearch.predicate?.predicateFormat ?? "<undefined>"
    lua_pushany(L, "\(USERDATA_TAG): \(title) (\(String(describing: Unmanaged.passUnretained(obj).toOpaque())))" as NSString)
    return 1
}

private func userdata_eq(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let obj1 = lua_tovalue(L, at: 1) as! HSMetadataQuery
        let obj2 = lua_tovalue(L, at: 2) as! HSMetadataQuery
        lua_pushboolean(L, obj1.isEqual(to: obj2) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func userdata_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
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

private func group_userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let obj = lua_tovalue(L, at: 1) as! NSMetadataQueryResultGroup
    let title = obj.attribute
    lua_pushany(L, "\(GROUP_UD_TAG): \(title) (\(String(describing: lua_topointer(L, 1)!)))" as NSString)
    return 1
}

private func group_userdata_eq(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if luaL_testudata(L, 1, GROUP_UD_TAG) != nil && luaL_testudata(L, 2, GROUP_UD_TAG) != nil {
        let obj1 = lua_tovalue(L, at: 1) as! NSMetadataQueryResultGroup
        let obj2 = lua_tovalue(L, at: 2) as! NSMetadataQueryResultGroup
        lua_pushboolean(L, obj1.isEqual(to: obj2) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func group_userdata_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let ptr = luaL_checkudata(L, 1, GROUP_UD_TAG)!
    let _ = Unmanaged<NSMetadataQueryResultGroup>.fromOpaque(ptr.load(as: UnsafeRawPointer.self)).takeRetainedValue()
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

private func item_userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let obj = lua_tovalue(L, at: 1) as! NSMetadataItem
    let title = obj.value(forAttribute: NSMetadataItemFSNameKey) as? String ?? "<undefined>"
    lua_pushany(L, "\(ITEM_UD_TAG): \(title) (\(String(describing: lua_topointer(L, 1)!)))" as NSString)
    return 1
}

private func item_userdata_eq(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if luaL_testudata(L, 1, ITEM_UD_TAG) != nil && luaL_testudata(L, 2, ITEM_UD_TAG) != nil {
        let obj1 = lua_tovalue(L, at: 1) as! NSMetadataItem
        let obj2 = lua_tovalue(L, at: 2) as! NSMetadataItem
        lua_pushboolean(L, obj1.isEqual(to: obj2) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func item_userdata_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let ptr = luaL_checkudata(L, 1, ITEM_UD_TAG)!
    let _ = Unmanaged<NSMetadataItem>.fromOpaque(ptr.load(as: UnsafeRawPointer.self)).takeRetainedValue()
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

private func meta_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if let queue = moduleSearchQueue {
        queue.cancelAllOperations()
        queue.waitUntilAllOperationsAreFinished()
        moduleSearchQueue = nil
    }
    return 0
}

// MARK: - luaL_Reg tables

private var userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("searchScopes"), func: spotlight_searchScopes),
    luaL_Reg(name: strdup("setCallback"), func: spotlight_callback),
    luaL_Reg(name: strdup("callbackMessages"), func: spotlight_callbackMessages),
    luaL_Reg(name: strdup("updateInterval"), func: spotlight_updateInterval),
    luaL_Reg(name: strdup("sortDescriptors"), func: spotlight_sortDescriptors),
    luaL_Reg(name: strdup("groupingAttributes"), func: spotlight_groupingAttributes),
    luaL_Reg(name: strdup("valueListAttributes"), func: spotlight_valueListAttributes),
    luaL_Reg(name: strdup("start"), func: spotlight_start),
    luaL_Reg(name: strdup("stop"), func: spotlight_stop),
    luaL_Reg(name: strdup("isRunning"), func: spotlight_isRunning),
    luaL_Reg(name: strdup("isGathering"), func: spotlight_isGathering),
    luaL_Reg(name: strdup("queryString"), func: spotlight_predicate),
    luaL_Reg(name: strdup("count"), func: spotlight_resultCount),
    luaL_Reg(name: strdup("resultAtIndex"), func: spotlight_resultAtIndex),
    luaL_Reg(name: strdup("valueLists"), func: spotlight_valueLists),
    luaL_Reg(name: strdup("groupedResults"), func: spotlight_groupedResults),
    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: strdup("__eq"), func: userdata_eq),
    luaL_Reg(name: strdup("__gc"), func: userdata_gc),
    luaL_Reg(name: nil, func: nil)
]

private var item_userdata_metalib: [luaL_Reg] = [
    luaL_Reg(name: strdup("attributes"), func: item_attributes),
    luaL_Reg(name: strdup("valueForAttribute"), func: item_valueForAttribute),
    luaL_Reg(name: strdup("__tostring"), func: item_userdata_tostring),
    luaL_Reg(name: strdup("__eq"), func: item_userdata_eq),
    luaL_Reg(name: strdup("__gc"), func: item_userdata_gc),
    luaL_Reg(name: nil, func: nil)
]

private var group_userdata_metalib: [luaL_Reg] = [
    luaL_Reg(name: strdup("attribute"), func: group_attribute),
    luaL_Reg(name: strdup("value"), func: group_value),
    luaL_Reg(name: strdup("count"), func: group_resultCount),
    luaL_Reg(name: strdup("resultAtIndex"), func: group_resultAtIndex),
    luaL_Reg(name: strdup("subgroups"), func: group_subgroups),
    luaL_Reg(name: strdup("__tostring"), func: group_userdata_tostring),
    luaL_Reg(name: strdup("__eq"), func: group_userdata_eq),
    luaL_Reg(name: strdup("__gc"), func: group_userdata_gc),
    luaL_Reg(name: nil, func: nil)
]

private var moduleLib_arr: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"), func: spotlight_new),
    luaL_Reg(name: strdup("newWithin"), func: spotlight_searchWithin),
    luaL_Reg(name: nil, func: nil)
]

private var module_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: meta_gc),
    luaL_Reg(name: nil, func: nil)
]

// MARK: - Module Entry Point

@_cdecl("luaopen_hs_libspotlight")
public func luaopen_hs_libspotlight(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Create ref table in registry
    lua_newtable(L)
    refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    // Register userdata metatables
    luaL_newmetatable(L, USERDATA_TAG)
    lua_pushvalue(L, -1)
    lua_setfield(L, -2, "__index")
    luaL_setfuncs(L, &userdata_metaLib, 0)
    lua_pop(L, 1)

    luaL_newmetatable(L, ITEM_UD_TAG)
    lua_pushvalue(L, -1)
    lua_setfield(L, -2, "__index")
    luaL_setfuncs(L, &item_userdata_metalib, 0)
    lua_pop(L, 1)

    luaL_newmetatable(L, GROUP_UD_TAG)
    lua_pushvalue(L, -1)
    lua_setfield(L, -2, "__index")
    luaL_setfuncs(L, &group_userdata_metalib, 0)
    lua_pop(L, 1)

    // Create module table
    lua_createtable(L, 0, Int32(moduleLib_arr.count - 1))
    luaL_setfuncs(L, &moduleLib_arr, 0)

    // Set module metatable (for __gc)
    lua_createtable(L, 0, Int32(module_metaLib.count - 1))
    luaL_setfuncs(L, &module_metaLib, 0)
    lua_setmetatable(L, -2)

    let _ = push_searchScopes(L);        lua_setfield(L, -2, "definedSearchScopes")
    let _ = push_commonAttributeKeys(L); lua_setfield(L, -2, "commonAttributeKeys")

    return 1
}
