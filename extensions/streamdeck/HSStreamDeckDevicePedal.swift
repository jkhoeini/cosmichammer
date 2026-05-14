//
//  HSStreamDeckDevicePedal.swift
//  streamdeck
//
//  Created by Chris Hocking on 02/03/2023.
//  Copyright © 2023 Hammerspoon. All rights reserved.
//

import Foundation
import Cocoa
import IOKit
import IOKit.hid

@objcMembers
class HSStreamDeckDevicePedal: HSStreamDeckDevice {

    override init(device: IOHIDDevice, manager: AnyObject) {
        super.init(device: device, manager: manager)

        self.deckType = "Elgato Stream Deck Pedal"
        self.keyRows = 1
        self.keyColumns = 3

        self.simpleReportLength = 32
        self.reportLength = 1024
        self.reportHeaderLength = 8
        self.dataKeyOffset = 4

        let resetHeader: [UInt8] = [0x03, 0x02]
        self.resetCommand = Data(resetHeader)

        self.serialNumberCommand = 0x06
        self.firmwareVersionCommand = 0x05

        self.serialNumberReadOffset = 2
        self.firmwareReadOffset = 6
    }

    override func setImage(_ image: NSImage, forButton button: Int32) {
        // Do nothing
    }

    override func deviceWriteImage(_ data: Data, button: Int32) {
        // Do nothing
    }

    override func setLCDImage(_ image: NSImage, forEncoder encoder: Int32) {
        // Do nothing
    }
}
