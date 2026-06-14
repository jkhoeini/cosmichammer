import Cocoa
import CLua
import Lua
import os.log
import ORSSerial
import IOKit.usb

private let USERDATA_TAG = "hs.serial"
private var refTable: Int32 = LUA_NOREF

// MARK: - ORSSerialPort Attributes Extension

extension ORSSerialPort {
    var ioDeviceAttributes: NSDictionary? {
        var result: NSDictionary? = nil

        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(self.ioKitDevice,
                                            kIOServicePlane,
                                            IOOptionBits(kIORegistryIterateRecursively + kIORegistryIterateParents),
                                            &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var device: io_object_t = IOIteratorNext(iterator)
        while device != 0 && result == nil {
            var usbProperties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(device, &usbProperties, kCFAllocatorDefault, 0) != KERN_SUCCESS {
                IOObjectRelease(device)
                device = IOIteratorNext(iterator)
                continue
            }

            guard let properties = usbProperties?.takeRetainedValue() as NSDictionary? else {
                IOObjectRelease(device)
                device = IOIteratorNext(iterator)
                continue
            }

            let vendorID = properties[kUSBVendorID as String]
            let productID = properties[kUSBProductID as String]

            if vendorID == nil || productID == nil {
                IOObjectRelease(device)
                device = IOIteratorNext(iterator)
                continue
            }

            result = properties
            IOObjectRelease(device)
            device = IOIteratorNext(iterator)
        }

        // Release remaining devices
        while device != 0 {
            IOObjectRelease(device)
            device = IOIteratorNext(iterator)
        }

        return result
    }
}

// MARK: - NSData hex string extension

extension Data {
    var hexadecimalString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - HSSerialPort

class HSSerialPort: NSObject, ORSSerialPortDelegate, LuaTeardownable {
    var serialPortManager: ORSSerialPortManager
    var serialPort: ORSSerialPort?

    var callbackRef: Int32 = Int32(LUA_NOREF)
    var callbackToken: AnyObject? = nil
    var deviceCallbackRef: Int32 = Int32(LUA_NOREF)

    var portName: String?
    var portPath: String?

    var lsCanary: UInt64 = UInt64()

    var parity: ORSSerialPortParity = .none
    var baudRate: NSNumber = NSNumber(value: 115200)
    var numberOfStopBits: UInt = 1
    var numberOfDataBits: UInt = 8
    var shouldEchoReceivedData: Bool = false
    var usesRTSCTSFlowControl: Bool = false
    var usesDTRDSRFlowControl: Bool = false
    var usesDCDOutputFlowControl: Bool = false
    var allowsNonStandardBaudRates: Bool = false
    var rts: Bool = false
    var dtr: Bool = false

    private var tornDown = false

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        if callbackToken != nil {
            serialPort?.close()
            callbackToken = nil
        }
        // callbackRef is cleaned up by the Lua GC caller
    }

    override init() {
        serialPortManager = ORSSerialPortManager.shared()
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Device watching

    func watchDevices() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(serialPortsWereConnected(_:)),
                       name: .ORSSerialPortsWereConnected, object: nil)
        nc.addObserver(self, selector: #selector(serialPortsWereDisconnected(_:)),
                       name: .ORSSerialPortsWereDisconnected, object: nil)
    }

    func unwatchDevices() {
        let nc = NotificationCenter.default
        nc.removeObserver(self, name: .ORSSerialPortsWereConnected, object: nil)
        nc.removeObserver(self, name: .ORSSerialPortsWereDisconnected, object: nil)
    }

    // MARK: - ORSSerialPortDelegate

