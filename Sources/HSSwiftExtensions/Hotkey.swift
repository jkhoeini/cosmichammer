import Cocoa
import CLua
import Lua
import Carbon
import os.log

// MARK: - Constants and Types

private let USERDATA_TAG = "hs.hotkey"
private var eventhandler: EventHandlerRef?

private var monotonicHotkeyCount: UInt32 = 0
private var hotkeys: NSMutableDictionary? = nil // [NSNumber: NSValue]

private var keyRepeatManager: HSKeyRepeatManager?

// MARK: - HSHotkey class

private class HSHotkey {
    var monotonicID: Int32 = 0
    var mods: UInt32 = 0
    var keycode: UInt32 = 0
    var pressedfn: LuaValue?
    var releasedfn: LuaValue?
    var repeatfn: LuaValue?
    var enabled: Bool = false
    var carbonHotKey: EventHotKeyRef? = nil
    var stateGeneration: UInt64 = 0
    private var tornDown = false

    /// Idempotent teardown: unregister the Carbon hotkey, drop all Lua callback
    /// references, remove from the global hotkeys dictionary.
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        stop()
        hotkeys?.removeObject(forKey: NSNumber(value: UInt32(monotonicID)))
        pressedfn = nil
        releasedfn = nil
        repeatfn = nil
    }

    func stop() {
        guard enabled else { return }
        enabled = false

        if carbonHotKey == nil {
            os_log(.info, "hs.hotkey stop() we think the hotkey is enabled, but it has no Carbon event. Refusing to unregister.")
        } else {
            let result = UnregisterEventHotKey(carbonHotKey)
            carbonHotKey = nil
            if result != noErr {
                os_log(.error, "hs.hotkey:stop() keycode: %u, mods: 0x%04x, UnregisterEventHotKey failed: %d", keycode, mods, result)
            }
        }

        keyRepeatManager?.stopTimer()
    }
}

// MARK: - HSKeyRepeatManager

@objc private class HSKeyRepeatManager: NSObject {
    private var keyRepeatTimer: Timer?
    private var eventID: Int32 = 0
    private var eventType: Int32 = 0

    func startTimer(_ theEventID: Int32, eventKind theEventKind: Int32) {
        if keyRepeatTimer != nil {
            os_log(.info, "hs.hotkey - startTimer() called while an existing repeat timer is running. Stopping existing timer and refusing to proceed.")
            stopTimer()
            return
        }
        keyRepeatTimer = Timer.scheduledTimer(
            timeInterval: NSEvent.keyRepeatDelay,
            target: self,
            selector: #selector(delayTimerFired(_:)),
            userInfo: nil,
            repeats: false
        )
        eventID = theEventID
        eventType = theEventKind
    }

    func stopTimer() {
        keyRepeatTimer?.invalidate()
        keyRepeatTimer = nil
        eventID = 0
        eventType = 0
    }

    @objc func delayTimerFired(_ timer: Timer) {
        _ = trigger_hotkey_callback(eventID, eventKind: eventType, isRepeat: true)

        keyRepeatTimer?.invalidate()
        keyRepeatTimer = Timer.scheduledTimer(
            timeInterval: NSEvent.keyRepeatInterval,
            target: self,
            selector: #selector(repeatTimerFired(_:)),
            userInfo: nil,
            repeats: true
        )
    }

    @objc func repeatTimerFired(_ timer: Timer) {
        _ = trigger_hotkey_callback(eventID, eventKind: eventType, isRepeat: true)
    }
}

// MARK: - Hotkey Functions

private func hotkey_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checktype(L, 1, LUA_TTABLE)
    let keycode = UInt32(luaL_checkinteger(L, 2))
    let hasDown = !lua_isnoneornil(L, 3)
    let hasUp = !lua_isnoneornil(L, 4)
    let hasRepeat = !lua_isnoneornil(L, 5)

    if !hasDown && !hasUp && !hasRepeat {
        luaL_error(L, "hs.hotkey: new hotkeys must have at least one callback function")
        lua_pushnil(L)
        return 1
    }
    lua_settop(L, 5)

    let hk = HSHotkey()

    let uid = monotonicHotkeyCount
    monotonicHotkeyCount += 1
    hk.monotonicID = Int32(uid)
    hk.stateGeneration = lua_currentStateGeneration()
    hotkeys?.setObject(NSValue(nonretainedObject: hk), forKey: NSNumber(value: uid))

    hk.carbonHotKey = nil
    hk.keycode = keycode

    // store pressedfn
    if hasDown {
        hk.pressedfn = L.ref(index: 3)
    }

    // store releasedfn
    if hasUp {
        hk.releasedfn = L.ref(index: 4)
    }

    // store repeatfn
    if hasRepeat {
        hk.repeatfn = L.ref(index: 5)
    }

    // save mods
    lua_pushnil(L)
    while lua_next(L, 1) != 0 {
        let mod = String(cString: luaL_checkstring(L, -1)).lowercased()
        if mod == "cmd" || mod == "\u{2318}" { hk.mods |= UInt32(cmdKey) }
        else if mod == "ctrl" || mod == "\u{2303}" { hk.mods |= UInt32(controlKey) }
        else if mod == "alt" || mod == "\u{2325}" { hk.mods |= UInt32(optionKey) }
        else if mod == "shift" || mod == "\u{21E7}" { hk.mods |= UInt32(shiftKey) }
        lua_pop(L, 1)
    }

    L.push(userdata: hk)

    return 1
}

