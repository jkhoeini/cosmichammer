//
//  HSStreamDeckDeviceOriginal.swift
//  streamdeck
//
//  Created by Chris Jones on 25/11/2019.
//  Copyright © 2019 Hammerspoon. All rights reserved.
//

import Foundation
import IOKit
import IOKit.hid

@objcMembers
class HSStreamDeckDeviceOriginal: HSStreamDeckDevice {

    override init(device: IOHIDDevice, manager: AnyObject) {
        super.init(device: device, manager: manager)

        self.deckType = "Elgato Stream Deck (Original v1)"
        self.keyRows = 3
        self.keyColumns = 5
        self.imageWidth = 72
        self.imageHeight = 72
        self.imageCodec = .bmp
        self.imageFlipX = true
        self.imageFlipY = true
        self.imageAngle = 0
        self.simpleReportLength = 17
        self.reportLength = 8192
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

    override func transformKeyIndex(_ sourceKey: Int32) -> Int32 {
        let midpoint: Int32

        if sourceKey >= 1 && sourceKey <= 5 {
            midpoint = 3
        } else if sourceKey >= 6 && sourceKey <= 10 {
            midpoint = 8
        } else if sourceKey >= 11 && sourceKey <= 15 {
            midpoint = 13
        } else {
            midpoint = 3 // This will cause incorrect rendering, but it shouldn't happen
        }

        let diff = midpoint - sourceKey
        return midpoint + diff
    }

    override func deviceWriteImage(_ data: Data, button: Int32) {
        var reportMagic: [UInt8] = [
            0x02,  // Report ID
            0x01,  // Unknown (always seems to be 1)
            0x01,  // Page Number
            0x00,  // Padding
            0x00,  // Continuation Bool
            UInt8(button), // Deck button to set
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        ]

        // The original Stream Deck needs images sent in two halves of seemingly arbitrary length
        let imageLen = data.count
        let halfImageLen = imageLen / 2

        // Prepare and send the first half of the image
        var reportPage1 = Data(count: Int(reportLength))
        reportPage1.replaceSubrange(0..<Int(reportHeaderLength), with: reportMagic)
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            reportPage1.replaceSubrange(Int(reportHeaderLength)..<(Int(reportHeaderLength) + halfImageLen),
                                        with: baseAddress, count: halfImageLen)
        }

        reportPage1.withUnsafeBytes { rawBuffer in
            guard let device = self.device,
                  let rawBytes = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            IOHIDDeviceSetReport(device, kIOHIDReportType(kIOHIDReportTypeOutput), CFIndex(reportMagic[0]), rawBytes, reportPage1.count)
        }

        // Prepare and send the second half of the image
        var reportPage2 = Data(count: Int(reportLength))
        reportMagic[2] = 2
        reportMagic[4] = 1
        reportPage2.replaceSubrange(0..<Int(reportHeaderLength), with: reportMagic)
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            let src = baseAddress.advanced(by: halfImageLen)
            reportPage2.replaceSubrange(Int(reportHeaderLength)..<(Int(reportHeaderLength) + halfImageLen),
                                        with: src, count: halfImageLen)
        }

        reportPage2.withUnsafeBytes { rawBuffer in
            guard let device = self.device,
                  let rawBytes = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            IOHIDDeviceSetReport(device, kIOHIDReportType(kIOHIDReportTypeOutput), CFIndex(reportMagic[0]), rawBytes, reportPage2.count)
        }
    }
}