    func serialPortWasOpened(_ serialPort: ORSSerialPort) {
        guard callbackRef != Int32(LUA_NOREF) else { return }
        let L = lua_getCurrentState()!
        guard lua_isStateGenerationValid(lsCanary) else { return }
        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(callbackRef))
        _ = pushHSSerialPort(L, self)
        lua_pushany(L, "opened" as NSString)
        if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }
    }

    func serialPortWasClosed(_ serialPort: ORSSerialPort) {
        guard callbackRef != Int32(LUA_NOREF) else { return }
        let L = lua_getCurrentState()!
        guard lua_isStateGenerationValid(lsCanary) else { return }
        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(callbackRef))
        _ = pushHSSerialPort(L, self)
        lua_pushany(L, "closed" as NSString)
        if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }
    }

    func serialPort(_ serialPort: ORSSerialPort, didReceive data: Data) {
        guard callbackRef != Int32(LUA_NOREF) else { return }
        let L = lua_getCurrentState()!
        guard lua_isStateGenerationValid(lsCanary) else { return }
        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(callbackRef))
        _ = pushHSSerialPort(L, self)
        lua_pushany(L, "received" as NSString)
        lua_pushany(L, data as NSData)
        lua_pushany(L, data.hexadecimalString as NSString)
        if lua_pcall(L, 4, 0, 0) != LUA_OK { lua_pop(L, 1) }
    }

    func serialPort(_ serialPort: ORSSerialPort, didReceivePacket packetData: Data, matching descriptor: ORSSerialPacketDescriptor) {
        // TODO: Implement `ORSSerialPacketDescriptor` functionality
    }

    func serialPortWasRemovedFromSystem(_ serialPort: ORSSerialPort) {
        if callbackRef != Int32(LUA_NOREF) {
            let L = lua_getCurrentState()!
            guard lua_isStateGenerationValid(lsCanary) else { return }
            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(callbackRef))
            _ = pushHSSerialPort(L, self)
            lua_pushany(L, "removed" as NSString)
            if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }
        }

        self.serialPort = nil
    }

    func serialPort(_ serialPort: ORSSerialPort, didEncounterError error: Error) {
        guard callbackRef != Int32(LUA_NOREF) else { return }
        let L = lua_getCurrentState()!
        guard lua_isStateGenerationValid(lsCanary) else { return }
        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(callbackRef))
        _ = pushHSSerialPort(L, self)
        lua_pushany(L, "error" as NSString)
        lua_pushany(L, error.localizedDescription as NSString)
        if lua_pcall(L, 3, 0, 0) != LUA_OK { lua_pop(L, 1) }
    }

    // MARK: - Device notifications

    @objc func serialPortsWereConnected(_ notification: Notification) {
        guard deviceCallbackRef != Int32(LUA_NOREF) else { return }
        let L = lua_getCurrentState()!
        guard lua_isStateGenerationValid(lsCanary) else { return }
        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(deviceCallbackRef))
        lua_pushany(L, "connected" as NSString)

        let connectedPorts = (notification.userInfo?[ORSConnectedSerialPortsKey] as? [ORSSerialPort]) ?? []
        let result = NSMutableArray()
        for port in connectedPorts {
            result.add(port.name)
        }
        lua_pushany(L, result)
        if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }
    }

    @objc func serialPortsWereDisconnected(_ notification: Notification) {
        guard deviceCallbackRef != Int32(LUA_NOREF) else { return }
        let L = lua_getCurrentState()!
        guard lua_isStateGenerationValid(lsCanary) else { return }
        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(deviceCallbackRef))
        lua_pushany(L, "disconnected" as NSString)

        let disconnectedPorts = (notification.userInfo?[ORSDisconnectedSerialPortsKey] as? [ORSSerialPort]) ?? []
        let result = NSMutableArray()
        for port in disconnectedPorts {
            result.add(port.name)
        }
        lua_pushany(L, result)
        if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }
    }

    // MARK: - Port validation and creation

    func isPortNameValid(_ portName: String) -> Bool {
        for port in serialPortManager.availablePorts {
            if portName == port.name {
                self.portName = portName
                return true
            }
        }
        return false
    }

    func isPathValid(_ path: String) -> Bool {
        for port in serialPortManager.availablePorts {
            if path == port.path {
                self.portPath = port.path
                self.portName = port.name
                return true
            }
        }
        return false
    }

    func createPortFromPortName(_ portName: String) -> Bool {
        for port in serialPortManager.availablePorts {
            if portName == port.name {
                serialPort?.close()
                serialPort?.delegate = nil

                serialPort = ORSSerialPort(path: port.path)
                serialPort?.delegate = self
                return true
            }
        }
        return false
    }

    func createPortFromPath(_ portPath: String) -> Bool {
        serialPort?.close()
        serialPort?.delegate = nil

        serialPort = ORSSerialPort(path: portPath)
        serialPort?.delegate = self
        return true
    }

    func open() -> Bool {
        if serialPort == nil, let path = portPath {
            _ = createPortFromPath(path)
        }
        if serialPort == nil, let name = portName {
            _ = createPortFromPortName(name)
        }
        if let sp = serialPort {
            sp.allowsNonStandardBaudRates = allowsNonStandardBaudRates
            sp.parity = parity
            sp.baudRate = baudRate
            sp.numberOfStopBits = numberOfStopBits
            sp.numberOfDataBits = numberOfDataBits
            sp.shouldEchoReceivedData = shouldEchoReceivedData
            sp.usesRTSCTSFlowControl = usesRTSCTSFlowControl
            sp.usesDTRDSRFlowControl = usesDTRDSRFlowControl
            sp.usesDCDOutputFlowControl = usesDCDOutputFlowControl
            sp.rts = rts
            sp.dtr = dtr
            sp.open()
        }
        return serialPort?.isOpen ?? false
    }

    func changeParity(_ parity: ORSSerialPortParity) {
        self.parity = parity
        if isOpen { serialPort?.parity = parity }
    }

    func changeBaudRate(_ baudRate: NSNumber) {
        self.baudRate = baudRate
        if isOpen {
            serialPort?.allowsNonStandardBaudRates = allowsNonStandardBaudRates
            serialPort?.baudRate = baudRate
        }
    }

    func changeNumberOfStopBits(_ bits: UInt) {
        numberOfStopBits = bits
        if isOpen { serialPort?.numberOfStopBits = bits }
    }

    func changeNumberOfDataBits(_ bits: UInt) {
        numberOfDataBits = bits
        if isOpen { serialPort?.numberOfDataBits = bits }
    }

    func changeRTS(_ enabled: Bool) {
        rts = enabled
        if isOpen { serialPort?.rts = enabled }
    }

    func changeDTR(_ enabled: Bool) {
        dtr = enabled
        if isOpen { serialPort?.dtr = enabled }
    }

    func changeUsesRTSCTSFlowControl(_ value: Bool) {
        usesRTSCTSFlowControl = value
        if isOpen { serialPort?.usesRTSCTSFlowControl = value }
    }

    func changeUsesDTRDSRFlowControl(_ value: Bool) {
        usesDTRDSRFlowControl = value
        if isOpen { serialPort?.usesDTRDSRFlowControl = value }
    }

    func changeUsesDCDOutputFlowControl(_ value: Bool) {
        usesDCDOutputFlowControl = value
        if isOpen { serialPort?.usesDCDOutputFlowControl = value }
    }

    func changeShouldEchoReceivedData(_ value: Bool) {
        shouldEchoReceivedData = value
        if isOpen { serialPort?.shouldEchoReceivedData = value }
    }

    func close() {
        serialPort?.close()
    }

    var isOpen: Bool {
        serialPort?.isOpen ?? false
    }

    func sendData(_ data: Data) {
        serialPort?.send(data)
    }
}