private func hotkey_systemAssigned(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checktype(L, 1, LUA_TTABLE)
    let keycode = UInt32(luaL_checkinteger(L, 2))
    var mods: UInt32 = 0

    // save mods
    lua_pushnil(L)
    while lua_next(L, 1) != 0 {
        let mod = String(cString: luaL_checkstring(L, -1)).lowercased()
        if mod == "cmd" || mod == "\u{2318}" { mods |= UInt32(cmdKey) }
        else if mod == "ctrl" || mod == "\u{2303}" { mods |= UInt32(controlKey) }
        else if mod == "alt" || mod == "\u{2325}" { mods |= UInt32(optionKey) }
        else if mod == "shift" || mod == "\u{21E7}" { mods |= UInt32(shiftKey) }
        lua_pop(L, 1)
    }

    var assigned = false
    var registeredHotKeys: Unmanaged<CFArray>?
    let status = CopySymbolicHotKeys(&registeredHotKeys)
    if status == noErr, let hotKeyArray = registeredHotKeys?.takeRetainedValue() {
        for item in hotKeyArray as NSArray {
            guard let hotKeyInfo = item as? NSDictionary,
                  let hotKeyCode = hotKeyInfo[kHISymbolicHotKeyCode] as? NSNumber,
                  let hotKeyModifiers = hotKeyInfo[kHISymbolicHotKeyModifiers] as? NSNumber,
                  let hotKeyEnabled = hotKeyInfo[kHISymbolicHotKeyEnabled] as? NSNumber else {
                continue
            }

            // Remove Fn key bit (1 << 17) if present
            let modifierFlags = hotKeyModifiers.uint32Value & ~(1 << 17)
            if hotKeyCode.uint32Value == keycode && modifierFlags == mods {
                lua_newtable(L)
                lua_pushany(L, hotKeyCode);    lua_setfield(L, -2, "keycode")
                lua_pushinteger(L, lua_Integer(modifierFlags)); lua_setfield(L, -2, "mods")
                lua_pushany(L, hotKeyEnabled); lua_setfield(L, -2, "enabled")
                assigned = true
                break
            }
        }
        if !assigned { lua_pushboolean(L, 0) }
    } else {
        os_log(.info, "hs.hotkey.assigned - unable to retrieve SymbolicHotKeys (%d)", status)
        lua_pushnil(L)
    }

    return 1
}

// MARK: - Carbon Event Callback

private func trigger_hotkey_callback(_ eventUID: Int32, eventKind: Int32, isRepeat: Bool) -> OSStatus {
    let L = lua_getCurrentState()!

    guard let hkValue = hotkeys?.object(forKey: NSNumber(value: UInt32(eventUID))) as? NSValue else {
        os_log(.info, "hs.hotkey system callback for an eventUID we don't know about: %d", eventUID)
        return noErr
    }
    guard let hk = hkValue.nonretainedObjectValue as? HSHotkey else {
        os_log(.info, "hs.hotkey system callback could not extract HSHotkey for eventUID: %d", eventUID)
        return noErr
    }

    if !lua_isStateGenerationValid(hk.stateGeneration) {
        hk.teardown()
        return noErr
    }

    if !isRepeat {
        keyRepeatManager?.stopTimer()
    }

    var cb: LuaValue?
    if isRepeat {
        cb = hk.repeatfn
    } else if eventKind == Int32(kEventHotKeyPressed) {
        cb = hk.pressedfn
    } else if eventKind == Int32(kEventHotKeyReleased) {
        cb = hk.releasedfn
    } else {
        os_log(.info, "Unknown event kind (%d) in hs.hotkey trigger_hotkey_callback", eventKind)
        return noErr
    }

    if let cb = cb {
        cb.push(onto: L)
        if lua_pcall(L, 0, 0, 0) != LUA_OK {
            lua_pop(L, 1)
            // For the sake of safety, invalidate any repeat timer so we don't spam errors
            keyRepeatManager?.stopTimer()
            return noErr
        }
    }

    if !isRepeat && eventKind == Int32(kEventHotKeyPressed) && hk.repeatfn != nil {
        keyRepeatManager?.startTimer(eventUID, eventKind: eventKind)
    }

    return noErr
}

private let hotkey_callback: EventHandlerProcPtr = { (inHandlerCallRef, inEvent, inUserData) -> OSStatus in
    var eventID = EventHotKeyID()

    let result = GetEventParameter(inEvent, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &eventID)
    if result != noErr {
        os_log(.info, "Error handling hotkey: %d", result)
        return noErr
    }

    let eventKind = Int32(GetEventKind(inEvent!))
    let eventUID = Int32(eventID.id)

    return trigger_hotkey_callback(eventUID, eventKind: eventKind, isRepeat: false)
}

