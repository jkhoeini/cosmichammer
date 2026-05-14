//
//  HSChooserCell.swift
//  Hammerspoon
//
//  Created by Chris Jones on 29/12/2015.
//  Copyright © 2015 Hammerspoon. All rights reserved.
//

import Cocoa

@objcMembers
class HSChooserCell: NSTableCellView {
    @IBOutlet weak var text: NSTextField!
    @IBOutlet weak var subText: NSTextField!
    @IBOutlet weak var shortcutText: NSTextField!
    @IBOutlet weak var image: NSImageView!

    override var allowsVibrancy: Bool { false }
}
