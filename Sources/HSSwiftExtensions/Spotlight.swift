import Cocoa
import CLua
import Lua
import HSDSTCore
import os.log

private let USERDATA_TAG = "hs.spotlight"
private let ITEM_UD_TAG  = "hs.spotlight.item"
private let GROUP_UD_TAG = "hs.spotlight.group"

private var moduleSearchQueue: OperationQueue?

// MARK: - Support Functions and Classes

private class HSMetadataQuery: NSObject {
    var metadataSearch: NSMetadataQuery
    var callback: LuaValue?
    var generation: UInt64 = 0
    var wantComplete: Bool = true
    var wantProgress: Bool = false
    var wantStart: Bool = false
    var wantUpdate: Bool = false
    private var tornDown = false
    private let notificationService: any NotificationProtocol
    private var observerTokens: [any NotificationObserverToken] = []

    init(notification: any NotificationProtocol) {
        metadataSearch = NSMetadataQuery()
        notificationService = notification
        super.init()

        if moduleSearchQueue == nil { moduleSearchQueue = OperationQueue() }
        metadataSearch.operationQueue = moduleSearchQueue

        observerTokens.append(notification.addObserver(
            name: NSNotification.Name.NSMetadataQueryDidFinishGathering.rawValue, object: metadataSearch
        ) { [weak self] userInfo in
            self?.queryDidFinish(userInfo)
        })
        observerTokens.append(notification.addObserver(
            name: NSNotification.Name.NSMetadataQueryDidStartGathering.rawValue, object: metadataSearch
        ) { [weak self] userInfo in
            self?.queryDidStart(userInfo)
        })
        observerTokens.append(notification.addObserver(
            name: NSNotification.Name.NSMetadataQueryDidUpdate.rawValue, object: metadataSearch
        ) { [weak self] userInfo in
            self?.queryDidUpdate(userInfo)
        })
        observerTokens.append(notification.addObserver(
            name: NSNotification.Name.NSMetadataQueryGatheringProgress.rawValue, object: metadataSearch
        ) { [weak self] userInfo in
            self?.queryProgress(userInfo)
        })
    }

    /// Idempotent teardown: remove notification observers, stop query, drop the
    /// Lua callback reference. Called from __gc while the lua_State is still
    /// alive, and from doCallback when the generation canary fires.
    func teardown() {
        guard !tornDown else {
            assert(callback == nil, "teardown: callback should already be nil after teardown")
            return
        }
        tornDown = true
        for token in observerTokens {
            notificationService.removeObserver(token)
        }
        observerTokens.removeAll()
        if !metadataSearch.isStopped { metadataSearch.stop() }
        callback = nil
    }

    func queryDidFinish(_ userInfo: [String: Any]) {
        if callback != nil && wantComplete { doCallback(for: "didFinish", with: userInfo) }
    }

    func queryDidStart(_ userInfo: [String: Any]) {
        if callback != nil && wantStart { doCallback(for: "didStart", with: userInfo) }
    }

    func queryDidUpdate(_ userInfo: [String: Any]) {
        if callback != nil && wantUpdate { doCallback(for: "didUpdate", with: userInfo) }
    }

    func queryProgress(_ userInfo: [String: Any]) {
        if callback != nil && wantProgress { doCallback(for: "inProgress", with: userInfo) }
    }

    func doCallback(for message: String, with userInfo: [String: Any]) {
        precondition(!message.isEmpty, "doCallback: message must not be empty")
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let cb = self.callback else { return }
            if !lua_isStateGenerationValid(self.generation) {
                self.teardown()
                return
            }
            let L = lua_getCurrentState()!
            cb.push(onto: L)
            L.push(userdata: self)
            lua_pushany(L, message as NSString)
            lua_pushany(L, userInfo as NSDictionary)
            if luaTelemetryPCall(
                L,
                nargs: 3,
                nresults: 0,
                callbackName: "hs.spotlight",
                attributes: ["spotlight.event": message]
            ) != LUA_OK { lua_pop(L, 1) }
        }
    }
}

// MARK: - Module Functions

/// hs.spotlight.new() -> spotlightObject
/// Constructor
/// Creates a new spotlightObject to use for Spotlight searches.
private func spotlight_new(_ L: LuaState) throws -> CInt {
    let query = HSMetadataQuery(notification: environmentGet(L).notification)
    query.generation = lua_currentStateGeneration()
    L.push(userdata: query)
    return 1
}

