//
//  HSChooserWindow.swift
//  Hammerspoon
//
//  Created by Chris Jones on 29/12/2015.
//  Copyright © 2015 Hammerspoon. All rights reserved.
//

import Cocoa

@objcMembers
class HSChooserWindow: NSPanel {
    override var canBecomeMain: Bool { true }
    override var canBecomeKey: Bool { true }
    override var allowsVibrancy: Bool { true }
}
