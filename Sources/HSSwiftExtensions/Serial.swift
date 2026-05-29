import Cocoa
import LuaSkin
import os.log
import ORSSerial
import IOKit.usb

private let USERDATA_TAG = "hs.serial"
private var refTable: Int32 = LUA_NOREF

private func get_objectFromUserdata<T: AnyObject>(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32, _ tag: UnsafePointer<CChar>) -> T {
    let ptr = luaL_checkudata(L, idx, tag)!.assumingMemoryBound(to: UnsafeMutableRawPointer.self)
    return Unmanaged<T>.fromOpaque(ptr.pointee).takeUnretainedValue()
}

// MARK: - ORSSerialPort Attributes Extension

extension ORSSerialPort {
    @objc var ioDeviceAttributes: NSDictionary? {
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

class HSSerialPort: NSObject, ORSSerialPortDelegate {
    var serialPortManager: ORSSerialPortManager
    var serialPort: ORSSerialPort?

    var selfRefCount: Int32 = 0
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
        lua_pushany(L, self)
        lua_pushany(L, "opened" as NSString)
        if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }
    }

    func serialPortWasClosed(_ serialPort: ORSSerialPort) {
        guard callbackRef != Int32(LUA_NOREF) else { return }
        let L = lua_getCurrentState()!
        guard lua_isStateGenerationValid(lsCanary) else { return }
        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(callbackRef))
        lua_pushany(L, self)
        lua_pushany(L, "closed" as NSString)
        if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }
    }

    func serialPort(_ serialPort: ORSSerialPort, didReceive data: Data) {
        guard callbackRef != Int32(LUA_NOREF) else { return }
        let L = lua_getCurrentState()!
        guard lua_isStateGenerationValid(lsCanary) else { return }
        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(callbackRef))
        lua_pushany(L, self)
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
            lua_pushany(L, self)
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
        lua_pushany(L, self)
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
        lua_pushany(L, serialPort)
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
        lua_pushany(L, serialPort)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.serial:callback(callbackFn) -> serialPortObject
/// Method
/// Sets or removes a callback function for the `hs.serial` object.
///
/// Parameters:
///  * `callbackFn` - a function to set as the callback for this `hs.serial` object.  If the value provided is `nil`, any currently existing callback function is removed.
///
/// Returns:
///  * The `hs.serial` object
///
/// Notes:
///  * The callback function should expect 4 arguments and should not return anything:
///    * `serialPortObject` - The serial port object that triggered the callback.
///    * `callbackType` - A string containing "opened", "closed", "received", "removed" or "error".
///    * `message` - If the `callbackType` is "received", then this will be the data received as a string. If the `callbackType` is "error", this will be the error message as a string.
///    * `hexadecimalString` - If the `callbackType` is "received", then this will be the data received as a hexadecimal string.
private func serial_callback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let serialPort: HSSerialPort = lua_tovalue(L, at: 1) as! HSSerialPort

    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, serialPort.callbackRef)


    serialPort.callbackRef = LUA_NOREF
    if serialPort.callbackToken != nil {
        serialPort.callbackToken = nil
    }

    if lua_type(L, 2) != LUA_TNIL {
        lua_pushvalue(L, 2)
        serialPort.callbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
    }

    lua_pushvalue(L, 1)
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

