//
//  libstreamdeck_new.swift
//  Cosmic Hammer
//
//  Ported from Objective-C to Swift.
//  Original authors: Chris Jones, Chris Hocking.
//  Copyright © 2017-2023 Cosmic Hammer. All rights reserved.
//

import Cocoa
import CLua
import Lua
import IOKit
import IOKit.hid
import os.log
import HSDSTCore

// MARK: - Constants (mirroring streamdeck.h)

private let USERDATA_TAG = "hs.streamdeck"
private var activeStreamDeckDiscoveryCallbackCount = 0
private var activeStreamDeckButtonCallbackCount = 0
private var activeStreamDeckEncoderCallbackCount = 0
private var activeStreamDeckScreenCallbackCount = 0

private func recordStreamDeckCallbackGauge(
    name: String,
    value: Int,
    L: UnsafeMutablePointer<lua_State>? = lua_getCurrentState()
) {
    let telemetry = L.map { environmentGet($0).telemetry } ?? environmentGetGlobalOrNil()?.telemetry
    telemetry?.recordMetric(
        name: name,
        kind: .gauge,
        value: Double(value),
        attributes: [:],
        unit: "1"
    )
}

func adjustStreamDeckDiscoveryCallbackCount(_ delta: Int, L: UnsafeMutablePointer<lua_State>? = lua_getCurrentState()) {
    activeStreamDeckDiscoveryCallbackCount = max(0, activeStreamDeckDiscoveryCallbackCount + delta)
    recordStreamDeckCallbackGauge(
        name: "cosmichammer.streamdeck.discovery.callback.active",
        value: activeStreamDeckDiscoveryCallbackCount,
        L: L
    )
}

func adjustStreamDeckButtonCallbackCount(_ delta: Int, L: UnsafeMutablePointer<lua_State>? = lua_getCurrentState()) {
    activeStreamDeckButtonCallbackCount = max(0, activeStreamDeckButtonCallbackCount + delta)
    recordStreamDeckCallbackGauge(
        name: "cosmichammer.streamdeck.button.callback.active",
        value: activeStreamDeckButtonCallbackCount,
        L: L
    )
}

func adjustStreamDeckEncoderCallbackCount(_ delta: Int, L: UnsafeMutablePointer<lua_State>? = lua_getCurrentState()) {
    activeStreamDeckEncoderCallbackCount = max(0, activeStreamDeckEncoderCallbackCount + delta)
    recordStreamDeckCallbackGauge(
        name: "cosmichammer.streamdeck.encoder.callback.active",
        value: activeStreamDeckEncoderCallbackCount,
        L: L
    )
}

func adjustStreamDeckScreenCallbackCount(_ delta: Int, L: UnsafeMutablePointer<lua_State>? = lua_getCurrentState()) {
    activeStreamDeckScreenCallbackCount = max(0, activeStreamDeckScreenCallbackCount + delta)
    recordStreamDeckCallbackGauge(
        name: "cosmichammer.streamdeck.screen.callback.active",
        value: activeStreamDeckScreenCallbackCount,
        L: L
    )
}

func setStreamDeckDiscoveryCallbackCounted(
    _ manager: HSStreamDeckManager,
    _ active: Bool,
    L: UnsafeMutablePointer<lua_State>? = lua_getCurrentState()
) {
    guard manager.countedDiscoveryCallbackActive != active else { return }
    manager.countedDiscoveryCallbackActive = active
    adjustStreamDeckDiscoveryCallbackCount(active ? 1 : -1, L: L)
}

func setStreamDeckButtonCallbackCounted(
    _ device: HSStreamDeckDevice,
    _ active: Bool,
    L: UnsafeMutablePointer<lua_State>? = lua_getCurrentState()
) {
    guard device.countedButtonCallbackActive != active else { return }
    device.countedButtonCallbackActive = active
    adjustStreamDeckButtonCallbackCount(active ? 1 : -1, L: L)
}

func setStreamDeckEncoderCallbackCounted(
    _ device: HSStreamDeckDevice,
    _ active: Bool,
    L: UnsafeMutablePointer<lua_State>? = lua_getCurrentState()
) {
    guard device.countedEncoderCallbackActive != active else { return }
    device.countedEncoderCallbackActive = active
    adjustStreamDeckEncoderCallbackCount(active ? 1 : -1, L: L)
}

func setStreamDeckScreenCallbackCounted(
    _ device: HSStreamDeckDevice,
    _ active: Bool,
    L: UnsafeMutablePointer<lua_State>? = lua_getCurrentState()
) {
    guard device.countedScreenCallbackActive != active else { return }
    device.countedScreenCallbackActive = active
    adjustStreamDeckScreenCallbackCount(active ? 1 : -1, L: L)
}

private let USB_VID_ELGATO: Int                  = 0x0fd9

private let USB_PID_STREAMDECK_ORIGINAL: Int     = 0x0060
private let USB_PID_STREAMDECK_ORIGINAL_V2: Int  = 0x006d
private let USB_PID_STREAMDECK_MINI: Int         = 0x0063
private let USB_PID_STREAMDECK_MINI_V2: Int      = 0x0090
private let USB_PID_STREAMDECK_XL: Int           = 0x006c
private let USB_PID_STREAMDECK_XL_V2: Int        = 0x008F
private let USB_PID_STREAMDECK_MK2: Int          = 0x0080
private let USB_PID_STREAMDECK_PLUS: Int         = 0x0084
private let USB_PID_STREAMDECK_PEDAL: Int        = 0x0086

// MARK: - Image codec enum

enum HSStreamDeckImageCodec: Int {
    case unknown = 0
    case bmp = 1
    case jpeg = 2
}

// MARK: - Global variables

private var streamDeckRefTable: Int32 = LUA_NOREF
private var deckManager: HSStreamDeckManager?

// MARK: - Helper

// MARK: - HSStreamDeckDevice (base class)

class HSStreamDeckDevice: NSObject, LuaTeardownable {
    var device: IOHIDDevice
    weak var manager: HSStreamDeckManager?

    var buttonCallbackRef: Int32 = LUA_NOREF
    var encoderCallbackRef: Int32 = LUA_NOREF
    var screenCallbackRef: Int32 = LUA_NOREF
    var countedButtonCallbackActive = false
    var countedEncoderCallbackActive = false
    var countedScreenCallbackActive = false

    var isValid: Bool = true
    var lsCanary: UInt64 = UInt64()

