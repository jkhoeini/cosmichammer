//
//  HSStreamDeckManager.swift
//  Hammerspoon
//
//  Created by Chris Jones on 06/09/2017.
//  Copyright © 2017 Hammerspoon. All rights reserved.
//

import Foundation
import IOKit
import IOKit.hid
import LuaSkin

// MARK: - IOKit C callbacks

private var inputBuffer: UnsafeMutablePointer<UInt8>?

private func HIDReport(_ deviceRef: UnsafeMutableRawPointer?,
                        _ result: IOReturn,
                        _ sender: UnsafeMutableRawPointer?,
                        _ type: IOHIDReportType,
                        _ reportID: UInt32,
                        _ report: UnsafeMutablePointer<UInt8>,
                        _ reportLength: CFIndex) {
    guard let deviceRef = deviceRef else { return }
    let device = Unmanaged<HSStreamDeckDevice>.fromOpaque(deviceRef).takeUnretainedValue()

    let inputType = report[1]
    if inputType == 0x00 || inputType == 0x01 {
        // An `inputType` of `0x01` was observed for button 1 on a Stream Deck Mini (Model 20GAI9901).
        // BUTTON EVENT:
        let buttonReport = NSMutableArray(capacity: Int(device.keyCount) + 1)

        // We need an unused button at slot zero - all our uses of these arrays are one-indexed
        buttonReport[0] = NSNumber(value: 0)

        for p in 1...device.keyCount {
            buttonReport[Int(p)] = NSNumber(value: 0)
        }

        let start = report.advanced(by: Int(device.dataKeyOffset))
        for button: Int32 in 1...device.keyCount {
            let val = NSNumber(value: start[Int(button - 1)])
            let translatedButton = device.transformKeyIndex(button)
            buttonReport[Int(translatedButton)] = val
        }
        device.deviceDidSendInput(buttonReport as! [Any])

    } else if inputType == 0x02 {
        // LCD EVENT:
        var eventTypeString = "Unknown"
        let startX = UInt16(report[6]) | (UInt16(report[7]) << 8)
        let startY = UInt16(report[8]) | (UInt16(report[9]) << 8)
        var endX: UInt16 = 0
        var endY: UInt16 = 0

        let eventType = report[4]
        if eventType == 0x01 {
            // SHORT PRESS:
            eventTypeString = "shortPress"
        } else if eventType == 0x02 {
            // LONG PRESS:
            eventTypeString = "longPress"
        } else if eventType == 0x03 {
            // SWIPE:
            eventTypeString = "swipe"
            endX = UInt16(report[10]) | (UInt16(report[11]) << 8)
            endY = UInt16(report[12]) | (UInt16(report[13]) << 8)
        }

        device.deviceDidSendScreenTouch(eventTypeString, startX: Int32(startX), startY: Int32(startY), endX: Int32(endX), endY: Int32(endY))

    } else if inputType == 0x03 {
        // ENCODER EVENT:
        let eventType = report[4]
        if eventType == 0x00 {
            // ENCODER PRESS/RELEASE:
            let buttonReport = NSMutableArray(capacity: Int(device.encoderCount) + 1)

            // We need an unused button at slot zero - all our uses of these arrays are one-indexed
            buttonReport[0] = NSNumber(value: 0)

            for p in 1...device.encoderCount {
                buttonReport[Int(p)] = NSNumber(value: 0)
            }

            let start = report.advanced(by: Int(device.dataEncoderOffset))
            for button: Int32 in 1...device.encoderCount {
                let val = NSNumber(value: start[Int(button - 1)])
                let translatedButton = device.transformKeyIndex(button)
                buttonReport[Int(translatedButton)] = val
            }
            device.deviceDidSendEncoderInput(buttonReport as! [Any])

        } else if eventType == 0x01 {
            // ENCODER TURN:
            let start = report.advanced(by: Int(device.dataEncoderOffset))
            for button: Int32 in 1...device.encoderCount {
                let value = Int(start[Int(button - 1)])
                if value > 0 {
                    let turningLeft = value >= 200
                    device.deviceDidSendEncoderTurn(withButton: NSNumber(value: button), turningLeft: turningLeft)
                }
            }
        }
    }
}

