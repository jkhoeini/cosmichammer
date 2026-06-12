//
//  NSImage+JPEG.swift
//  streamdeck
//
//  Created by Chris Jones on 28/11/2019.
//  Copyright © 2019 Cosmic Hammer. All rights reserved.
//

import Foundation
import Cocoa

extension NSImage {

    func jpegData() -> Data? {
        return jpegData(withCompressionFactor: 100.0)
    }

    func jpegData(withCompressionFactor compressionFactor: CGFloat) -> Data? {
        let pixelsWide = Int(self.size.width)
        let pixelsHigh = Int(self.size.height)

        guard let bitmapImageRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: pixelsWide * 4,
            bitsPerPixel: 32
        ) else {
            return nil
        }

        guard let ctx = NSGraphicsContext(bitmapImageRep: bitmapImageRep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx

        // Draw a black background
        NSColor.black.drawSwatch(in: NSRect(x: 0, y: 0, width: self.size.width, height: self.size.height))

        // Render our image into the bitmaprep
        self.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1.0)
        ctx.flushGraphics()

        NSGraphicsContext.restoreGraphicsState()

        let data = bitmapImageRep.representation(
            using: .jpeg,
            properties: [.compressionFactor: NSNumber(value: Double(compressionFactor))]
        )
        return data
    }
}
