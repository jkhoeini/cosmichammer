import Cocoa
import CLua
import Lua
import os.log

private let USERDATA_TAG = "hs.doc" // we're using it as a module tag for console messages

private var triggerFn: LuaValue?

private var registeredFiles: NSMutableDictionary!
private var documentationTree: NSMutableDictionary!

// MARK: - Support Functions and Classes

func docSortFunction(_ a: NSString, _ b: NSString, _ context: UnsafeMutableRawPointer?) -> NSInteger {
    var error: NSError?
    var parser: NSRegularExpression?
    do {
        parser = try NSRegularExpression(pattern: "^_\\d[\\d_]*", options: .useUnicodeWordBoundaries)
    } catch let e as NSError {
        error = e
    }

    if error == nil, let parser = parser {
        let aMatch = parser.firstMatch(in: a as String, options: [], range: NSRange(location: 0, length: a.length))
        let bMatch = parser.firstMatch(in: b as String, options: [], range: NSRange(location: 0, length: b.length))

        if let aRange = aMatch?.range, aRange.length != 0,
           let bRange = bMatch?.range, bRange.length != 0 {
            let aTag = a.substring(with: aRange)
            let bTag = b.substring(with: bRange)

            var parser2: NSRegularExpression?
            do {
                parser2 = try NSRegularExpression(pattern: "\\d+", options: .useUnicodeWordBoundaries)
            } catch let e as NSError {
                error = e
            }

            if error == nil, let parser2 = parser2 {
                let aNumericParts = parser2.matches(in: aTag, options: [], range: NSRange(location: 0, length: (aTag as NSString).length))
                let bNumericParts = parser2.matches(in: bTag, options: [], range: NSRange(location: 0, length: (bTag as NSString).length))

                let minCount = min(aNumericParts.count, bNumericParts.count)
                let f = NumberFormatter()
                f.numberStyle = .none
                for i in 0..<minCount {
                    let aPartMatch = aNumericParts[i]
                    let bPartMatch = bNumericParts[i]
                    let aNumber = f.number(from: (a as String).substring(with: aPartMatch.range))
                    let bNumber = f.number(from: (b as String).substring(with: bPartMatch.range))
                    if let aNum = aNumber, let bNum = bNumber {
                        let test = aNum.compare(bNum)
                        if test != .orderedSame { return NSInteger(test.rawValue) }
                    }
                }
                if aNumericParts.count < bNumericParts.count { return NSInteger(ComparisonResult.orderedAscending.rawValue) }
                if aNumericParts.count > bNumericParts.count { return NSInteger(ComparisonResult.orderedDescending.rawValue) }
                return NSInteger(ComparisonResult.orderedSame.rawValue)
            } else {
                os_log(.error, "%{public}s","\(USERDATA_TAG).docSortFunction - error initializing 2nd regex: \(error?.localizedDescription ?? "unknown")")
            }
        }
    } else {
        os_log(.error, "%{public}s","\(USERDATA_TAG).docSortFunction - error initializing regex: \(error?.localizedDescription ?? "unknown")")
    }
    return NSInteger(a.caseInsensitiveCompare(b as String).rawValue)
}

private extension String {
    func substring(with nsRange: NSRange) -> String {
        guard let range = Range(nsRange, in: self) else { return "" }
        return String(self[range])
    }
}

