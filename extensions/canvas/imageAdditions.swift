import Cocoa
import LuaSkin

//
// NSImageView alignment, scale, and framing functions
//
// This file contains functions to replicate NSImageView functionality without actually
// forcing the image to be handled by a subview.
//
// Portions of this file are modified from code found in the GNUStep, project at https://github.com/gnustep/gui
// Primarily, but not necessarily limited to:
//    * Source/NSImageView.m
//    * Source/NSImageCell.m
//

private func xLeftInRect(_ innerSize: NSSize, _ outerRect: NSRect) -> CGFloat {
    return outerRect.minX
}

private func xCenterInRect(_ innerSize: NSSize, _ outerRect: NSRect) -> CGFloat {
    return outerRect.midX - (innerSize.width / 2.0)
}

private func xRightInRect(_ innerSize: NSSize, _ outerRect: NSRect) -> CGFloat {
    return outerRect.maxX - innerSize.width
}

private func yTopInRect(_ innerSize: NSSize, _ outerRect: NSRect, _ flipped: Bool) -> CGFloat {
    if flipped {
        return outerRect.minY
    } else {
        return outerRect.maxY - innerSize.height
    }
}

private func yCenterInRect(_ innerSize: NSSize, _ outerRect: NSRect, _ flipped: Bool) -> CGFloat {
    return outerRect.midY - innerSize.height / 2.0
}

private func yBottomInRect(_ innerSize: NSSize, _ outerRect: NSRect, _ flipped: Bool) -> CGFloat {
    if flipped {
        return outerRect.maxY - innerSize.height
    } else {
        return outerRect.minY
    }
}

private func scaleProportionally(_ imageSize: NSSize, _ canvasSize: NSSize, _ scaleUpOrDown: Bool) -> NSSize {
    var result = imageSize
    if result.width <= 0 || result.height <= 0 {
        return NSMakeSize(0, 0)
    }
    // Get the smaller ratio and scale the image size by it.
    let ratio = fmin(canvasSize.width / result.width, canvasSize.height / result.height)
    // Only scale down, unless scaleUpOrDown is true
    if ratio < 1.0 || scaleUpOrDown {
        result.width *= ratio
        result.height *= ratio
    }
    return result
}

// MARK: - HSCanvasView (imageAdditions)

extension HSCanvasView {

    func _scaleImage(withSize imageSize: NSSize, toFitInSize canvasSize: NSSize, scalingType: NSImageScaling) -> NSSize {
        let result: NSSize
        switch scalingType {
        case .scaleProportionallyDown: // == NSScaleProportionally
            result = scaleProportionally(imageSize, canvasSize, false)
        case .scaleAxesIndependently: // == NSScaleToFit
            result = canvasSize
        case .scaleProportionallyUpOrDown:
            result = scaleProportionally(imageSize, canvasSize, true)
        default: // .scaleNone == NSScaleNone
            result = imageSize
        }
        return result
    }

    func realRect(for theImage: NSImage, inFrame cellFrame: NSRect,
                  withScaling scaleStyle: NSImageScaling,
                  withAlignment alignmentStyle: NSImageAlignment) -> NSRect {
        var position = NSPoint.zero
        let isFlipped = self.isFlipped
        let imageSize = _scaleImage(withSize: theImage.size, toFitInSize: cellFrame.size, scalingType: scaleStyle)

        switch alignmentStyle {
        case .alignLeft:
            position.x = xLeftInRect(imageSize, cellFrame)
            position.y = yCenterInRect(imageSize, cellFrame, isFlipped)
        case .alignRight:
            position.x = xRightInRect(imageSize, cellFrame)
            position.y = yCenterInRect(imageSize, cellFrame, isFlipped)
        case .alignCenter:
            position.x = xCenterInRect(imageSize, cellFrame)
            position.y = yCenterInRect(imageSize, cellFrame, isFlipped)
        case .alignTop:
            position.x = xCenterInRect(imageSize, cellFrame)
            position.y = yTopInRect(imageSize, cellFrame, isFlipped)
        case .alignBottom:
            position.x = xCenterInRect(imageSize, cellFrame)
            position.y = yBottomInRect(imageSize, cellFrame, isFlipped)
        case .alignTopLeft:
            position.x = xLeftInRect(imageSize, cellFrame)
            position.y = yTopInRect(imageSize, cellFrame, isFlipped)
        case .alignTopRight:
            position.x = xRightInRect(imageSize, cellFrame)
            position.y = yTopInRect(imageSize, cellFrame, isFlipped)
        case .alignBottomLeft:
            position.x = xLeftInRect(imageSize, cellFrame)
            position.y = yBottomInRect(imageSize, cellFrame, isFlipped)
        case .alignBottomRight:
            position.x = xRightInRect(imageSize, cellFrame)
            position.y = yBottomInRect(imageSize, cellFrame, isFlipped)
        @unknown default:
            position.x = xLeftInRect(imageSize, cellFrame)
            position.y = yCenterInRect(imageSize, cellFrame, isFlipped)
        }

        return centerScanRect(NSMakeRect(position.x, position.y, imageSize.width, imageSize.height))
    }

