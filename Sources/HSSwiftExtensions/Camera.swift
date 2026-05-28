import Cocoa
import AVFoundation
import CoreMediaIO
import LuaSkin
import os.log

// MARK: - Module declarations

private var refTable: Int32 = 0
private let USERDATA_TAG = "hs.camera"

// MARK: - Devices watcher declarations

private struct DeviceWatcher {
    var callback: Int32
    var running: Bool
    var lsCanary: UInt64
}

private var deviceWatcher: UnsafeMutablePointer<DeviceWatcher>?
private var deviceWatcherAddedObserver: NSObjectProtocol?
private var deviceWatcherRemovedObserver: NSObjectProtocol?

// MARK: - Device property watcher declarations

private let propertyWatchSelectors: [CMIOObjectPropertySelector] = [
    CMIOObjectPropertySelector(kAudioDevicePropertyDeviceHasChanged),
    CMIOObjectPropertySelector(kAudioDevicePropertyDeviceIsRunningSomewhere),
]

// MARK: - HSCamera class

private class HSCamera: NSObject {
    var deviceId: CMIODeviceID
    var name: String?
    var uid: String?
    var propertyWatcherCallback: Int32 = LUA_NOREF
    var propertyWatcherRunning: Bool = false
    var propertyWatcherBlock: CMIOObjectPropertyListenerBlock?
    var canary: UInt64

