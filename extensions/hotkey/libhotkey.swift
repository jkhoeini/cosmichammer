import Cocoa
import Carbon
import LuaSkin

// MARK: - Constants and Types

private let USERDATA_TAG = "hs.hotkey"
private var refTable: LSRefTable = 0
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
    var lsCanary: LSGCCanary = 0
}

// MARK: - HSKeyRepeatManager

@objc private class HSKeyRepeatManager: NSObject {
    private var keyRepeatTimer: Timer?
    private var eventID: Int32 = 0
    private var eventType: Int32 = 0

    func startTimer(_ theEventID: Int32, eventKind theEventKind: Int32) {
        if keyRepeatTimer != nil {
            let skin = LuaSkin.shared(withState: nil)
            skin.logWarn("hs.hotkey - startTimer() called while an existing repeat timer is running. Stopping existing timer and refusing to proceed.")
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

private func hotkey_new(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)

    luaL_checktype(L, 1, LUA_TTABLE)
    let keycode = UInt32(luaL_checkinteger(L, 2))
    let hasDown = !lua_isnoneornil(L, 3)
    let hasUp = !lua_isnoneornil(L, 4)
    let hasRepeat = !lua_isnoneornil(L, 5)

    if !hasDown && !hasUp && !hasRepeat {
        skin.logError("hs.hotkey: new hotkeys must have at least one callback function")
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
    hotkey.pointee.lsCanary = skin.createGCCanary()
    hotkeys?.setObject(NSValue(pointer: hotkey), forKey: NSNumber(value: uid))

    hotkey.pointee.carbonHotKey = nil
    hotkey.pointee.keycode = keycode

    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)

    // store pressedfn
    if hasDown {
        lua_pushvalue(L, 3)
        hotkey.pointee.pressedfn = skin.luaRef(refTable)
    } else {
        hotkey.pointee.pressedfn = LUA_NOREF
    }

    // store releasedfn
    if hasUp {
        lua_pushvalue(L, 4)
        hotkey.pointee.releasedfn = skin.luaRef(refTable)
    } else {
        hotkey.pointee.releasedfn = LUA_NOREF
    }

    // store repeatfn
    if hasRepeat {
        lua_pushvalue(L, 5)
        hotkey.pointee.repeatfn = skin.luaRef(refTable)
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

private func hotkey_systemAssigned(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)

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
    var registeredHotKeys: CFArray?
    let status = CopySymbolicHotKeys(&registeredHotKeys)
    if status == noErr, let hotKeyArray = registeredHotKeys {
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
                skin.pushNSObject(hotKeyCode);    lua_setfield(L, -2, "keycode")
                lua_pushinteger(L, lua_Integer(modifierFlags)); lua_setfield(L, -2, "mods")
                skin.pushNSObject(hotKeyEnabled); lua_setfield(L, -2, "enabled")
                assigned = true
                break
            }
        }
        if !assigned { lua_pushboolean(L, 0) }
    } else {
        skin.logWarn("\(USERDATA_TAG).assigned - unable to retrieve SymbolicHotKeys (\(status))")
        lua_pushnil(L)
    }

    return 1
}

private func hotkey_enable(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)

    let hotkey = lua_touserdata(L, 1)!.bindMemory(to: hotkey_t.self, capacity: 1)
    lua_settop(L, 1)

    if hotkey.pointee.enabled {
        return 1
    }

    if hotkey.pointee.carbonHotKey != nil {
        skin.logBreadcrumb("hs.hotkey:enable() we think the hotkey is disabled, but it has a Carbon event. Proceeding, but this is a leak.")
    }

    var hotKeyID = EventHotKeyID(signature: OSType(0x484D5350), id: UInt32(hotkey.pointee.monotonicID)) // 'HMSP'
    var carbonHotKey: EventHotKeyRef?
    let result = RegisterEventHotKey(hotkey.pointee.keycode, hotkey.pointee.mods, hotKeyID, GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &carbonHotKey)

    if result == noErr {
        hotkey.pointee.carbonHotKey = carbonHotKey
        hotkey.pointee.enabled = true
        lua_pushvalue(L, 1)
    } else {
        skin.logError("\(USERDATA_TAG):enable() keycode: \(hotkey.pointee.keycode), mods: 0x\(String(format: "%04x", hotkey.pointee.mods)), RegisterEventHotKey failed: \(result)")
        if result == OSStatus(eventHotKeyExistsErr) {
            skin.logError("This hotkey is already registered. It may be a duplicate in your Hammerspoon config, or it may be registered by macOS. See System Preferences->Keyboard->Shortcuts")
        }
        lua_pushnil(L)
    }

    return 1
}

private func stop(_ L: OpaquePointer!, _ hotkey: UnsafeMutablePointer<hotkey_t>) {
    let skin = LuaSkin.shared(withState: L)

    if !hotkey.pointee.enabled { return }
    hotkey.pointee.enabled = false

    if hotkey.pointee.carbonHotKey == nil {
        skin.logBreadcrumb("hs.hotkey stop() we think the hotkey is enabled, but it has no Carbon event. Refusing to unregister.")
    } else {
        let result = UnregisterEventHotKey(hotkey.pointee.carbonHotKey)
        hotkey.pointee.carbonHotKey = nil
        if result != noErr {
            skin.logError("\(USERDATA_TAG):stop() keycode: \(hotkey.pointee.keycode), mods: 0x\(String(format: "%04x", hotkey.pointee.mods)), UnregisterEventHotKey failed: \(result)")
        }
    }

    keyRepeatManager?.stopTimer()
}