    private var tornDown = false

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        setStreamDeckButtonCallbackCounted(self, false)
        setStreamDeckEncoderCallbackCounted(self, false)
        setStreamDeckScreenCallbackCounted(self, false)
        if let L = lua_getCurrentState() {
            lua_unrefRegistryRef(L, &buttonCallbackRef)
            lua_unrefRegistryRef(L, &encoderCallbackRef)
            lua_unrefRegistryRef(L, &screenCallbackRef)
        }
    }

    var deckType: String = "Unknown"
    var keyColumns: Int32 = -1
    var keyRows: Int32 = -1
    var imageWidth: Int32 = 0
    var imageHeight: Int32 = 0

    var encoderColumns: Int32 = 0
    var encoderRows: Int32 = 0

    var lcdStripWidth: Int32 = 0
    var lcdStripHeight: Int32 = 0

    var imageCodec: HSStreamDeckImageCodec = .unknown
    var imageFlipX: Bool = false
    var imageFlipY: Bool = false
    var imageAngle: Int32 = 0
    var simpleReportLength: Int32 = 0
    var reportLength: Int32 = 0
    var reportHeaderLength: Int32 = 0

    var lcdReportLength: Int32 = 0
    var lcdReportHeaderLength: Int32 = 0

    var dataKeyOffset: Int32 = 0
    var dataEncoderOffset: Int32 = 0
    var firmwareReadOffset: Int = 0
    var serialNumberReadOffset: Int = 0
    var resetCommand: Data?
    var setBrightnessCommand: Data?
    var serialNumberCommand: Int = 0
    var firmwareVersionCommand: Int = 0

    var buttonStateCache: [NSNumber] = []
    var encoderButtonStateCache: [NSNumber] = []

    private var serialNumberCache: String?

    var keyCount: Int32 {
        return keyColumns * keyRows
    }

    var encoderCount: Int32 {
        return encoderColumns * encoderRows
    }

    var serialNumber: String? {
        if serialNumberCache == nil {
            serialNumberCache = cacheSerialNumber()
        }
        return serialNumberCache
    }

    init(device: IOHIDDevice, manager: HSStreamDeckManager) {
        self.device = device
        self.manager = manager
        super.init()
    }

    func invalidate() {
        isValid = false
    }

    func initialiseCaches() {
        buttonStateCache = []
        for _ in 0...keyCount {
            buttonStateCache.append(NSNumber(value: 0))
        }

        encoderButtonStateCache = []
        for _ in 0...encoderCount {
            encoderButtonStateCache.append(NSNumber(value: 0))
        }

        serialNumberCache = cacheSerialNumber()
    }

    // MARK: - Device I/O

    func deviceWriteSimpleReport(_ command: Data) -> IOReturn {
        if simpleReportLength == 0 {
            os_log(.error, "%{public}s", "Initialising Stream Deck device with no simple report length defined")
            return kIOReturnInternalError
        }
        var reportData = Data(count: Int(simpleReportLength))
        reportData.replaceSubrange(0..<command.count, with: command)
        return deviceWrite(reportData)
    }

    func deviceWrite(_ report: Data) -> IOReturn {
        return report.withUnsafeBytes { rawBuf -> IOReturn in
            let ptr = rawBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(ptr[0]), ptr, report.count)
        }
    }

    func deviceRead(resultLength: Int, reportID: CFIndex, readOffset: Int) -> Data {
        let reportLength = resultLength + readOffset
        let report = UnsafeMutablePointer<UInt8>.allocate(capacity: reportLength)
        report.initialize(repeating: 0, count: reportLength)
        defer { report.deallocate() }

        var actualLength = CFIndex(reportLength)
        IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, reportID, report, &actualLength)

        let rawData = Data(bytes: report + readOffset, count: resultLength)

        // Strip trailing null bytes
        var data = Data()
        for byte in rawData {
            if byte == 0x00 {
                break
            }
            data.append(byte)
        }
        return data
    }

    func transformKeyIndex(_ sourceKey: Int32) -> Int32 {
        return sourceKey
    }

    // MARK: - Input handling

    func deviceDidSendInput(_ newButtonStates: [NSNumber]) {
        guard isValid else { return }

        let L = lua_getCurrentState()!

        guard lua_isStateGenerationValid(lsCanary) else {
            return
        }

        if buttonCallbackRef == LUA_NOREF || buttonCallbackRef == LUA_REFNIL {
            os_log(.error, "%{public}s", "hs.streamdeck received a button input, but no callback has been set. See hs.streamdeck:buttonCallback()")
            return
        }

        for button: Int32 in 1...keyCount {
            let idx = Int(button)
            if buttonStateCache[idx] != newButtonStates[idx] {
                lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(buttonCallbackRef))
                _ = pushHSStreamDeckDevice(L, self)
                L.push(Int(button))
                L.push(newButtonStates[idx].boolValue)
                if luaTelemetryPCall(
                    L,
                    nargs: 3,
                    nresults: 0,
                    callbackName: "hs.streamdeck.button",
                    attributes: [
                        "streamdeck.event": "button",
                        "streamdeck.button": Int(button),
                        "streamdeck.pressed": newButtonStates[idx].boolValue,
                    ]
                ) != LUA_OK { lua_pop(L, 1) }
                buttonStateCache[idx] = newButtonStates[idx]
            }
        }
    }

    func deviceDidSendEncoderInput(_ newPressEncoderStates: [NSNumber]) {
        guard isValid else { return }

        let L = lua_getCurrentState()!

        guard lua_isStateGenerationValid(lsCanary) else {
            return
        }

        if encoderCallbackRef == LUA_NOREF || encoderCallbackRef == LUA_REFNIL {
            os_log(.error, "%{public}s", "hs.streamdeck received an encoder button input, but no callback has been set. See hs.streamdeck:encoderCallback()")
            return
        }

        for button: Int32 in 1...encoderCount {
            let idx = Int(button)
            if encoderButtonStateCache[idx] != newPressEncoderStates[idx] {
                lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(encoderCallbackRef))
                _ = pushHSStreamDeckDevice(L, self)
                L.push(Int(button))
                L.push(newPressEncoderStates[idx].boolValue)
                L.push(false)
                L.push(false)
                if luaTelemetryPCall(
                    L,
                    nargs: 5,
                    nresults: 0,
                    callbackName: "hs.streamdeck.encoder",
                    attributes: [
                        "streamdeck.event": "encoder_button",
                        "streamdeck.button": Int(button),
                        "streamdeck.pressed": newPressEncoderStates[idx].boolValue,
                    ]
                ) != LUA_OK { lua_pop(L, 1) }
                encoderButtonStateCache[idx] = newPressEncoderStates[idx]
            }
        }
    }

    func deviceDidSendEncoderTurn(button: Int32, turningLeft: Bool) {
        guard isValid else { return }

        let L = lua_getCurrentState()!

        guard lua_isStateGenerationValid(lsCanary) else {
            return
        }

        if encoderCallbackRef == LUA_NOREF || encoderCallbackRef == LUA_REFNIL {
            os_log(.error, "%{public}s", "hs.streamdeck received an encoder button input, but no callback has been set. See hs.streamdeck:encoderCallback()")
            return
        }

        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(encoderCallbackRef))
        _ = pushHSStreamDeckDevice(L, self)
        L.push(Int(button))
        L.push(false)
        L.push(turningLeft)
        L.push(!turningLeft)
        if luaTelemetryPCall(
            L,
            nargs: 5,
            nresults: 0,
            callbackName: "hs.streamdeck.encoder",
            attributes: [
                "streamdeck.event": "encoder_turn",
                "streamdeck.button": Int(button),
                "streamdeck.turning_left": turningLeft,
            ]
        ) != LUA_OK { lua_pop(L, 1) }
    }

    func deviceDidSendScreenTouch(eventType: String, startX: Int32, startY: Int32, endX: Int32, endY: Int32) {
        guard isValid else { return }

        let L = lua_getCurrentState()!

        guard lua_isStateGenerationValid(lsCanary) else {
            return
        }

        if screenCallbackRef == LUA_NOREF || screenCallbackRef == LUA_REFNIL {
            os_log(.error, "%{public}s", "hs.streamdeck received an screen input, but no callback has been set. See hs.streamdeck:screenCallback()")
            return
        }

        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(screenCallbackRef))
        _ = pushHSStreamDeckDevice(L, self)
        L.push(eventType)
        L.push(Int(startX))
        L.push(Int(startY))
        L.push(Int(endX))
        L.push(Int(endY))
        if luaTelemetryPCall(
            L,
            nargs: 6,
            nresults: 0,
            callbackName: "hs.streamdeck.screen",
            attributes: [
                "streamdeck.event": "screen_touch",
                "streamdeck.touch.event_type": eventType,
            ]
        ) != LUA_OK { lua_pop(L, 1) }
    }

    // MARK: - Device commands

    @discardableResult
    func setBrightness(_ brightness: Int32) -> Bool {
        guard isValid else { return false }

        guard let cmd = setBrightnessCommand else {
            NSException(name: NSExceptionName("HSStreamDeckDeviceUnimplemented"),
                        reason: "setBrightness method not implemented",
                        userInfo: nil).raise()
            return false
        }

        var brightnessCommand = cmd
        var value = UInt8(clamping: brightness)
        brightnessCommand.replaceSubrange((brightnessCommand.count - 1)..<brightnessCommand.count, with: &value, count: 1)
        let res = deviceWriteSimpleReport(brightnessCommand)
        return res == kIOReturnSuccess
    }

    func reset() {
        guard isValid else { return }

        guard let resetCmd = resetCommand else {
            NSException(name: NSExceptionName("HSStreamDeckDeviceUnimplemented"),
                        reason: "resetCommand bytes not set, or reset method not overridden",
                        userInfo: nil).raise()
            return
        }

        let res = deviceWriteSimpleReport(resetCmd)
        if res != kIOReturnSuccess {
            os_log(.error, "hs.streamdeck:reset() failed on %{public}s (%{public}s)", deckType, serialNumber ?? "unknown")
        }
    }

    func cacheSerialNumber() -> String? {
        guard isValid else { return nil }

        if serialNumberCommand == 0 {
            NSException(name: NSExceptionName("HSStreamDeckDeviceUnimplemented"),
                        reason: "serialNumberCommand not set, or cacheSerialNumber method not overridden",
                        userInfo: nil).raise()
            return nil
        }

        let data = deviceRead(resultLength: Int(simpleReportLength), reportID: CFIndex(serialNumberCommand), readOffset: serialNumberReadOffset)
        return String(data: data, encoding: .utf8)
    }

    func firmwareVersion() -> String? {
        guard isValid else { return nil }

        if firmwareVersionCommand == 0 {
            NSException(name: NSExceptionName("HSStreamDeckDeviceUnimplemented"),
                        reason: "firmwareVersionCommand not set, or firmwareVersion method not implemented",
                        userInfo: nil).raise()
            return nil
        }

        let data = deviceRead(resultLength: Int(simpleReportLength), reportID: CFIndex(firmwareVersionCommand), readOffset: firmwareReadOffset)
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Image handling

    func clearImage(_ button: Int32) {
        setColor(NSColor.black, forButton: button)
    }

    func setColor(_ color: NSColor, forButton button: Int32) {
        guard isValid else { return }

        let image = NSImage(size: NSSize(width: CGFloat(imageWidth), height: CGFloat(imageHeight)))
        image.lockFocus()
        color.drawSwatch(in: NSRect(x: 0, y: 0, width: CGFloat(imageWidth), height: CGFloat(imageHeight)))
        image.unlockFocus()
        setImage(image, forButton: button)
    }

    func setImage(_ image: NSImage, forButton button: Int32) {
        guard isValid else { return }

        // Resize the image
        let sourceImage = image.copy() as! NSImage
        let newSize = NSSize(width: CGFloat(imageWidth), height: CGFloat(imageHeight))
        let renderImageRaw = NSImage(size: newSize)
        renderImageRaw.lockFocus()
        sourceImage.size = newSize
        NSGraphicsContext.current?.imageInterpolation = .high
        sourceImage.draw(at: .zero, from: NSRect(origin: .zero, size: newSize), operation: .copy, fraction: 1.0)
        renderImageRaw.unlockFocus()

        if !image.isValid {
            os_log(.error, "%{public}s", "image is invalid")
        }
        if !renderImageRaw.isValid {
            os_log(.error, "%{public}s", "Invalid image passed to hs.streamdeck:setImage() (renderImage)")
        }

        // Apply rotation and flipping (no-ops if not needed)
        var renderImage = renderImageRaw.imageRotated(Int(imageAngle))
        renderImage = renderImage.flipImage(imageFlipX, vert: imageFlipY)

        var data: Data?

        switch imageCodec {
        case .bmp:
            data = renderImage.bmpData()
        case .jpeg:
            data = renderImage.jpegData()
        case .unknown:
            os_log(.error, "%{public}s", "Unknown image codec for hs.streamdeck device")
        }

        if let data = data {
            deviceWriteImage(data, button: transformKeyIndex(button))
        }
    }

    func deviceWriteImage(_ data: Data, button: Int32) {
        NSException(name: NSExceptionName("HSStreamDeckDeviceUnimplemented"),
                    reason: "deviceWriteImage method not implemented",
                    userInfo: nil).raise()
    }

    func deviceV2WriteImage(_ data: Data, button: Int32) {
        var reportHeader: [UInt8] = [
            0x02,           // Report ID
            0x07,           // Unknown (always seems to be 7)
            UInt8(button - 1), // Deck button to set
            0x00,           // Final page bool
            0x00,           // Length encoding low
            0x00,           // Length encoding high
            0x00,           // Page number low
            0x00,           // Page number high
        ]

        let maxPayloadLength = Int(reportLength - reportHeaderLength)
        var bytesRemaining = data.count
        var pageNumber = 0

        data.withUnsafeBytes { rawBuf in
            let imageBuf = rawBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)

            while bytesRemaining > 0 {
                let thisPageLength = min(bytesRemaining, maxPayloadLength)
                let bytesSent = pageNumber * maxPayloadLength

                reportHeader[6] = UInt8(pageNumber & 0xFF)
                reportHeader[7] = UInt8(pageNumber >> 8)
                reportHeader[4] = UInt8(thisPageLength & 0xFF)
                reportHeader[5] = UInt8(thisPageLength >> 8)

                if bytesRemaining <= maxPayloadLength { reportHeader[3] = 1 }

                var report = Data(count: Int(reportLength))
                report.replaceSubrange(0..<Int(reportHeaderLength), with: reportHeader)
                report.replaceSubrange(Int(reportHeaderLength)..<Int(reportHeaderLength) + thisPageLength,
                                       with: UnsafeBufferPointer(start: imageBuf + bytesSent, count: thisPageLength))

                let result = report.withUnsafeBytes { reportBuf -> IOReturn in
                    let ptr = reportBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(reportHeader[0]), ptr, report.count)
                }

                if result != kIOReturnSuccess {
                    os_log(.error, "WARNING: writing an image with hs.streamdeck encountered a failure on page %d: %d", pageNumber, result)
                }

                bytesRemaining -= thisPageLength
                pageNumber += 1
            }
        }
    }

    // MARK: - LCD image handling

    func setLCDImage(_ image: NSImage, forEncoder encoder: Int32) {
        guard isValid else { return }

        let sourceImage = image.copy() as! NSImage
        let encoderWidth = lcdStripWidth / encoderColumns
        let newSize = NSSize(width: CGFloat(encoderWidth), height: CGFloat(lcdStripHeight))
        let renderImageRaw = NSImage(size: newSize)
        renderImageRaw.lockFocus()
        sourceImage.size = newSize
        NSGraphicsContext.current?.imageInterpolation = .high
        sourceImage.draw(at: .zero, from: NSRect(origin: .zero, size: newSize), operation: .copy, fraction: 1.0)
        renderImageRaw.unlockFocus()

        if !image.isValid {
            os_log(.error, "%{public}s", "image is invalid")
        }
        if !renderImageRaw.isValid {
            os_log(.error, "%{public}s", "Invalid image passed to hs.streamdeck:setLCDImage() (renderImage)")
        }

        var renderImage = renderImageRaw.imageRotated(Int(imageAngle))
        renderImage = renderImage.flipImage(imageFlipX, vert: imageFlipY)

        var data: Data?

        switch imageCodec {
        case .bmp:
            data = renderImage.bmpData()
        case .jpeg:
            data = renderImage.jpegData()
        case .unknown:
            os_log(.error, "%{public}s", "Unknown image codec for hs.streamdeck device")
        }

        if let data = data {
            deviceLCDWriteImage(data, forEncoder: encoder)
        }
    }

    func deviceLCDWriteImage(_ data: Data, forEncoder encoder: Int32) {
        let encoderWidth = Int(lcdStripWidth / encoderColumns)

        let left   = encoderWidth * Int(encoder) - encoderWidth
        let top    = 0
        let width  = encoderWidth
        let height = Int(lcdStripHeight)

        var reportHeader: [UInt8] = [
            0x02,                                   // 0: Report ID
            0x0c,                                   // 1: Image Rectangle JPEG
            UInt8(left & 0xFF),                     // 2: Left low
            UInt8(left >> 8),                       // 3: Left high
            UInt8(top & 0xFF),                      // 4: Top low
            UInt8(top >> 8),                        // 5: Top high
            UInt8(width & 0xFF),                    // 6: Width low
            UInt8(width >> 8),                      // 7: Width high
            UInt8(height & 0xFF),                   // 8: Height low
            UInt8(height >> 8),                     // 9: Height high
            0x00,                                   // 10: Is Last Page
            0x00,                                   // 11: Page Number low
            0x00,                                   // 12: Page Number high
            0x00,                                   // 13: Payload Length low
            0x00,                                   // 14: Payload Length high
            0x00,                                   // 15: Padding
        ]

        let maxPayloadLength = Int(lcdReportLength - lcdReportHeaderLength)
        var bytesRemaining = data.count
        var pageNumber = 0

        data.withUnsafeBytes { rawBuf in
            let imageBuf = rawBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)

            while bytesRemaining > 0 {
                let thisPageLength = min(bytesRemaining, maxPayloadLength)
                let bytesSent = pageNumber * maxPayloadLength

                reportHeader[11] = UInt8(pageNumber & 0xFF)
                reportHeader[12] = UInt8(pageNumber >> 8)
                reportHeader[13] = UInt8(thisPageLength & 0xFF)
                reportHeader[14] = UInt8(thisPageLength >> 8)

                if bytesRemaining <= maxPayloadLength { reportHeader[10] = 1 }

                var report = Data(count: Int(lcdReportLength))
                report.replaceSubrange(0..<Int(lcdReportHeaderLength), with: reportHeader)
                report.replaceSubrange(Int(lcdReportHeaderLength)..<Int(lcdReportHeaderLength) + thisPageLength,
                                       with: UnsafeBufferPointer(start: imageBuf + bytesSent, count: thisPageLength))

                let result = report.withUnsafeBytes { reportBuf -> IOReturn in
                    let ptr = reportBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(reportHeader[0]), ptr, report.count)
                }

                if result != kIOReturnSuccess {
                    os_log(.error, "WARNING: writing an image with hs.streamdeck encountered a failure on page %d: %d", pageNumber, result)
                }

                bytesRemaining -= thisPageLength
                pageNumber += 1
            }
        }
    }
}