private func processRegisteredFile(_ L: UnsafeMutablePointer<lua_State>!, _ path: NSString) -> Bool {

    var error: NSError?
    var rawFile: Data?
    do {
        rawFile = try Data(contentsOf: URL(fileURLWithPath: path as String), options: .mappedIfSafe)
    } catch let e as NSError {
        error = e
    }
    guard let rawFile = rawFile, error == nil else {
        os_log(.error, "%{public}s", "\(USERDATA_TAG).processRegisteredFile - unable to open '\(path)' (\(error?.localizedDescription ?? "unknown"))")
        return false
    }

    var obj: Any?
    do {
        obj = try JSONSerialization.jsonObject(with: rawFile, options: .fragmentsAllowed)
    } catch let e as NSError {
        error = e
    }
    if let error = error {
        os_log(.error, "%{public}s", "\(USERDATA_TAG).processRegisteredFile - error parsing JSON for \(path): \(error.localizedDescription)")
        return false
    }
    guard let obj = obj else {
        os_log(.error, "%{public}s", "\(USERDATA_TAG).processRegisteredFile - error parsing JSON for \(path): input resolved to nil")
        return false
    }

    (registeredFiles[path] as! NSMutableDictionary)["json"] = obj

    let root: NSMutableDictionary = documentationTree

    guard let objArray = obj as? NSArray else {
        os_log(.error, "%{public}s", "\(USERDATA_TAG).processRegisteredFile - malformed documentation file \(path): proper format requires an array of entries")
        return false
    }

    var regexError: NSError?
    var parser: NSRegularExpression?
    do {
        parser = try NSRegularExpression(pattern: "[\\w_]+", options: .useUnicodeWordBoundaries)
    } catch let e as NSError {
        regexError = e
    }

    if regexError == nil, let parser = parser {
        for (idx, element) in objArray.enumerated() {
            var pos = root

            guard let entry = element as? NSDictionary, let entryName = entry["name"] as? NSString else {
                os_log(.error, "%{public}s", "\(USERDATA_TAG).processRegisteredFile - malformed entry in \(path) -- expected module dictionary with 'name' key at index \(idx + 1) in \(path); skipping")
                continue
            }

            parser.enumerateMatches(in: entryName as String, options: [], range: NSRange(location: 0, length: entryName.length)) { match, _, _ in
                guard let match = match else { return }
                let part = entryName.substring(with: match.range)
                if pos[part] == nil {
                    pos[part] = NSMutableDictionary(dictionary: ["__type__": "placeholder"])
                }
                pos = pos[part] as! NSMutableDictionary
            }

            if pos["__json__"] != nil {
                // FIXME: Duplicate Handling
                //    In theory additions or changes to the module could be defined elsewhere. Bad style, so log anyways, and we'll
                //    decide how to officially handle it if it becomes normal as opposed to an "in-development" shortcut. For now,
                //    assume since coredocs are loaded first, that this is an in-progress update that should overwrite the original.
                os_log(.info, "%{public}s", "\(USERDATA_TAG).processRegisteredFile - duplicate module entry in \(path) for \(entryName) (\(entry["desc"] ?? ""))")
            }
            pos["__json__"] = entry
            pos["__type__"] = "module" // this is more than a placeholder now

            if let itemsAttached = entry["items"] {
                guard let itemsArray = itemsAttached as? NSArray else {
                    os_log(.info, "%{public}s", "\(USERDATA_TAG).processRegisteredFile - malformed entry in \(path) -- expected array or nil in 'items' key for \(entryName) at index \(idx + 1); skipping")
                    continue
                }

                for (idx2, itemElement) in itemsArray.enumerated() {
                    guard let itemEntry = itemElement as? NSDictionary, let itemName = itemEntry["name"] as? NSString else {
                        os_log(.info, "%{public}s", "\(USERDATA_TAG).processRegisteredFile - malformed entry in \(path) -- expected item dictionary with 'name' key for \(entryName) at index \(idx2 + 1); skipping")
                        continue
                    }

                    if let match = parser.firstMatch(in: itemName as String, options: [], range: NSRange(location: 0, length: itemName.length)),
                       match.range.location != NSNotFound {
                        let part = itemName.substring(with: match.range)
                        if pos[part] != nil {
                            // FIXME: Duplicate Handling
                            //     See above for current behavior and reasoning
                            os_log(.info, "%{public}s", "\(USERDATA_TAG).processRegisteredFile - duplicate item in \(path): \(itemName) (\(entry["def"] ?? "")) for \(entryName)")
                        }
                        let itemDict = NSMutableDictionary(dictionary: ["__type__": "entry"])
                        itemDict["__json__"] = itemEntry
                        pos[part] = itemDict
                    } else {
                        os_log(.info, "%{public}s", "\(USERDATA_TAG).processRegisteredFile - malformed entry in \(path) -- item name (\(itemName)) invalid for \(entryName) at index \(idx2 + 1); skipping")
                    }
                }
            } // no items at all is ok, we only log when items isn't an array
        }

        // make sure watchers knows that something has changed
        if let fn = triggerFn {
            fn.push(onto: L)
            lua_call(L, 0, 0)
        }
    } else {
        os_log(.error, "%{public}s", "\(USERDATA_TAG).processRegisteredFile - error initializing regex: \(regexError?.localizedDescription ?? "unknown")")
    }

    return true
}

private func findUnloadedDocumentationFiles(_ L: UnsafeMutablePointer<lua_State>!) {
    for path in registeredFiles.allKeys {
        let entry = registeredFiles[path] as! NSMutableDictionary
        if entry["json"] == nil {
            _ = processRegisteredFile(L, path as! NSString)
        }
    }
}