    var isInUse: Bool {
        let skin = LuaSkin.skin(with: nil)
        var dataSize: UInt32 = 0
        var dataUsed: UInt32 = 0
        var isInUseVal: UInt32 = 0

        var prop = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard)
        )

        var err = CMIOObjectGetPropertyDataSize(deviceId, &prop, 0, nil, &dataSize)
        if err != OSStatus(kCMIOHardwareNoError) {
            os_log(.error, "%{public}s", "getVideoDeviceIsUsed(): get data size error: \(err)")
            return false
        }

        err = CMIOObjectGetPropertyData(deviceId, &prop, 0, nil, dataSize, &dataUsed, &isInUseVal)
        if err != OSStatus(kCMIOHardwareNoError) {
            os_log(.error, "%{public}s", "getVideoDeviceIsUsed(): get data error: \(err)")
            return false
        }

        return isInUseVal != 0
    }

    init(deviceID: CMIODeviceID) {
        let skin = LuaSkin.skin(with: nil)
        let L = LuaSkin.skin(with: nil).l!

        self.deviceId = deviceID
        self.canary = lua_currentStateGeneration()

        super.init()

        os_log(.info, "HSCamera init: %{public}s (%d)", String(describing: self), deviceID)

        self.uid = getCameraUID()
        self.name = getCameraName()

        weak let weakSelf = self
        self.propertyWatcherBlock = { (numberAddresses: UInt32, addresses: UnsafePointer<CMIOObjectPropertyAddress>?) in
            guard let addresses = addresses else { return }
            var events: [[String: Any]] = []

            for i in 0..<Int(numberAddresses) {
                let addr = addresses[i]
                let mSelector = UTCreateStringForOSType(addr.mSelector).takeRetainedValue() as String
                let mScope = UTCreateStringForOSType(addr.mScope).takeRetainedValue() as String
                let mElement = NSNumber(value: addr.mElement)
                events.append(["mSelector": mSelector, "mScope": mScope, "mElement": mElement])
            }

            DispatchQueue.main.async {
                let skin = LuaSkin.skin(with: nil)
                let L = LuaSkin.skin(with: nil).l!
                guard let strongSelf = weakSelf else { return }

                if !lua_isStateGenerationValid(strongSelf.canary) {
                    return
                }

                let savedTop = lua_gettop(L)

                if strongSelf.propertyWatcherCallback == LUA_NOREF {
                    os_log(.error, "%{public}s", "hs.camera property watcher fired, but no callback has been set")
                } else {
                    for event in events {
                        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(strongSelf.propertyWatcherCallback))
                        lua_pushany(L, strongSelf)
                        lua_pushany(L, event["mSelector"] as? NSString)
                        lua_pushany(L, event["mScope"] as? NSString)
                        lua_pushany(L, event["mElement"] as? NSNumber)

                        if lua_pcall(L, 4, 0, 0) != LUA_OK { lua_pop(L, 1) }
                    }
                }
                assert(savedTop == lua_gettop(L))
            }
        }
    }

    deinit {
        os_log(.info, "HSCamera dealloc: %{public}s", String(describing: self))
        wasRemoved()
    }

    func wasRemoved() {
        stopPropertyWatcher()
    }

    func startPropertyWatcher() {
        guard !propertyWatcherRunning else { return }

        var propertyAddress = CMIOObjectPropertyAddress(
            mSelector: 0,
            mScope: CMIOObjectPropertyScope(kAudioObjectPropertyScopeWildcard),
            mElement: CMIOObjectPropertyElement(kAudioObjectPropertyElementWildcard)
        )

        for selector in propertyWatchSelectors {
            propertyAddress.mSelector = selector
            CMIOObjectAddPropertyListenerBlock(deviceId, &propertyAddress,
                                               DispatchQueue.main, propertyWatcherBlock!)
        }

        propertyWatcherRunning = true
    }

    func stopPropertyWatcher() {
        guard propertyWatcherRunning else { return }

        var propertyAddress = CMIOObjectPropertyAddress(
            mSelector: 0,
            mScope: CMIOObjectPropertyScope(kAudioObjectPropertyScopeWildcard),
            mElement: CMIOObjectPropertyElement(kAudioObjectPropertyElementWildcard)
        )

        for selector in propertyWatchSelectors {
            propertyAddress.mSelector = selector
            CMIOObjectRemovePropertyListenerBlock(deviceId, &propertyAddress,
                                                  DispatchQueue.main, propertyWatcherBlock!)
        }

        propertyWatcherRunning = false
    }

    func getCameraUID() -> String? {
        let skin = LuaSkin.skin(with: nil)
        var dataSize: UInt32 = 0
        var dataUsed: UInt32 = 0

        var prop = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard)
        )

        var err = CMIOObjectGetPropertyDataSize(deviceId, &prop, 0, nil, &dataSize)
        if err != OSStatus(kCMIOHardwareNoError) {
            os_log(.error, "%{public}s", "getUID: Unable to get data size: \(err)")
            return nil
        }

        var uidStringRef: Unmanaged<CFString>?
        err = withUnsafeMutablePointer(to: &uidStringRef) { ptr in
            ptr.withMemoryRebound(to: Optional<Unmanaged<CFString>>.self, capacity: 1) { cfPtr in
                CMIOObjectGetPropertyData(deviceId, &prop, 0, nil, dataSize, &dataUsed, cfPtr)
            }
        }
        if err != OSStatus(kCMIOHardwareNoError) {
            os_log(.error, "%{public}s", "getUID: Unable to get data: \(err)")
            return nil
        }

        return uidStringRef?.takeUnretainedValue() as String?
    }

    func getCameraName() -> String? {
        let skin = LuaSkin.skin(with: nil)
        guard let uid = self.uid,
              let avDevice = AVCaptureDevice(uniqueID: uid) else {
            os_log(.info, "%{public}s", "Unable to get camera name for: \(self.uid ?? "nil")")
            return nil
        }
        return avDevice.localizedName
    }
}

// MARK: - HSCameraManager class

private class HSCameraManager: NSObject {
    var cameraCache: [HSCamera] = []

    func cameraForDeviceID(_ deviceId: CMIODeviceID) -> HSCamera {
        // Check if we already have this device cached
        if let existing = cameraCache.first(where: { $0.deviceId == deviceId }) {
            return existing
        }

        // We don't have this camera cached, so create a new object and cache it.
        let camera = HSCamera(deviceID: deviceId)
        cameraCache.append(camera)
        return camera
    }

    func deviceRemoved(_ deviceId: CMIODeviceID) {
        if let index = cameraCache.firstIndex(where: { $0.deviceId == deviceId }) {
            cameraCache[index].wasRemoved()
            cameraCache.remove(at: index)
        }
    }