// MARK: - HSStreamDeckDeviceMini

class HSStreamDeckDeviceMini: HSStreamDeckDevice {
    override init(device: IOHIDDevice, manager: HSStreamDeckManager) {
        super.init(device: device, manager: manager)
        deckType = "Elgato Stream Deck (Mini)"
        keyRows = 2
        keyColumns = 3
        imageWidth = 80
        imageHeight = 80
        imageCodec = .bmp
        imageFlipX = false
        imageFlipY = true
        imageAngle = 90
        simpleReportLength = 17
        reportLength = 1024
        reportHeaderLength = 16
        dataKeyOffset = 1

        resetCommand = Data([0x0B, 0x63])
        setBrightnessCommand = Data([0x05, 0x55, 0xAA, 0xD1, 0x01, 0xFF])

        serialNumberCommand = 0x03
        firmwareVersionCommand = 0x4

        serialNumberReadOffset = 5
        firmwareReadOffset = 5
    }

    override func deviceWriteImage(_ data: Data, button: Int32) {
        var reportMagic: [UInt8] = [
            0x02,   // Report ID
            0x01,   // Unknown
            0x00,   // Page Number
            0x00,   // Padding
            0x00,   // Last page Bool
            UInt8(button), // Deck button
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        ]

        let payloadLength = Int(reportLength - reportHeaderLength)
        var bytesRemaining = data.count
        var pageNumber: UInt8 = reportMagic[2]

        data.withUnsafeBytes { rawBuf in
            let imageBuf = rawBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)

            while bytesRemaining > 0 {
                let thisReportLength = min(bytesRemaining, payloadLength)
                let bytesSent = Int(pageNumber) * payloadLength

                reportMagic[2] = pageNumber
                if bytesRemaining <= payloadLength { reportMagic[4] = 1 }

                var report = Data(count: Int(reportLength))
                report.replaceSubrange(0..<Int(reportHeaderLength), with: reportMagic)
                report.replaceSubrange(Int(reportHeaderLength)..<Int(reportHeaderLength) + thisReportLength,
                                       with: UnsafeBufferPointer(start: imageBuf + bytesSent, count: thisReportLength))

                let result = report.withUnsafeBytes { reportBuf -> IOReturn in
                    let ptr = reportBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(reportMagic[0]), ptr, report.count)
                }
                if result != kIOReturnSuccess {
                    os_log(.error, "WARNING: writing an image with hs.streamdeck encountered a failure on page %d: %d", pageNumber, result)
                }
                bytesRemaining -= Int(reportLength)
                pageNumber += 1
            }
        }
    }
}

