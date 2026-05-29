import Cocoa
import LuaSkin
import Carbon
import os.log

// MARK: - Constants and Types

private let USERDATA_TAG = "hs.hotkey"
private var refTable: Int32 = LUA_NOREF
private var eventhandler: EventHandlerRef?

private var monotonicHotkeyCount: UInt32 = 0
private var hotkeys: NSMutableDictionary? = nil // [NSNumber: NSValue]

private var keyRepeatManager: HSKeyRepeatManager?

private struct hotkey_t {
    var monotonicID: Int32 = 0
    var mods: UInt32 = 0
    var keycode: UInt32 = 0
    var pressedfn: Int32 = LUA_NOREF
    var releasedfn: Int32 = LUA_NOREF
    var repeatfn: Int32 = LUA_NOREF
    var enabled: Bool = false
    var carbonHotKey: EventHotKeyRef? = nil
    var stateGeneration: UInt64 = 0
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

    let ptr = lua_newuserdata(L, MemoryLayout<hotkey_t>.size)!
    let hotkey = ptr.bindMemory(to: hotkey_t.self, capacity: 1)
    hotkey.pointee = hotkey_t()

    let uid = monotonicHotkeyCount
    monotonicHotkeyCount += 1
    hotkey.pointee.monotonicID = Int32(uid)
    hotkey.pointee.stateGeneration = lua_currentStateGeneration()
    hotkeys?.setObject(NSValue(pointer: hotkey), forKey: NSNumber(value: uid))