// MARK: - Meta Functions

private func meta_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if let handler = eventhandler {
        RemoveEventHandler(handler)
    }
    keyRepeatManager?.stopTimer()
    keyRepeatManager = nil
    hotkeys?.removeAllObjects()
    return 0
}

// MARK: - Module Registration

@_cdecl("luaopen_hs_libhotkey")
public func luaopen_hs_libhotkey(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if hotkeys == nil {
        hotkeys = NSMutableDictionary()
    }
    keyRepeatManager = HSKeyRepeatManager()

    // Register idiomatic Metatable<HSHotkey> with LuaSwift.
    L.register(Metatable<HSHotkey>(
        fields: [
            "enable": .closure { L in
                let hk: HSHotkey = try L.checkArgument(1)
                lua_settop(L, 1)

                if hk.enabled {
                    return 1
                }

                if hk.carbonHotKey != nil {
                    os_log(.info, "hs.hotkey:enable() we think the hotkey is disabled, but it has a Carbon event. Proceeding, but this is a leak.")
                }

                let hotKeyID = EventHotKeyID(signature: OSType(0x484D5350), id: UInt32(hk.monotonicID)) // 'HMSP'
                var carbonHotKey: EventHotKeyRef?
                let result = RegisterEventHotKey(hk.keycode, hk.mods, hotKeyID, GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &carbonHotKey)

                if result == noErr {
                    hk.carbonHotKey = carbonHotKey
                    hk.enabled = true
                    lua_pushvalue(L, 1)
                } else {
                    os_log(.error, "hs.hotkey:enable() keycode: %u, mods: 0x%04x, RegisterEventHotKey failed: %d", hk.keycode, hk.mods, result)
                    if result == OSStatus(eventHotKeyExistsErr) {
                        os_log(.error, "This hotkey is already registered. It may be a duplicate in your Cosmic Hammer config, or it may be registered by macOS. See System Preferences->Keyboard->Shortcuts")
                    }
                    lua_pushnil(L)
                }

                return 1
            },
            "disable": .closure { L in
                let hk: HSHotkey = try L.checkArgument(1)
                hk.stop()
                lua_pushvalue(L, 1)
                return 1
            },
        ],
        tostring: .closure { L in
            let hk: HSHotkey = try L.checkArgument(1)
            let ptrStr = String(describing: lua_topointer(L, 1)!)
            let str = "\(USERDATA_TAG): keycode: \(hk.keycode), mods: 0x\(String(format: "%04x", hk.mods)) (\(ptrStr))"
            lua_pushstring(L, str)
            return 1
        }
    ))

    // -- Post-registration metatable patching --
    // LuaSwift's register() always installs its own gcUserdata as __gc, which
    // only deinitializes the Any box. We MUST replace it with a custom __gc
    // that first calls teardown() (unregister Carbon hotkey, drop the LuaValue
    // callbacks) and THEN deinitializes the Any box.
    L.pushMetatable(for: HSHotkey.self)

    // Replace __gc with our explicit teardown + deinitialize
    lua_pushcclosure(L, { (L: LuaState!) -> CInt in
        if let hk: HSHotkey = L.touserdata(1) {
            hk.teardown()
        }
        let rawptr = lua_touserdata(L, 1)!
        rawptr.assumingMemoryBound(to: Any.self).deinitialize(count: 1)
        return 0
    }, 0)
    lua_setfield(L, -2, "__gc")

    // Set __type and __name for lsunit.lua assertIsUserdataOfType and tostring
    lua_pushstring(L, USERDATA_TAG)
    lua_setfield(L, -2, "__type")
    lua_pushstring(L, USERDATA_TAG)
    lua_setfield(L, -2, "__name")

    // Alias the metatable under the legacy registry name so that
    // core_getObjectMetatable("hs.hotkey") still resolves.
    lua_setfield(L, LUA_REGISTRYINDEX_VALUE, USERDATA_TAG)

    // Create module table
    lua_createtable(L, 0, 2)
    L.push(hotkey_new)
    lua_setfield(L, -2, "_new")
    L.push(hotkey_systemAssigned)
    lua_setfield(L, -2, "systemAssigned")

    // Set module metatable (for __gc)
    lua_createtable(L, 0, 1)
    lua_pushcclosure(L, meta_gc, 0)
    lua_setfield(L, -2, "__gc")
    lua_setmetatable(L, -2)

    // watch for hotkey events
    var hotKeyPressedSpec: [EventTypeSpec] = [
        EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
        EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
    ]

    InstallEventHandler(
        GetEventDispatcherTarget(),
        hotkey_callback,
        hotKeyPressedSpec.count,
        &hotKeyPressedSpec,
        nil,
        &eventhandler
    )

    return 1
}