// MARK: - HSStreamDeckDeviceOriginal

class HSStreamDeckDeviceOriginal: HSStreamDeckDevice {
    override init(device: IOHIDDevice, manager: HSStreamDeckManager) {
        super.init(device: device, manager: manager)
        deckType = "Elgato Stream Deck (Original v1)"
        keyRows = 3
        keyColumns = 5
        imageWidth = 72
        imageHeight = 72
        imageCodec = .bmp
        imageFlipX = true
        imageFlipY = true
        imageAngle = 0
        simpleReportLength = 17
        reportLength = 8192
        reportHeaderLength = 16
        dataKeyOffset = 1

        resetCommand = Data([0x0B, 0x63])
        setBrightnessCommand = Data([0x05, 0x55, 0xAA, 0xD1, 0x01, 0xFF])

        serialNumberCommand = 0x3
        firmwareVersionCommand = 0x4

        serialNumberReadOffset = 5
        firmwareReadOffset = 5
    }

    override func transformKeyIndex(_ sourceKey: Int32) -> Int32 {
        let midpoint: Int32
        if sourceKey >= 1 && sourceKey <= 5 {
            midpoint = 3
        } else if sourceKey >= 6 && sourceKey <= 10 {
            midpoint = 8
        } else if sourceKey >= 11 && sourceKey <= 15 {
            midpoint = 13
        } else {
            midpoint = 3
        }
        let diff = midpoint - sourceKey
        return midpoint + diff
    }