/// hs.spotlight.newWithin(spotlightObject) -> spotlightObject
/// Constructor
/// Creates a new spotlightObject that limits its searches to the current results of another spotlightObject.
private func spotlight_searchWithin(_ L: LuaState) throws -> CInt {
    let query: HSMetadataQuery = try L.checkArgument(1)

    let newQuery = HSMetadataQuery(notification: environmentGet(L).notification)
    newQuery.generation = lua_currentStateGeneration()
    query.metadataSearch.disableUpdates()
    newQuery.metadataSearch.searchItems = query.metadataSearch.results
    query.metadataSearch.enableUpdates()

    L.push(userdata: newQuery)
    return 1
}

// MARK: - Module Methods

// wrapped in init.lua
private func spotlight_searchScopes(_ L: LuaState) throws -> CInt {
    let query: HSMetadataQuery = try L.checkArgument(1)

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
    let query: HSMetadataQuery = try L.checkArgument(1)

    query.callback = nil
    if lua_type(L, 2) == LUA_TFUNCTION {
        query.callback = L.ref(index: 2)
    }
    lua_pushvalue(L, 1)
    return 1
}

// wrapped in init.lua
private func spotlight_callbackMessages(_ L: LuaState) throws -> CInt {
    let query: HSMetadataQuery = try L.checkArgument(1)

    if lua_gettop(L) == 1 {
        lua_newtable(L)
        if query.wantComplete { L.push("didFinish");  lua_rawseti(L, -2, luaL_len(L, -2) + 1) }
        if query.wantStart    { L.push("didStart");   lua_rawseti(L, -2, luaL_len(L, -2) + 1) }
        if query.wantUpdate   { L.push("didUpdate");  lua_rawseti(L, -2, luaL_len(L, -2) + 1) }
        if query.wantProgress { L.push("inProgress"); lua_rawseti(L, -2, luaL_len(L, -2) + 1) }
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
    let query: HSMetadataQuery = try L.checkArgument(1)

    if lua_gettop(L) == 1 {
        L.push(query.metadataSearch.notificationBatchingInterval)
    } else {
        query.metadataSearch.notificationBatchingInterval = lua_tonumber(L, 2)
        lua_pushvalue(L, 1)
    }
    return 1
}

// wrapped in init.lua
private func spotlight_sortDescriptors(_ L: LuaState) throws -> CInt {
    let query: HSMetadataQuery = try L.checkArgument(1)

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
    let query: HSMetadataQuery = try L.checkArgument(1)

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
    let query: HSMetadataQuery = try L.checkArgument(1)

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
    let query: HSMetadataQuery = try L.checkArgument(1)

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
    let query: HSMetadataQuery = try L.checkArgument(1)

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
    let query: HSMetadataQuery = try L.checkArgument(1)

    L.push(query.metadataSearch.isStarted && !query.metadataSearch.isStopped)
    return 1
}

/// hs.spotlight:isGathering() -> boolean
/// Method
/// Returns a boolean specifying whether or not the query is in the active gathering phase.
private func spotlight_isGathering(_ L: LuaState) throws -> CInt {
    let query: HSMetadataQuery = try L.checkArgument(1)

    L.push(query.metadataSearch.isGathering)
    return 1
}

/// hs.spotlight:queryString(query) -> spotlightObject
/// Method
/// Specify the query string for the spotlightObject
private func spotlight_predicate(_ L: LuaState) throws -> CInt {
    let query: HSMetadataQuery = try L.checkArgument(1)

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
    let query: HSMetadataQuery = try L.checkArgument(1)

    L.push(lua_Integer(query.metadataSearch.resultCount))
    return 1
}

/// hs.spotlight:resultAtIndex(index) -> spotlightItemObject
/// Method
/// Returns the spotlightItemObject at the specified index of the spotlightObject
private func spotlight_resultAtIndex(_ L: LuaState) throws -> CInt {
    let query: HSMetadataQuery = try L.checkArgument(1)

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
    L.push(userdata: item)
    return 1
}

/// hs.spotlight:valueLists() -> table
/// Method
/// Returns the value list summaries for the Spotlight query
private func spotlight_valueLists(_ L: LuaState) throws -> CInt {
    let query: HSMetadataQuery = try L.checkArgument(1)

    pushSpotlightValue(L, query.metadataSearch.valueLists as NSDictionary)
    return 1
}

/// hs.spotlight:groupedResults() -> table
/// Method
/// Returns the grouped results for a Spotlight query.
private func spotlight_groupedResults(_ L: LuaState) throws -> CInt {
    let query: HSMetadataQuery = try L.checkArgument(1)

    pushSpotlightValue(L, query.metadataSearch.groupedResults as NSArray)
    return 1
}

// MARK: - Module Group Methods

/// hs.spotlight.group:attribute() -> string
private func group_attribute(_ L: LuaState) throws -> CInt {
    let resultGroup: NSMetadataQueryResultGroup = try L.checkArgument(1)
    lua_pushany(L, resultGroup.attribute as NSString)
    return 1
}

/// hs.spotlight.group:value() -> value
private func group_value(_ L: LuaState) throws -> CInt {
    let resultGroup: NSMetadataQueryResultGroup = try L.checkArgument(1)
    pushSpotlightValue(L, resultGroup.value as? NSObject)
    return 1
}

/// hs.spotlight.group:count() -> integer
private func group_resultCount(_ L: LuaState) throws -> CInt {
    let resultGroup: NSMetadataQueryResultGroup = try L.checkArgument(1)
    L.push(lua_Integer(resultGroup.resultCount))
    return 1
}

/// hs.spotlight.group:resultAtIndex(index) -> spotlightItemObject
private func group_resultAtIndex(_ L: LuaState) throws -> CInt {
    let resultGroup: NSMetadataQueryResultGroup = try L.checkArgument(1)

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
    let resultGroup: NSMetadataQueryResultGroup = try L.checkArgument(1)
    pushSpotlightValue(L, resultGroup.subgroups as NSArray?)
    return 1
}

// MARK: - Module Item Methods

/// hs.spotlight.item:attributes() -> table
private func item_attributes(_ L: LuaState) throws -> CInt {
    let item: NSMetadataItem = try L.checkArgument(1)
    pushSpotlightValue(L, item.attributes as NSArray)
    return 1
}

/// hs.spotlight.item:valueForAttribute(attribute) -> value
private func item_valueForAttribute(_ L: LuaState) throws -> CInt {
    let item: NSMetadataItem = try L.checkArgument(1)

    luaL_checktype(L, 2, LUA_TSTRING)
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
    precondition(L != nil, "pushSpotlightValue: L must not be nil")
    precondition(depth >= 0, "pushSpotlightValue: depth must be non-negative")
    guard depth < 50 else {
        lua_pushnil(L)
        return
    }

    guard let value else {
        lua_pushnil(L)
        return
    }

    if let query = value as? HSMetadataQuery {
        L.push(userdata: query)
    } else if let group = value as? NSMetadataQueryResultGroup {
        L.push(userdata: group)
    } else if let item = value as? NSMetadataItem {
        L.push(userdata: item)
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
            L.push(key)
            pushSpotlightValue(L, item, depth: depth + 1)
            lua_settable(L, -3)
        }
    } else {
        lua_pushany(L, value)
    }
}