    func drainCache() {
        cameraCache = []
    }

    func getCameras() -> [HSCamera] {
        let skin = LuaSkin.skin(with: nil)
        var dataSize: UInt32 = 0
        var prop = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )

        // Get the number of cameras
        var err = CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &prop, 0, nil, &dataSize)
        if err != OSStatus(kCMIOHardwareNoError) {
            os_log(.error, "%{public}s", "Unable to fetch camera device count: \(err)")
            return []
        }
        let numCameras = Int(dataSize) / MemoryLayout<CMIODeviceID>.size

        // Get the camera devices
        var dataUsed: UInt32 = 0
        let cameraList = UnsafeMutablePointer<CMIODeviceID>.allocate(capacity: numCameras)
        defer { cameraList.deallocate() }

        err = CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &prop, 0, nil, dataSize, &dataUsed, cameraList)
        if err != OSStatus(kCMIOHardwareNoError) {
            os_log(.error, "%{public}s", "Unable to fetch camera devices: \(err)")
            return []
        }

        // Prepare the array
        var cameras: [HSCamera] = []
        for i in 0..<numCameras {
            let cameraID = cameraList[i]
            let camera = cameraManagerInstance.cameraForDeviceID(cameraID)
            cameras.append(camera)
        }

        return cameras
    }
}

private var cameraManagerInstance = HSCameraManager()

// MARK: - Lua API

/// hs.camera.allCameras() -> table
/// Function
/// Get all the cameras known to the system
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table containing all of the known cameras
private func allCameras(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    lua_pushany(L, cameraManagerInstance.getCameras() as NSArray)
    return 1
}

// NOTE: Private API used here — AVCaptureDevice.connectionID
// Accessed via value(forKey:) since this is a private property

// This calls the devices watcher callback Lua function when a device is added/removed
private func deviceWatcherDoCallback(_ deviceId: CMIODeviceID, _ event: String) {
    let skin = LuaSkin.skin(with: nil)
    let L = LuaSkin.skin(with: nil).l!

    guard let watcher = deviceWatcher else {
        os_log(.info, "%{public}s", "hs.camera devices watcher callback fired, but deviceWatcher is nil. This is a bug")
        return
    }

    if !lua_isStateGenerationValid(watcher.pointee.lsCanary) {
        return
    }
    let savedTop = lua_gettop(L)

    if watcher.pointee.callback == LUA_NOREF {
        os_log(.info, "%{public}s", "hs.camera devices watcher callback fired, but there is no callback. This is a bug")
        return
    }

    lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(watcher.pointee.callback))
    lua_pushany(L, cameraManagerInstance.cameraForDeviceID(deviceId))
    lua_pushany(L, event as NSString)
    if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }

    assert(savedTop == lua_gettop(L))
}

/// hs.camera.startWatcher()
/// Function
/// Starts the camera devices watcher
///
/// Parameters:
///  * None
///
/// Returns:
///  * None
private func startWatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    guard let watcher = deviceWatcher, watcher.pointee.callback != LUA_NOREF else {
        os_log(.error, "%{public}s", "You must call hs.camera.setWatcherCallback() before hs.camera.startWatcher()")
        return 0
    }

    guard !watcher.pointee.running else { return 0 }

    // For some reason, the device added/removed notifications don't fire unless we ask macOS to enumerate the devices first
    let session = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera, .external],
        mediaType: .video,
        position: .unspecified
    )
    _ = session.devices

    let center = NotificationCenter.default
    deviceWatcherAddedObserver = center.addObserver(
        forName: .AVCaptureDeviceWasConnected,
        object: nil,
        queue: .main
    ) { note in
        guard let device = note.object as? AVCaptureDevice,
              device.hasMediaType(.video) else { return }
        let devId = (device.value(forKey: "connectionID") as? NSNumber)?.uint32Value ?? 0
        DispatchQueue.main.async {
            deviceWatcherDoCallback(CMIODeviceID(devId), "Added")
        }
    }

    deviceWatcherRemovedObserver = center.addObserver(
        forName: .AVCaptureDeviceWasDisconnected,
        object: nil,
        queue: .main
    ) { note in
        guard let device = note.object as? AVCaptureDevice,
              device.hasMediaType(.video) else { return }
        let devId = (device.value(forKey: "connectionID") as? NSNumber)?.uint32Value ?? 0
        DispatchQueue.main.async {
            deviceWatcherDoCallback(CMIODeviceID(devId), "Removed")
            cameraManagerInstance.deviceRemoved(CMIODeviceID(devId))
        }
    }

    os_log(.info, "startWatcher: got objects: %{public}s, %{public}s",
           String(describing: deviceWatcherAddedObserver),
           String(describing: deviceWatcherRemovedObserver))
    watcher.pointee.running = true
    return 0
}