    override func deviceWriteImage(_ data: Data, button: Int32) {
        var reportMagic: [UInt8] = [
            0x02,           // Report ID
            0x01,           // Unknown
            0x01,           // Page Number
            0x00,           // Padding
            0x00,           // Continuation Bool
            UInt8(button),  // Deck button
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        ]

        let imageLen = data.count
        let halfImageLen = imageLen / 2

        data.withUnsafeBytes { rawBuf in
            let imageBuf = rawBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)

            // First half
            var reportPage1 = Data(count: Int(reportLength))
            reportPage1.replaceSubrange(0..<Int(reportHeaderLength), with: reportMagic)
            reportPage1.replaceSubrange(Int(reportHeaderLength)..<Int(reportHeaderLength) + halfImageLen,
                                        with: UnsafeBufferPointer(start: imageBuf, count: halfImageLen))

            reportPage1.withUnsafeBytes { buf in
                let ptr = buf.baseAddress!.assumingMemoryBound(to: UInt8.self)
                IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(reportMagic[0]), ptr, reportPage1.count)
            }

            // Second half
            reportMagic[2] = 2
            reportMagic[4] = 1
            var reportPage2 = Data(count: Int(reportLength))
            reportPage2.replaceSubrange(0..<Int(reportHeaderLength), with: reportMagic)
            reportPage2.replaceSubrange(Int(reportHeaderLength)..<Int(reportHeaderLength) + halfImageLen,
                                        with: UnsafeBufferPointer(start: imageBuf + halfImageLen, count: halfImageLen))

            reportPage2.withUnsafeBytes { buf in
                let ptr = buf.baseAddress!.assumingMemoryBound(to: UInt8.self)
                IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(reportMagic[0]), ptr, reportPage2.count)
            }
        }
    }
}

// MARK: - HSStreamDeckDeviceOriginalV2

class HSStreamDeckDeviceOriginalV2: HSStreamDeckDevice {
    override init(device: IOHIDDevice, manager: HSStreamDeckManager) {
        super.init(device: device, manager: manager)
        deckType = "Elgato Stream Deck (V2)"
        keyRows = 3
        keyColumns = 5
        imageWidth = 72
        imageHeight = 72
        imageCodec = .jpeg
        imageFlipX = true
        imageFlipY = true
        imageAngle = 0
        simpleReportLength = 32
        reportLength = 1024
        reportHeaderLength = 8
        dataKeyOffset = 4

        resetCommand = Data([0x03, 0x02])
        setBrightnessCommand = Data([0x03, 0x08, 0xFF])

        serialNumberCommand = 0x06
        firmwareVersionCommand = 0x05

        serialNumberReadOffset = 2
        firmwareReadOffset = 6
    }

    override func deviceWriteImage(_ data: Data, button: Int32) {
        deviceV2WriteImage(data, button: button)
    }
}

// MARK: - HSStreamDeckDeviceMk2

class HSStreamDeckDeviceMk2: HSStreamDeckDevice {
    override init(device: IOHIDDevice, manager: HSStreamDeckManager) {
        super.init(device: device, manager: manager)
        deckType = "Elgato Stream Deck (Mk2)"
        keyRows = 3
        keyColumns = 5
        imageWidth = 72
        imageHeight = 72
        imageCodec = .jpeg
        imageFlipX = true
        imageFlipY = true
        imageAngle = 0
        simpleReportLength = 32
        reportLength = 1024
        reportHeaderLength = 8
        dataKeyOffset = 4

        resetCommand = Data([0x03, 0x02])
        setBrightnessCommand = Data([0x03, 0x08, 0xFF])

        serialNumberCommand = 0x06
        firmwareVersionCommand = 0x05

        serialNumberReadOffset = 2
        firmwareReadOffset = 6
    }

    override func deviceWriteImage(_ data: Data, button: Int32) {
        deviceV2WriteImage(data, button: button)
    }
}

// MARK: - HSStreamDeckDeviceXL

class HSStreamDeckDeviceXL: HSStreamDeckDevice {
    override init(device: IOHIDDevice, manager: HSStreamDeckManager) {
        super.init(device: device, manager: manager)
        deckType = "Elgato Stream Deck (XL)"
        keyRows = 4
        keyColumns = 8
        imageWidth = 96
        imageHeight = 96
        imageCodec = .jpeg
        imageFlipX = true
        imageFlipY = true
        imageAngle = 0
        simpleReportLength = 32
        reportLength = 1024
        reportHeaderLength = 8
        dataKeyOffset = 4

        resetCommand = Data([0x03, 0x02])
        setBrightnessCommand = Data([0x03, 0x08, 0xFF])

        serialNumberCommand = 0x06
        firmwareVersionCommand = 0x05

        serialNumberReadOffset = 2
        firmwareReadOffset = 6
    }

    override func deviceWriteImage(_ data: Data, button: Int32) {
        deviceV2WriteImage(data, button: button)
    }
}

// MARK: - HSStreamDeckDevicePlus

class HSStreamDeckDevicePlus: HSStreamDeckDevice {
    override init(device: IOHIDDevice, manager: HSStreamDeckManager) {
        super.init(device: device, manager: manager)
        deckType = "Elgato Stream Deck Plus"
        keyRows = 2
        keyColumns = 4
        imageWidth = 120
        imageHeight = 120
        imageCodec = .jpeg
        imageFlipX = false
        imageFlipY = false
        imageAngle = 0
        simpleReportLength = 32
        reportLength = 1024
        reportHeaderLength = 8

        dataKeyOffset = 4
        dataEncoderOffset = 5

        encoderColumns = 4
        encoderRows = 1

        lcdStripWidth = 800
        lcdStripHeight = 100

        lcdReportLength = 1024
        lcdReportHeaderLength = 16

        resetCommand = Data([0x03, 0x02])
        setBrightnessCommand = Data([0x03, 0x08, 0xFF])

        serialNumberCommand = 0x06
        firmwareVersionCommand = 0x05

        serialNumberReadOffset = 2
        firmwareReadOffset = 6
    }

    override func deviceWriteImage(_ data: Data, button: Int32) {
        deviceV2WriteImage(data, button: button)
    }
}

// MARK: - HSStreamDeckDevicePedal

class HSStreamDeckDevicePedal: HSStreamDeckDevice {
    override init(device: IOHIDDevice, manager: HSStreamDeckManager) {
        super.init(device: device, manager: manager)
        deckType = "Elgato Stream Deck Pedal"
        keyRows = 1
        keyColumns = 3

        simpleReportLength = 32
        reportLength = 1024
        reportHeaderLength = 8
        dataKeyOffset = 4

        resetCommand = Data([0x03, 0x02])

        serialNumberCommand = 0x06
        firmwareVersionCommand = 0x05

        serialNumberReadOffset = 2
        firmwareReadOffset = 6
    }

