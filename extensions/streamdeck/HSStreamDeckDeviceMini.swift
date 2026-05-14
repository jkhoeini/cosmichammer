//
//  HSStreamDeckDeviceMini.swift
//  streamdeck
//
//  Created by Chris Jones on 25/11/2019.
//  Copyright © 2019 Hammerspoon. All rights reserved.
//
// Stream Deck Mini support was made possible by examining https://github.com/abcminiuser/python-elgato-streamdeck/tree/master/src/StreamDeck/Devices

import Foundation
import IOKit
import IOKit.hid

@objcMembers
class HSStreamDeckDeviceMini: HSStreamDeckDevice {

    override init(device: IOHIDDevice, manager: AnyObject) {
        super.init(device: device, manager: manager)

        self.deckType = "Elgato Stream Deck (Mini)"
        self.keyRows = 2
        self.keyColumns = 3
        self.imageWidth = 80
        self.imageHeight = 80
        self.imageCodec = .bmp
        self.imageFlipX = false
        self.imageFlipY = true
        self.imageAngle = 90
        self.simpleReportLength = 17
        self.reportLength = 1024
        self.reportHeaderLength = 16
        self.dataKeyOffset = 1

        let resetHeader: [UInt8] = [0x0B, 0x63]
        self.resetCommand = Data(resetHeader)

        let brightnessHeader: [UInt8] = [0x05, 0x55, 0xAA, 0xD1, 0x01, 0xFF]
        self.setBrightnessCommand = Data(brightnessHeader)

        self.serialNumberCommand = 0x03
        self.firmwareVersionCommand = 0x04

        self.serialNumberReadOffset = 5
        self.firmwareReadOffset = 5
    }

    override func deviceWriteImage(_ data: Data, button: Int32) {
        var reportMagic: [UInt8] = [
            0x02,  // Report ID
            0x01,  // Unknown (always seems to be 1)
            0x00,  // Page Number
            0x00,  // Padding
            0x00,  // Last page Bool
            UInt8(button), // Deck button to set
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        ]

        // The Mini Stream Deck needs images sent in slices no more than 1008 bytes
        let payloadLength = Int(reportLength - reportHeaderLength)
        var bytesRemaining = data.count
        var pageNumber: UInt8 = reportMagic[2]

        while bytesRemaining > 0 {
            let thisReportLength = min(bytesRemaining, payloadLength)
            let bytesSent = Int(pageNumber) * payloadLength

            // Set our current page number
            reportMagic[2] = pageNumber
            // Set if we're the last page of data
            if bytesRemaining <= payloadLength { reportMagic[4] = 1 }

            var report = Data(count: Int(self.reportLength))
            report.replaceSubrange(0..<Int(reportHeaderLength), with: reportMagic)
            data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                let src = baseAddress.advanced(by: bytesSent)
                report.replaceSubrange(Int(reportHeaderLength)..<(Int(reportHeaderLength) + thisReportLength),
                                       with: src, count: thisReportLength)
            }

            let result = report.withUnsafeBytes { rawBuffer -> IOReturn in
                guard let device = self.device,
                      let rawBytes = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return IOReturn(kIOReturnNotReady)
                }
                return IOHIDDeviceSetReport(device, kIOHIDReportType(kIOHIDReportTypeOutput), CFIndex(reportMagic[0]), rawBytes, report.count)
            }
            if result != kIOReturnSuccess {
                NSLog("WARNING: writing an image with hs.streamdeck encountered a failure on page %d: %d", pageNumber, result)
            }
            bytesRemaining -= Int(self.reportLength)
            pageNumber += 1
        }
    }
}