    @objc func drawImage(_ theImage: NSImage, atIndex idx: UInt, inRect cellFrame: NSRect, operation compositeType: UInt) {
        // do nothing if cell's frame rect is zero
        if cellFrame.isEmpty { return }

        let alignmentString = getElementValue(for: "imageAlignment", atIndex: idx, onlyIfSet: false) as? String ?? "center"
        let alignment = NSImageAlignment((IMAGEALIGNMENT_TYPES[alignmentString] as? NSNumber)?.uintValue ?? 0)

        let scalingString = getElementValue(for: "imageScaling", atIndex: idx, onlyIfSet: false) as? String ?? "scaleProportionally"
        let scaling = NSImageScaling(rawValue: (IMAGESCALING_TYPES[scalingString] as? NSNumber)?.uintValue ?? 0) ?? .scaleNone

        let alpha: NSNumber
        if theImage.isTemplate {
            // approximates NSCell's drawing of a template image since drawInRect bypasses Apple's template handling
            alpha = (getElementValue(for: "imageAlpha", atIndex: idx, onlyIfSet: true) as? NSNumber) ?? NSNumber(value: 0.5)
        } else {
            alpha = (getElementValue(for: "imageAlpha", atIndex: idx) as? NSNumber) ?? NSNumber(value: 1.0)
        }

        // draw actual image
        let rect = realRect(for: theImage, inFrame: cellFrame, withScaling: scaling, withAlignment: alignment)

        let gc = NSGraphicsContext.current!
        gc.saveGraphicsState()
        NSBezierPath.clip(cellFrame)

        let realImageSize = theImage.size
        theImage.draw(in: rect,
                      from: NSMakeRect(0, 0, realImageSize.width, realImageSize.height),
                      operation: NSCompositingOperation(rawValue: UInt(compositeType)) ?? .sourceOver,
                      fraction: CGFloat(alpha.doubleValue),
                      respectFlipped: true,
                      hints: nil)

        gc.restoreGraphicsState()
    }
}

// MARK: - HSGifAnimator

@objc class HSGifAnimator: NSObject {
    @objc weak var animatingRepresentation: NSBitmapImageRep?
    @objc weak var inCanvas: HSCanvasView?
    @objc var isRunning: Bool = false

    @objc init(image: NSImage, forCanvas canvas: HSCanvasView) {
        self.inCanvas = canvas
        self.isRunning = false

        var foundRepresentation: NSBitmapImageRep? = nil
        for case let representation as NSBitmapImageRep in image.representations {
            if let maxFrames = representation.value(forProperty: .frameCount) as? NSNumber, maxFrames.intValue > 0 {
                foundRepresentation = representation
                break
            }
        }
        // if animatingRepresentation is nil, start and stop don't do anything, so this becomes a no-op
        self.animatingRepresentation = foundRepresentation

        super.init()
    }

    @objc func startAnimating() {
        guard let animatingRepresentation = animatingRepresentation else {
            isRunning = false
            return
        }

        if !isRunning {
            let frameDuration = (animatingRepresentation.value(forProperty: .currentFrameDuration) as? NSNumber) ?? NSNumber(value: 0.1)
            Timer.scheduledTimer(timeInterval: frameDuration.doubleValue,
                                target: self,
                                selector: #selector(animateFrame(_:)),
                                userInfo: nil,
                                repeats: false)
            isRunning = true
        }
    }

    @objc func stopAnimating() {
        if isRunning {
            isRunning = false
        }
    }

    @objc private func animateFrame(_ timer: Timer) {
        guard let animatingRepresentation = animatingRepresentation,
              let inCanvas = inCanvas else {
            isRunning = false
            return
        }

        guard let maxFrames = animatingRepresentation.value(forProperty: .frameCount) as? NSNumber,
              let curFrame = animatingRepresentation.value(forProperty: .currentFrame) as? NSNumber else {
            isRunning = false
            return
        }

        let newFrame = (curFrame.intValue + 1) % maxFrames.intValue
        animatingRepresentation.setProperty(.currentFrame, withValue: NSNumber(value: newFrame))
        inCanvas.needsDisplay = true

        if isRunning {
            isRunning = false
            startAnimating()
        }
    }
}