private func hotkey_disable(_ L: OpaquePointer!) -> Int32 {
    let hotkey = luaL_checkudata(L, 1, USERDATA_TAG)!.bindMemory(to: hotkey_t.self, capacity: 1)
    stop(L, hotkey)
    lua_pushvalue(L, 1)
    return 1
}

private func hotkey_gc(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    let hotkey = luaL_checkudata(L, 1, USERDATA_TAG)!.bindMemory(to: hotkey_t.self, capacity: 1)

    stop(L, hotkey)

    hotkeys?.removeObject(forKey: NSNumber(value: UInt32(hotkey.pointee.monotonicID)))
    skin.destroyGCCanary(&hotkey.pointee.lsCanary)

    hotkey.pointee.pressedfn = skin.luaUnref(refTable, ref: hotkey.pointee.pressedfn)
    hotkey.pointee.releasedfn = skin.luaUnref(refTable, ref: hotkey.pointee.releasedfn)
    hotkey.pointee.repeatfn = skin.luaUnref(refTable, ref: hotkey.pointee.repeatfn)

    return 0
}

// MARK: - Carbon Event Callback

private func trigger_hotkey_callback(_ eventUID: Int32, eventKind: Int32, isRepeat: Bool) -> OSStatus {
    let skin = LuaSkin.shared(withState: nil)
    let L = skin.L!

    guard let hkValue = hotkeys?.object(forKey: NSNumber(value: UInt32(eventUID))) as? NSValue else {
        skin.logWarn("hs.hotkey system callback for an eventUID we don't know about: \(eventUID)")
        return noErr
    }
    let hotkey = hkValue.pointerValue!.bindMemory(to: hotkey_t.self, capacity: 1)

    if !skin.checkGCCanary(hotkey.pointee.lsCanary) {
        return noErr
    }

    _lua_stackguard_entry(L)

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
        skin.logWarn("Unknown event kind (\(eventKind)) in hs.hotkey trigger_hotkey_callback")
        return noErr
    }

    if ref != LUA_NOREF {
        skin.pushLuaRef(refTable, ref: ref)

        if !skin.protectedCallAndError("hs.hotkey callback", nargs: 0, nresults: 0) {
            // For the sake of safety, invalidate any repeat timer so we don't spam errors
            keyRepeatManager?.stopTimer()
            return noErr
        }
    }

    if !isRepeat && eventKind == Int32(kEventHotKeyPressed) && hotkey.pointee.repeatfn != LUA_NOREF {
        keyRepeatManager?.startTimer(eventUID, eventKind: eventKind)
    }

    _lua_stackguard_exit(L)
    return noErr
}

private let hotkey_callback: EventHandlerProcPtr = { (inHandlerCallRef, inEvent, inUserData) -> OSStatus in
    let skin = LuaSkin.shared(withState: nil)
    var eventID = EventHotKeyID()

    let result = GetEventParameter(inEvent, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &eventID)
    if result != noErr {
        skin.logBreadcrumb("Error handling hotkey: \(result)")
        return noErr
    }

    let eventKind = Int32(GetEventKind(inEvent!))
    let eventUID = Int32(eventID.id)

    return trigger_hotkey_callback(eventUID, eventKind: eventKind, isRepeat: false)
}

// MARK: - Meta Functions

private func meta_gc(_ L: OpaquePointer!) -> Int32 {
    if let handler = eventhandler {
        RemoveEventHandler(handler)
    }
    keyRepeatManager?.stopTimer()
    keyRepeatManager = nil
    hotkeys?.removeAllObjects()
    return 0
}

private func userdata_tostring(_ L: OpaquePointer!) -> Int32 {
    let hotkey = luaL_checkudata(L, 1, USERDATA_TAG)!.bindMemory(to: hotkey_t.self, capacity: 1)
    let str = String(format: "%s: keycode: %d, mods: 0x%04x (%p)", USERDATA_TAG, hotkey.pointee.keycode, hotkey.pointee.mods, lua_topointer(L, 1)!)
    lua_pushstring(L, str)
    return 1
}

// MARK: - C Callback Wrappers

private let hotkey_new_C: @convention(c) (OpaquePointer?) -> Int32 = { L in hotkey_new(L) }
private let hotkey_systemAssigned_C: @convention(c) (OpaquePointer?) -> Int32 = { L in hotkey_systemAssigned(L) }
private let hotkey_enable_C: @convention(c) (OpaquePointer?) -> Int32 = { L in hotkey_enable(L) }
private let hotkey_disable_C: @convention(c) (OpaquePointer?) -> Int32 = { L in hotkey_disable(L) }
private let hotkey_gc_C: @convention(c) (OpaquePointer?) -> Int32 = { L in hotkey_gc(L) }
private let meta_gc_C: @convention(c) (OpaquePointer?) -> Int32 = { L in meta_gc(L) }
private let userdata_tostring_C: @convention(c) (OpaquePointer?) -> Int32 = { L in userdata_tostring(L) }

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
public func luaopen_hs_libhotkey(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)

    if hotkeys == nil {
        hotkeys = NSMutableDictionary()
    }
    keyRepeatManager = HSKeyRepeatManager()

    refTable = skin.registerLibrary(withObject: USERDATA_TAG, functions: &hotkeylib, metaFunctions: &metalib, objectFunctions: &hotkey_objectlib)

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