func getPosInTreeFor(_ target: NSString) -> NSMutableDictionary? {
    var pos: NSMutableDictionary?

    var error: NSError?
    var parser: NSRegularExpression?
    do {
        parser = try NSRegularExpression(pattern: "[^.]+", options: .useUnicodeWordBoundaries)
    } catch let e as NSError {
        error = e
    }

    if error == nil, let parser = parser {
        pos = documentationTree
        parser.enumerateMatches(in: target as String, options: [], range: NSRange(location: 0, length: target.length)) { match, _, stop in
            guard let match = match, let currentPos = pos else {
                stop.pointee = true
                return
            }
            let part = target.substring(with: match.range)
            if let next = currentPos[part] as? NSMutableDictionary {
                pos = next
            } else {
                pos = nil
                stop.pointee = true
            }
        }
    } else {
        os_log(.error, "%{public}s","\(USERDATA_TAG).getPosInTreeFor - error initializing regex: \(error?.localizedDescription ?? "unknown")")
    }

    return pos
}

// MARK: - Module Functions

// documented in init.lua
private func doc_help(_ L: LuaState) throws -> CInt {
    var identifier: NSString = ""
    if lua_gettop(L) == 1 && lua_type(L, 1) == LUA_TSTRING {
        identifier = lua_tovalue(L, at: 1) as! NSString
    }

    findUnloadedDocumentationFiles(L)

    var result = NSMutableString()

    let pos = getPosInTreeFor(identifier)

    if let pos = pos {
        result = NSMutableString()

        let typeStr = pos["__type__"] as? String

        if typeStr == "root" {
            result.append("[modules]\n")
            let children = (pos.allKeys as! [String]).sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
            for entry in children {
                if !(entry.hasPrefix("__") && entry.hasSuffix("__")) {
                    result.appendFormat("%@\n", entry as NSString)
                }
            }
        } else if let json = pos["__json__"] as? NSDictionary, json["items"] == nil {
            let signature = (json["signature"] as? String) ?? (json["def"] as? String) ?? ""
            result.appendFormat("%@: %@\n\n%@\n",
                (json["type"] as? NSString) ?? "",
                signature as NSString,
                (json["doc"] as? NSString) ?? ""
            )
        } else {
            if let json = pos["__json__"] as? NSDictionary {
                result.appendFormat("%@", (json["doc"] as? NSString) ?? "")
            } else {
                result.append("** DOCUMENTATION MISSING **")
            }
            let submodules = NSMutableString()
            let items = NSMutableString()
            let children = (pos.allKeys as! [String]).sorted { a, b in
                ComparisonResult(rawValue: docSortFunction(a as NSString, b as NSString, nil))! == .orderedAscending
            }

            for entry in children {
                if !(entry.hasPrefix("__") && entry.hasSuffix("__")) {
                    let entryDict = pos[entry] as? NSDictionary
                    let entryJson = entryDict?["__json__"] as? NSDictionary
                    let entryType = entryJson?["type"] as? String

                    if entryJson == nil || entryType == nil || entryType == "Module" {
                        submodules.appendFormat("%@\n", entry as NSString)
                    } else {
                        let itemSignature = (entryJson?["signature"] as? String) ?? (entryJson?["def"] as? String) ?? ""
                        items.appendFormat("%@\n", itemSignature as NSString)
                    }
                }
            }
            result.appendFormat("\n\n[submodules]\n%@\n[items]\n%@\n", submodules, items)
        }
    }

    lua_pushany(L, result)
    return 1
}

/// hs.doc.registerJSONFile(jsonfile) -> status[, message]
/// Function
/// Register a JSON file for inclusion when Cosmic Hammer generates internal documentation.
///
/// Parameters:
///  * jsonfile - A string containing the location of a JSON file
///
/// Returns:
///  * status - Boolean flag indicating if the file was registered or not.  If the file was not registered, then a message indicating the error is also returned.
///
/// Notes:
///  * this function just registers the documentation file; it won't actually be loaded and parsed until [hs.doc.help](#help) is invoked.
private func doc_registerJSONFile(_ L: LuaState) throws -> CInt {
    var path = String(cString: luaL_checkstring(L, 1)) as NSString

    // some tricks used to figure out if the docs.json file exists duplicate final "/" before "docs.json"
    // so rather then track them all down, just adjust it here; otherwise we have two "different" paths
    // containing the same data and get a lot of duplicate entry warnings
    path = (path.standardizingPath as NSString).resolvingSymlinksInPath as NSString

    if registeredFiles[path] != nil {
        lua_pushboolean(L, 0)
        lua_pushany(L, "File '\(path)' already registered" as NSString)
        return 2
    }

    registeredFiles[path] = NSMutableDictionary()

    // changecount function will be triggered when json built in findUnloadedDocumentationFiles for new path

    lua_pushboolean(L, 1)
    return 1
}