    override func setImage(_ image: NSImage, forButton button: Int32) {
        // Do nothing - Pedal has no display
    }

    override func deviceWriteImage(_ data: Data, button: Int32) {
        // Do nothing - Pedal has no display
    }

    override func setLCDImage(_ image: NSImage, forEncoder encoder: Int32) {
        // Do nothing - Pedal has no display
    }
}

// MARK: - HSStreamDeckManager

class HSStreamDeckManager: NSObject {
    var ioHIDManager: IOHIDManager?
    var devices: [HSStreamDeckDevice] = []
    var discoveryCallbackRef: Int32 = LUA_NOREF
    var countedDiscoveryCallbackActive = false
    var lsCanary: UInt64 = UInt64()

    var inputBuffer: UnsafeMutablePointer<UInt8>?

    override init() {
        super.init()
        devices.reserveCapacity(5)
        inputBuffer = .allocate(capacity: 1024)
        inputBuffer?.initialize(repeating: 0, count: 1024)

        // Create a HID device manager
        ioHIDManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        guard let hidManager = ioHIDManager else { return }

        // Configure matching against Stream Deck devices
        let vendorIDKey = kIOHIDVendorIDKey as String
        let productIDKey = kIOHIDProductIDKey as String

        let matchDicts: [[String: Any]] = [
            [vendorIDKey: USB_VID_ELGATO, productIDKey: USB_PID_STREAMDECK_ORIGINAL],
            [vendorIDKey: USB_VID_ELGATO, productIDKey: USB_PID_STREAMDECK_ORIGINAL_V2],
            [vendorIDKey: USB_VID_ELGATO, productIDKey: USB_PID_STREAMDECK_MINI],
            [vendorIDKey: USB_VID_ELGATO, productIDKey: USB_PID_STREAMDECK_MINI_V2],
            [vendorIDKey: USB_VID_ELGATO, productIDKey: USB_PID_STREAMDECK_XL],
            [vendorIDKey: USB_VID_ELGATO, productIDKey: USB_PID_STREAMDECK_XL_V2],
            [vendorIDKey: USB_VID_ELGATO, productIDKey: USB_PID_STREAMDECK_MK2],
            [vendorIDKey: USB_VID_ELGATO, productIDKey: USB_PID_STREAMDECK_PLUS],
            [vendorIDKey: USB_VID_ELGATO, productIDKey: USB_PID_STREAMDECK_PEDAL],
        ]

        IOHIDManagerSetDeviceMatchingMultiple(hidManager, matchDicts as CFArray)

        // Add callbacks for connect/disconnect
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(hidManager, hidConnectCallback, selfPtr)
        IOHIDManagerRegisterDeviceRemovalCallback(hidManager, hidDisconnectCallback, selfPtr)

        // Start the HID manager on the current run loop
        IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    func doGC() {
        guard let hidManager = ioHIDManager else { return }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(hidManager, nil, selfPtr)
        IOHIDManagerRegisterDeviceRemovalCallback(hidManager, nil, selfPtr)
        IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        ioHIDManager = nil

        inputBuffer?.deallocate()
        inputBuffer = nil
    }

    @discardableResult
    func startHIDManager() -> Bool {
        guard let hidManager = ioHIDManager else { return false }
        let result = IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        return result == kIOReturnSuccess
    }

    @discardableResult
    func stopHIDManager() -> Bool {
        guard let hidManager = ioHIDManager else { return true }
        let result = IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        return result == kIOReturnSuccess
    }

    func deviceDidConnect(_ hidDevice: IOHIDDevice) -> HSStreamDeckDevice? {
        let L = lua_getCurrentState()!

        guard lua_isStateGenerationValid(lsCanary) else {
            return nil
        }

        if discoveryCallbackRef == LUA_NOREF || discoveryCallbackRef == LUA_REFNIL {
            os_log(.info, "%{public}s", "hs.streamdeck detected a device connecting, but no discovery callback has been set. See hs.streamdeck.discoveryCallback()")
            return nil
        }

        guard let vendorID = IOHIDDeviceGetProperty(hidDevice, kIOHIDVendorIDKey as CFString) as? Int,
              let productID = IOHIDDeviceGetProperty(hidDevice, kIOHIDProductIDKey as CFString) as? Int else {
            return nil
        }

        if vendorID != USB_VID_ELGATO {
            os_log(.error, "deviceDidConnect from unknown vendor: %d", vendorID)
            return nil
        }

        let deck: HSStreamDeckDevice?

        switch productID {
        case USB_PID_STREAMDECK_ORIGINAL:
            deck = HSStreamDeckDeviceOriginal(device: hidDevice, manager: self)
        case USB_PID_STREAMDECK_MINI, USB_PID_STREAMDECK_MINI_V2:
            deck = HSStreamDeckDeviceMini(device: hidDevice, manager: self)
        case USB_PID_STREAMDECK_XL, USB_PID_STREAMDECK_XL_V2:
            deck = HSStreamDeckDeviceXL(device: hidDevice, manager: self)
        case USB_PID_STREAMDECK_ORIGINAL_V2:
            deck = HSStreamDeckDeviceOriginalV2(device: hidDevice, manager: self)
        case USB_PID_STREAMDECK_MK2:
            deck = HSStreamDeckDeviceMk2(device: hidDevice, manager: self)
        case USB_PID_STREAMDECK_PLUS:
            deck = HSStreamDeckDevicePlus(device: hidDevice, manager: self)
        case USB_PID_STREAMDECK_PEDAL:
            deck = HSStreamDeckDevicePedal(device: hidDevice, manager: self)
        default:
            os_log(.error, "deviceDidConnect from unknown device: %d", productID)
            deck = nil
        }

        guard let deck = deck else {
            os_log(.error, "deviceDidConnect: no HSStreamDeckDevice was created, ignoring")
            return nil
        }

        deck.lsCanary = lua_currentStateGeneration()
        deck.initialiseCaches()
        devices.append(deck)

        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(discoveryCallbackRef))
        L.push(true)
        _ = pushHSStreamDeckDevice(L, deck)
        if luaTelemetryPCall(
            L,
            nargs: 2,
            nresults: 0,
            callbackName: "hs.streamdeck.discovery",
            attributes: ["streamdeck.connected": true]
        ) != LUA_OK { lua_pop(L, 1) }
        return deck
    }

    func deviceDidDisconnect(_ hidDevice: IOHIDDevice) {
        let L = lua_getCurrentState()!

        guard lua_isStateGenerationValid(lsCanary) else {
            return
        }

        for (index, deckDevice) in devices.enumerated() {
            if deckDevice.device === hidDevice {
                deckDevice.invalidate()

                if discoveryCallbackRef == LUA_NOREF || discoveryCallbackRef == LUA_REFNIL {
                    os_log(.info, "%{public}s", "hs.streamdeck detected a device disconnecting, but no callback has been set. See hs.streamdeck.discoveryCallback()")
                } else {
                    lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(discoveryCallbackRef))
                    L.push(false)
                    _ = pushHSStreamDeckDevice(L, deckDevice)
                    if luaTelemetryPCall(
                        L,
                        nargs: 2,
                        nresults: 0,
                        callbackName: "hs.streamdeck.discovery",
                        attributes: ["streamdeck.connected": false]
                    ) != LUA_OK { lua_pop(L, 1) }
                }

                var tmpLSUUID = deckDevice.lsCanary
                deckDevice.lsCanary = tmpLSUUID

                devices.remove(at: index)
                return
            }
        }
        os_log(.error, "ERROR: A Stream Deck was disconnected that we didn't know about")
    }
}