@discardableResult
private func pushNSSortDescriptor(_ L: UnsafeMutablePointer<lua_State>!, obj: Any!) -> Int32 {
    let descriptor = obj as! NSSortDescriptor
    lua_newtable(L)
    lua_pushany(L, descriptor.key! as NSString); lua_setfield(L, -2, "key")
    L.push(descriptor.ascending); lua_setfield(L, -2, "ascending")
    L.push("NSSortDescriptor"); lua_setfield(L, -2, "__luaSkinType")
    return 1
}

private func toNSSortDescriptorFromLua(_ L: UnsafeMutablePointer<lua_State>!, idx: Int32) -> Any! {
    precondition(L != nil, "toNSSortDescriptorFromLua: L must not be nil")
    precondition(idx != 0, "toNSSortDescriptorFromLua: idx must not be 0")
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
    L.push(lua_Integer(count)); lua_setfield(L, -2, "count")
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
    precondition(L != nil, "luaopen_hs_libspotlight: L must not be nil")
    // 1. Register HSMetadataQuery metatable
    L.register(Metatable<HSMetadataQuery>(
        fields: [
            "searchScopes": .closure { L in try spotlight_searchScopes(L) },
            "setCallback": .closure { L in try spotlight_callback(L) },
            "callbackMessages": .closure { L in try spotlight_callbackMessages(L) },
            "updateInterval": .closure { L in try spotlight_updateInterval(L) },
            "sortDescriptors": .closure { L in try spotlight_sortDescriptors(L) },
            "groupingAttributes": .closure { L in try spotlight_groupingAttributes(L) },
            "valueListAttributes": .closure { L in try spotlight_valueListAttributes(L) },
            "start": .closure { L in try spotlight_start(L) },
            "stop": .closure { L in try spotlight_stop(L) },
            "isRunning": .closure { L in try spotlight_isRunning(L) },
            "isGathering": .closure { L in try spotlight_isGathering(L) },
            "queryString": .closure { L in try spotlight_predicate(L) },
            "count": .closure { L in try spotlight_resultCount(L) },
            "resultAtIndex": .closure { L in try spotlight_resultAtIndex(L) },
            "valueLists": .closure { L in try spotlight_valueLists(L) },
            "groupedResults": .closure { L in try spotlight_groupedResults(L) },
        ],
        tostring: .closure { L in
            let obj: HSMetadataQuery = try L.checkArgument(1)
            let title = obj.metadataSearch.predicate?.predicateFormat ?? "<undefined>"
            L.push("\(USERDATA_TAG): \(title) (\(String(describing: Unmanaged.passUnretained(obj).toOpaque())))")
            return 1
        }
    ))

    // Post-registration __gc patch for HSMetadataQuery
    L.pushMetatable(for: HSMetadataQuery.self)

    // Replace __gc with teardown + deinitialize
    L.push({ (L: LuaState!) -> CInt in
        if let query: HSMetadataQuery = L.touserdata(1) {
            query.teardown()
        }
        let rawptr = lua_touserdata(L, 1)!
        let anyPtr = rawptr.assumingMemoryBound(to: Any.self)
        anyPtr.deinitialize(count: 1)
        return 0
    })
    lua_setfield(L, -2, "__gc")

    // __eq for HSMetadataQuery
    L.push({ (L: LuaState!) -> CInt in
        if let obj1: HSMetadataQuery = L.touserdata(1),
           let obj2: HSMetadataQuery = L.touserdata(2) {
            L.push(obj1.isEqual(obj2))
        } else {
            L.push(false)
        }
        return 1
    })
    lua_setfield(L, -2, "__eq")

    // Set __type and __name
    L.push(USERDATA_TAG)
    lua_setfield(L, -2, "__type")
    L.push(USERDATA_TAG)
    lua_setfield(L, -2, "__name")

    // Registry alias so core_getObjectMetatable("hs.spotlight") resolves
    lua_setfield(L, LUA_REGISTRYINDEX_VALUE, USERDATA_TAG)

    // 2. Register NSMetadataItem metatable
    L.register(Metatable<NSMetadataItem>(
        fields: [
            "attributes": .closure { L in try item_attributes(L) },
            "valueForAttribute": .closure { L in try item_valueForAttribute(L) },
        ],
        tostring: .closure { L in
            let obj: NSMetadataItem = try L.checkArgument(1)
            let title = obj.value(forAttribute: NSMetadataItemFSNameKey) as? String ?? "<undefined>"
            L.push("\(ITEM_UD_TAG): \(title) (\(String(describing: lua_topointer(L, 1)!)))")
            return 1
        }
    ))

    // Post-registration patch for NSMetadataItem
    L.pushMetatable(for: NSMetadataItem.self)

    // __eq for NSMetadataItem
    L.push({ (L: LuaState!) -> CInt in
        if let obj1: NSMetadataItem = L.touserdata(1),
           let obj2: NSMetadataItem = L.touserdata(2) {
            L.push(obj1.isEqual(obj2))
        } else {
            L.push(false)
        }
        return 1
    })
    lua_setfield(L, -2, "__eq")

    // Set __type and __name
    L.push(ITEM_UD_TAG)
    lua_setfield(L, -2, "__type")
    L.push(ITEM_UD_TAG)
    lua_setfield(L, -2, "__name")

    // Registry alias
    lua_setfield(L, LUA_REGISTRYINDEX_VALUE, ITEM_UD_TAG)

    // 3. Register NSMetadataQueryResultGroup metatable
    L.register(Metatable<NSMetadataQueryResultGroup>(
        fields: [
            "attribute": .closure { L in try group_attribute(L) },
            "value": .closure { L in try group_value(L) },
            "count": .closure { L in try group_resultCount(L) },
            "resultAtIndex": .closure { L in try group_resultAtIndex(L) },
            "subgroups": .closure { L in try group_subgroups(L) },
        ],
        tostring: .closure { L in
            let obj: NSMetadataQueryResultGroup = try L.checkArgument(1)
            let title = obj.attribute
            L.push("\(GROUP_UD_TAG): \(title) (\(String(describing: lua_topointer(L, 1)!)))")
            return 1
        }
    ))

    // Post-registration patch for NSMetadataQueryResultGroup
    L.pushMetatable(for: NSMetadataQueryResultGroup.self)

    // __eq for NSMetadataQueryResultGroup
    L.push({ (L: LuaState!) -> CInt in
        if let obj1: NSMetadataQueryResultGroup = L.touserdata(1),
           let obj2: NSMetadataQueryResultGroup = L.touserdata(2) {
            L.push(obj1.isEqual(obj2))
        } else {
            L.push(false)
        }
        return 1
    })
    lua_setfield(L, -2, "__eq")

    // Set __type and __name
    L.push(GROUP_UD_TAG)
    lua_setfield(L, -2, "__type")
    L.push(GROUP_UD_TAG)
    lua_setfield(L, -2, "__name")

    // Registry alias
    lua_setfield(L, LUA_REGISTRYINDEX_VALUE, GROUP_UD_TAG)

    // 4. Build module table
    lua_createtable(L, 0, 4)
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

    return 1
}
