//
//  HSStreamDeckDevicePlus.swift
//  streamdeck
//
//  Created by Chris Hocking on 16/02/2023.
//  Copyright © 2023 Hammerspoon. All rights reserved.
//

import Foundation
import IOKit
import IOKit.hid

@objcMembers
class HSStreamDeckDevicePlus: HSStreamDeckDevice {

    override init(device: IOHIDDevice, manager: AnyObject) {
        super.init(device: device, manager: manager)

        self.deckType = "Elgato Stream Deck Plus"
        self.keyRows = 2
        self.keyColumns = 4
        self.imageWidth = 120
        self.imageHeight = 120
        self.imageCodec = .jpeg
        self.imageFlipX = false
        self.imageFlipY = false
        self.imageAngle = 0
        self.simpleReportLength = 32
        self.reportLength = 1024
        self.reportHeaderLength = 8

        self.dataKeyOffset = 4
        self.dataEncoderOffset = 5

        self.encoderColumns = 4
        self.encoderRows = 1

        self.lcdStripWidth = 800
        self.lcdStripHeight = 100

        self.lcdReportLength = 1024
        self.lcdReportHeaderLength = 16

        let resetHeader: [UInt8] = [0x03, 0x02]
        self.resetCommand = Data(resetHeader)

        let brightnessHeader: [UInt8] = [0x03, 0x08, 0xFF]
        self.setBrightnessCommand = Data(brightnessHeader)

        self.serialNumberCommand = 0x06
        self.firmwareVersionCommand = 0x05

        self.serialNumberReadOffset = 2
        self.firmwareReadOffset = 6
    }

    override func deviceWriteImage(_ data: Data, button: Int32) {
        deviceV2WriteImage(data, button: button)
    }
}