/// hs.camera.stopWatcher()
/// Function
/// Stops the camera devices watcher
///
/// Parameters:
///  * None
///
/// Returns:
///  * None
private func stopWatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // This is an ugly hack so we can call this from elsewhere without checkArgs exploding
    if L != nil {
        }

    guard let watcher = deviceWatcher else { return 0 }

    let center = NotificationCenter.default
    if let added = deviceWatcherAddedObserver {
        center.removeObserver(added, name: .AVCaptureDeviceWasConnected, object: nil)
    }
    if let removed = deviceWatcherRemovedObserver {
        center.removeObserver(removed, name: .AVCaptureDeviceWasDisconnected, object: nil)
    }

    watcher.pointee.running = false
    return 0
}

/// hs.camera.isWatcherRunning() -> Boolean
/// Function
/// Checks if the camera devices watcher is running
///
/// Parameters:
///  * None
///
/// Returns:
///  * A boolean, True if the watcher is running, otherwise False
private func isWatcherRunning(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    lua_pushboolean(L, (deviceWatcher != nil && deviceWatcher!.pointee.running) ? 1 : 0)
    return 1
}

/// hs.camera.setWatcherCallback(fn)
/// Function
/// Sets/clears the callback function for the camera devices watcher
///
/// Parameters:
///  * fn - A callback function, or nil to remove a previously set callback. The callback should accept a two arguments (see Notes below)
///
/// Returns:
///  * None
///
/// Notes:
///  * The callback will be called when a camera is added or removed from the system
///  * To watch for changes within a single camera device, see `hs.camera:newWatcher()`
///  * The callback function arguments are:
///   * An hs.camera device object for the affected device
///   * A string, either "Added" or "Removed" depending on whether the device was added or removed from the system
///  * For "Removed" events, most methods on the hs.camera device object will not function correctly anymore and the device object passed to the callback is likely to be useless. It is recommended you re-check `hs.camera.allCameras()` and keep records of the cameras you care about
///  * Passing nil will cause the watcher to stop if it is running
private func setWatcherCallback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    if deviceWatcher == nil {
        deviceWatcher = .allocate(capacity: 1)
        deviceWatcher!.initialize(to: DeviceWatcher(
            callback: LUA_NOREF,
            running: false,
            lsCanary: lua_currentStateGeneration()
        ))
    }

    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, deviceWatcher!.pointee.callback)
    deviceWatcher!.pointee.callback = LUA_NOREF

    switch lua_type(L, 1) {
    case LUA_TFUNCTION:
        lua_pushvalue(L, 1)
        deviceWatcher!.pointee.callback = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
    case LUA_TNIL:
        _ = stopWatcher(nil)
    default:
        break
    }

    return 0
}

/// hs.camera:uid() -> String
/// Method
/// Get the UID of the camera
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string containing the UID of the camera
///
/// Notes:
///  * The UID is not guaranteed to be stable across reboots
private func camera_uid(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    luaL_checkudata(L, 1, USERDATA_TAG)

    let camera: HSCamera = lua_tovalue(L, at: 1) as! HSCamera
    lua_pushany(L, camera.uid as NSString?)
    return 1
}