private func HIDconnect(_ context: UnsafeMutableRawPointer?,
                         _ result: IOReturn,
                         _ sender: UnsafeMutableRawPointer?,
                         _ device: IOHIDDevice) {
    guard let context = context else { return }
    let manager = Unmanaged<HSStreamDeckManager>.fromOpaque(context).takeUnretainedValue()
    if let deckDevice = manager.deviceDidConnect(device) {
        guard let buffer = inputBuffer else { return }
        let unmanaged = Unmanaged.passUnretained(deckDevice)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 1024, HIDReport, unmanaged.toOpaque())
    }
}

private func HIDdisconnect(_ context: UnsafeMutableRawPointer?,
                            _ result: IOReturn,
                            _ sender: UnsafeMutableRawPointer?,
                            _ device: IOHIDDevice) {
    guard let context = context else { return }
    let manager = Unmanaged<HSStreamDeckManager>.fromOpaque(context).takeUnretainedValue()
    manager.deviceDidDisconnect(device)
    IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
}

// MARK: - Stream Deck Manager implementation

@objcMembers
class HSStreamDeckManager: NSObject {
    var ioHIDManager: IOHIDManager?
    var devices: NSMutableArray = NSMutableArray()
    var discoveryCallbackRef: Int32 = LUA_NOREF
    var lsCanary: LSGCCanary = 0

    override init() {
        super.init()

        self.devices = NSMutableArray(capacity: 5)
        self.discoveryCallbackRef = LUA_NOREF
        inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)

