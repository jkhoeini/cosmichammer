//
//  HSChooserTableView.swift
//  Hammerspoon
//
//  Created by Chris Jones on 30/12/2015.
//  Copyright © 2015 Hammerspoon. All rights reserved.
//

import Cocoa

// Here we're defining an extra protocol for our own methods, to avoid overloading the normal NSTableViewDelegate
@objc protocol HSChooserTableViewDelegate: NSObjectProtocol {
    func tableView(_ tableView: NSTableView, didClickedRow row: Int)
    func didRightClick(atRow row: Int)
}

@objcMembers
class HSChooserTableView: NSTableView {

    weak var extendedDelegate: HSChooserTableViewDelegate?
    var trackingArea: NSTrackingArea!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        trackingArea = NSTrackingArea(rect: frame,
                                      options: [.activeInKeyWindow, .mouseMoved],
                                      owner: self,
                                      userInfo: nil)
        addTrackingArea(trackingArea)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        trackingArea = NSTrackingArea(rect: frame,
                                      options: [.activeInKeyWindow, .mouseMoved],
                                      owner: self,
                                      userInfo: nil)
        addTrackingArea(trackingArea)
    }

    override func updateTrackingAreas() {
        removeTrackingArea(trackingArea)
        trackingArea = NSTrackingArea(rect: frame,
                                      options: [.mouseMoved, .activeInKeyWindow],
                                      owner: self,
                                      userInfo: nil)
        addTrackingArea(trackingArea)
    }

    override func mouseDown(with theEvent: NSEvent) {
        let globalLocation = theEvent.locationInWindow
        let localLocation = convert(globalLocation, from: nil)
        let clickedRow = row(at: localLocation)

        super.mouseDown(with: theEvent)

        if clickedRow != -1 {
            extendedDelegate?.tableView(self, didClickedRow: clickedRow)
        }
    }

    override func mouseMoved(with theEvent: NSEvent) {
        let globalLocation = theEvent.locationInWindow
        let localLocation = convert(globalLocation, from: nil)
        let row = row(at: localLocation)

        super.mouseMoved(with: theEvent)

        if row != -1 {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            scrollRowToVisible(row)
        }
    }

    override func rightMouseDown(with theEvent: NSEvent) {
        let globalLocation = theEvent.locationInWindow
        let localLocation = convert(globalLocation, from: nil)
        let row = row(at: localLocation)
        extendedDelegate?.didRightClick(atRow: row)
    }

    override var allowsVibrancy: Bool { false }
}