/// hs.camera:connectionID() -> String
/// Method
/// Get the raw connection ID of the camera
///
/// Parameters:
///  * None
///
/// Returns:
///  * A number containing the connection ID of the camera
private func camera_cID(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    luaL_checkudata(L, 1, USERDATA_TAG)

    let camera: HSCamera = lua_tovalue(L, at: 1) as! HSCamera
    lua_pushinteger(L, lua_Integer(camera.deviceId))
    return 1
}

/// hs.camera:name() -> String
/// Method
/// Get the name of the camera
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string containing the name of the camera
private func camera_name(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    luaL_checkudata(L, 1, USERDATA_TAG)

    let camera: HSCamera = lua_tovalue(L, at: 1) as! HSCamera
    lua_pushany(L, camera.name as NSString?)
    return 1
}

/// hs.camera:isInUse() -> Boolean
/// Method
/// Get the usage status of the camera
///
/// Parameters:
///  * None
///
/// Returns:
///  * A boolean, True if the camera is in use, otherwise False
private func camera_isinuse(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    luaL_checkudata(L, 1, USERDATA_TAG)

    let camera: HSCamera = lua_tovalue(L, at: 1) as! HSCamera
    lua_pushboolean(L, camera.isInUse ? 1 : 0)
    return 1
}

/// hs.camera:setPropertyWatcherCallback(fn) -> hs.camera object
/// Method
/// Sets or clears a callback for when the properties of an hs.camera object change
///
/// Parameters:
///  * fn - A function to be called when properties of the camera change, or nil to clear a previously set callback. The function should accept the following parameters:
///   * The hs.camera object that changed
///   * A string describing the property that changed. Possible values are:
///    * gone - The device's "in use" status changed (ie another app started using the camera, or stopped using it)
///   * A string containing the scope of the event, this will likely always be "glob"
///   * A number containing the element of the event, this will likely always be "0"
///
/// Returns:
///  * The `hs.camera` object
private func camera_propertyWatcherCallback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    luaL_checkudata(L, 1, USERDATA_TAG)

    let camera: HSCamera = lua_tovalue(L, at: 1) as! HSCamera
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, camera.propertyWatcherCallback)

    camera.propertyWatcherCallback = LUA_NOREF

    switch lua_type(L, 2) {
    case LUA_TFUNCTION:
        lua_pushvalue(L, 2)
        camera.propertyWatcherCallback = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
    case LUA_TNIL:
        break
    default:
        break
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.camera:startPropertyWatcher()
/// Method
/// Starts the property watcher on a camera
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.camera` object
private func camera_startPropertyWatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    luaL_checkudata(L, 1, USERDATA_TAG)

    let camera: HSCamera = lua_tovalue(L, at: 1) as! HSCamera

    if camera.propertyWatcherCallback == LUA_NOREF {
        os_log(.error, "%{public}s", "You must call hs.camera:setPropertyWatcherCallback() before hs.camera:startPropertyWatcher()")
        lua_pushnil(L)
        return 1
    }

    camera.startPropertyWatcher()

    lua_pushvalue(L, 1)
    return 1
}

/// hs.camera:stopPropertyWatcher()
/// Method
/// Stops the property watcher on a camera
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.camera` object
private func camera_stopPropertyWatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    luaL_checkudata(L, 1, USERDATA_TAG)

    let camera: HSCamera = lua_tovalue(L, at: 1) as! HSCamera
    camera.stopPropertyWatcher()

    lua_pushvalue(L, 1)
    return 1
}