// MARK: - IOKit C callbacks (free functions required by IOHIDManager)

private func hidReportCallback(_ context: UnsafeMutableRawPointer?,
                               _ result: IOReturn,
                               _ sender: UnsafeMutableRawPointer?,
                               _ type: IOHIDReportType,
                               _ reportID: UInt32,
                               _ report: UnsafeMutablePointer<UInt8>,
                               _ reportLength: CFIndex) {
    guard let context = context else { return }
    let device = Unmanaged<HSStreamDeckDevice>.fromOpaque(context).takeUnretainedValue()

    let inputType = report[1]
    if inputType == 0x00 || inputType == 0x01 {
        handleButtonEvent(device: device, report: report)
    } else if inputType == 0x02 {
        handleLCDEvent(device: device, report: report)
    } else if inputType == 0x03 {
        handleEncoderEvent(device: device, report: report)
    }
}

private func handleButtonEvent(device: HSStreamDeckDevice, report: UnsafeMutablePointer<UInt8>) {
    var buttonReport: [NSNumber] = [NSNumber(value: 0)]
    for _ in 1...device.keyCount {
        buttonReport.append(NSNumber(value: 0))
    }

    let start = report + Int(device.dataKeyOffset)
    for button: Int32 in 1...device.keyCount {
        let val = NSNumber(value: start[Int(button - 1)])
        let translatedButton = device.transformKeyIndex(button)
        buttonReport[Int(translatedButton)] = val
    }
    device.deviceDidSendInput(buttonReport)
}

private func handleLCDEvent(device: HSStreamDeckDevice, report: UnsafeMutablePointer<UInt8>) {
    var eventTypeString = "Unknown"
    let startX = Int32(UInt16(report[6]) | (UInt16(report[7]) << 8))
    let startY = Int32(UInt16(report[8]) | (UInt16(report[9]) << 8))
    var endX: Int32 = 0
    var endY: Int32 = 0

    let eventType = report[4]
    if eventType == 0x01 {
        eventTypeString = "shortPress"
    } else if eventType == 0x02 {
        eventTypeString = "longPress"
    } else if eventType == 0x03 {
        eventTypeString = "swipe"
        endX = Int32(UInt16(report[10]) | (UInt16(report[11]) << 8))
        endY = Int32(UInt16(report[12]) | (UInt16(report[13]) << 8))
    }

    device.deviceDidSendScreenTouch(eventType: eventTypeString, startX: startX, startY: startY, endX: endX, endY: endY)
}

private func handleEncoderEvent(device: HSStreamDeckDevice, report: UnsafeMutablePointer<UInt8>) {
    let eventType = report[4]
    if eventType == 0x00 {
        handleEncoderPressRelease(device: device, report: report)
    } else if eventType == 0x01 {
        handleEncoderTurn(device: device, report: report)
    }
}

private func handleEncoderPressRelease(device: HSStreamDeckDevice, report: UnsafeMutablePointer<UInt8>) {
    var buttonReport: [NSNumber] = [NSNumber(value: 0)]
    for _ in 1...device.encoderCount {
        buttonReport.append(NSNumber(value: 0))
    }

    let start = report + Int(device.dataEncoderOffset)
    for button: Int32 in 1...device.encoderCount {
        let val = NSNumber(value: start[Int(button - 1)])
        let translatedButton = device.transformKeyIndex(button)
        buttonReport[Int(translatedButton)] = val
    }
    device.deviceDidSendEncoderInput(buttonReport)
}

private func handleEncoderTurn(device: HSStreamDeckDevice, report: UnsafeMutablePointer<UInt8>) {
    let start = report + Int(device.dataEncoderOffset)
    for button: Int32 in 1...device.encoderCount {
        let value = Int(start[Int(button - 1)])
        if value > 0 {
            let turningLeft = value >= 200
            device.deviceDidSendEncoderTurn(button: button, turningLeft: turningLeft)
        }
    }
}

private func hidConnectCallback(_ context: UnsafeMutableRawPointer?,
                                _ result: IOReturn,
                                _ sender: UnsafeMutableRawPointer?,
                                _ hidDevice: IOHIDDevice) {
    guard let context = context else { return }
    let manager = Unmanaged<HSStreamDeckManager>.fromOpaque(context).takeUnretainedValue()
    guard let device = manager.deviceDidConnect(hidDevice) else { return }

    guard let inputBuffer = manager.inputBuffer else { return }
    let devicePtr = Unmanaged.passUnretained(device).toOpaque()
    IOHIDDeviceRegisterInputReportCallback(hidDevice, inputBuffer, 1024, hidReportCallback, devicePtr)
}

private func hidDisconnectCallback(_ context: UnsafeMutableRawPointer?,
                                   _ result: IOReturn,
                                   _ sender: UnsafeMutableRawPointer?,
                                   _ hidDevice: IOHIDDevice) {
    guard let context = context else { return }
    let manager = Unmanaged<HSStreamDeckManager>.fromOpaque(context).takeUnretainedValue()
    manager.deviceDidDisconnect(hidDevice)
    IOHIDDeviceRegisterInputValueCallback(hidDevice, nil, nil)
}

// MARK: - Lua API

private func teardownStreamDeckManager(_ manager: HSStreamDeckManager, L: UnsafeMutablePointer<lua_State>?) {
    setStreamDeckDiscoveryCallbackCounted(manager, false, L: L)
    for device in manager.devices {
        device.teardown()
    }
    manager.stopHIDManager()
    manager.doGC()
    if let L {
        lua_unrefRegistryRef(L, &manager.discoveryCallbackRef)
    }
}

/// hs.streamdeck.init(fn)
/// Function
/// Initialises the Stream Deck driver and sets a discovery callback
///
/// Parameters:
///  * fn - A function that will be called when a Stream Deck is connected or disconnected. It should take the following arguments:
///   * A boolean, true if a device was connected, false if a device was disconnected
///   * An hs.streamdeck object, being the device that was connected/disconnected
///
/// Returns:
///  * None
///
/// Notes:
///  * This function must be called before any other parts of this module are used
private func streamdeck_init(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checktype(L, 1, LUA_TFUNCTION)

    if let manager = deckManager {
        teardownStreamDeckManager(manager, L: L)
    }
    deckManager = HSStreamDeckManager()
    lua_replaceRegistryFunctionRef(L, &deckManager!.discoveryCallbackRef, at: 1)
    setStreamDeckDiscoveryCallbackCounted(deckManager!, true, L: L)
    deckManager!.lsCanary = lua_currentStateGeneration()
    deckManager!.startHIDManager()

    return 0
}

/// hs.streamdeck.discoveryCallback(fn)
/// Function
/// Sets/clears a callback for reacting to device discovery events
///
/// Parameters:
///  * fn - A function that will be called when a Stream Deck is connected or disconnected. It should take the following arguments:
///   * A boolean, true if a device was connected, false if a device was disconnected
///   * An hs.streamdeck object, being the device that was connected/disconnected
///
/// Returns:
///  * None
private func streamdeck_discoveryCallback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if let manager = deckManager {
        let active = lua_type(L, 1) == LUA_TFUNCTION
        lua_replaceRegistryFunctionRef(L, &manager.discoveryCallbackRef, at: 1)
        setStreamDeckDiscoveryCallbackCounted(manager, active, L: L)
    }

    return 0
}

