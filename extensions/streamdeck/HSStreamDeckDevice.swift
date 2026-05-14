//
//  HSStreamDeckDevice.swift
//  Hammerspoon
//
//  Created by Chris Jones on 06/09/2017.
//  Copyright © 2017 Hammerspoon. All rights reserved.
//

import Foundation
import Cocoa
import IOKit
import IOKit.hid
import LuaSkin

@objc enum HSStreamDeckImageCodec: UInt {
    case unknown = 0
    case bmp
    case jpeg
}

@objcMembers
class HSStreamDeckDevice: NSObject {
    var device: IOHIDDevice?
    var manager: AnyObject?
    var selfRefCount: Int32 = 0

    var buttonCallbackRef: Int32 = LUA_NOREF
    var encoderCallbackRef: Int32 = LUA_NOREF
    var screenCallbackRef: Int32 = LUA_NOREF

    var isValid: Bool = false
    var lsCanary: LSGCCanary = 0

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
    var firmwareReadOffset: UInt = 0
    var serialNumberReadOffset: UInt = 0
    var resetCommand: Data?
    var setBrightnessCommand: Data?
    var serialNumberCommand: UInt = 0
    var firmwareVersionCommand: UInt = 0

    var buttonStateCache: NSMutableArray = NSMutableArray()
    var encoderButtonStateCache: NSMutableArray = NSMutableArray()

    private var serialNumberCache: String?

    @objc var keyCount: Int32 {
        return keyColumns * keyRows
    }

    @objc var encoderCount: Int32 {
        return encoderColumns * encoderRows
    }

    @objc var serialNumber: String? {
        if serialNumberCache == nil {
            // This shouldn't be necessary, since we cache the serial number when the device is initialised, but just in case
            serialNumberCache = cacheSerialNumber()
        }
        return serialNumberCache
    }

    @objc init(device: IOHIDDevice, manager: AnyObject) {
        super.init()

        self.device = device
        self.isValid = true
        self.manager = manager

        self.buttonCallbackRef = LUA_NOREF
        self.encoderCallbackRef = LUA_NOREF
        self.screenCallbackRef = LUA_NOREF

        self.selfRefCount = 0

        self.buttonStateCache = NSMutableArray()
        self.encoderButtonStateCache = NSMutableArray()

        // These defaults are not necessary, all base classes will override them, but if we miss something, these are chosen to try and provoke a crash where possible, so we notice the lack of an override.
        self.imageCodec = .unknown
        self.deckType = "Unknown"
        self.keyColumns = -1
        self.keyRows = -1
        self.imageFlipX = false
        self.imageFlipY = false
        self.imageAngle = 0
        self.simpleReportLength = 0
        self.reportLength = 0
        self.reportHeaderLength = 0

        self.lcdReportLength = 0
        self.lcdReportHeaderLength = 0

        self.encoderColumns = 0
        self.encoderRows = 0

        self.lcdStripWidth = 0
        self.lcdStripHeight = 0

        self.dataKeyOffset = 0
        self.dataEncoderOffset = 0

        self.resetCommand = nil
        self.setBrightnessCommand = nil
        self.serialNumberCommand = 0
        self.firmwareVersionCommand = 0

        self.firmwareReadOffset = 0
        self.serialNumberReadOffset = 0

        self.serialNumberCache = nil
    }

    @objc func invalidate() {
        self.isValid = false
    }

    @objc func initialiseCaches() {
        for i in 0...keyCount {
            buttonStateCache[Int(i)] = NSNumber(value: 0)
        }

        for i in 0...encoderCount {
            encoderButtonStateCache[Int(i)] = NSNumber(value: 0)
        }

        _ = cacheSerialNumber()
    }

    @objc func deviceWriteSimpleReport(_ command: Data) -> IOReturn {
        if simpleReportLength == 0 {
            LuaSkin.logError("Initialising Stream Deck device with no simple report length defined")
            return IOReturn(kIOReturnInternalError)
        }
        var reportData = Data(count: Int(simpleReportLength))
        reportData.replaceSubrange(0..<command.count, with: command)
        return deviceWrite(reportData)
    }

