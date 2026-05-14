//
//  HSChooserVerticallyCenteringTextFieldCell.swift
//  chooser
//
//  Created by Chris Jones on 03/05/2019.
//  Copyright © 2019 Hammerspoon. All rights reserved.
//

import Cocoa

@objcMembers
class HSChooserVerticallyCenteringTextFieldCell: NSTextFieldCell {

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        var attrString = attributedStringValue

        // If your values can be attributed strings, make them white when selected
        if isHighlighted && backgroundStyle == .emphasized {
            let whiteString = attrString.mutableCopy() as! NSMutableAttributedString
            whiteString.addAttribute(.foregroundColor,
                                     value: NSColor.white,
                                     range: NSRange(location: 0, length: whiteString.length))
            attrString = whiteString
        }

        attrString.draw(with: titleRect(forBounds: cellFrame),
                         options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
    }

    override func titleRect(forBounds theRect: NSRect) -> NSRect {
        // Get the standard text content rectangle
        var titleFrame = super.titleRect(forBounds: theRect)

        // Find out how big the rendered text will be
        let attrString = attributedStringValue
        let textRect = attrString.boundingRect(with: titleFrame.size,
                                               options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])

        // If the height of the rendered text is less than the available height,
        // we modify the titleRect to center the text vertically
        if textRect.size.height < titleFrame.size.height {
            titleFrame.origin.y = theRect.origin.y + (theRect.size.height - textRect.size.height) / 2.0
            titleFrame.size.height = textRect.size.height
        }
        return titleFrame
    }
}