/// hs.streamdeck.numDevices()
/// Function
/// Gets the number of Stream Deck devices connected
///
/// Parameters:
///  * None
///
/// Returns:
///  * A number containing the number of Stream Deck devices attached to the system
private func streamdeck_numDevices(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    L.push(Int(deckManager?.devices.count ?? 0))
    return 1
}

/// hs.streamdeck.getDevice(num)
/// Function
/// Gets an hs.streamdeck object for the specified device
///
/// Parameters:
///  * num - A number that should be within the bounds of the number of connected devices
///
/// Returns:
///  * An hs.streamdeck object
private func streamdeck_getDevice(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checktype(L, 1, LUA_TNUMBER)

    let index = Int(lua_tointeger(L, 1)) - 1
    if let manager = deckManager, index >= 0, index < manager.devices.count {
        _ = pushHSStreamDeckDevice(L, manager.devices[index])
    } else {
        lua_pushnil(L)
    }
    return 1
}


// MARK: - Lua<->NSObject Conversion Functions

@discardableResult
private func pushHSStreamDeckDevice(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    guard let value = obj as? HSStreamDeckDevice else { return 0 }
    L.push(userdata: value)
    return 1
}

// MARK: - Lua initialiser

@_cdecl("luaopen_hs_libstreamdeck")
func luaopen_hs_libstreamdeck(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Create ref table in registry
    lua_newtable(L)
    streamDeckRefTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    // Register idiomatic Metatable<HSStreamDeckDevice> with LuaSwift.
    L.register(Metatable<HSStreamDeckDevice>(
        fields: [
            "serialNumber": .closure { L in
                let device: HSStreamDeckDevice = try L.checkArgument(1)
                lua_pushany(L, device.serialNumber as NSString?)
                return 1
            },
            "firmwareVersion": .closure { L in
                let device: HSStreamDeckDevice = try L.checkArgument(1)
                lua_pushany(L, device.firmwareVersion() as NSString?)
                return 1
            },
            "buttonLayout": .closure { L in
                let device: HSStreamDeckDevice = try L.checkArgument(1)
                L.push(Int(device.keyColumns))
                L.push(Int(device.keyRows))
                return 2
            },
            "imageSize": .closure { L in
                let device: HSStreamDeckDevice = try L.checkArgument(1)
                let size = NSSize(width: CGFloat(device.imageWidth), height: CGFloat(device.imageHeight))
                lua_pushNSSize(L, size)
                return 1
            },
            "buttonCallback": .closure { L in
                let device: HSStreamDeckDevice = try L.checkArgument(1)
                let active = lua_type(L, 2) == LUA_TFUNCTION
                lua_replaceRegistryFunctionRef(L, &device.buttonCallbackRef, at: 2)
                setStreamDeckButtonCallbackCounted(device, active, L: L)
                lua_pushvalue(L, 1)
                return 1
            },
            "encoderCallback": .closure { L in
                let device: HSStreamDeckDevice = try L.checkArgument(1)
                let active = lua_type(L, 2) == LUA_TFUNCTION
                lua_replaceRegistryFunctionRef(L, &device.encoderCallbackRef, at: 2)
                setStreamDeckEncoderCallbackCounted(device, active, L: L)
                lua_pushvalue(L, 1)
                return 1
            },
            "screenCallback": .closure { L in
                let device: HSStreamDeckDevice = try L.checkArgument(1)
                let active = lua_type(L, 2) == LUA_TFUNCTION
                lua_replaceRegistryFunctionRef(L, &device.screenCallbackRef, at: 2)
                setStreamDeckScreenCallbackCounted(device, active, L: L)
                lua_pushvalue(L, 1)
                return 1
            },
            "setButtonImage": .closure { L in
                let device: HSStreamDeckDevice = try L.checkArgument(1)
                let image: NSImage = lua_checkUserdataObject(NSImage.self, L, at: 3, metatableName: "hs.image")
                device.setImage(image, forButton: Int32(lua_tointeger(L, 2)))
                lua_pushvalue(L, 1)
                return 1
            },
            "setScreenImage": .closure { L in
                let device: HSStreamDeckDevice = try L.checkArgument(1)
                let image: NSImage = lua_checkUserdataObject(NSImage.self, L, at: 3, metatableName: "hs.image")
                device.setLCDImage(image, forEncoder: Int32(lua_tointeger(L, 2)))
                lua_pushvalue(L, 1)
                return 1
            },
            "setButtonColor": .closure { L in
                let device: HSStreamDeckDevice = try L.checkArgument(1)
                guard let color = tableToNSColor(L, at: 3) else {
                    return luaL_argerror(L, 3, "color table expected")
                }
                device.setColor(color, forButton: Int32(lua_tointeger(L, 2)))
                lua_pushvalue(L, 1)
                return 1
            },
            "setBrightness": .closure { L in
                let device: HSStreamDeckDevice = try L.checkArgument(1)
                luaL_checktype(L, 2, LUA_TNUMBER)
                device.setBrightness(Int32(lua_tointeger(L, 2)))
                lua_pushvalue(L, 1)
                return 1
            },
            "reset": .closure { L in
                let device: HSStreamDeckDevice = try L.checkArgument(1)
                device.reset()
                lua_pushvalue(L, 1)
                return 1
            },
        ],
        eq: .closure { L in
            if let obj1: HSStreamDeckDevice = L.touserdata(1),
               let obj2: HSStreamDeckDevice = L.touserdata(2) {
                L.push(obj1.isEqual(to: obj2))
            } else {
                L.push(false)
            }
            return 1
        },
        tostring: .closure { L in
            let obj: HSStreamDeckDevice = try L.checkArgument(1)
            let title = "\(obj.deckType), serial: \(obj.serialNumber ?? "unknown")"
            let ptr = lua_topointer(L, 1)
            let ptrStr = ptr.map { String(format: "%p", Int(bitPattern: $0)) } ?? "0x0"
            L.push("\(USERDATA_TAG): \(title) (\(ptrStr))")
            return 1
        }
    ))

    installMetatableBoilerplate(L, for: HSStreamDeckDevice.self, tag: USERDATA_TAG)

    // Create module table
    lua_createtable(L, 0, 4)
    L.push(streamdeck_init)
    lua_setfield(L, -2, "init")
    L.push(streamdeck_discoveryCallback)
    lua_setfield(L, -2, "discoveryCallback")
    L.push(streamdeck_numDevices)
    lua_setfield(L, -2, "numDevices")
    L.push(streamdeck_getDevice)
    lua_setfield(L, -2, "getDevice")

    // Set module metatable (for __gc)
    lua_createtable(L, 0, 1)
    lua_pushcclosure(L, { L in
        if let manager = deckManager {
            var tmpLSUUID = manager.lsCanary
            manager.lsCanary = tmpLSUUID
            teardownStreamDeckManager(manager, L: L)
            deckManager = nil
        }
        return 0
    }, 0)
    lua_setfield(L, -2, "__gc")
    lua_setmetatable(L, -2)

    return 1
}