    hotkey.pointee.carbonHotKey = nil
    hotkey.pointee.keycode = keycode

    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)

    // store pressedfn
    if hasDown {
        lua_pushvalue(L, 3)
        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(refTable))
        lua_pushvalue(L, -2)
        hotkey.pointee.pressedfn = luaL_ref(L, -2)
        lua_pop(L, 2)
    } else {
        hotkey.pointee.pressedfn = LUA_NOREF
    }

    // store releasedfn
    if hasUp {
        lua_pushvalue(L, 4)
        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(refTable))
        lua_pushvalue(L, -2)
        hotkey.pointee.releasedfn = luaL_ref(L, -2)
        lua_pop(L, 2)
    } else {
        hotkey.pointee.releasedfn = LUA_NOREF
    }

    // store repeatfn
    if hasRepeat {
        lua_pushvalue(L, 5)
        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(refTable))
        lua_pushvalue(L, -2)
        hotkey.pointee.repeatfn = luaL_ref(L, -2)
        lua_pop(L, 2)
    } else {
        hotkey.pointee.repeatfn = LUA_NOREF
    }

    // save mods
    lua_pushnil(L)
    while lua_next(L, 1) != 0 {
        let mod = String(cString: luaL_checkstring(L, -1)).lowercased()
        if mod == "cmd" || mod == "\u{2318}" { hotkey.pointee.mods |= UInt32(cmdKey) }
        else if mod == "ctrl" || mod == "\u{2303}" { hotkey.pointee.mods |= UInt32(controlKey) }
        else if mod == "alt" || mod == "\u{2325}" { hotkey.pointee.mods |= UInt32(optionKey) }
        else if mod == "shift" || mod == "\u{21E7}" { hotkey.pointee.mods |= UInt32(shiftKey) }
        lua_pop(L, 1)
    }

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
        let count = CFArrayGetCount(hotKeyArray)
        for i in 0..<count {
            let hotKeyInfo = unsafeBitCast(CFArrayGetValueAtIndex(hotKeyArray, i), to: CFDictionary.self)
            let hotKeyCode = unsafeBitCast(CFDictionaryGetValue(hotKeyInfo, unsafeBitCast(kHISymbolicHotKeyCode, to: UnsafeRawPointer.self)), to: NSNumber.self)
            let hotKeyModifiers = unsafeBitCast(CFDictionaryGetValue(hotKeyInfo, unsafeBitCast(kHISymbolicHotKeyModifiers, to: UnsafeRawPointer.self)), to: NSNumber.self)
            let hotKeyEnabled = unsafeBitCast(CFDictionaryGetValue(hotKeyInfo, unsafeBitCast(kHISymbolicHotKeyEnabled, to: UnsafeRawPointer.self)), to: NSNumber.self)

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

private func hotkey_enable(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let hotkey = luaL_checkudata(L, 1, USERDATA_TAG)!.bindMemory(to: hotkey_t.self, capacity: 1)
    lua_settop(L, 1)

    if hotkey.pointee.enabled {
        return 1
    }

    if hotkey.pointee.carbonHotKey != nil {
        os_log(.info, "hs.hotkey:enable() we think the hotkey is disabled, but it has a Carbon event. Proceeding, but this is a leak.")
    }

    let hotKeyID = EventHotKeyID(signature: OSType(0x484D5350), id: UInt32(hotkey.pointee.monotonicID)) // 'HMSP'
    var carbonHotKey: EventHotKeyRef?
    let result = RegisterEventHotKey(hotkey.pointee.keycode, hotkey.pointee.mods, hotKeyID, GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &carbonHotKey)

    if result == noErr {
        hotkey.pointee.carbonHotKey = carbonHotKey
        hotkey.pointee.enabled = true
        lua_pushvalue(L, 1)
    } else {
        os_log(.error, "hs.hotkey:enable() keycode: %u, mods: 0x%04x, RegisterEventHotKey failed: %d", hotkey.pointee.keycode, hotkey.pointee.mods, result)
        if result == OSStatus(eventHotKeyExistsErr) {
            os_log(.error, "This hotkey is already registered. It may be a duplicate in your Cosmic Hammer config, or it may be registered by macOS. See System Preferences->Keyboard->Shortcuts")
        }
        lua_pushnil(L)
    }

    return 1
}

private func stop(_ L: UnsafeMutablePointer<lua_State>!, _ hotkey: UnsafeMutablePointer<hotkey_t>) {
    if !hotkey.pointee.enabled { return }
    hotkey.pointee.enabled = false

    if hotkey.pointee.carbonHotKey == nil {
        os_log(.info, "hs.hotkey stop() we think the hotkey is enabled, but it has no Carbon event. Refusing to unregister.")
    } else {
        let result = UnregisterEventHotKey(hotkey.pointee.carbonHotKey)
        hotkey.pointee.carbonHotKey = nil
        if result != noErr {
            os_log(.error, "hs.hotkey:stop() keycode: %u, mods: 0x%04x, UnregisterEventHotKey failed: %d", hotkey.pointee.keycode, hotkey.pointee.mods, result)
        }
    }

    keyRepeatManager?.stopTimer()
}

private func hotkey_disable(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let hotkey = luaL_checkudata(L, 1, USERDATA_TAG)!.bindMemory(to: hotkey_t.self, capacity: 1)
    stop(L, hotkey)
    lua_pushvalue(L, 1)
    return 1
}

private func hotkey_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let hotkey = luaL_checkudata(L, 1, USERDATA_TAG)!.bindMemory(to: hotkey_t.self, capacity: 1)

    stop(L, hotkey)

    hotkeys?.removeObject(forKey: NSNumber(value: UInt32(hotkey.pointee.monotonicID)))

    lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(refTable))
    luaL_unref(L, -1, hotkey.pointee.pressedfn); hotkey.pointee.pressedfn = LUA_NOREF
    luaL_unref(L, -1, hotkey.pointee.releasedfn); hotkey.pointee.releasedfn = LUA_NOREF
    luaL_unref(L, -1, hotkey.pointee.repeatfn); hotkey.pointee.repeatfn = LUA_NOREF
    lua_pop(L, 1)

    return 0
}

// MARK: - Carbon Event Callback