        // Create a HID device manager
        let hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDManagerOptionNone))
        self.ioHIDManager = hidManager

        // Configure the HID manager to match against Stream Deck devices
        let vendorIDKey = kIOHIDVendorIDKey
        let productIDKey = kIOHIDProductIDKey

        let matchOriginal:   [String: Any] = [vendorIDKey: USB_VID_ELGATO, productIDKey: USB_PID_STREAMDECK_ORIGINAL]
        let matchOriginalV2: [String: Any] = [vendorIDKey: USB_VID_ELGATO, productIDKey: USB_PID_STREAMDECK_ORIGINAL_V2]
        let matchMini:       [String: Any] = [vendorIDKey: USB_VID_ELGATO, productIDKey: USB_PID_STREAMDECK_MINI]
        let matchMiniV2:     [String: Any] = [vendorIDKey: USB_VID_ELGATO, productIDKey: USB_PID_STREAMDECK_MINI_V2]
        let matchXL:         [String: Any] = [vendorIDKey: USB_VID_ELGATO, productIDKey: USB_PID_STREAMDECK_XL]
        let matchXLV2:       [String: Any] = [vendorIDKey: USB_VID_ELGATO, productIDKey: USB_PID_STREAMDECK_XL_V2]
        let matchMk2:        [String: Any] = [vendorIDKey: USB_VID_ELGATO, productIDKey: USB_PID_STREAMDECK_MK2]
        let matchPlus:       [String: Any] = [vendorIDKey: USB_VID_ELGATO, productIDKey: USB_PID_STREAMDECK_PLUS]
        let matchPedal:      [String: Any] = [vendorIDKey: USB_VID_ELGATO, productIDKey: USB_PID_STREAMDECK_PEDAL]

        IOHIDManagerSetDeviceMatchingMultiple(hidManager,
                                              [matchOriginal,
                                               matchOriginalV2,
                                               matchMini,
                                               matchMiniV2,
                                               matchXL,
                                               matchXLV2,
                                               matchMk2,
                                               matchPlus,
                                               matchPedal] as CFArray)

        // Add our callbacks for relevant events
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(hidManager, HIDconnect, selfPtr)
        IOHIDManagerRegisterDeviceRemovalCallback(hidManager, HIDdisconnect, selfPtr)

        // Start our HID manager
        IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    @objc func doGC() {
        guard let hidManager = ioHIDManager else {
            // Something is wrong and the manager doesn't exist, so just bail
            return
        }

        // Remove our callbacks
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(hidManager, nil, selfPtr)
        IOHIDManagerRegisterDeviceRemovalCallback(hidManager, nil, selfPtr)

        // Remove our HID manager from the runloop
        IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        // Deallocate the HID manager
        self.ioHIDManager = nil

        if let buffer = inputBuffer {
            buffer.deallocate()
            inputBuffer = nil
        }
    }

    @objc func startHIDManager() -> Bool {
        guard let hidManager = ioHIDManager else { return false }
        let result = IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        return result == kIOReturnSuccess
    }

    @objc func stopHIDManager() -> Bool {
        guard let hidManager = ioHIDManager else { return true }
        let result = IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        return result == kIOReturnSuccess
    }

    @objc func deviceDidConnect(_ device: IOHIDDevice) -> HSStreamDeckDevice? {
        let skin = LuaSkin.shared(withState: nil)!
        _lua_stackguard_entry(skin.L)

        if !skin.checkGCCanary(lsCanary) {
            _lua_stackguard_exit(skin.L)
            return nil
        }

        if discoveryCallbackRef == LUA_NOREF || discoveryCallbackRef == LUA_REFNIL {
            skin.logWarn("hs.streamdeck detected a device connecting, but no discovery callback has been set. See hs.streamdeck.discoveryCallback()")
            _lua_stackguard_exit(skin.L)
            return nil
        }

        let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber
        let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber

        guard let vendorID = vendorID, vendorID.intValue == USB_VID_ELGATO else {
            NSLog("deviceDidConnect from unknown vendor: %d", vendorID?.intValue ?? -1)
            return nil
        }

        var deck: HSStreamDeckDevice?

        switch productID?.intValue {
        case USB_PID_STREAMDECK_ORIGINAL:
            deck = HSStreamDeckDeviceOriginal(device: device, manager: self)
        case USB_PID_STREAMDECK_MINI:
            deck = HSStreamDeckDeviceMini(device: device, manager: self)
        case USB_PID_STREAMDECK_MINI_V2:
            deck = HSStreamDeckDeviceMini(device: device, manager: self)
        case USB_PID_STREAMDECK_XL:
            deck = HSStreamDeckDeviceXL(device: device, manager: self)
        case USB_PID_STREAMDECK_XL_V2:
            deck = HSStreamDeckDeviceXL(device: device, manager: self)
        case USB_PID_STREAMDECK_ORIGINAL_V2:
            deck = HSStreamDeckDeviceOriginalV2(device: device, manager: self)
        case USB_PID_STREAMDECK_MK2:
            deck = HSStreamDeckDeviceMk2(device: device, manager: self)
        case USB_PID_STREAMDECK_PLUS:
            deck = HSStreamDeckDevicePlus(device: device, manager: self)
        case USB_PID_STREAMDECK_PEDAL:
            deck = HSStreamDeckDevicePedal(device: device, manager: self)
        default:
            NSLog("deviceDidConnect from unknown device: %d", productID?.intValue ?? -1)
        }

        guard let deck = deck else {
            NSLog("deviceDidConnect: no HSStreamDeckDevice was created, ignoring")
            return nil
        }

        deck.lsCanary = skin.createGCCanary()
        deck.initialiseCaches()
        devices.add(deck)

        skin.pushLuaRef(streamDeckRefTable, ref: discoveryCallbackRef)
        lua_pushboolean(skin.L, 1)
        skin.pushNSObject(deck)
        skin.protectedCallAndError("hs.streamdeck:deviceDidConnect", nargs: 2, nresults: 0)

        _lua_stackguard_exit(skin.L)
        return deck
    }

    @objc func deviceDidDisconnect(_ device: IOHIDDevice) {
        let skin = LuaSkin.shared(withState: nil)!
        _lua_stackguard_entry(skin.L)

        if !skin.checkGCCanary(lsCanary) {
            _lua_stackguard_exit(skin.L)
            return
        }

        for deckDevice in devices {
            guard let deckDevice = deckDevice as? HSStreamDeckDevice else { continue }
            if deckDevice.device == device {
                deckDevice.invalidate()

                if discoveryCallbackRef == LUA_NOREF || discoveryCallbackRef == LUA_REFNIL {
                    skin.logWarn("hs.streamdeck detected a device disconnecting, but no callback has been set. See hs.streamdeck.discoveryCallback()")
                } else {
                    skin.pushLuaRef(streamDeckRefTable, ref: discoveryCallbackRef)
                    lua_pushboolean(skin.L, 0)
                    skin.pushNSObject(deckDevice)
                    skin.protectedCallAndError("hs.streamdeck:deviceDidDisconnect", nargs: 2, nresults: 0)
                }

                var tmpLSUUID = deckDevice.lsCanary
                skin.destroyGCCanary(&tmpLSUUID)
                deckDevice.lsCanary = tmpLSUUID

                devices.remove(deckDevice)
                _lua_stackguard_exit(skin.L)
                return
            }
        }
        NSLog("ERROR: A Stream Deck was disconnected that we didn't know about")
        _lua_stackguard_exit(skin.L)
    }
}