// MARK: - Lua module functions

/// hs.serial.newFromName(portName) -> serialPortObject
/// Constructor
/// Creates a new `hs.serial` object using the port name.
///
/// Parameters:
///  * portName - A string containing the port name.
///
/// Returns:
///  * An `hs.serial` object or `nil` if an error occurred.
///
/// Notes:
///  * A valid port name can be found by checking `hs.serial.availablePortNames()`.
private func serial_newFromName(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checktype(L, 1, LUA_TSTRING)

    let portName = lua_tovalue(L, at: 1) as! String
    let serialPort = HSSerialPort()
    serialPort.lsCanary = lua_currentStateGeneration()

    if serialPort.isPortNameValid(portName) {
        L.push(userdata: serialPort)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.serial.newFromPath(path) -> serialPortObject
/// Constructor
/// Creates a new `hs.serial` object using a path.
///
/// Parameters:
///  * path - A string containing the path (i.e. "/dev/cu.usbserial").
///
/// Returns:
///  * An `hs.serial` object or `nil` if an error occurred.
///
/// Notes:
///  * A valid port name can be found by checking `hs.serial.availablePortPaths()`.
private func serial_newFromPath(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checktype(L, 1, LUA_TSTRING)

    let path = lua_tovalue(L, at: 1) as! String
    let serialPort = HSSerialPort()
    serialPort.lsCanary = lua_currentStateGeneration()

    if serialPort.isPathValid(path) {
        L.push(userdata: serialPort)
    } else {
        lua_pushnil(L)
    }
    return 1
}


/// hs.serial.availablePortNames() -> table
/// Function
/// Returns a table of currently connected serial ports names.
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table containing the names of any connected serial port names as strings.
private func serial_availablePortNames(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let portManager = ORSSerialPortManager.shared()
    let result = NSMutableArray()
    for port in portManager.availablePorts {
        result.add(port.name)
    }
    lua_pushany(L, result)
    return 1
}

/// hs.serial.availablePortDetails() -> table
/// Function
/// Returns a table of currently connected serial ports details, organised by port name.
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table containing the IOKit details of any connected serial ports, organised by port name.
private func serial_availablePortDetails(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let portManager = ORSSerialPortManager.shared()
    let result = NSMutableDictionary()
    for port in portManager.availablePorts {
        let attributes = port.ioDeviceAttributes ?? NSDictionary()
        result[port.name] = attributes
    }
    lua_pushany(L, result)
    return 1
}

/// hs.serial.availablePortPaths() -> table
/// Function
/// Returns a table of currently connected serial ports paths.
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table containing the names of any connected serial port paths as strings.
private func serial_availablePortPaths(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let portManager = ORSSerialPortManager.shared()
    let result = NSMutableArray()
    for port in portManager.availablePorts {
        result.add(port.path)
    }
    lua_pushany(L, result)
    return 1
}


// MARK: - Device callback

private var watcherDeviceManager: HSSerialPort? = nil

/// hs.serial.deviceCallback(callbackFn) -> none
/// Function
/// A callback that's triggered when a serial port is added or removed from the system.
///
/// Parameters:
///  * callbackFn - the callback function to trigger, or nil to remove the current callback
///
/// Returns:
///  * None
///
/// Notes:
///  * The callback function should expect 1 argument and should not return anything:
///    * `devices` - A table containing the names of any serial ports connected as strings.
private func serial_deviceCallback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    if lua_type(L, 1) == LUA_TNIL {
        guard let manager = watcherDeviceManager else { return 0 }
        lua_unrefRegistryRef(L, &manager.deviceCallbackRef)
        manager.unwatchDevices()
        watcherDeviceManager = nil
        return 0
    }

    if watcherDeviceManager == nil {
        watcherDeviceManager = HSSerialPort()
        watcherDeviceManager!.lsCanary = lua_currentStateGeneration()
    }

    lua_replaceRegistryFunctionRef(L, &watcherDeviceManager!.deviceCallbackRef, at: 1)
    watcherDeviceManager!.watchDevices()

    return 0
}

// MARK: - Lua<->NSObject Conversion

@discardableResult
func pushHSSerialPort(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    guard let value = obj as? HSSerialPort else { return 0 }
    L.push(userdata: value)
    return 1
}

// MARK: - Module entry point

@_cdecl("luaopen_hs_libserial")
public func luaopen_hs_libserial(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Create ref table in registry
    lua_newtable(L)
    refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    // Register idiomatic Metatable<HSSerialPort> with LuaSwift.
    L.register(Metatable<HSSerialPort>(
        fields: [
            "name": .closure { L in
                let serialPort: HSSerialPort = try L.checkArgument(1)
                if let name = serialPort.serialPort?.name {
                    lua_pushany(L, name as NSString)
                } else {
                    lua_pushnil(L)
                }
                return 1
            },
            "path": .closure { L in
                let serialPort: HSSerialPort = try L.checkArgument(1)
                if let path = serialPort.serialPort?.path {
                    lua_pushany(L, path as NSString)
                } else {
                    lua_pushnil(L)
                }
                return 1
            },
            "open": .closure { L in
                let serialPort: HSSerialPort = try L.checkArgument(1)
                if serialPort.open() {
                    lua_pushvalue(L, 1)
                } else {
                    lua_pushnil(L)
                }
                return 1
            },
            "close": .closure { L in
                let serialPort: HSSerialPort = try L.checkArgument(1)
                serialPort.close()
                lua_pushvalue(L, 1)
                return 1
            },
            "baudRate": .closure { L in
                let serialPort: HSSerialPort = try L.checkArgument(1)
                if lua_gettop(L) == 1 {
                    lua_pushany(L, serialPort.baudRate)
                } else {
                    let proposedBaudRate = lua_tovalue(L, at: 2) as! NSNumber
                    let allowNonStandard = lua_isboolean(L, 3) && lua_toboolean(L, 3) != 0
                    if allowNonStandard {
                        serialPort.allowsNonStandardBaudRates = true
                        serialPort.changeBaudRate(proposedBaudRate)
                    } else {
                        let available: [NSNumber] = [300, 1200, 2400, 4800, 9600, 14400, 19200, 28800, 38400, 57600, 115200, 230400]
                        if available.contains(proposedBaudRate) {
                            serialPort.changeBaudRate(proposedBaudRate)
                        } else {
                            os_log(.error, "%{public}s", "\(USERDATA_TAG): Invalid Baud Rate supplied. Possible baud rates are: 300, 1200, 2400, 4800, 9600, 14400, 19200, 28800, 38400, 57600, 115200 and 230400.")
                        }
                    }
                    lua_pushvalue(L, 1)
                }
                return 1
            },
            "sendData": .closure { L in
                let serialPort: HSSerialPort = try L.checkArgument(1)
                luaL_checktype(L, 2, LUA_TSTRING)
                let data = lua_checkdata(L, at: 2)
                serialPort.sendData(data)
                return 0
            },
            "parity": .closure { L in
                let serialPort: HSSerialPort = try L.checkArgument(1)
                if lua_gettop(L) == 1 {
                    let parity = serialPort.serialPort?.parity ?? serialPort.parity
                    switch parity {
                    case .none: lua_pushany(L, "none" as NSString)
                    case .odd:  lua_pushany(L, "odd" as NSString)
                    case .even: lua_pushany(L, "even" as NSString)
                    @unknown default: lua_pushany(L, "none" as NSString)
                    }
                } else {
                    let proposed = lua_tovalue(L, at: 2) as! String
                    let available = ["none", "odd", "even"]
                    if available.contains(proposed) {
                        let newParity: ORSSerialPortParity
                        switch proposed {
                        case "odd":  newParity = .odd
                        case "even": newParity = .even
                        default:     newParity = .none
                        }
                        serialPort.changeParity(newParity)
                    } else {
                        os_log(.error, "%{public}s", "\(USERDATA_TAG): Invalid Parity string supplied. Should be 'none', 'odd' or 'even'.")
                    }
                    lua_pushvalue(L, 1)
                }
                return 1
            },
            "isOpen": .closure { L in
                let serialPort: HSSerialPort = try L.checkArgument(1)
                L.push(serialPort.isOpen)
                return 1
            },
            "callback": .closure { L in
                let serialPort: HSSerialPort = try L.checkArgument(1)
                if serialPort.callbackToken != nil {
                    serialPort.callbackToken = nil
                }
                lua_replaceRegistryFunctionRef(L, &serialPort.callbackRef, at: 2)
                lua_pushvalue(L, 1)
                return 1
            },
            "stopBits": .closure { L in
                let serialPort: HSSerialPort = try L.checkArgument(1)
                if lua_gettop(L) == 1 {
                    lua_pushany(L, NSNumber(value: serialPort.numberOfStopBits))
                } else {
                    let proposed = UInt(lua_tointeger(L, 2))
                    if proposed >= 1 && proposed <= 2 {
                        serialPort.changeNumberOfStopBits(proposed)
                    } else {
                        os_log(.error, "%{public}s", "\(USERDATA_TAG): Invalid number of stop bits Should be 1 or 2.")
                    }
                    lua_pushvalue(L, 1)
                }
                return 1
            },
            "dataBits": .closure { L in
                let serialPort: HSSerialPort = try L.checkArgument(1)
                if lua_gettop(L) == 1 {
                    lua_pushany(L, NSNumber(value: serialPort.numberOfDataBits))
                } else {
                    let proposed = UInt(lua_tointeger(L, 2))
                    if proposed >= 5 && proposed <= 8 {
                        serialPort.changeNumberOfDataBits(proposed)
                    } else {
                        os_log(.error, "%{public}s", "\(USERDATA_TAG): Invalid number of data bits Should be 1 or 2.")
                    }
                    lua_pushvalue(L, 1)
                }
                return 1
            },
            "shouldEchoReceivedData": .closure { L in
                let serialPort: HSSerialPort = try L.checkArgument(1)
                if lua_gettop(L) == 1 {
                    L.push(serialPort.shouldEchoReceivedData)
                } else {
                    serialPort.changeShouldEchoReceivedData(lua_toboolean(L, 2) != 0)
                    lua_pushvalue(L, 1)
                }
                return 1
            },
            "usesRTSCTSFlowControl": .closure { L in
                let serialPort: HSSerialPort = try L.checkArgument(1)
                if lua_gettop(L) == 1 {
                    L.push(serialPort.usesRTSCTSFlowControl)
                } else {
                    serialPort.changeUsesRTSCTSFlowControl(lua_toboolean(L, 2) != 0)
                    lua_pushvalue(L, 1)
                }
                return 1
            },
            "usesDTRDSRFlowControl": .closure { L in
                let serialPort: HSSerialPort = try L.checkArgument(1)
                if lua_gettop(L) == 1 {
                    L.push(serialPort.usesDTRDSRFlowControl)
                } else {
                    serialPort.changeUsesDTRDSRFlowControl(lua_toboolean(L, 2) != 0)
                    lua_pushvalue(L, 1)
                }
                return 1
            },
            "usesDCDOutputFlowControl": .closure { L in
                let serialPort: HSSerialPort = try L.checkArgument(1)
                if lua_gettop(L) == 1 {
                    L.push(serialPort.usesDCDOutputFlowControl)
                } else {
                    serialPort.changeUsesDCDOutputFlowControl(lua_toboolean(L, 2) != 0)
                    lua_pushvalue(L, 1)
                }
                return 1
            },
            "rts": .closure { L in
                let serialPort: HSSerialPort = try L.checkArgument(1)
                if lua_gettop(L) == 1 {
                    L.push(serialPort.rts)
                } else {
                    serialPort.changeRTS(lua_toboolean(L, 2) != 0)
                    lua_pushvalue(L, 1)
                }
                return 1
            },
            "dtr": .closure { L in
                let serialPort: HSSerialPort = try L.checkArgument(1)
                if lua_gettop(L) == 1 {
                    L.push(serialPort.dtr)
                } else {
                    serialPort.changeDTR(lua_toboolean(L, 2) != 0)
                    lua_pushvalue(L, 1)
                }
                return 1
            },
        ],
        eq: .closure { L in
            if let obj1: HSSerialPort = L.touserdata(1),
               let obj2: HSSerialPort = L.touserdata(2) {
                L.push(obj1.isEqual(obj2))
            } else {
                L.push(false)
            }
            return 1
        },
        tostring: .closure { L in
            let obj: HSSerialPort = try L.checkArgument(1)
            let title = obj.portName ?? "unknown"
            let connected = obj.isOpen ? "Connected" : "Disconnected"
            L.push("\(USERDATA_TAG): \(title) - \(connected) (\(String(describing: lua_topointer(L, 1)!)))")
            return 1
        }
    ))

    installMetatableBoilerplate(L, for: HSSerialPort.self, tag: USERDATA_TAG)

    // Create module table
    lua_createtable(L, 0, 6)
    L.push(serial_newFromName)
    lua_setfield(L, -2, "newFromName")
    L.push(serial_newFromPath)
    lua_setfield(L, -2, "newFromPath")
    L.push(serial_availablePortNames)
    lua_setfield(L, -2, "availablePortNames")
    L.push(serial_availablePortPaths)
    lua_setfield(L, -2, "availablePortPaths")
    L.push(serial_availablePortDetails)
    lua_setfield(L, -2, "availablePortDetails")
    L.push(serial_deviceCallback)
    lua_setfield(L, -2, "deviceCallback")

    // Set module metatable (for __gc)
    lua_createtable(L, 0, 1)
    lua_pushcclosure(L, { L in
        if let manager = watcherDeviceManager {
            lua_unrefRegistryRef(L, &manager.deviceCallbackRef)
            manager.unwatchDevices()
            watcherDeviceManager = nil
        }
        return 0
    }, 0)
    lua_setfield(L, -2, "__gc")
    lua_setmetatable(L, -2)

    return 1
}
