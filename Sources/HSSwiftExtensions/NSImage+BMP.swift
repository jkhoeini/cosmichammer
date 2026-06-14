//
//  NSImage+BMP.swift
//  Cosmic Hammer
//
//  Created by Chris Jones on 07/09/2017.
//  Copyright © 2017 Cosmic Hammer. All rights reserved.
//
// Copyright 1997-2017 Omni Development, Inc. All rights reserved.
//
//  Omni Source License 2007
// OPEN PERMISSION TO USE AND REPRODUCE OMNI SOURCE CODE SOFTWARE
// Omni Source Code software is available from The Omni Group on their web site at http://www.omnigroup.com/
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
// Any original copyright notices and this permission notice shall be included in all copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

import Foundation
import Cocoa

extension NSImage {

    func imageRep(ofClass imageRepClass: AnyClass) -> NSImageRep? {
        for rep in representations {
            if rep.isKind(of: imageRepClass) {
                return rep
            }
        }
        return nil
    }

    func bmpData() -> Data {
        return bmpData(withBackgroundColor: nil)
    }

    func bmpData(withBackgroundColor backgroundColor: NSColor?) -> Data {
        let pixelsWide = Int(self.size.width)
        let pixelsHigh = Int(self.size.height)

        guard let bitmapImageRep = bmpCreateBitmapRep(pixelsWide: pixelsWide, pixelsHigh: pixelsHigh) else {
            return Data()
        }

        bmpRenderIntoBitmapRep(bitmapImageRep)

        assert(bitmapImageRep.pixelsWide < Int(Int32.max))
        assert(bitmapImageRep.pixelsHigh < Int(Int32.max))

        let width = UInt32(bitmapImageRep.pixelsWide)
        let height = UInt32(bitmapImageRep.pixelsHigh)
        guard let image = bitmapImageRep.bitmapData else { return Data() }
        let samplesPerPixel = UInt32(bitmapImageRep.samplesPerPixel)
        let extrabytes = (4 - (width * 3) % 4) % 4
        let bytesize = (width * 3 + extrabytes) * height

        var mutableBMPData = Data()
        bmpAppendFileHeader(&mutableBMPData)
        bmpAppendInfoHeader(&mutableBMPData, width: width, height: height, bytesize: bytesize)
        bmpAppendPixelData(&mutableBMPData, image: image, width: width, height: height,
                           samplesPerPixel: samplesPerPixel, extrabytes: extrabytes, bytesize: bytesize)

        return mutableBMPData
    }

    // MARK: - BMP private helpers

    private func bmpCreateBitmapRep(pixelsWide: Int, pixelsHigh: Int) -> NSBitmapImageRep? {
        return NSBitmapImageRep(
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
        )
    }

    private func bmpRenderIntoBitmapRep(_ bitmapImageRep: NSBitmapImageRep) {
        let ctx = NSGraphicsContext(bitmapImageRep: bitmapImageRep)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        self.draw(at: .zero, from: .zero, operation: .copy, fraction: 1.0)
        ctx?.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func bmpAppendFileHeader(_ data: inout Data) {
        // BMP structures — must be packed to 2-byte alignment.
        // BITMAPFILEHEADER (14 bytes): bfType (2), bfSize (4), bfReserved1 (2), bfReserved2 (2), bfOffBits (4)
        let bitmapFileHeaderSize: UInt32 = 14
        let bitmapInfoHeaderSize: UInt32 = 40

        var bfType = UInt16(19778).littleEndian
        var bfSize = UInt32(0).littleEndian
        var bfReserved1 = UInt16(0).littleEndian
        var bfReserved2 = UInt16(0).littleEndian
        var bfOffBits = (bitmapFileHeaderSize + bitmapInfoHeaderSize).littleEndian

        data.append(Data(bytes: &bfType, count: 2))
        data.append(Data(bytes: &bfSize, count: 4))
        data.append(Data(bytes: &bfReserved1, count: 2))
        data.append(Data(bytes: &bfReserved2, count: 2))
        data.append(Data(bytes: &bfOffBits, count: 4))
    }

    private func bmpAppendInfoHeader(_ data: inout Data, width: UInt32, height: UInt32, bytesize: UInt32) {
        // BITMAPINFOHEADER (40 bytes)
        let bitmapInfoHeaderSize: UInt32 = 40
        var biSize = bitmapInfoHeaderSize.littleEndian
        var biWidth = width.littleEndian
        var biHeight = height.littleEndian
        var biPlanes = UInt16(1).littleEndian
        var biBitCount = UInt16(24).littleEndian
        var biCompression = UInt32(0).littleEndian  // BI_RGB
        var biSizeImage = bytesize.littleEndian
        var biXPelsPerMeter = UInt32(0).littleEndian
        var biYPelsPerMeter = UInt32(0).littleEndian
        var biClrUsed = UInt32(0).littleEndian
        var biClrImportant = UInt32(0).littleEndian

        data.append(Data(bytes: &biSize, count: 4))
        data.append(Data(bytes: &biWidth, count: 4))
        data.append(Data(bytes: &biHeight, count: 4))
        data.append(Data(bytes: &biPlanes, count: 2))
        data.append(Data(bytes: &biBitCount, count: 2))
        data.append(Data(bytes: &biCompression, count: 4))
        data.append(Data(bytes: &biSizeImage, count: 4))
        data.append(Data(bytes: &biXPelsPerMeter, count: 4))
        data.append(Data(bytes: &biYPelsPerMeter, count: 4))
        data.append(Data(bytes: &biClrUsed, count: 4))
        data.append(Data(bytes: &biClrImportant, count: 4))
    }

    private func bmpAppendPixelData(_ data: inout Data, image: UnsafeMutablePointer<UInt8>,
                                     width: UInt32, height: UInt32, samplesPerPixel: UInt32,
                                     extrabytes: UInt32, bytesize: UInt32) {
        let paddedImage = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(bytesize))
        paddedImage.initialize(repeating: 0, count: Int(bytesize))

        // Flip vertically, pad rows, and swap RGB -> BGR
        for row in 0..<height {
            let imagePtr = image.advanced(by: Int((height - 1 - row) * width * samplesPerPixel))
            let paddedImagePtr = paddedImage.advanced(by: Int(row * (width * 3 + extrabytes)))
            for column in 0..<width {
                let srcOffset = Int(column * samplesPerPixel)
                let dstOffset = Int(column * 3)
                paddedImagePtr[dstOffset]     = imagePtr[srcOffset + 2] // B
                paddedImagePtr[dstOffset + 1] = imagePtr[srcOffset + 1] // G
                paddedImagePtr[dstOffset + 2] = imagePtr[srcOffset]     // R
            }
        }

        data.append(paddedImage, count: Int(bytesize))
        paddedImage.deallocate()
    }
}