/// hs.camera:isPropertyWatcherRunning() -> bool
/// Method
/// Checks if the property watcher on a camera object is running
///
/// Parameters:
///  * None
///
/// Returns:
///  * A boolean, True if the property watcher is running, otherwise False
private func camera_isPropertyWatcherRunning(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    luaL_checkudata(L, 1, USERDATA_TAG)

    let camera: HSCamera = lua_tovalue(L, at: 1) as! HSCamera
    lua_pushboolean(L, camera.propertyWatcherRunning ? 1 : 0)
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions

private func pushHSCamera(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    guard let value = obj as? HSCamera else { return 0 }
    let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    valuePtr.pointee = Unmanaged.passRetained(value).toOpaque()
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private func toHSCameraFromLua(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Any! {
    if luaL_testudata(L, idx, USERDATA_TAG) != nil {
        let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
            .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        guard let rawPtr = ptr.pointee else { return nil }
        return Unmanaged<HSCamera>.fromOpaque(rawPtr).takeUnretainedValue()
    } else {
        os_log(.error, "%{public}s", "expected \(USERDATA_TAG) object, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
        return nil
    }
}

// MARK: - Core Lua metamethods

private func hsCamera_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let camera: HSCamera = lua_tovalue(L, at: 1) as! HSCamera
    lua_pushany(L, "\(USERDATA_TAG): (\(camera.uid ?? "nil"):\(camera.name ?? "nil"))" as NSString)
    return 1
}

private func hsCamera_eq(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let obj1: HSCamera = lua_tovalue(L, at: 1) as! HSCamera
        let obj2: HSCamera = lua_tovalue(L, at: 2) as! HSCamera
        lua_pushboolean(L, obj1.isEqual(to: obj2) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func hsCamera_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

private func module_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)

    if let watcher = deviceWatcher {
        _ = stopWatcher(nil)
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, watcher.pointee.callback)

        watcher.pointee.callback = LUA_NOREF
        watcher.deallocate()
        deviceWatcher = nil
    }

    for camera in cameraManagerInstance.cameraCache {
        camera.wasRemoved()
    }
    cameraManagerInstance.drainCache()

    return 0
}

// MARK: - Registration tables

private var cameraDeviceLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("uid"), func: camera_uid),
    luaL_Reg(name: strdup("connectionID"), func: camera_cID),
    luaL_Reg(name: strdup("name"), func: camera_name),
    luaL_Reg(name: strdup("isInUse"), func: camera_isinuse),
    luaL_Reg(name: strdup("setPropertyWatcherCallback"), func: camera_propertyWatcherCallback),
    luaL_Reg(name: strdup("startPropertyWatcher"), func: camera_startPropertyWatcher),
    luaL_Reg(name: strdup("stopPropertyWatcher"), func: camera_stopPropertyWatcher),
    luaL_Reg(name: strdup("isPropertyWatcherRunning"), func: camera_isPropertyWatcherRunning),

    luaL_Reg(name: strdup("__tostring"), func: hsCamera_tostring),
    luaL_Reg(name: strdup("__eq"), func: hsCamera_eq),
    luaL_Reg(name: strdup("__gc"), func: hsCamera_gc),
    luaL_Reg(name: nil, func: nil),
]

private var cameraLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("allCameras"), func: allCameras),
    luaL_Reg(name: strdup("setWatcherCallback"), func: setWatcherCallback),
    luaL_Reg(name: strdup("startWatcher"), func: startWatcher),
    luaL_Reg(name: strdup("stopWatcher"), func: stopWatcher),
    luaL_Reg(name: strdup("isWatcherRunning"), func: isWatcherRunning),

    luaL_Reg(name: nil, func: nil),
]

private var cameraLibMeta: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: module_gc),
    luaL_Reg(name: nil, func: nil),
]

// MARK: - Lua initialisation

@_cdecl("luaopen_hs_libcamera")
public func luaopen_hs_libcamera(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    cameraManagerInstance = HSCameraManager()

    // Create ref table in registry
    lua_newtable(L)
    refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    // Register userdata metatable
    luaL_newmetatable(L, USERDATA_TAG)
    lua_pushvalue(L, -1)
    lua_setfield(L, -2, "__index")
    luaL_setfuncs(L, &cameraDeviceLib, 0)
    lua_pop(L, 1)

    // Create module table
    lua_createtable(L, 0, Int32(cameraLib.count - 1))
    luaL_setfuncs(L, &cameraLib, 0)

    // Set module metatable (for __gc)
    lua_createtable(L, 0, Int32(cameraLibMeta.count - 1))
    luaL_setfuncs(L, &cameraLibMeta, 0)
    lua_setmetatable(L, -2)

    return 1
}