private func trigger_hotkey_callback(_ eventUID: Int32, eventKind: Int32, isRepeat: Bool) -> OSStatus {
    let L = lua_getCurrentState()!

    guard let hkValue = hotkeys?.object(forKey: NSNumber(value: UInt32(eventUID))) as? NSValue else {
        os_log(.info, "hs.hotkey system callback for an eventUID we don't know about: %d", eventUID)
        return noErr
    }
    let hotkey = hkValue.pointerValue!.bindMemory(to: hotkey_t.self, capacity: 1)

    if !lua_isStateGenerationValid(hotkey.pointee.stateGeneration) {
        return noErr
    }

    if !isRepeat {
        keyRepeatManager?.stopTimer()
    }

    var ref: Int32 = 0
    if isRepeat {
        ref = hotkey.pointee.repeatfn
    } else if eventKind == Int32(kEventHotKeyPressed) {
        ref = hotkey.pointee.pressedfn
    } else if eventKind == Int32(kEventHotKeyReleased) {
        ref = hotkey.pointee.releasedfn
    } else {
        os_log(.info, "Unknown event kind (%d) in hs.hotkey trigger_hotkey_callback", eventKind)
        return noErr
    }

    if ref != LUA_NOREF {
        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(refTable))
        lua_rawgeti(L, -1, lua_Integer(ref))
        lua_remove(L, -2)

        if lua_pcall(L, 0, 0, 0) != LUA_OK {
            lua_pop(L, 1)
            // For the sake of safety, invalidate any repeat timer so we don't spam errors
            keyRepeatManager?.stopTimer()
            return noErr
        }
    }

    if !isRepeat && eventKind == Int32(kEventHotKeyPressed) && hotkey.pointee.repeatfn != LUA_NOREF {
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

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let hotkey = luaL_checkudata(L, 1, USERDATA_TAG)!.bindMemory(to: hotkey_t.self, capacity: 1)
    let ptrStr = String(describing: lua_topointer(L, 1)!)
    let str = "\(USERDATA_TAG): keycode: \(hotkey.pointee.keycode), mods: 0x\(String(format: "%04x", hotkey.pointee.mods)) (\(ptrStr))"
    lua_pushstring(L, str)
    return 1
}

// MARK: - C Callback Wrappers

private let hotkey_new_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in hotkey_new(L) }
private let hotkey_systemAssigned_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in hotkey_systemAssigned(L) }
private let hotkey_enable_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in hotkey_enable(L) }
private let hotkey_disable_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in hotkey_disable(L) }
private let hotkey_gc_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in hotkey_gc(L) }
private let meta_gc_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in meta_gc(L) }
private let userdata_tostring_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in userdata_tostring(L) }

// MARK: - Module Registration

private var hotkeylib: [luaL_Reg] = [
    luaL_Reg(name: strdup("_new"), func: hotkey_new_C),
    luaL_Reg(name: strdup("systemAssigned"), func: hotkey_systemAssigned_C),
    luaL_Reg(name: nil, func: nil),
]

private var metalib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: meta_gc_C),
    luaL_Reg(name: nil, func: nil),
]

private var hotkey_objectlib: [luaL_Reg] = [
    luaL_Reg(name: strdup("enable"), func: hotkey_enable_C),
    luaL_Reg(name: strdup("disable"), func: hotkey_disable_C),
    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring_C),
    luaL_Reg(name: strdup("__gc"), func: hotkey_gc_C),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libhotkey")
public func luaopen_hs_libhotkey(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if hotkeys == nil {
        hotkeys = NSMutableDictionary()
    }
    keyRepeatManager = HSKeyRepeatManager()

    // Create ref table in registry
    lua_newtable(L)
    refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    // Register userdata metatable
    luaL_newmetatable(L, USERDATA_TAG)
    lua_pushvalue(L, -1)
    lua_setfield(L, -2, "__index")  // mt.__index = mt
    luaL_setfuncs(L, &hotkey_objectlib, 0)
    lua_pop(L, 1)

    // Create module table
    lua_createtable(L, 0, Int32(hotkeylib.count - 1))
    luaL_setfuncs(L, &hotkeylib, 0)

    // Set module metatable (for __gc)
    lua_createtable(L, 0, Int32(metalib.count - 1))
    luaL_setfuncs(L, &metalib, 0)
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
