//
//  NSImage+Flipped.swift
//  streamdeck
//
//  Created by Chris Jones on 25/11/2019.
//  Copyright © 2019 Cosmic Hammer. All rights reserved.
//

import Cocoa

extension NSImage {

    @objc func flipImage(_ horiz: Bool, vert: Bool) -> NSImage {
        if !horiz && !vert { return self }

        let existingSize = self.size
        let newSize = NSSize(width: existingSize.width, height: existingSize.height)
        let flippedImage = NSImage(size: newSize)

        flippedImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high

        let t = NSAffineTransform()
        let xTrans: CGFloat = horiz ? existingSize.width : 0.0
        let yTrans: CGFloat = vert ? existingSize.height : 0.0
        let xScale: CGFloat = horiz ? -1.0 : 1.0
        let yScale: CGFloat = vert ? -1.0 : 1.0

        t.translateX(by: xTrans, yBy: yTrans)
        t.scaleX(by: xScale, yBy: yScale)
        t.concat()

        self.draw(
            at: .zero,
            from: NSRect(x: 0, y: 0, width: newSize.width, height: newSize.height),
            operation: .sourceOver,
            fraction: 1.0
        )

        flippedImage.unlockFocus()

        return flippedImage
    }
}
