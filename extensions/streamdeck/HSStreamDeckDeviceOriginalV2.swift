//
//  HSStreamDeckDeviceOriginalV2.swift
//  streamdeck
//
//  Created by Chris Jones on 08/01/2020.
//  Copyright © 2020 Hammerspoon. All rights reserved.
//

import Foundation
import IOKit
import IOKit.hid

@objcMembers
class HSStreamDeckDeviceOriginalV2: HSStreamDeckDevice {

    override init(device: IOHIDDevice, manager: AnyObject) {
        super.init(device: device, manager: manager)

        self.deckType = "Elgato Stream Deck (V2)"
        self.keyRows = 3
        self.keyColumns = 5
        self.imageWidth = 72
        self.imageHeight = 72
        self.imageCodec = .jpeg
        self.imageFlipX = true
        self.imageFlipY = true
        self.imageAngle = 0
        self.simpleReportLength = 32
        self.reportLength = 1024
        self.reportHeaderLength = 8
        self.dataKeyOffset = 4

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
