//
//  NSImage+Rotated.swift
//  streamdeck
//
//  Created by Chris Jones on 25/11/2019.
//  Copyright © 2019 Cosmic Hammer. All rights reserved.
//

import Foundation
import Cocoa

extension NSImage {

    @objc func imageRotated(_ degrees: Int) -> NSImage {
        if degrees == 0 {
            return self
        }

        var adjustedDegrees = degrees % 360

        if fmod(Double(degrees), 90.0) != 0 {
            NSLog("This code has only been tested for multiples of 90 degrees. (TODO: test and remove this line)")
        }
        adjustedDegrees = Int(fmod(Double(degrees), 360.0))

        let size = self.size
        let maxSize: NSSize
        if adjustedDegrees == 90 || adjustedDegrees == 270 || adjustedDegrees == -90 || adjustedDegrees == -270 {
            maxSize = NSSize(width: size.height, height: size.width)
        } else if adjustedDegrees == 180 || adjustedDegrees == -180 {
            maxSize = size
        } else {
            let m = max(size.width, size.height)
            maxSize = NSSize(width: 20 + m, height: 20 + m)
        }

        let rot = NSAffineTransform()
        rot.rotate(byDegrees: CGFloat(adjustedDegrees))
        let center = NSAffineTransform()
        center.translateX(by: maxSize.width / 2.0, yBy: maxSize.height / 2.0)
        rot.append(center as AffineTransform)

        let image = NSImage(size: maxSize)
        image.lockFocus()
        rot.concat()
        let rect = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        let corner = NSPoint(x: -size.width / 2.0, y: -size.height / 2.0)
        self.draw(at: corner, from: rect, operation: .copy, fraction: 1.0)
        image.unlockFocus()

        return image
    }
}
