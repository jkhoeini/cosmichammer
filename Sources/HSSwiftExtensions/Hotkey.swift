import Cocoa
import CLua
import Lua
import Carbon
import HSDSTCore
import os.log

// MARK: - Constants and Types

private let USERDATA_TAG = "hs.hotkey"
private var eventhandler: EventHandlerRef?

private var monotonicHotkeyCount: UInt32 = 0
private var hotkeys: NSMutableDictionary? = nil // [NSNumber: NSValue]
private var activeHotkeyCount = 0

private var keyRepeatManager: HSKeyRepeatManager?

private func recordActiveHotkeyGauge(_ L: UnsafeMutablePointer<lua_State>? = lua_getCurrentState()) {
    let telemetry = L.map { environmentGet($0).telemetry } ?? environmentGetGlobalOrNil()?.telemetry
    telemetry?.recordMetric(
        name: "cosmichammer.hotkey.active",
        kind: .gauge,
        value: Double(activeHotkeyCount),
        attributes: [:],
        unit: "1"
    )
}

// MARK: - HSHotkey class

private class HSHotkey {
    var monotonicID: Int32 = 0
    var mods: UInt32 = 0
    var keycode: UInt32 = 0
    var pressedfn: LuaValue?
    var releasedfn: LuaValue?
    var repeatfn: LuaValue?
    var enabled: Bool = false
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
        activeHotkeyCount = max(0, activeHotkeyCount - 1)
        recordActiveHotkeyGauge()

        // Unregister via the protocol — ProductionInput calls Carbon's
        // UnregisterEventHotKey; SimulatedInput removes from its table.
        environmentGetGlobalOrNil()?.input.unregisterHotkey(id: UInt32(monotonicID))

        keyRepeatManager?.stopTimer()
    }
}

// MARK: - HSKeyRepeatManager

private class HSKeyRepeatManager {
    private var keyRepeatTimer: Foundation.Timer?
    private var eventID: Int32 = 0
    private var eventType: Int32 = 0

    func startTimer(_ theEventID: Int32, eventKind theEventKind: Int32) {
        if keyRepeatTimer != nil {
            os_log(.info, "hs.hotkey - startTimer() called while an existing repeat timer is running. Stopping existing timer and refusing to proceed.")
            stopTimer()
            return
        }
        eventID = theEventID
        eventType = theEventKind
        keyRepeatTimer = Foundation.Timer.scheduledTimer(withTimeInterval: NSEvent.keyRepeatDelay, repeats: false) { [weak self] _ in
            self?.delayTimerFired()
        }
    }

    func stopTimer() {
        keyRepeatTimer?.invalidate()
        keyRepeatTimer = nil
        eventID = 0
        eventType = 0
    }

    private func delayTimerFired() {
        _ = trigger_hotkey_callback(eventID, eventKind: eventType, isRepeat: true)

        keyRepeatTimer?.invalidate()
        keyRepeatTimer = Foundation.Timer.scheduledTimer(withTimeInterval: NSEvent.keyRepeatInterval, repeats: true) { [weak self] _ in
            self?.repeatTimerFired()
        }
    }

    private func repeatTimerFired() {
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
                L.push(lua_Integer(modifierFlags)); lua_setfield(L, -2, "mods")
                lua_pushany(L, hotKeyEnabled); lua_setfield(L, -2, "enabled")
                assigned = true
                break
            }
        }
        if !assigned { L.push(false) }
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
        if luaTelemetryPCall(
            L,
            nargs: 0,
            nresults: 0,
            callbackName: "hs.hotkey",
            attributes: [
                "hotkey.id": hk.monotonicID,
                "hotkey.keycode": hk.keycode,
                "hotkey.mods": hk.mods,
                "hotkey.event_kind": eventKind,
                "hotkey.repeat": isRepeat,
            ]
        ) != LUA_OK {
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
    activeHotkeyCount = 0
    recordActiveHotkeyGauge(L)
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

                // Register via the protocol — ProductionInput calls Carbon's
                // RegisterEventHotKey; SimulatedInput records in its table.
                let input = environmentGet(L).input
                let registered = input.registerHotkey(id: UInt32(hk.monotonicID), keyCode: hk.keycode, mods: hk.mods) { eventUID, eventKind in
                    _ = trigger_hotkey_callback(eventUID, eventKind: eventKind, isRepeat: false)
                }
                if registered {
                    hk.enabled = true
                    activeHotkeyCount += 1
                    recordActiveHotkeyGauge(L)
                    lua_pushvalue(L, 1)
                } else {
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
            L.push(str)
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
    L.push(USERDATA_TAG)
    lua_setfield(L, -2, "__type")
    L.push(USERDATA_TAG)
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

    // Install the global hotkey dispatcher via the protocol —
    // ProductionInput installs the Carbon event handler;
    // SimulatedInput does nothing (hotkeys route through postEvent).
    environmentGetGlobalOrNil()?.input.installHotkeyDispatcher(
        callback: hotkey_callback as Any,
        handler: &eventhandler
    )

    return 1
}