    @objc func deviceWrite(_ report: Data) -> IOReturn {
        guard let device = self.device else { return IOReturn(kIOReturnNotReady) }
        return report.withUnsafeBytes { rawBuffer -> IOReturn in
            guard let rawBytes = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return IOReturn(kIOReturnInternalError)
            }
            return IOHIDDeviceSetReport(device, kIOHIDReportType(kIOHIDReportTypeFeature), CFIndex(rawBytes[0]), rawBytes, report.count)
        }
    }

    @objc func deviceRead(_ resultLength: Int32, reportID: CFIndex, readOffset: UInt) -> Data {
        guard let device = self.device else { return Data() }
        var reportLength = CFIndex(resultLength) + CFIndex(readOffset)
        let report = UnsafeMutablePointer<UInt8>.allocate(capacity: reportLength)
        defer { report.deallocate() }

        IOHIDDeviceGetReport(device, kIOHIDReportType(kIOHIDReportTypeFeature), reportID, report, &reportLength)

        let cData = report.advanced(by: Int(readOffset))
        let dataRaw = Data(bytes: cData, count: Int(resultLength))

        var data = Data()
        dataRaw.withUnsafeBytes { rawBuffer in
            guard let bytes = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var copyLength = dataRaw.count
            for i in 0..<dataRaw.count {
                if bytes[i] == 0x00 {
                    copyLength = i
                    break
                }
            }
            data.append(bytes, count: copyLength)
        }

        return data
    }

    @objc func transformKeyIndex(_ sourceKey: Int32) -> Int32 {
        return sourceKey
    }

    @objc func deviceDidSendInput(_ newButtonStates: [Any]) {
        guard isValid else { return }

        let skin = LuaSkin.shared(withState: nil)!
        _lua_stackguard_entry(skin.L)

        if !skin.checkGCCanary(lsCanary) {
            _lua_stackguard_exit(skin.L)
            return
        }

        if buttonCallbackRef == LUA_NOREF || buttonCallbackRef == LUA_REFNIL {
            skin.logError("hs.streamdeck received a button input, but no callback has been set. See hs.streamdeck:buttonCallback()")
            return
        }

        for button in 1...keyCount {
            let idx = Int(button)
            if !(buttonStateCache[idx] as! NSObject).isEqual(newButtonStates[idx]) {
                skin.pushLuaRef(streamDeckRefTable, ref: buttonCallbackRef)
                skin.pushNSObject(self)
                lua_pushinteger(skin.L, lua_Integer(button))
                lua_pushboolean(skin.L, (newButtonStates[idx] as! NSNumber).boolValue ? 1 : 0)
                skin.protectedCallAndError("hs.streamdeck:buttonCallback", nargs: 3, nresults: 0)
                buttonStateCache[idx] = newButtonStates[idx]
            }
        }

        _lua_stackguard_exit(skin.L)
    }

    @objc func deviceDidSendEncoderInput(_ newPressEncoderStates: [Any]) {
        guard isValid else { return }

        let skin = LuaSkin.shared(withState: nil)!
        _lua_stackguard_entry(skin.L)

        if !skin.checkGCCanary(lsCanary) {
            _lua_stackguard_exit(skin.L)
            return
        }

        if encoderCallbackRef == LUA_NOREF || encoderCallbackRef == LUA_REFNIL {
            skin.logError("hs.streamdeck received an encoder button input, but no callback has been set. See hs.streamdeck:encoderCallback()")
            return
        }

        for button in 1...encoderCount {
            let idx = Int(button)
            if !(encoderButtonStateCache[idx] as! NSObject).isEqual(newPressEncoderStates[idx]) {
                skin.pushLuaRef(streamDeckRefTable, ref: encoderCallbackRef)
                skin.pushNSObject(self)
                lua_pushinteger(skin.L, lua_Integer(button))
                lua_pushboolean(skin.L, (newPressEncoderStates[idx] as! NSNumber).boolValue ? 1 : 0)
                lua_pushboolean(skin.L, 0)
                lua_pushboolean(skin.L, 0)
                skin.protectedCallAndError("hs.streamdeck:encoderCallback", nargs: 5, nresults: 0)
                encoderButtonStateCache[idx] = newPressEncoderStates[idx]
            }
        }

        _lua_stackguard_exit(skin.L)
    }

    @objc func deviceDidSendEncoderTurn(withButton button: NSNumber, turningLeft: Bool) {
        guard isValid else { return }

        let skin = LuaSkin.shared(withState: nil)!
        _lua_stackguard_entry(skin.L)

        if !skin.checkGCCanary(lsCanary) {
            _lua_stackguard_exit(skin.L)
            return
        }

        if encoderCallbackRef == LUA_NOREF || encoderCallbackRef == LUA_REFNIL {
            skin.logError("hs.streamdeck received an encoder button input, but no callback has been set. See hs.streamdeck:encoderCallback()")
            return
        }

        skin.pushLuaRef(streamDeckRefTable, ref: encoderCallbackRef)
        skin.pushNSObject(self)
        lua_pushinteger(skin.L, lua_Integer(button.int32Value))
        lua_pushboolean(skin.L, 0)
        lua_pushboolean(skin.L, turningLeft ? 1 : 0)
        lua_pushboolean(skin.L, turningLeft ? 0 : 1)
        skin.protectedCallAndError("hs.streamdeck:encoderCallback", nargs: 5, nresults: 0)

        _lua_stackguard_exit(skin.L)
    }

    @objc func deviceDidSendScreenTouch(_ eventType: String, startX: Int32, startY: Int32, endX: Int32, endY: Int32) {
        guard isValid else { return }

        let skin = LuaSkin.shared(withState: nil)!
        _lua_stackguard_entry(skin.L)

        if !skin.checkGCCanary(lsCanary) {
            _lua_stackguard_exit(skin.L)
            return
        }

        if screenCallbackRef == LUA_NOREF || screenCallbackRef == LUA_REFNIL {
            skin.logError("hs.streamdeck received an screen input, but no callback has been set. See hs.streamdeck:screenCallback()")
            return
        }

        skin.pushLuaRef(streamDeckRefTable, ref: screenCallbackRef)
        skin.pushNSObject(self)
        skin.pushNSObject(eventType as NSString)
        lua_pushinteger(skin.L, lua_Integer(startX))
        lua_pushinteger(skin.L, lua_Integer(startY))
        lua_pushinteger(skin.L, lua_Integer(endX))
        lua_pushinteger(skin.L, lua_Integer(endY))
        skin.protectedCallAndError("hs.streamdeck:screenCallback", nargs: 6, nresults: 0)

        _lua_stackguard_exit(skin.L)
    }

    @objc func setBrightness(_ brightness: Int32) -> Bool {
        guard isValid else { return false }

        guard let brightnessCmd = setBrightnessCommand else {
            NSException(name: NSExceptionName("HSStreamDeckDeviceUnimplemented"),
                        reason: "setBrightness method not implemented",
                        userInfo: nil).raise()
            return false
        }

        var mutableCmd = brightnessCmd
        var brightnessValue = UInt8(clamping: brightness)
        mutableCmd.replaceSubrange((brightnessCmd.count - 1)..<brightnessCmd.count, with: &brightnessValue, count: 1)
        let res = deviceWriteSimpleReport(mutableCmd)
        return res == kIOReturnSuccess
    }

    @objc func reset() {
        guard isValid else { return }

        guard let resetCmd = resetCommand else {
            NSException(name: NSExceptionName("HSStreamDeckDeviceUnimplemented"),
                        reason: "resetCommand bytes not set, or reset method not overridden",
                        userInfo: nil).raise()
            return
        }

        let res = deviceWriteSimpleReport(resetCmd)
        if res != kIOReturnSuccess {
            NSLog("hs.streamdeck:reset() failed on %@ (%@)", deckType, serialNumber ?? "unknown")
        }
    }

    @objc func cacheSerialNumber() -> String? {
        guard isValid else { return nil }

        if serialNumberCommand == 0 {
            NSException(name: NSExceptionName("HSStreamDeckDeviceUnimplemented"),
                        reason: "serialNumberCommand not set, or cacheSerialNumber method not overridden",
                        userInfo: nil).raise()
            return nil
        }

        let serialNumberData = deviceRead(simpleReportLength, reportID: CFIndex(serialNumberCommand), readOffset: serialNumberReadOffset)
        let result = String(data: serialNumberData, encoding: .utf8)
        serialNumberCache = result
        return result
    }

    @objc func firmwareVersion() -> String? {
        guard isValid else { return nil }

        if firmwareVersionCommand == 0 {
            NSException(name: NSExceptionName("HSStreamDeckDeviceUnimplemented"),
                        reason: "firmwareVersionCommand not set, or firmwareVersion method not implemented",
                        userInfo: nil).raise()
            return nil
        }

        let data = deviceRead(simpleReportLength, reportID: CFIndex(firmwareVersionCommand), readOffset: firmwareReadOffset)
        return String(data: data, encoding: .utf8)
    }

    @objc func clearImage(_ button: Int32) {
        setColor(.black, forButton: button)
    }

    @objc func setColor(_ color: NSColor, forButton button: Int32) {
        guard isValid else { return }

        let image = NSImage(size: NSSize(width: CGFloat(imageWidth), height: CGFloat(imageHeight)))
        image.lockFocus()
        color.drawSwatch(in: NSRect(x: 0, y: 0, width: CGFloat(imageWidth), height: CGFloat(imageHeight)))
        image.unlockFocus()
        setImage(image, forButton: button)
    }

    @objc func setImage(_ image: NSImage, forButton button: Int32) {
        guard isValid else { return }

        // Unconditionally resize the image
        let sourceImage = image.copy() as! NSImage
        let newSize = NSSize(width: CGFloat(imageWidth), height: CGFloat(imageHeight))
        let renderImage = NSImage(size: newSize)
        renderImage.lockFocus()
        sourceImage.size = newSize
        NSGraphicsContext.current?.imageInterpolation = .high
        sourceImage.draw(at: .zero, from: CGRect(origin: .zero, size: newSize), operation: .copy, fraction: 1.0)
        renderImage.unlockFocus()

        if !image.isValid {
            LuaSkin.logError("image is invalid")
        }
        if !renderImage.isValid {
            LuaSkin.logError("Invalid image passed to hs.streamdeck:setImage() (renderImage)")
        }

        // Both of these functions are no-ops if there are no rotations or flips required, so we'll call them unconditionally
        var finalImage = renderImage.imageRotated(Int(imageAngle))
        finalImage = finalImage.flipImage(imageFlipX, vert: imageFlipY)

        var data: Data?

        switch imageCodec {
        case .bmp:
            data = finalImage.bmpData()
        case .jpeg:
            data = finalImage.jpegData()
        case .unknown:
            LuaSkin.logError("Unknown image codec for hs.streamdeck device")
        @unknown default:
            LuaSkin.logError("Invalid image codec value")
        }

        // Writing the image to hardware is a device-specific operation, so hand it off to our subclasses
        if let data = data {
            deviceWriteImage(data, button: transformKeyIndex(button))
        }
    }

    @objc func deviceWriteImage(_ data: Data, button: Int32) {
        NSException(name: NSExceptionName("HSStreamDeckDeviceUnimplemented"),
                    reason: "deviceWriteImage method not implemented",
                    userInfo: nil).raise()
    }

    @objc func deviceV2WriteImage(_ data: Data, button: Int32) {
        var reportHeader: [UInt8] = [
            0x02,           // Report ID
            0x07,           // Unknown (always seems to be 7)
            UInt8(button - 1), // Deck button to set
            0x00,           // Final page bool
            0x00,           // Some kind of encoding of the length of the current page
            0x00,           // Some other kind of encoding of the current page length
            0x00,           // Some kind of encoding of the page number
            0x00            // Some other kind of encoding of the page number
        ]

        // The v2 Stream Decks needs images sent in slices no more than 1016 bytes + the report header
        let maxPayloadLength = Int(reportLength - reportHeaderLength)

        var bytesRemaining = data.count
        var pageNumber = 0

        while bytesRemaining > 0 {
            let thisPageLength = min(bytesRemaining, maxPayloadLength)
            let bytesSent = pageNumber * maxPayloadLength

            // Set our current page number
            reportHeader[6] = UInt8(pageNumber & 0xFF)
            reportHeader[7] = UInt8(pageNumber >> 8)

            // Set our current page length
            reportHeader[4] = UInt8(thisPageLength & 0xFF)
            reportHeader[5] = UInt8(thisPageLength >> 8)

            // Set if we're the last page of data
            if bytesRemaining <= maxPayloadLength { reportHeader[3] = 1 }

            var report = Data(count: Int(reportLength))
            report.replaceSubrange(0..<Int(reportHeaderLength), with: reportHeader)
            data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                let src = baseAddress.advanced(by: bytesSent)
                report.replaceSubrange(Int(reportHeaderLength)..<(Int(reportHeaderLength) + thisPageLength),
                                       with: src, count: thisPageLength)
            }

            let result = report.withUnsafeBytes { rawBuffer -> IOReturn in
                guard let device = self.device,
                      let rawBytes = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return IOReturn(kIOReturnNotReady)
                }
                return IOHIDDeviceSetReport(device, kIOHIDReportType(kIOHIDReportTypeOutput), CFIndex(reportHeader[0]), rawBytes, report.count)
            }
            if result != kIOReturnSuccess {
                NSLog("WARNING: writing an image with hs.streamdeck encountered a failure on page %d: %d", pageNumber, result)
            }

            bytesRemaining -= thisPageLength
            pageNumber += 1
        }
    }

    @objc func setLCDImage(_ image: NSImage, forEncoder encoder: Int32) {
        guard isValid else { return }

        // Unconditionally resize the image
        let sourceImage = image.copy() as! NSImage
        let encoderWidth = Int(lcdStripWidth / encoderColumns)
        let newSize = NSSize(width: CGFloat(encoderWidth), height: CGFloat(lcdStripHeight))
        let renderImage = NSImage(size: newSize)
        renderImage.lockFocus()
        sourceImage.size = newSize
        NSGraphicsContext.current?.imageInterpolation = .high
        sourceImage.draw(at: .zero, from: CGRect(origin: .zero, size: newSize), operation: .copy, fraction: 1.0)
        renderImage.unlockFocus()

        if !image.isValid {
            LuaSkin.logError("image is invalid")
        }
        if !renderImage.isValid {
            LuaSkin.logError("Invalid image passed to hs.streamdeck:setLCDImage() (renderImage)")
        }

        // Both of these functions are no-ops if there are no rotations or flips required, so we'll call them unconditionally
        var finalImage = renderImage.imageRotated(Int(imageAngle))
        finalImage = finalImage.flipImage(imageFlipX, vert: imageFlipY)

        var data: Data?

        switch imageCodec {
        case .bmp:
            data = finalImage.bmpData()
        case .jpeg:
            data = finalImage.jpegData()
        case .unknown:
            LuaSkin.logError("Unknown image codec for hs.streamdeck device")
        @unknown default:
            LuaSkin.logError("Invalid image codec value")
        }

        // Writing the image to hardware is a device-specific operation, so hand it off to our subclasses
        if let data = data {
            deviceLCDWriteImage(data, forEncoder: encoder)
        }
    }

    @objc func deviceLCDWriteImage(_ data: Data, forEncoder encoder: Int32) {
        let encoderWidth = Int(lcdStripWidth / encoderColumns)

        let left    = encoderWidth * Int(encoder) - encoderWidth
        let top     = 0
        let width   = encoderWidth
        let height  = Int(lcdStripHeight)

        var reportHeader: [UInt8] = [
            0x02,                               // 0: Report ID
            0x0c,                               // 1: Image Rectangle JPEG
            UInt8(left & 0xFF),                 // 2: Left LSB
            UInt8(left >> 8),                   // 3: Left MSB
            UInt8(top & 0xFF),                  // 4: Top LSB
            UInt8(top >> 8),                    // 5: Top MSB
            UInt8(width & 0xFF),                // 6: Width LSB
            UInt8(width >> 8),                  // 7: Width MSB
            UInt8(height & 0xFF),               // 8: Height LSB
            UInt8(height >> 8),                 // 9: Height MSB
            0x00,                               // 10: Is Last Page (1 or 0)?
            0x00,                               // 11: Page Number LSB
            0x00,                               // 12: Page Number MSB
            0x00,                               // 13: Payload Length LSB
            0x00,                               // 14: Payload Length MSB
            0x00                                // 15: Padding
        ]

        // The v2 Stream Decks needs images sent in slices no more than 1024 bytes minus the report header (16 bytes)
        let maxPayloadLength = Int(lcdReportLength - lcdReportHeaderLength)

        var bytesRemaining = data.count
        var pageNumber = 0

        while bytesRemaining > 0 {
            let thisPageLength = min(bytesRemaining, maxPayloadLength)
            let bytesSent = pageNumber * maxPayloadLength

            // Set our current page number
            reportHeader[11] = UInt8(pageNumber & 0xFF)
            reportHeader[12] = UInt8(pageNumber >> 8)

            // Set our current page length
            reportHeader[13] = UInt8(thisPageLength & 0xFF)
            reportHeader[14] = UInt8(thisPageLength >> 8)

            // Set if we're the last page of data
            if bytesRemaining <= maxPayloadLength { reportHeader[10] = 1 }

            var report = Data(count: Int(lcdReportLength))
            report.replaceSubrange(0..<Int(lcdReportHeaderLength), with: reportHeader)
            data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                let src = baseAddress.advanced(by: bytesSent)
                report.replaceSubrange(Int(lcdReportHeaderLength)..<(Int(lcdReportHeaderLength) + thisPageLength),
                                       with: src, count: thisPageLength)
            }

            let result = report.withUnsafeBytes { rawBuffer -> IOReturn in
                guard let device = self.device,
                      let rawBytes = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return IOReturn(kIOReturnNotReady)
                }
                return IOHIDDeviceSetReport(device, kIOHIDReportType(kIOHIDReportTypeOutput), CFIndex(reportHeader[0]), rawBytes, report.count)
            }
            if result != kIOReturnSuccess {
                NSLog("WARNING: writing an image with hs.streamdeck encountered a failure on page %d: %d", pageNumber, result)
            }

            bytesRemaining -= thisPageLength
            pageNumber += 1
        }
    }
}