/// hs.serial:name() -> string
/// Method
/// Returns the name of a `hs.serial` object.
///
/// Parameters:
///  * None
///
/// Returns:
///  * The name as a string.
private func serial_name(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let serialPort: HSSerialPort = lua_tovalue(L, at: 1) as! HSSerialPort
    if let name = serialPort.serialPort?.name {
        lua_pushany(L, name as NSString)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.serial:path() -> string
/// Method
/// Returns the path of a `hs.serial` object.
///
/// Parameters:
///  * None
///
/// Returns:
///  * The path as a string.
private func serial_path(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let serialPort: HSSerialPort = lua_tovalue(L, at: 1) as! HSSerialPort
    if let path = serialPort.serialPort?.path {
        lua_pushany(L, path as NSString)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.serial:open() -> serialPortObject | nil
/// Method
/// Opens the serial port.
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.serial` object or `nil` if the port could not be opened.
private func serial_open(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let serialPort: HSSerialPort = lua_tovalue(L, at: 1) as! HSSerialPort
    if serialPort.open() {
        lua_pushvalue(L, 1)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.serial:close() -> serialPortObject
/// Method
/// Closes the serial port.
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.serial` object.
private func serial_close(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let serialPort: HSSerialPort = lua_tovalue(L, at: 1) as! HSSerialPort
    serialPort.close()
    lua_pushvalue(L, 1)
    return 1
}

/// hs.serial:baudRate([value], [allowNonStandardBaudRates]) -> number | serialPortObject
/// Method
/// Gets or sets the baud rate for the serial port.
///
/// Parameters:
///  * value - An optional number to set the baud rate.
///  * [allowNonStandardBaudRates] - An optional boolean to enable non-standard baud rates. Defaults to `false`.
///
/// Returns:
///  * If a value is specified, then this method returns the serial port object. Otherwise this method returns the baud rate as a number
///
/// Notes:
///  * This function supports the following standard baud rates as numbers: 300, 1200, 2400, 4800, 9600, 14400, 19200, 28800, 38400, 57600, 115200, 230400.
///  * If no baud rate is supplied, it defaults to 115200.
private func serial_baudRate(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let serialPort: HSSerialPort = lua_tovalue(L, at: 1) as! HSSerialPort

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
}

/// hs.serial:parity([value]) -> string | serialPortObject
/// Method
/// Gets or sets the parity for the serial port.
///
/// Parameters:
///  * value - An optional string to set the parity. It can be "none", "odd" or "even".
///
/// Returns:
///  * If a value is specified, then this method returns the serial port object. Otherwise this method returns a string value of "none", "odd" or "even".
private func serial_parity(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let serialPort: HSSerialPort = lua_tovalue(L, at: 1) as! HSSerialPort

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
}

/// hs.serial:usesDTRDSRFlowControl([value]) -> boolean | serialPortObject
/// Method
/// Gets or sets whether the port should use DCD Flow Control.
///
/// Parameters:
///  * value - An optional boolean.
///
/// Returns:
///  * If a value is specified, then this method returns the serial port object. Otherwise this method returns a boolean.
///
/// Notes:
///  * The default value is `false`.
private func serial_usesDCDOutputFlowControl(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let serialPort: HSSerialPort = lua_tovalue(L, at: 1) as! HSSerialPort
    if lua_gettop(L) == 1 {
        lua_pushboolean(L, serialPort.usesDCDOutputFlowControl ? 1 : 0)
    } else {
        serialPort.changeUsesDCDOutputFlowControl(lua_toboolean(L, 2) != 0)
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.serial:usesDTRDSRFlowControl([value]) -> boolean | serialPortObject
/// Method
/// Gets or sets whether the port should use DTR/DSR Flow Control.
///
/// Parameters:
///  * value - An optional boolean.
///
/// Returns:
///  * If a value is specified, then this method returns the serial port object. Otherwise this method returns a boolean.
///
/// Notes:
///  * The default value is `false`.
private func serial_usesDTRDSRFlowControl(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let serialPort: HSSerialPort = lua_tovalue(L, at: 1) as! HSSerialPort
    if lua_gettop(L) == 1 {
        lua_pushboolean(L, serialPort.usesDTRDSRFlowControl ? 1 : 0)
    } else {
        serialPort.changeUsesDTRDSRFlowControl(lua_toboolean(L, 2) != 0)
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.serial:usesRTSCTSFlowControl([value]) -> boolean | serialPortObject
/// Method
/// Gets or sets whether the port should use RTS/CTS Flow Control.
///
/// Parameters:
///  * value - An optional boolean.
///
/// Returns:
///  * If a value is specified, then this method returns the serial port object. Otherwise this method returns a boolean.
///
/// Notes:
///  * The default value is `false`.
private func serial_usesRTSCTSFlowControl(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let serialPort: HSSerialPort = lua_tovalue(L, at: 1) as! HSSerialPort
    if lua_gettop(L) == 1 {
        lua_pushboolean(L, serialPort.usesRTSCTSFlowControl ? 1 : 0)
    } else {
        serialPort.changeUsesRTSCTSFlowControl(lua_toboolean(L, 2) != 0)
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.serial:dtr([value]) -> boolean | serialPortObject
/// Method
/// Gets or sets the state of the serial port's DTR (Data Terminal Ready) pin.
///
/// Parameters:
///  * value - An optional boolean.
///
/// Returns:
///  * If a value is specified, then this method returns the serial port object. Otherwise this method returns a boolean.
///
/// Notes:
///  * The default value is `false`.
///  * Setting this to `true` is most likely required for Arduino devices prior to opening the serial port.
private func serial_dtr(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let serialPort: HSSerialPort = lua_tovalue(L, at: 1) as! HSSerialPort
    if lua_gettop(L) == 1 {
        lua_pushboolean(L, serialPort.dtr ? 1 : 0)
    } else {
        serialPort.changeDTR(lua_toboolean(L, 2) != 0)
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.serial:rts([value]) -> boolean | serialPortObject
/// Method
/// Gets or sets the state of the serial port's RTS (Request to Send) pin.
///
/// Parameters:
///  * value - An optional boolean.
///
/// Returns:
///  * If a value is specified, then this method returns the serial port object. Otherwise this method returns a boolean.
///
/// Notes:
///  * The default value is `false`.
///  * Setting this to `true` is most likely required for Arduino devices prior to opening the serial port.
private func serial_rts(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let serialPort: HSSerialPort = lua_tovalue(L, at: 1) as! HSSerialPort
    if lua_gettop(L) == 1 {
        lua_pushboolean(L, serialPort.rts ? 1 : 0)
    } else {
        serialPort.changeRTS(lua_toboolean(L, 2) != 0)
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.serial:shouldEchoReceivedData([value]) -> boolean | serialPortObject
/// Method
/// Gets or sets whether the port should echo received data.
///
/// Parameters:
///  * value - An optional boolean.
///
/// Returns:
///  * If a value is specified, then this method returns the serial port object. Otherwise this method returns a boolean.
///
/// Notes:
///  * The default value is `false`.
private func serial_shouldEchoReceivedData(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let serialPort: HSSerialPort = lua_tovalue(L, at: 1) as! HSSerialPort
    if lua_gettop(L) == 1 {
        lua_pushboolean(L, serialPort.shouldEchoReceivedData ? 1 : 0)
    } else {
        serialPort.changeShouldEchoReceivedData(lua_toboolean(L, 2) != 0)
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.serial:stopBits([value]) -> number | serialPortObject
/// Method
/// Gets or sets the number of stop bits for the serial port.
///
/// Parameters:
///  * value - An optional number to set the number of stop bits. It can be 1 or 2.
///
/// Returns:
///  * If a value is specified, then this method returns the serial port object. Otherwise this method returns the number of stop bits as a number.
///
/// Notes:
///  * The default value is 1.
private func serial_numberOfStopBits(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let serialPort: HSSerialPort = lua_tovalue(L, at: 1) as! HSSerialPort
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
}

/// hs.serial:dataBits([value]) -> number | serialPortObject
/// Method
/// Gets or sets the number of data bits for the serial port.
///
/// Parameters:
///  * value - An optional number to set the number of data bits. It can be 5 to 8.
///
/// Returns:
///  * If a value is specified, then this method returns the serial port object. Otherwise this method returns the data bits as a number.
///  * The default value is 8.
private func serial_numberOfDataBits(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let serialPort: HSSerialPort = lua_tovalue(L, at: 1) as! HSSerialPort
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
}

/// hs.serial:isOpen() -> boolean
/// Method
/// Gets whether or not a serial port is open.
///
/// Parameters:
///  * None
///
/// Returns:
///  * `true` if open, otherwise `false`.
private func serial_isOpen(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let serialPort: HSSerialPort = lua_tovalue(L, at: 1) as! HSSerialPort
    lua_pushboolean(L, serialPort.isOpen ? 1 : 0)
    return 1
}

/// hs.serial:sendData(value) -> none
/// Method
/// Sends data via a serial port.
///
/// Parameters:
///  * value - A string of data to send.
///
/// Returns:
///  * None
private func serial_sendData(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)

    luaL_checktype(L, 2, LUA_TSTRING)
    let serialPort: HSSerialPort = lua_tovalue(L, at: 1) as! HSSerialPort
    let data = lua_tovalue(L, at: 2) as! Data
    serialPort.sendData(data)
    return 0
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
        if manager.deviceCallbackRef != Int32(LUA_NOREF) {
            luaL_unref(L, LUA_REGISTRYINDEX_VALUE, manager.deviceCallbackRef)

            manager.deviceCallbackRef = LUA_NOREF
        }
        manager.unwatchDevices()
        watcherDeviceManager = nil
        return 0
    }

    if watcherDeviceManager == nil {
        watcherDeviceManager = HSSerialPort()
        watcherDeviceManager!.lsCanary = lua_currentStateGeneration()
    }

    lua_pushvalue(L, 1)
    watcherDeviceManager!.deviceCallbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
    watcherDeviceManager!.watchDevices()

    return 0
}

// MARK: - Lua<->NSObject Conversion

private func pushHSSerialPort(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let value = obj as! HSSerialPort
    value.selfRefCount += 1
    let ptr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!.assumingMemoryBound(to: UnsafeMutableRawPointer.self)
    ptr.pointee = Unmanaged.passRetained(value).toOpaque()
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private func toHSSerialPortFromLua(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Any! {
    if luaL_testudata(L, idx, USERDATA_TAG) != nil {
        return get_objectFromUserdata(L, idx, USERDATA_TAG) as HSSerialPort
    } else {
        os_log(.error, "%{public}s", "expected \(USERDATA_TAG) object, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
        return nil
    }
}

// MARK: - Cosmic Hammer/Lua Infrastructure

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let obj = lua_tovalue(L, at: 1) as! HSSerialPort
    let title = obj.portName ?? "unknown"
    let connected = obj.isOpen ? "Connected" : "Disconnected"
    lua_pushany(L, "\(USERDATA_TAG): \(title) - \(connected) (\(String(describing: lua_topointer(L, 1)!)))" as NSString)
    return 1
}

private func userdata_eq(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let obj1 = lua_tovalue(L, at: 1) as! HSSerialPort
        let obj2 = lua_tovalue(L, at: 2) as! HSSerialPort
        lua_pushboolean(L, obj1.isEqual(obj2) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func userdata_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!.assumingMemoryBound(to: UnsafeMutableRawPointer.self)
    let obj = Unmanaged<HSSerialPort>.fromOpaque(ptr.pointee).takeRetainedValue()

    obj.selfRefCount -= 1
    if obj.selfRefCount == 0 {
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, obj.callbackRef)

        obj.callbackRef = LUA_NOREF

        if obj.callbackToken != nil {
            obj.serialPort?.close()
            obj.callbackToken = nil
        }

        var tmpCanary = obj.lsCanary
        obj.lsCanary = tmpCanary
    }

    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

private func meta_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    if let manager = watcherDeviceManager {
        if manager.deviceCallbackRef != Int32(LUA_NOREF) {
            luaL_unref(L, LUA_REGISTRYINDEX_VALUE, manager.deviceCallbackRef)

            manager.deviceCallbackRef = LUA_NOREF
        }
        manager.unwatchDevices()
        watcherDeviceManager = nil
    }
    return 0
}

// MARK: - luaL_Reg tables

private var userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("name"), func: serial_name),
    luaL_Reg(name: strdup("path"), func: serial_path),
    luaL_Reg(name: strdup("open"), func: serial_open),
    luaL_Reg(name: strdup("close"), func: serial_close),
    luaL_Reg(name: strdup("baudRate"), func: serial_baudRate),
    luaL_Reg(name: strdup("sendData"), func: serial_sendData),
    luaL_Reg(name: strdup("parity"), func: serial_parity),
    luaL_Reg(name: strdup("isOpen"), func: serial_isOpen),
    luaL_Reg(name: strdup("callback"), func: serial_callback),
    luaL_Reg(name: strdup("stopBits"), func: serial_numberOfStopBits),
    luaL_Reg(name: strdup("dataBits"), func: serial_numberOfDataBits),
    luaL_Reg(name: strdup("shouldEchoReceivedData"), func: serial_shouldEchoReceivedData),
    luaL_Reg(name: strdup("usesRTSCTSFlowControl"), func: serial_usesRTSCTSFlowControl),
    luaL_Reg(name: strdup("usesDTRDSRFlowControl"), func: serial_usesDTRDSRFlowControl),
    luaL_Reg(name: strdup("rts"), func: serial_rts),
    luaL_Reg(name: strdup("dtr"), func: serial_dtr),
    luaL_Reg(name: strdup("usesDCDOutputFlowControl"), func: serial_usesDCDOutputFlowControl),
    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: strdup("__eq"), func: userdata_eq),
    luaL_Reg(name: strdup("__gc"), func: userdata_gc),
    luaL_Reg(name: nil, func: nil),
]

private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("newFromName"), func: serial_newFromName),
    luaL_Reg(name: strdup("newFromPath"), func: serial_newFromPath),
    luaL_Reg(name: strdup("availablePortNames"), func: serial_availablePortNames),
    luaL_Reg(name: strdup("availablePortPaths"), func: serial_availablePortPaths),
    luaL_Reg(name: strdup("availablePortDetails"), func: serial_availablePortDetails),
    luaL_Reg(name: strdup("deviceCallback"), func: serial_deviceCallback),
    luaL_Reg(name: nil, func: nil),
]

private var module_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: meta_gc),
    luaL_Reg(name: nil, func: nil),
]

// MARK: - Module entry point

@_cdecl("luaopen_hs_libserial")
public func luaopen_hs_libserial(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Create ref table in registry
    lua_newtable(L)
    refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    // Register userdata metatable
    luaL_newmetatable(L, USERDATA_TAG)
    lua_pushvalue(L, -1)
    lua_setfield(L, -2, "__index")
    luaL_setfuncs(L, &userdata_metaLib, 0)
    lua_pop(L, 1)

    // Create module table
    lua_createtable(L, 0, Int32(moduleLib.count - 1))
    luaL_setfuncs(L, &moduleLib, 0)

    // Set module metatable (for __gc)
    lua_createtable(L, 0, Int32(module_metaLib.count - 1))
    luaL_setfuncs(L, &module_metaLib, 0)
    lua_setmetatable(L, -2)

    return 1
}