/// hs.doc.unregisterJSONFile(jsonfile) -> status[, message]
/// Function
/// Remove a JSON file from the list of registered files.
///
/// Parameters:
///  * jsonfile - A string containing the location of a JSON file
///
/// Returns:
///  * status - Boolean flag indicating if the file was unregistered or not.  If the file was not unregistered, then a message indicating the error is also returned.
///
/// Notes:
///  * This function requires the rebuilding of the entire documentation tree for all remaining registered files, so the next time help is queried with [hs.doc.help](#help), there may be a slight one-time delay.
private func doc_unregisterJSONFile(_ L: LuaState) throws -> CInt {
    let path = String(cString: luaL_checkstring(L, 1)) as NSString

    if registeredFiles[path] == nil {
        lua_pushboolean(L, 0)
        lua_pushany(L, "File '\(path)' was not registered" as NSString)
        return 2
    }

    registeredFiles[path] = nil
    documentationTree.removeAllObjects()
    documentationTree = NSMutableDictionary(dictionary: [
        "__type__": "root",
    ])

    for path2 in registeredFiles.allKeys {
        let entry = registeredFiles[path2] as! NSMutableDictionary
        if entry["json"] != nil { entry["json"] = nil }
    }

    // changecount function will be triggered when json rebuilt in findUnloadedDocumentationFiles for remaining paths

    lua_pushboolean(L, 1)
    return 1
}

// documented in init.lua
private func doc_registeredFiles(_ L: LuaState) throws -> CInt {

    let sortedPaths = (registeredFiles.allKeys as! [String]).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    lua_pushany(L, sortedPaths as NSArray)
    return 1
}

// MARK: - Internal Use Functions

// returns list of children in documentTree for __index and __pairs of helper table for `help`
private func internal_arrayOfChildren(_ L: LuaState) throws -> CInt {
    var identifier: NSString = ""
    if lua_gettop(L) == 1 && lua_type(L, 1) == LUA_TSTRING {
        identifier = lua_tovalue(L, at: 1) as! NSString
    }

    lua_newtable(L)

    if let pos = getPosInTreeFor(identifier) {
        for entry in pos.allKeys {
            let key = entry as! String
            if !(key.hasPrefix("__") && key.hasSuffix("__")) {
                lua_pushany(L, key as NSString)
                lua_rawseti(L, -2, luaL_len(L, -2) + 1)
            }
        }
    }
    return 1
}

// used by doc_help and when json being rebuilt for hsdocs
private func internal_loadRegisteredFiles(_ L: LuaState) throws -> CInt {

    findUnloadedDocumentationFiles(L)
    return 0
}

// used to register lua function to trigger `hs.watchable` change counter so hsdocs knows when doc files have been updated
private func internal_registerTriggerFunction(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TFUNCTION)
    triggerFn = L.ref(index: 1)
    return 0
}

// MARK: - objectWrapper Constructors

// returns objectWrapper for registeredFiles
private func internal_registeredFiles(_ L: LuaState) throws -> CInt {
    lua_pushany(L, registeredFiles)
    return 1
}

// returns objectWrapper for documentationTree
private func internal_documentationTree(_ L: LuaState) throws -> CInt {
    lua_pushany(L, documentationTree)
    return 1
}

// MARK: - Cosmic Hammer/Lua Infrastructure

private func meta_gc(_ L: LuaState) throws -> CInt {
    triggerFn = nil

    // probably overkill, but lets just be official about it
    registeredFiles.removeAllObjects()
    registeredFiles = nil
    documentationTree.removeAllObjects()
    documentationTree = nil
    return 0
}

@_cdecl("luaopen_hs_libdoc")
public func luaopen_hs_libdoc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Create module table (4 functions)
        lua_createtable(L, 0, 4)
        L.push(doc_help)
        lua_setfield(L, -2, "help")
        L.push(doc_registerJSONFile)
        lua_setfield(L, -2, "registerJSONFile")
        L.push(doc_registeredFiles)
        lua_setfield(L, -2, "registeredFiles")
        L.push(doc_unregisterJSONFile)
        lua_setfield(L, -2, "unregisterJSONFile")

        // Set module metatable (6 functions)
        lua_createtable(L, 0, 6)
        L.push(internal_arrayOfChildren)
        lua_setfield(L, -2, "_children")
        L.push(internal_loadRegisteredFiles)
        lua_setfield(L, -2, "_loadRegisteredFiles")
        L.push(internal_registerTriggerFunction)
        lua_setfield(L, -2, "_registerTriggerFunction")
        L.push(internal_registeredFiles)
        lua_setfield(L, -2, "_registeredFilesObject")
        L.push(internal_documentationTree)
        lua_setfield(L, -2, "_documentationTreeObject")
        L.push(meta_gc)
        lua_setfield(L, -2, "__gc")
        lua_setmetatable(L, -2)

        registeredFiles = NSMutableDictionary()
        documentationTree = NSMutableDictionary(dictionary: [
            "__type__": "root",
        ])
    }
}
