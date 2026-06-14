import Cocoa
import CLua
import Lua
import os.log

private let kMaxCanvasRecursionDepth = 50

// MARK: - HSCanvasView

@objc class HSCanvasView: NSView {
    var selfRef: LuaValue?             // used during fadeOut to make sure collection doesn't interrupt
    var selfRefCount: Int32 = 0
    @objc var wrapperWindow: HSCanvasWindow?
    var mouseCallbackFn: LuaValue?
    var draggingCallbackFn: LuaValue?
    var generation: UInt64 = 0
    var mouseTracking: Bool = false
    var canvasMouseDown: Bool = false
    var canvasMouseUp: Bool = false
    var canvasMouseEnterExit: Bool = false
    var canvasMouseMove: Bool = false
    var previousTrackedIndex: UInt = UInt(NSNotFound)
    var canvasDefaults: NSMutableDictionary = NSMutableDictionary()
    var elementList: NSMutableArray = NSMutableArray()
    var elementBounds: NSMutableArray = NSMutableArray()
    var canvasTransform: NSAffineTransform = NSAffineTransform()
    var imageAnimations: NSMapTable<NSImage, HSGifAnimator> = NSMapTable<NSImage, HSGifAnimator>.weakToStrongObjects()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        selfRef = nil
        selfRefCount = 0
        wrapperWindow = nil

        mouseCallbackFn = nil
        draggingCallbackFn = nil
        canvasDefaults = NSMutableDictionary()
        elementList = NSMutableArray()
        elementBounds = NSMutableArray()
        canvasTransform = NSAffineTransform()
        imageAnimations = NSMapTable<NSImage, HSGifAnimator>.weakToStrongObjects()

        canvasMouseDown = false
        canvasMouseUp = false
        canvasMouseEnterExit = false
        canvasMouseMove = false

        mouseTracking = false
        previousTrackedIndex = UInt(NSNotFound)

        let trackingArea = NSTrackingArea(rect: frameRect,
                                          options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                          owner: self,
                                          userInfo: nil)
        addTrackingArea(trackingArea)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { return true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        guard let window = self.window else { return false }
        return !window.ignoresMouseEvents
    }

    override var canBecomeKeyView: Bool {
        for element in elementList {
            if let dict = element as? NSDictionary,
               let canvas = dict["canvas"] as? NSView,
               canvas.canBecomeKeyView {
                return true
            }
        }
        return false
    }

    // MARK: Mouse event handling

    override func mouseMoved(with theEvent: NSEvent) {
        let canvasMouseEvents = canvasMouseEnterExit || canvasMouseMove

        guard mouseCallbackFn != nil, mouseTracking || canvasMouseEvents else { return }

        let eventLocation = theEvent.locationInWindow
        let localPoint = convert(eventLocation, from: nil)

        let targetIndex = hitTestElementBounds(localPoint: localPoint)

        let realTargetIndex: UInt = (targetIndex != UInt(NSNotFound)) ?
            ((elementBounds[Int(targetIndex)] as! NSDictionary)["index"] as! NSNumber).uintValue : UInt(NSNotFound)
        let realPrevIndex: UInt = (previousTrackedIndex != UInt(NSNotFound)) ?
            ((elementBounds[Int(previousTrackedIndex)] as! NSDictionary)["index"] as! NSNumber).uintValue : UInt(NSNotFound)

        dispatchMouseMoveCallbacks(
            targetIndex: targetIndex, realTargetIndex: realTargetIndex,
            realPrevIndex: realPrevIndex, localPoint: localPoint,
            canvasMouseEvents: canvasMouseEvents)

        previousTrackedIndex = targetIndex
    }

    private func hitTestElementBounds(localPoint: NSPoint) -> UInt {
        for i in stride(from: elementBounds.count - 1, through: 0, by: -1) {
            guard let box = elementBounds[i] as? NSDictionary,
                  let elementIdx = (box["index"] as? NSNumber)?.uintValue else { continue }
            let trackEnterExit = (getElementValue(for: "trackMouseEnterExit", atIndex: elementIdx) as? NSNumber)?.boolValue ?? false
            let trackMove = (getElementValue(for: "trackMouseMove", atIndex: elementIdx) as? NSNumber)?.boolValue ?? false
            guard trackEnterExit || trackMove else { continue }

            let actualPoint = transformedPoint(localPoint, forElementAtIndex: elementIdx)

            if let imageByBounds = box["imageByBounds"] as? NSNumber, !imageByBounds.boolValue {
                if let theImage = (elementList[Int(elementIdx)] as? NSDictionary)?["image"] as? NSImage {
                    let hitRect = NSMakeRect(actualPoint.x, actualPoint.y, 1.0, 1.0)
                    let imageRect = (box["frame"] as! NSValue).rectValue
                    if theImage.hitTest(hitRect, withDestinationRect: imageRect, context: nil, hints: nil, flipped: true) {
                        return UInt(i)
                    }
                }
            } else if let frame = box["frame"] as? NSValue, NSPointInRect(actualPoint, frame.rectValue) {
                return UInt(i)
            } else if let path = box["path"] as? NSBezierPath, path.contains(actualPoint) {
                return UInt(i)
            }
        }
        return UInt(NSNotFound)
    }

    private func transformedPoint(_ localPoint: NSPoint, forElementAtIndex elementIdx: UInt) -> NSPoint {
        let pointTransform = canvasTransform.copy() as! NSAffineTransform
        if let elemTransform = getElementValue(for: "transformation", atIndex: elementIdx) as? NSAffineTransform {
            pointTransform.append(elemTransform as AffineTransform)
        }
        pointTransform.invert()
        let isView = (getElementValue(for: "type", atIndex: elementIdx) as? String) == "canvas"
        return isView ? localPoint : pointTransform.transform(localPoint)
    }

    private func dispatchMouseMoveCallbacks(targetIndex: UInt, realTargetIndex: UInt,
                                             realPrevIndex: UInt, localPoint: NSPoint,
                                             canvasMouseEvents: Bool) {
        if previousTrackedIndex == targetIndex {
            if targetIndex != UInt(NSNotFound),
               (getElementValue(for: "trackMouseMove", atIndex: realPrevIndex) as? NSNumber)?.boolValue ?? false {
                let targetID: Any = getElementValue(for: "id", atIndex: realPrevIndex, onlyIfSet: true) ?? NSNumber(value: realPrevIndex + 1)
                doMouseCallback("mouseMove", for: targetID, at: localPoint)
            }
        } else {
            if previousTrackedIndex != UInt(NSNotFound),
               (getElementValue(for: "trackMouseEnterExit", atIndex: realPrevIndex) as? NSNumber)?.boolValue ?? false {
                let targetID: Any = getElementValue(for: "id", atIndex: realPrevIndex, onlyIfSet: true) ?? NSNumber(value: realPrevIndex + 1)
                doMouseCallback("mouseExit", for: targetID, at: localPoint)
            }
            if targetIndex != UInt(NSNotFound) {
                let targetID: Any = getElementValue(for: "id", atIndex: realTargetIndex, onlyIfSet: true) ?? NSNumber(value: realTargetIndex + 1)
                if (getElementValue(for: "trackMouseEnterExit", atIndex: realTargetIndex) as? NSNumber)?.boolValue ?? false {
                    doMouseCallback("mouseEnter", for: targetID, at: localPoint)
                } else if (getElementValue(for: "trackMouseMove", atIndex: realTargetIndex) as? NSNumber)?.boolValue ?? false {
                    doMouseCallback("mouseMove", for: targetID, at: localPoint)
                }
                if canvasMouseEnterExit && previousTrackedIndex == UInt(NSNotFound) {
                    doMouseCallback("mouseExit", for: "_canvas_", at: localPoint)
                }
            }
        }

        if canvasMouseEvents && targetIndex == UInt(NSNotFound) {
            if previousTrackedIndex == UInt(NSNotFound) && canvasMouseMove {
                doMouseCallback("mouseMove", for: "_canvas_", at: localPoint)
            } else if previousTrackedIndex != UInt(NSNotFound) && canvasMouseEnterExit {
                doMouseCallback("mouseEnter", for: "_canvas_", at: localPoint)
            }
        }
    }

    override func mouseEntered(with theEvent: NSEvent) {
        if mouseCallbackFn != nil && canvasMouseEnterExit {
            let eventLocation = theEvent.locationInWindow
            let localPoint = convert(eventLocation, from: nil)
            doMouseCallback("mouseEnter", for: "_canvas_", at: localPoint)
        }
    }

    override func mouseExited(with theEvent: NSEvent) {
        let canvasMouseEvents = canvasMouseEnterExit || canvasMouseMove

        guard mouseCallbackFn != nil, mouseTracking || canvasMouseEvents else { return }

        let eventLocation = theEvent.locationInWindow
        let localPoint = convert(eventLocation, from: nil)
        if previousTrackedIndex != UInt(NSNotFound) {
            let realPrevIndex = ((elementBounds[Int(previousTrackedIndex)] as! NSDictionary)["index"] as! NSNumber).uintValue
            if (getElementValue(for: "trackMouseEnterExit", atIndex: realPrevIndex) as? NSNumber)?.boolValue ?? false {
                let targetID: Any = getElementValue(for: "id", atIndex: realPrevIndex, onlyIfSet: true) ?? NSNumber(value: realPrevIndex + 1)
                doMouseCallback("mouseExit", for: targetID, at: localPoint)
            }
        }
        if canvasMouseEnterExit {
            doMouseCallback("mouseExit", for: "_canvas_", at: localPoint)
        }
        previousTrackedIndex = UInt(NSNotFound)
    }

    func doMouseCallback(_ message: String, for elementIdentifier: Any, at location: NSPoint) {
        precondition(!message.isEmpty, "doMouseCallback: message must not be empty")
        guard let cb = mouseCallbackFn else { return }
        guard lua_isStateGenerationValid(generation) else { return }
        let L = lua_getCurrentState()!
        cb.push(onto: L)
        canvas_pushValue(L, self)
        canvas_pushValue(L, message as NSString)
        canvas_pushValue(L, elementIdentifier)
        L.push(lua_Number(location.x))
        L.push(lua_Number(location.y))
        if lua_pcall(L, 5, 0, 0) != LUA_OK { lua_pop(L, 1) }
    }

    func subviewCallback(_ sender: Any) {
        guard let cb = mouseCallbackFn else { return }
        guard lua_isStateGenerationValid(generation) else { return }
        let L = lua_getCurrentState()!
        cb.push(onto: L)
        canvas_pushValue(L, self)
        canvas_pushValue(L, "_subview_" as NSString)
        canvas_pushValue(L, sender as AnyObject)
        if lua_pcall(L, 3, 0, 0) != LUA_OK { lua_pop(L, 1) }
    }

    override func mouseDown(with theEvent: NSEvent) {
        NSApp.preventWindowOrdering()
        guard mouseCallbackFn != nil else { return }

        let isDown = (theEvent.type == .leftMouseDown)  ||
                     (theEvent.type == .rightMouseDown) ||
                     (theEvent.type == .otherMouseDown)

        let eventLocation = theEvent.locationInWindow
        let localPoint = convert(eventLocation, from: nil)

        var targetID: Any? = nil
        var actualPoint = localPoint

        for i in stride(from: elementBounds.count - 1, through: 0, by: -1) {
            guard let box = elementBounds[i] as? NSDictionary,
                  let elementIdx = (box["index"] as? NSNumber)?.uintValue else { continue }
            let trackKey = isDown ? "trackMouseDown" : "trackMouseUp"
            if (getElementValue(for: trackKey, atIndex: elementIdx) as? NSNumber)?.boolValue ?? false {
                let pointTransform = canvasTransform.copy() as! NSAffineTransform
                if let elemTransform = getElementValue(for: "transformation", atIndex: elementIdx) as? NSAffineTransform {
                    pointTransform.append(elemTransform as AffineTransform)
                }
                pointTransform.invert()
                let isView = (getElementValue(for: "type", atIndex: elementIdx) as? String) == "canvas"
                actualPoint = isView ? localPoint : pointTransform.transform(localPoint)

                var found = false
                if let imageByBounds = box["imageByBounds"] as? NSNumber, !imageByBounds.boolValue {
                    if let theImage = (elementList[Int(elementIdx)] as? NSDictionary)?["image"] as? NSImage {
                        let hitRect = NSMakeRect(actualPoint.x, actualPoint.y, 1.0, 1.0)
                        let imageRect = (box["frame"] as! NSValue).rectValue
                        if theImage.hitTest(hitRect, withDestinationRect: imageRect, context: nil, hints: nil, flipped: true) {
                            targetID = getElementValue(for: "id", atIndex: elementIdx, onlyIfSet: true) ?? NSNumber(value: elementIdx + 1)
                            found = true
                        }
                    }
                } else if let frame = box["frame"] as? NSValue, NSPointInRect(actualPoint, frame.rectValue) {
                    targetID = getElementValue(for: "id", atIndex: elementIdx, onlyIfSet: true) ?? NSNumber(value: elementIdx + 1)
                    found = true
                } else if let path = box["path"] as? NSBezierPath, path.contains(actualPoint) {
                    targetID = getElementValue(for: "id", atIndex: elementIdx, onlyIfSet: true) ?? NSNumber(value: elementIdx + 1)
                    found = true
                }

                if found {
                    if isDown, (getElementValue(for: "trackMouseDown", atIndex: elementIdx) as? NSNumber)?.boolValue ?? false {
                        doMouseCallback("mouseDown", for: targetID!, at: localPoint)
                    }
                    if !isDown, (getElementValue(for: "trackMouseUp", atIndex: elementIdx) as? NSNumber)?.boolValue ?? false {
                        doMouseCallback("mouseUp", for: targetID!, at: localPoint)
                    }
                    break
                }
            }
        }

        if targetID == nil {
            if isDown && canvasMouseDown {
                doMouseCallback("mouseDown", for: "_canvas_", at: localPoint)
            } else if !isDown && canvasMouseUp {
                doMouseCallback("mouseUp", for: "_canvas_", at: localPoint)
            }
        }
    }

    override func rightMouseDown(with theEvent: NSEvent) { mouseDown(with: theEvent) }
    override func otherMouseDown(with theEvent: NSEvent) { mouseDown(with: theEvent) }
    override func mouseUp(with theEvent: NSEvent)        { mouseDown(with: theEvent) }
    override func rightMouseUp(with theEvent: NSEvent)   { mouseDown(with: theEvent) }
    override func otherMouseUp(with theEvent: NSEvent)   { mouseDown(with: theEvent) }

    override func viewDidMoveToSuperview() {
        if self.superview == nil, let wrapperWindow = self.wrapperWindow {
            // stick us back into our wrapper window if we've been released from another canvas
            self.frame = wrapperWindow.contentView!.bounds
            wrapperWindow.contentView = self
        }
    }

    override func willRemoveSubview(_ subview: NSView) {
        var viewFound = false
        for element in elementList {
            if let dict = element as? NSMutableDictionary, (dict["canvas"] as? NSView) === subview {
                dict.removeObject(forKey: "canvas")
                viewFound = true
                break
            }
        }
        if !viewFound {
            os_log(.error, "%{public}s","view removed from canvas superview does not belong to any known canvas element")
        }
    }

    // MARK: - Path generation

    func pathForElement(atIndex idx: UInt) -> NSBezierPath? {
        let frame = getElementValue(for: "frame", atIndex: idx, resolvePercentages: true) as? NSDictionary
        let frameRect: NSRect
        if let frame = frame {
            frameRect = NSMakeRect((frame["x"] as? NSNumber)?.doubleValue ?? 0,
                                   (frame["y"] as? NSNumber)?.doubleValue ?? 0,
                                   (frame["w"] as? NSNumber)?.doubleValue ?? 0,
                                   (frame["h"] as? NSNumber)?.doubleValue ?? 0)
        } else {
            frameRect = .zero
        }
        return pathForElement(atIndex: idx, withFrame: frameRect)
    }

    func pathForElement(atIndex idx: UInt, withFrame frameRect: NSRect) -> NSBezierPath? {
        assert(idx < elementList.count, "pathForElement: index \(idx) out of bounds for elementList of count \(elementList.count)")
        let elementType = getElementValue(for: "type", atIndex: idx) as? String

        switch elementType {
        case "arc":            return pathForArc(atIndex: idx)
        case "circle":         return pathForCircle(atIndex: idx)
        case "ellipticalArc":  return pathForEllipticalArc(atIndex: idx, withFrame: frameRect)
        case "oval":           return pathForOval(withFrame: frameRect)
        case "rectangle":      return pathForRectangle(atIndex: idx, withFrame: frameRect)
        case "points":         return pathForPoints(atIndex: idx)
        case "segments":       return pathForSegments(atIndex: idx)
        default:               return nil
        }
    }

    private func pathForArc(atIndex idx: UInt) -> NSBezierPath {
        let center = getElementValue(for: "center", atIndex: idx, resolvePercentages: true) as? NSDictionary
        let cx = (center?["x"] as? NSNumber)?.doubleValue ?? 0
        let cy = (center?["y"] as? NSNumber)?.doubleValue ?? 0
        let r = (getElementValue(for: "radius", atIndex: idx, resolvePercentages: true) as? NSNumber)?.doubleValue ?? 0
        let myCenterPoint = NSMakePoint(CGFloat(cx), CGFloat(cy))
        let path = NSBezierPath()
        let startAngle = ((getElementValue(for: "startAngle", atIndex: idx) as? NSNumber)?.doubleValue ?? 0) - 90
        let endAngle = ((getElementValue(for: "endAngle", atIndex: idx) as? NSNumber)?.doubleValue ?? 0) - 90
        let arcDir = (getElementValue(for: "arcClockwise", atIndex: idx) as? NSNumber)?.boolValue ?? true
        let arcLegs = (getElementValue(for: "arcRadii", atIndex: idx) as? NSNumber)?.boolValue ?? true
        if arcLegs { path.move(to: myCenterPoint) }
        path.appendArc(withCenter: myCenterPoint,
                       radius: CGFloat(r),
                       startAngle: CGFloat(startAngle),
                       endAngle: CGFloat(endAngle),
                       clockwise: !arcDir) // because our canvas is flipped, we have to reverse this
        if arcLegs { path.line(to: myCenterPoint) }
        return path
    }

    private func pathForCircle(atIndex idx: UInt) -> NSBezierPath {
        let center = getElementValue(for: "center", atIndex: idx, resolvePercentages: true) as? NSDictionary
        let cx = (center?["x"] as? NSNumber)?.doubleValue ?? 0
        let cy = (center?["y"] as? NSNumber)?.doubleValue ?? 0
        let r = (getElementValue(for: "radius", atIndex: idx, resolvePercentages: true) as? NSNumber)?.doubleValue ?? 0
        let path = NSBezierPath()
        path.appendOval(in: NSMakeRect(CGFloat(cx - r), CGFloat(cy - r), CGFloat(r * 2), CGFloat(r * 2)))
        return path
    }

    private func pathForEllipticalArc(atIndex idx: UInt, withFrame frameRect: NSRect) -> NSBezierPath {
        let cx = frameRect.origin.x + frameRect.size.width / 2
        let cy = frameRect.origin.y + frameRect.size.height / 2
        let r = frameRect.size.width / 2

        let moveTransform = NSAffineTransform()
        moveTransform.translateX(by: cx, yBy: cy)
        let scaleTransform = NSAffineTransform()
        scaleTransform.scaleX(by: 1.0, yBy: frameRect.size.height / frameRect.size.width)
        let finalTransform = NSAffineTransform(transform: scaleTransform as AffineTransform)
        finalTransform.append(moveTransform as AffineTransform)
        let path = NSBezierPath()
        let startAngle = ((getElementValue(for: "startAngle", atIndex: idx) as? NSNumber)?.doubleValue ?? 0) - 90
        let endAngle = ((getElementValue(for: "endAngle", atIndex: idx) as? NSNumber)?.doubleValue ?? 0) - 90
        let arcDir = (getElementValue(for: "arcClockwise", atIndex: idx) as? NSNumber)?.boolValue ?? true
        let arcLegs = (getElementValue(for: "arcRadii", atIndex: idx) as? NSNumber)?.boolValue ?? true
        if arcLegs { path.move(to: .zero) }
        path.appendArc(withCenter: .zero, radius: r,
                       startAngle: CGFloat(startAngle),
                       endAngle: CGFloat(endAngle),
                       clockwise: !arcDir)
        if arcLegs { path.line(to: .zero) }
        return finalTransform.transform(path)
    }

    private func pathForOval(withFrame frameRect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        path.appendOval(in: frameRect)
        return path
    }

    private func pathForRectangle(atIndex idx: UInt, withFrame frameRect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        let roundedRect = getElementValue(for: "roundedRectRadii", atIndex: idx) as? NSDictionary
        path.appendRoundedRect(frameRect,
                               xRadius: CGFloat((roundedRect?["xRadius"] as? NSNumber)?.doubleValue ?? 0),
                               yRadius: CGFloat((roundedRect?["yRadius"] as? NSNumber)?.doubleValue ?? 0))
        return path
    }

    private func pathForPoints(atIndex idx: UInt) -> NSBezierPath {
        let path = NSBezierPath()
        let coordinates = getElementValue(for: "coordinates", atIndex: idx, resolvePercentages: true) as? [NSDictionary] ?? []
        for aPoint in coordinates {
            let x = (aPoint["x"] as? NSNumber)?.doubleValue ?? 0
            let y = (aPoint["y"] as? NSNumber)?.doubleValue ?? 0
            path.appendRect(NSMakeRect(CGFloat(x), CGFloat(y), 1.0, 1.0))
        }
        return path
    }

    private func pathForSegments(atIndex idx: UInt) -> NSBezierPath {
        let path = NSBezierPath()
        let coordinates = getElementValue(for: "coordinates", atIndex: idx, resolvePercentages: true) as? [NSDictionary] ?? []
        for (idx2, aPoint) in coordinates.enumerated() {
            let x = (aPoint["x"] as? NSNumber)?.doubleValue ?? 0
            let y = (aPoint["y"] as? NSNumber)?.doubleValue ?? 0
            let c1x = aPoint["c1x"] as? NSNumber
            let c1y = aPoint["c1y"] as? NSNumber
            let c2x = aPoint["c2x"] as? NSNumber
            let c2y = aPoint["c2y"] as? NSNumber
            let goodForCurve = (c1x != nil) && (c1y != nil) && (c2x != nil) && (c2y != nil)
            if idx2 == 0 {
                path.move(to: NSMakePoint(CGFloat(x), CGFloat(y)))
            } else if !goodForCurve {
                path.line(to: NSMakePoint(CGFloat(x), CGFloat(y)))
            } else {
                path.curve(to: NSMakePoint(CGFloat(x), CGFloat(y)),
                           controlPoint1: NSMakePoint(CGFloat(c1x!.doubleValue), CGFloat(c1y!.doubleValue)),
                           controlPoint2: NSMakePoint(CGFloat(c2x!.doubleValue), CGFloat(c2y!.doubleValue)))
            }
        }
        if (getElementValue(for: "closed", atIndex: idx) as? NSNumber)?.boolValue ?? false {
            path.close()
        }
        return path
    }

    // MARK: - massageKeyValue / getDefaultValue / setDefault / getElementValue / setElementValue

    func massageKeyValue(_ oldValue: Any!, forKey keyName: String, withState L: UnsafeMutablePointer<lua_State>!, depth: Int = 0) -> Any! {
        precondition(!keyName.isEmpty, "massageKeyValue: keyName must not be empty")

        if depth >= kMaxCanvasRecursionDepth {
            os_log(.error, "massageKeyValue: recursion depth limit (%d) reached, returning original value", kMaxCanvasRecursionDepth)
            return oldValue
        }

        var newValue: Any! = oldValue

        // fix "...Color" tables
        if keyName.hasSuffix("Color") {
            if let color = canvas_colorFromValue(oldValue) {
                newValue = color
            }

        // fillGradientColors is an array of colors
        } else if keyName == "fillGradientColors" {
            let result = NSMutableArray()
            if let oldArray = canvas_gradientColorsFromValue(oldValue) {
                oldArray.enumerateObjects { (anItem, idx, _) in
                    let item = anItem
                    if let color = item as? NSColor, color.usingColorSpace(.genericRGB) != nil {
                        result.add(color)
                    } else {
                        os_log(.default, "%{public}s","\(canvas_USERDATA_TAG):not a proper color at index \(idx + 1) of fillGradientColor; using Black")
                        result.add(NSColor.black)
                    }
                }
            }
            if result.count < 2 {
                os_log(.default, "%{public}s","\(canvas_USERDATA_TAG):fillGradientColor requires at least 2 colors; using default")
                newValue = getDefaultValue(for: keyName, onlyIfSet: false)
            } else {
                newValue = result
            }

        // fix NSAffineTransform table
        } else if keyName == "transformation" {
            if let transform = canvas_transformFromValue(oldValue) {
                newValue = transform
            }

        // fix NSShadow table
        } else if keyName == "shadow" {
            if let shadow = canvas_shadowFromValue(oldValue) {
                newValue = shadow
            }

        // fix hs.styledText as Table
        } else if keyName == "text", oldValue is NSArray {
            if let text = canvas_styledTextFromValue(oldValue) {
                newValue = text
            }

        // recurse into fields which have subfields
        } else if let dict = oldValue as? NSDictionary {
            let blockValue = NSMutableDictionary()
            dict.enumerateKeysAndObjects { (blockKeyName, valueForKey, _) in
                blockValue.setObject(self.massageKeyValue(valueForKey, forKey: blockKeyName as! String, withState: L, depth: depth + 1) as Any, forKey: blockKeyName as! NSCopying)
            }
            newValue = blockValue
        }

        return newValue
    }

    func getDefaultValue(for keyName: String, onlyIfSet: Bool) -> Any? {
        precondition(!keyName.isEmpty, "getDefaultValue: keyName must not be empty")
        guard let attributeDefinition = canvas_languageDictionary[keyName] as? NSDictionary else { return nil }
        var result: Any?
        if attributeDefinition["default"] == nil {
            return nil
        } else if let canvasDefault = canvasDefaults[keyName] {
            result = canvasDefault
        } else if !onlyIfSet {
            result = attributeDefinition["default"]
        } else {
            result = nil
        }

        if let mutableCopyable = result as? NSMutableCopying {
            result = mutableCopyable.mutableCopy(with: nil)
        } else if let copyable = result as? NSCopying {
            result = copyable.copy(with: nil)
        }
        return result
    }

    func setDefault(for keyName: String, to keyValue: Any!, withState L: UnsafeMutablePointer<lua_State>!) -> Int {
        precondition(!keyName.isEmpty, "setDefault: keyName must not be empty")
        var validityStatus: AttributeValidity = .invalid
        guard let langEntry = canvas_languageDictionary[keyName] as? NSDictionary,
              (langEntry["nullable"] as? NSNumber)?.boolValue == true else {
            self.needsDisplay = true
            return validityStatus.rawValue
        }
        let massaged = massageKeyValue(keyValue, forKey: keyName, withState: L)
        validityStatus = canvas_isValueValidForAttribute(keyName as NSString, massaged)
        switch validityStatus {
        case .valid:
            canvasDefaults[keyName] = massaged
        case .nulling:
            canvasDefaults.removeObject(forKey: keyName)
        case .invalid:
            break
        }
        self.needsDisplay = true
        return validityStatus.rawValue
    }

    func getElementValue(for keyName: String, atIndex index: UInt) -> Any? {
        return getElementValue(for: keyName, atIndex: index, resolvePercentages: false, onlyIfSet: false)
    }

    func getElementValue(for keyName: String, atIndex index: UInt, onlyIfSet: Bool) -> Any? {
        return getElementValue(for: keyName, atIndex: index, resolvePercentages: false, onlyIfSet: onlyIfSet)
    }

    func getElementValue(for keyName: String, atIndex index: UInt, resolvePercentages: Bool) -> Any? {
        return getElementValue(for: keyName, atIndex: index, resolvePercentages: resolvePercentages, onlyIfSet: false)
    }

    func getElementValue(for keyName: String, atIndex index: UInt, resolvePercentages: Bool, onlyIfSet: Bool) -> Any? {
        guard index < elementList.count else { return nil }
        let elementAttributes = elementList[Int(index)] as! NSDictionary
        var foundObject: Any? = elementAttributes[keyName] ?? (onlyIfSet ? nil : getDefaultValue(for: keyName, onlyIfSet: false))

        if let mutableCopyable = foundObject as? NSMutableCopying {
            foundObject = mutableCopyable.mutableCopy(with: nil)
        } else if let copyable = foundObject as? NSCopying {
            foundObject = copyable.copy(with: nil)
        }

        if keyName == "imageAnimationFrame" {
            foundObject = currentAnimationFrame(atIndex: index) ?? foundObject
        }

        if foundObject != nil && resolvePercentages {
            foundObject = resolvePercentageValues(foundObject, forKey: keyName, atIndex: index)
        }

        return foundObject
    }

    private func currentAnimationFrame(atIndex index: UInt) -> Any? {
        guard let theImage = (elementList[Int(index)] as? NSDictionary)?["image"] as? NSImage else { return nil }
        for case let representation as NSBitmapImageRep in theImage.representations {
            if let currentFrame = representation.value(forProperty: .currentFrame) {
                return currentFrame
            }
        }
        return nil
    }

    private func resolvePercentageValues(_ foundObject: Any?, forKey keyName: String, atIndex index: UInt) -> Any? {
        let padding = (getElementValue(for: "padding", atIndex: index) as? NSNumber)?.doubleValue ?? 0.0
        let paddedWidth = Double(self.frame.size.width) - padding * 2
        let paddedHeight = Double(self.frame.size.height) - padding * 2

        if keyName == "radius" {
            return resolveRadiusPercentage(foundObject, paddedWidth: paddedWidth)
        } else if keyName == "center" {
            resolveDictPercentageFields(foundObject as? NSMutableDictionary,
                                        fields: [("x", paddedWidth, true), ("y", paddedHeight, true)], padding: padding)
        } else if keyName == "frame" {
            resolveDictPercentageFields(foundObject as? NSMutableDictionary,
                                        fields: [("x", paddedWidth, true), ("y", paddedHeight, true),
                                                 ("w", paddedWidth, false), ("h", paddedHeight, false)], padding: padding)
        } else if keyName == "coordinates" {
            return resolveCoordinatesPercentages(foundObject, padding: padding,
                                                  paddedWidth: paddedWidth, paddedHeight: paddedHeight)
        }
        return foundObject
    }

    private func resolveRadiusPercentage(_ foundObject: Any?, paddedWidth: Double) -> Any? {
        if let stringVal = foundObject as? String,
           let percentage = canvas_convertPercentageStringToNumber(stringVal) {
            return NSNumber(value: percentage.doubleValue * paddedWidth)
        }
        return foundObject
    }

    private func resolveDictPercentageFields(_ dict: NSMutableDictionary?,
                                              fields: [(String, Double, Bool)], padding: Double) {
        guard let dict = dict else { return }
        for (field, dimension, addPadding) in fields {
            if let str = dict[field] as? String, let pct = canvas_convertPercentageStringToNumber(str) {
                dict[field] = NSNumber(value: (addPadding ? padding : 0) + pct.doubleValue * dimension)
            }
        }
    }

    private func resolveCoordinatesPercentages(_ foundObject: Any?, padding: Double,
                                                paddedWidth: Double, paddedHeight: Double) -> Any? {
        let ourCopy = NSMutableArray()
        if let coords = foundObject as? NSMutableArray {
            coords.enumerateObjects { (subItem, idx, _) in
                let targetItem = NSMutableDictionary()
                if let subDict = subItem as? NSMutableDictionary {
                    for field in ["x", "y", "c1x", "c1y", "c2x", "c2y"] {
                        if let strVal = subDict[field] as? String {
                            if let pct = canvas_convertPercentageStringToNumber(strVal) {
                                let ourPadding = field.hasSuffix("x") ? paddedWidth : paddedHeight
                                targetItem[field] = NSNumber(value: padding + pct.doubleValue * ourPadding)
                            }
                        } else {
                            targetItem[field] = subDict[field]
                        }
                    }
                }
                ourCopy[idx] = targetItem
            }
        }
        return ourCopy
    }

    func setElementValue(for keyName: String, atIndex index: UInt, to keyValue: Any!, withState L: UnsafeMutablePointer<lua_State>!) -> Int {
        precondition(!keyName.isEmpty, "setElementValue: keyName must not be empty")
        guard index < elementList.count else { return AttributeValidity.invalid.rawValue }
        let massaged = massageKeyValue(keyValue, forKey: keyName, withState: L)
        var validityStatus = canvas_isValueValidForAttribute(keyName as NSString, massaged)

        switch validityStatus {
        case .valid:
            validityStatus = handleValidValue(for: keyName, atIndex: index, massaged: massaged, withState: L)
        case .nulling:
            validityStatus = handleNullingValue(for: keyName, atIndex: index)
        case .invalid:
            break
        }

        self.needsDisplay = true
        return validityStatus.rawValue
    }

    private func handleValidValue(for keyName: String, atIndex index: UInt, massaged: Any?, withState L: UnsafeMutablePointer<lua_State>!) -> AttributeValidity {
        if !validatePercentageStrings(for: keyName, atIndex: index, massaged: massaged) {
            return .invalid
        }

        if keyName == "canvas" {
            if let status = handleCanvasViewAssignment(atIndex: index, massaged: massaged) { return status }
        } else if keyName == "imageAnimationFrame" {
            if let status = handleSetAnimationFrame(atIndex: index, keyName: keyName, massaged: massaged) { return status }
        } else if keyName == "imageAnimates" {
            handleSetImageAnimates(atIndex: index, massaged: massaged)
        } else if keyName == "image" {
            handleSetImage(atIndex: index, massaged: massaged)
        }

        if keyName != "imageAnimationFrame" {
            (elementList[Int(index)] as! NSMutableDictionary)[keyName] = massaged
        }
        if keyName == "type" {
            populateRequiredDefaults(for: massaged as! String, atIndex: index, withState: L)
        }
        return .valid
    }

    private func validatePercentageStrings(for keyName: String, atIndex index: UInt, massaged: Any?) -> Bool {
        if keyName == "radius", let strVal = massaged as? String {
            if canvas_convertPercentageStringToNumber(strVal) == nil {
                os_log(.error, "%{public}s","\(canvas_USERDATA_TAG):invalid percentage string specified for \(keyName) for element \(index + 1)")
                return false
            }
        } else if keyName == "center", let dict = massaged as? NSDictionary {
            if !validateDictPercentageFields(dict, fields: ["x", "y"], keyName: keyName, index: index) { return false }
        } else if keyName == "frame", let dict = massaged as? NSDictionary {
            if !validateDictPercentageFields(dict, fields: ["x", "y", "w", "h"], keyName: keyName, index: index) { return false }
        } else if keyName == "coordinates", let arr = massaged as? NSMutableArray {
            if !validateCoordinatesPercentages(arr, keyName: keyName, index: index) { return false }
        }
        return true
    }

    private func validateDictPercentageFields(_ dict: NSDictionary, fields: [String], keyName: String, index: UInt) -> Bool {
        for field in fields {
            if let str = dict[field] as? String, canvas_convertPercentageStringToNumber(str) == nil {
                os_log(.error, "%{public}s","\(canvas_USERDATA_TAG):invalid percentage string specified for field \(field) of \(keyName) for element \(index + 1)")
                return false
            }
        }
        return true
    }

    private func validateCoordinatesPercentages(_ arr: NSMutableArray, keyName: String, index: UInt) -> Bool {
        var isValid = true
        arr.enumerateObjects { (subItem, idx, stop) in
            if let subDict = subItem as? NSMutableDictionary {
                var seenFields = Set<String>()
                for field in ["x", "y", "c1x", "c1y", "c2x", "c2y"] {
                    if subDict[field] != nil {
                        seenFields.insert(field)
                        if let str = subDict[field] as? String, canvas_convertPercentageStringToNumber(str) == nil {
                            os_log(.error, "%{public}s","\(canvas_USERDATA_TAG):invalid percentage string specified for field \(field) at index \(idx + 1) of \(keyName) for element \(index + 1)")
                            isValid = false
                            stop.pointee = true
                            return
                        }
                    }
                }
                let goodForPoint = seenFields.contains("x") && seenFields.contains("y")
                let goodForCurve = goodForPoint && seenFields.contains("c1x") && seenFields.contains("c1y") && seenFields.contains("c2x") && seenFields.contains("c2y")
                let partialCurve = (seenFields.contains("c1x") || seenFields.contains("c1y") || seenFields.contains("c2x") || seenFields.contains("c2y")) && !goodForCurve
                if !goodForPoint {
                    os_log(.error, "%{public}s","\(canvas_USERDATA_TAG):index \(idx + 1) of \(keyName) for element \(index + 1) does not specify a valid point or curve with control points")
                    isValid = false
                } else if goodForPoint && partialCurve {
                    os_log(.default, "%{public}s","\(canvas_USERDATA_TAG):index \(idx + 1) of \(keyName) for element \(index + 1) does not contain complete curve control points; treating as a singular point")
                }
            }
        }
        return isValid
    }

    private func handleCanvasViewAssignment(atIndex index: UInt, massaged: Any?) -> AttributeValidity? {
        guard let newView = massaged as? NSView else { return nil }
        let oldView = (elementList[Int(index)] as? NSMutableDictionary)?["canvas"] as? NSView
        guard newView != oldView else { return nil }

        if !newView.isDescendant(of: self) && (newView.window == nil || !(newView.window?.isVisible ?? false)) {
            oldView?.removeFromSuperview()
            self.addSubview(newView)
            return nil
        } else {
            os_log(.default, "%{public}s","\(canvas_USERDATA_TAG):view for element \(index + 1) is already in use")
            return .invalid
        }
    }

    private func handleSetAnimationFrame(atIndex index: UInt, keyName: String, massaged: Any?) -> AttributeValidity? {
        if (getElementValue(for: "imageAnimates", atIndex: index) as? NSNumber)?.boolValue == true {
            os_log(.default, "%{public}s","\(canvas_USERDATA_TAG):\(keyName) cannot be changed when element \(index + 1) is animating")
            return .invalid
        }
        if let theImage = (elementList[Int(index)] as? NSDictionary)?["image"] as? NSImage {
            for case let rep as NSBitmapImageRep in theImage.representations {
                if let maxFrames = rep.value(forProperty: .frameCount) as? NSNumber {
                    var newFrame = (massaged as? NSNumber)?.intValue ?? 0
                    newFrame = newFrame % maxFrames.intValue
                    // TigerStyle: bounded loop — guard against pathological modulo edge cases
                    var frameFixIter = 0
                    while newFrame < 0 {
                        newFrame = maxFrames.intValue + newFrame
                        frameFixIter += 1
                        if frameFixIter >= maxFrames.intValue {
                            os_log(.error, "%{public}s: animation frame normalization exceeded maxFrames (%d) iterations — breaking", canvas_USERDATA_TAG, maxFrames.intValue)
                            newFrame = 0
                            break
                        }
                    }
                    rep.setProperty(.currentFrame, withValue: NSNumber(value: newFrame))
                    break
                }
            }
        }
        return nil
    }

    private func handleSetImageAnimates(atIndex index: UInt, massaged: Any?) {
        guard let currentImage = (elementList[Int(index)] as? NSDictionary)?["image"] as? NSImage else { return }
        let shouldAnimate = (massaged as? NSNumber)?.boolValue ?? false
        var animator = imageAnimations.object(forKey: currentImage)
        if shouldAnimate {
            if animator == nil {
                animator = HSGifAnimator(image: currentImage, forCanvas: self)
                if let a = animator { imageAnimations.setObject(a, forKey: currentImage) }
            }
            animator?.startAnimating()
        } else {
            animator?.stopAnimating()
        }
    }

    private func handleSetImage(atIndex index: UInt, massaged: Any?) {
        if let currentImage = (elementList[Int(index)] as? NSDictionary)?["image"] as? NSImage {
            if let animator = imageAnimations.object(forKey: currentImage) {
                animator.stopAnimating()
                imageAnimations.removeObject(forKey: currentImage)
            }
        }
        let shouldAnimate = (getElementValue(for: "imageAnimates", atIndex: index) as? NSNumber)?.boolValue ?? false
        if shouldAnimate, let newImage = massaged as? NSImage {
            let animator = HSGifAnimator(image: newImage, forCanvas: self)
            imageAnimations.setObject(animator, forKey: newImage)
            animator.startAnimating()
        }
    }

    private func populateRequiredDefaults(for typeName: String, atIndex index: UInt, withState L: UnsafeMutablePointer<lua_State>!) {
        let requiredKeys = (canvas_languageDictionary as! [String: NSDictionary]).filter { (key, typeDefinition) in
            key != "type" && (typeDefinition["requiredFor"] as? [String])?.contains(typeName) == true
        }.map { $0.key }
        let elemDict = elementList[Int(index)] as! NSMutableDictionary
        for additionalKey in requiredKeys {
            if elemDict[additionalKey] == nil {
                _ = setElementValue(for: additionalKey, atIndex: index, to: getDefaultValue(for: additionalKey, onlyIfSet: false), withState: L)
            }
        }
    }

    private func handleNullingValue(for keyName: String, atIndex index: UInt) -> AttributeValidity {
        if keyName == "canvas" {
            if let oldView = (elementList[Int(index)] as? NSMutableDictionary)?[keyName] as? NSView {
                oldView.removeFromSuperview()
            }
        } else if keyName == "imageAnimationFrame" {
            if let status = handleNullAnimationFrame(atIndex: index, keyName: keyName) { return status }
        } else if keyName == "imageAnimates" {
            handleNullImageAnimates(atIndex: index)
        } else if keyName == "image" {
            stopAndRemoveImageAnimator(atIndex: index)
        }
        (elementList[Int(index)] as! NSMutableDictionary).removeObject(forKey: keyName)
        return .nulling
    }

    private func handleNullAnimationFrame(atIndex index: UInt, keyName: String) -> AttributeValidity? {
        if (getElementValue(for: "imageAnimates", atIndex: index) as? NSNumber)?.boolValue == true {
            os_log(.default, "%{public}s","\(canvas_USERDATA_TAG):\(keyName) cannot be changed when element \(index + 1) is animating")
            return .invalid
        }
        if let theImage = (elementList[Int(index)] as? NSDictionary)?["image"] as? NSImage {
            let imageFrame = getDefaultValue(for: "imageAnimationFrame", onlyIfSet: false) as? NSNumber
            for case let rep as NSBitmapImageRep in theImage.representations {
                if let maxFrames = rep.value(forProperty: .frameCount) as? NSNumber {
                    let newFrame = (imageFrame?.intValue ?? 0) % maxFrames.intValue
                    rep.setProperty(.currentFrame, withValue: NSNumber(value: newFrame))
                    break
                }
            }
        }
        return nil
    }

    private func handleNullImageAnimates(atIndex index: UInt) {
        guard let currentImage = (elementList[Int(index)] as? NSDictionary)?["image"] as? NSImage else { return }
        let shouldAnimate = (getDefaultValue(for: "imageAnimates", onlyIfSet: false) as? NSNumber)?.boolValue ?? false
        var animator = imageAnimations.object(forKey: currentImage)
        if shouldAnimate {
            if animator == nil {
                animator = HSGifAnimator(image: currentImage, forCanvas: self)
                if let a = animator { imageAnimations.setObject(a, forKey: currentImage) }
            }
            animator?.startAnimating()
        } else {
            animator?.stopAnimating()
        }
    }

    private func stopAndRemoveImageAnimator(atIndex index: UInt) {
        guard let currentImage = (elementList[Int(index)] as? NSDictionary)?["image"] as? NSImage else { return }
        if let animator = imageAnimations.object(forKey: currentImage) {
            animator.stopAnimating()
            imageAnimations.removeObject(forKey: currentImage)
        }
    }

    // MARK: - drawRect

    override func draw(_ rect: NSRect) {
        let gc = NSGraphicsContext.current!
        gc.saveGraphicsState()
        canvasTransform.concat()

        applyDrawingDefaults(gc: gc)
        let CS = getDefaultValue(for: "compositeRule", onlyIfSet: false) as? String ?? "sourceOver"
        gc.compositingOperation = NSCompositingOperation(rawValue: COMPOSITING_TYPES[CS]?.uintValue ?? 2) ?? .sourceOver
        (getDefaultValue(for: "fillColor", onlyIfSet: false) as? NSColor)?.setFill()
        (getDefaultValue(for: "strokeColor", onlyIfSet: false) as? NSColor)?.setStroke()

        // because of changes to the elements, skip actions, etc, previous tracking info may change...
        var previousTrackedRealIndex: UInt = UInt.max
        if previousTrackedIndex != UInt(NSNotFound) {
            previousTrackedRealIndex = (elementBounds[Int(previousTrackedIndex)] as! NSDictionary)["index"] as! UInt
            previousTrackedIndex = UInt(NSNotFound)
        }
        elementBounds = NSMutableArray()

        var renderPath: NSBezierPath? = nil
        var clippingModified = false
        var needMouseTracking = false

        elementList.enumerateObjects { (element, idx, _) in
            let elementDict = element as! NSDictionary
            let elementType = elementDict["type"] as? String ?? ""
            let action = self.getElementValue(for: "action", atIndex: UInt(idx)) as? String ?? "strokeAndFill"

            guard action != "skip" else {
                self.hideSkippedCanvasView(elementType: elementType, atIndex: UInt(idx))
                return
            }

            if !needMouseTracking {
                needMouseTracking = self.elementNeedsMouseTracking(atIndex: UInt(idx))
            }

            var wasClippingChanged = false
            gc.saveGraphicsState()
            self.applyElementOverrides(gc: gc, atIndex: UInt(idx))

            let frameRect = self.frameRectForElement(atIndex: UInt(idx))
            let elementPath = self.pathForElement(atIndex: UInt(idx), withFrame: frameRect)

            if elementPath == nil {
                wasClippingChanged = self.drawNonPathElement(
                    elementType: elementType, atIndex: idx, frameRect: frameRect,
                    compositeRule: CS, gc: gc, clippingModified: &clippingModified)
            }

            if let path = elementPath {
                let currentPath = self.preparePathForRendering(path, atIndex: UInt(idx))
                if renderPath != nil { renderPath!.append(currentPath) } else { renderPath = currentPath }

                wasClippingChanged = self.executeRenderAction(
                    action: action, elementType: elementType, atIndex: UInt(idx),
                    renderPath: &renderPath, gc: gc, clippingModified: &clippingModified,
                    wasClippingChanged: wasClippingChanged)
            }

            if !wasClippingChanged { gc.restoreGraphicsState() }
            if UInt(idx) == previousTrackedRealIndex {
                self.previousTrackedIndex = UInt(self.elementBounds.count - 1)
            }
        }

        if clippingModified { gc.restoreGraphicsState() }
        mouseTracking = needMouseTracking
        gc.restoreGraphicsState()
    }

    private func applyDrawingDefaults(gc: NSGraphicsContext) {
        NSBezierPath.defaultLineWidth = (getDefaultValue(for: "strokeWidth", onlyIfSet: false) as? NSNumber)?.doubleValue ?? 1.0
        NSBezierPath.defaultMiterLimit = (getDefaultValue(for: "miterLimit", onlyIfSet: false) as? NSNumber)?.doubleValue ?? 10.0
        NSBezierPath.defaultFlatness = (getDefaultValue(for: "flatness", onlyIfSet: false) as? NSNumber)?.doubleValue ?? 0.6
        if let ljs = getDefaultValue(for: "strokeJoinStyle", onlyIfSet: false) as? String {
            NSBezierPath.defaultLineJoinStyle = NSBezierPath.LineJoinStyle(rawValue: STROKE_JOIN_STYLES[ljs]?.uintValue ?? 0) ?? .miter
        }
        if let lcs = getDefaultValue(for: "strokeCapStyle", onlyIfSet: false) as? String {
            NSBezierPath.defaultLineCapStyle = NSBezierPath.LineCapStyle(rawValue: STROKE_CAP_STYLES[lcs]?.uintValue ?? 0) ?? .butt
        }
        if let wr = getDefaultValue(for: "windingRule", onlyIfSet: false) as? String {
            NSBezierPath.defaultWindingRule = NSBezierPath.WindingRule(rawValue: WINDING_RULES[wr]?.uintValue ?? 0) ?? .nonZero
        }
    }

    private func elementNeedsMouseTracking(atIndex idx: UInt) -> Bool {
        if (getElementValue(for: "trackMouseEnterExit", atIndex: idx) as? NSNumber)?.boolValue == true { return true }
        if (getElementValue(for: "trackMouseMove", atIndex: idx) as? NSNumber)?.boolValue == true { return true }
        return false
    }

    private func applyElementOverrides(gc: NSGraphicsContext, atIndex idx: UInt) {
        let hasShadow = (getElementValue(for: "withShadow", atIndex: idx) as? NSNumber)?.boolValue ?? false
        if hasShadow, let shadow = getElementValue(for: "shadow", atIndex: idx) as? NSShadow { shadow.set() }
        if let shouldAntialias = getElementValue(for: "antialias", atIndex: idx, onlyIfSet: true) as? NSNumber {
            gc.shouldAntialias = shouldAntialias.boolValue
        }
        if let cs = getElementValue(for: "compositeRule", atIndex: idx, onlyIfSet: true) as? String {
            gc.compositingOperation = NSCompositingOperation(rawValue: COMPOSITING_TYPES[cs]?.uintValue ?? 2) ?? .sourceOver
        }
        if let fc = getElementValue(for: "fillColor", atIndex: idx, onlyIfSet: true) as? NSColor { fc.setFill() }
        if let sc = getElementValue(for: "strokeColor", atIndex: idx, onlyIfSet: true) as? NSColor { sc.setStroke() }
        if let t = getElementValue(for: "transformation", atIndex: idx) as? NSAffineTransform { t.concat() }
    }

    private func frameRectForElement(atIndex idx: UInt) -> NSRect {
        let frame = getElementValue(for: "frame", atIndex: idx, resolvePercentages: true) as? NSDictionary ?? [:]
        return NSMakeRect(CGFloat((frame["x"] as? NSNumber)?.doubleValue ?? 0),
                          CGFloat((frame["y"] as? NSNumber)?.doubleValue ?? 0),
                          CGFloat((frame["w"] as? NSNumber)?.doubleValue ?? 0),
                          CGFloat((frame["h"] as? NSNumber)?.doubleValue ?? 0))
    }

    private func hideSkippedCanvasView(elementType: String, atIndex idx: UInt) {
        guard elementType == "canvas" else { return }
        if let externalView = getElementValue(for: "canvas", atIndex: idx, onlyIfSet: false) as? NSView {
            if !externalView.isHidden { externalView.isHidden = true }
        }
    }

    private func drawNonPathElement(elementType: String, atIndex idx: Int, frameRect: NSRect,
                                     compositeRule CS: String, gc: NSGraphicsContext,
                                     clippingModified: inout Bool) -> Bool {
        var wasClippingChanged = false
        if elementType == "image" {
            drawImageElement(atIndex: idx, frameRect: frameRect, compositeRule: CS)
        } else if elementType == "text" {
            drawTextElement(atIndex: UInt(idx), frameRect: frameRect)
            elementBounds.add(["index": NSNumber(value: idx), "frame": NSValue(rect: frameRect)])
        } else if elementType == "canvas" {
            drawCanvasElement(atIndex: UInt(idx), frameRect: frameRect)
        } else if elementType == "resetClip" {
            gc.restoreGraphicsState()
            wasClippingChanged = true
            if clippingModified {
                gc.restoreGraphicsState()
                clippingModified = false
            } else {
                os_log(.default, "%{public}s","\(canvas_USERDATA_TAG):drawRect - un-nested resetClip at index \(idx + 1)")
            }
        } else {
            os_log(.default, "%{public}s","\(canvas_USERDATA_TAG):drawRect - unrecognized type \(elementType) at index \(idx + 1)")
        }
        return wasClippingChanged
    }

    private func drawImageElement(atIndex idx: Int, frameRect: NSRect, compositeRule CS: String) {
        guard let theImage = elementList[idx] as? NSDictionary, let img = theImage["image"] as? NSImage else { return }
        drawImage(img, atIndex: UInt(idx), inRect: frameRect,
                  operation: UInt(COMPOSITING_TYPES[CS]?.uintValue ?? 2))
        elementBounds.add([
            "index": NSNumber(value: idx),
            "frame": NSValue(rect: frameRect),
            "imageByBounds": getElementValue(for: "trackMouseByBounds", atIndex: UInt(idx)) ?? NSNumber(value: true)
        ])
    }

    private func drawTextElement(atIndex idx: UInt, frameRect: NSRect) {
        var textEntry: Any? = getElementValue(for: "text", atIndex: idx, onlyIfSet: true)
        if textEntry == nil { textEntry = "" }
        else if let num = textEntry as? NSNumber { textEntry = num.stringValue }

        if let plainText = textEntry as? String {
            let myFont = getElementValue(for: "textFont", atIndex: idx, onlyIfSet: false) as? String ?? "Helvetica"
            let mySize = (getElementValue(for: "textSize", atIndex: idx, onlyIfSet: false) as? NSNumber)?.doubleValue ?? 27.0
            let theParagraphStyle = (NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle)
            if let alignment = getElementValue(for: "textAlignment", atIndex: idx, onlyIfSet: false) as? String {
                theParagraphStyle.alignment = NSTextAlignment(rawValue: TEXTALIGNMENT_TYPES[alignment]?.intValue ?? 0) ?? .left
            }
            if let wrap = getElementValue(for: "textLineBreak", atIndex: idx, onlyIfSet: false) as? String {
                theParagraphStyle.lineBreakMode = NSLineBreakMode(rawValue: UInt(TEXTWRAP_TYPES[wrap]?.intValue ?? 0)) ?? .byWordWrapping
            }
            let color = getElementValue(for: "textColor", atIndex: idx, onlyIfSet: false) as? NSColor ?? .white
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: color,
                .font: NSFont(name: myFont, size: CGFloat(mySize)) ?? NSFont.systemFont(ofSize: CGFloat(mySize)),
                .paragraphStyle: theParagraphStyle,
            ]
            (plainText as NSString).draw(in: frameRect, withAttributes: attributes)
        } else if let attrText = textEntry as? NSAttributedString {
            attrText.draw(in: frameRect)
        }
    }

    private func drawCanvasElement(atIndex idx: UInt, frameRect: NSRect) {
        guard let externalView = getElementValue(for: "canvas", atIndex: idx, onlyIfSet: false) as? NSView else { return }
        externalView.needsDisplay = true
        if externalView.isHidden { externalView.isHidden = false }
        if let alpha = getElementValue(for: "canvasAlpha", atIndex: idx, onlyIfSet: true) as? NSNumber {
            externalView.alphaValue = CGFloat(alpha.doubleValue)
        }
        externalView.frame = frameRect
        elementBounds.add(["index": NSNumber(value: idx), "frame": NSValue(rect: frameRect)])
    }

    private func preparePathForRendering(_ path: NSBezierPath, atIndex idx: UInt) -> NSBezierPath {
        if let miterLimit = getElementValue(for: "miterLimit", atIndex: idx, onlyIfSet: true) as? NSNumber {
            path.miterLimit = CGFloat(miterLimit.doubleValue)
        }
        if let flatness = getElementValue(for: "flatness", atIndex: idx, onlyIfSet: true) as? NSNumber {
            path.flatness = CGFloat(flatness.doubleValue)
        }
        var currentPath = path
        if (getElementValue(for: "flattenPath", atIndex: idx) as? NSNumber)?.boolValue == true {
            currentPath = currentPath.flattened
        }
        if (getElementValue(for: "reversePath", atIndex: idx) as? NSNumber)?.boolValue == true {
            currentPath = currentPath.reversed
        }
        if let windingRule = getElementValue(for: "windingRule", atIndex: idx, onlyIfSet: true) as? String {
            currentPath.windingRule = NSBezierPath.WindingRule(rawValue: WINDING_RULES[windingRule]?.uintValue ?? 0) ?? .nonZero
        }
        return currentPath
    }

    private func executeRenderAction(action: String, elementType: String, atIndex idx: UInt,
                                      renderPath: inout NSBezierPath?, gc: NSGraphicsContext,
                                      clippingModified: inout Bool, wasClippingChanged: Bool) -> Bool {
        var wasClippingChanged = wasClippingChanged

        if action == "clip" {
            gc.restoreGraphicsState()
            wasClippingChanged = true
            if !clippingModified { gc.saveGraphicsState(); clippingModified = true }
            renderPath!.addClip()
            renderPath = nil
        } else if action == "fill" || action == "stroke" || action == "strokeAndFill" {
            performFillAndStroke(action: action, elementType: elementType, atIndex: idx,
                                renderPath: renderPath!, gc: gc)
            recordElementBounds(atIndex: idx, renderPath: renderPath!)
            renderPath = nil
        } else if action != "build" {
            os_log(.default, "%{public}s","\(canvas_USERDATA_TAG):drawRect - unrecognized action \(action) at index \(idx + 1)")
        }
        return wasClippingChanged
    }

    private func performFillAndStroke(action: String, elementType: String, atIndex idx: UInt,
                                       renderPath: NSBezierPath, gc: NSGraphicsContext) {
        let clipToPath = (getElementValue(for: "clipToPath", atIndex: idx) as? NSNumber)?.boolValue ?? false
        if CLOSED.contains(elementType) && clipToPath {
            gc.saveGraphicsState()
            renderPath.addClip()
        }

        if elementType != "points" && (action == "fill" || action == "strokeAndFill") {
            fillPath(renderPath, atIndex: idx)
        }
        if action == "stroke" || action == "strokeAndFill" {
            strokePath(renderPath, atIndex: idx)
        }

        if CLOSED.contains(elementType) && clipToPath {
            gc.restoreGraphicsState()
        }
    }

    private func fillPath(_ renderPath: NSBezierPath, atIndex idx: UInt) {
        let fillGradient = getElementValue(for: "fillGradient", atIndex: idx) as? String ?? "none"
        guard fillGradient != "none" && !renderPath.isEmpty else {
            renderPath.fill()
            return
        }
        let gradientColors = getElementValue(for: "fillGradientColors", atIndex: idx) as? [NSColor] ?? [.white, .black]
        let gradient = NSGradient(colors: gradientColors)
        if fillGradient == "linear" {
            let angle = (getElementValue(for: "fillGradientAngle", atIndex: idx) as? NSNumber)?.doubleValue ?? 0
            gradient?.draw(in: renderPath, angle: CGFloat(angle))
        } else if fillGradient == "radial" {
            let centerPoint = getElementValue(for: "fillGradientCenter", atIndex: idx) as? NSDictionary ?? [:]
            gradient?.draw(in: renderPath, relativeCenterPosition: NSMakePoint(
                CGFloat((centerPoint["x"] as? NSNumber)?.doubleValue ?? 0),
                CGFloat((centerPoint["y"] as? NSNumber)?.doubleValue ?? 0)))
        }
    }

    private func strokePath(_ renderPath: NSBezierPath, atIndex idx: UInt) {
        if let strokeWidth = getElementValue(for: "strokeWidth", atIndex: idx, onlyIfSet: true) as? NSNumber {
            renderPath.lineWidth = CGFloat(strokeWidth.doubleValue)
        }
        if let lineJoinStyle = getElementValue(for: "strokeJoinStyle", atIndex: idx, onlyIfSet: true) as? String {
            renderPath.lineJoinStyle = NSBezierPath.LineJoinStyle(rawValue: STROKE_JOIN_STYLES[lineJoinStyle]?.uintValue ?? 0) ?? .miter
        }
        if let lineCapStyle = getElementValue(for: "strokeCapStyle", atIndex: idx, onlyIfSet: true) as? String {
            renderPath.lineCapStyle = NSBezierPath.LineCapStyle(rawValue: STROKE_CAP_STYLES[lineCapStyle]?.uintValue ?? 0) ?? .butt
        }
        if let strokeDashes = getElementValue(for: "strokeDashPattern", atIndex: idx) as? [NSNumber], strokeDashes.count > 0 {
            let phase = (getElementValue(for: "strokeDashPhase", atIndex: idx) as? NSNumber)?.doubleValue ?? 0
            var pattern = strokeDashes.map { CGFloat($0.doubleValue) }
            renderPath.setLineDash(&pattern, count: pattern.count, phase: CGFloat(phase))
        }
        renderPath.stroke()
    }

    private func recordElementBounds(atIndex idx: UInt, renderPath: NSBezierPath) {
        if (getElementValue(for: "trackMouseByBounds", atIndex: idx) as? NSNumber)?.boolValue == true {
            var objectBounds = NSZeroRect
            if !renderPath.isEmpty { objectBounds = renderPath.bounds }
            elementBounds.add(["index": NSNumber(value: idx), "frame": NSValue(rect: objectBounds)])
        } else {
            elementBounds.add(["index": NSNumber(value: idx), "path": renderPath])
        }
    }

    // MARK: - View Animation Methods

    func fadeIn(_ fadeTime: TimeInterval) {
        precondition(fadeTime >= 0, "fadeIn: fadeTime must be non-negative")
        let alphaSetting = self.alphaValue
        self.alphaValue = 0.0
        self.isHidden = false
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = fadeTime
        self.animator().alphaValue = alphaSetting
        NSAnimationContext.endGrouping()
    }

    func fadeOut(_ fadeTime: TimeInterval, andDelete deleteView: Bool, withState L: UnsafeMutablePointer<lua_State>!) {
        precondition(fadeTime >= 0, "fadeOut: fadeTime must be non-negative")
        precondition(L != nil, "fadeOut: Lua state must not be nil")
        if selfRef != nil { return } // already in a fade
        canvas_pushValue(L, self)
        selfRef = L.ref(index: -1)
        lua_pop(L, 1)

        let alphaSetting = self.alphaValue
        NSAnimationContext.beginGrouping()
        weak var bself = self
        NSAnimationContext.current.duration = fadeTime
        NSAnimationContext.current.completionHandler = {
            guard let mySelf = bself else { return }
            mySelf.selfRef = nil

            if deleteView {
                mySelf.removeFromSuperview()
            } else {
                mySelf.isHidden = true
                mySelf.alphaValue = alphaSetting
            }
        }
        self.animator().alphaValue = 0.0
        NSAnimationContext.endGrouping()
    }

    // MARK: - NSDraggingDestination protocol methods

    func performDraggingCallback(_ message: String, with sender: NSDraggingInfo?) -> Bool {
        precondition(!message.isEmpty, "performDraggingCallback: message must not be empty")
        var isAllGood = false
        guard let cb = draggingCallbackFn else { return isAllGood }
        guard lua_isStateGenerationValid(generation) else { return isAllGood }

        let L = lua_getCurrentState()!
        var argCount: Int32 = 2
        cb.push(onto: L)
        canvas_pushValue(L, self)
        canvas_pushValue(L, message as NSString)

        if let sender = sender {
            lua_newtable(L)
            let pasteboard = sender.draggingPasteboard
            canvas_pushValue(L, pasteboard.name.rawValue as NSString)
            lua_setfield(L, -2, "pasteboard")

            L.push(lua_Integer(sender.draggingSequenceNumber))
            lua_setfield(L, -2, "sequence")

            lua_pushNSPoint(L, sender.draggingLocation)
            lua_setfield(L, -2, "mouse")

            let operation = sender.draggingSourceOperationMask
            lua_newtable(L)
            if operation == [] {
                L.push("none"); lua_rawseti(L, -2, luaL_len(L, -2) + 1)
            } else {
                if operation.contains(.copy)    { L.push("copy");    lua_rawseti(L, -2, luaL_len(L, -2) + 1) }
                if operation.contains(.link)    { L.push("link");    lua_rawseti(L, -2, luaL_len(L, -2) + 1) }
                if operation.contains(.generic) { L.push("generic"); lua_rawseti(L, -2, luaL_len(L, -2) + 1) }
                if operation.contains(.private) { L.push("private"); lua_rawseti(L, -2, luaL_len(L, -2) + 1) }
                if operation.contains(.move)    { L.push("move");    lua_rawseti(L, -2, luaL_len(L, -2) + 1) }
                if operation.contains(.delete)  { L.push("delete");  lua_rawseti(L, -2, luaL_len(L, -2) + 1) }
            }
            lua_setfield(L, -2, "operation")
            argCount += 1
        }

        if lua_pcall(L, argCount, 1, 0) == LUA_OK {
            isAllGood = lua_isnoneornil(L, -1) ? true : (lua_toboolean(L, -1) != 0)
        } else {
            os_log(.error, "%{public}s", "\(canvas_USERDATA_TAG):draggingCallback error: \(lua_tovalue(L, at: -1) ?? "unknown" as NSString)")
        }
        lua_pop(L, 1)

        return isAllGood
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { return false }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { return true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return performDraggingCallback("enter", with: sender) ? .generic : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        _ = performDraggingCallback("exit", with: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return performDraggingCallback("receive", with: sender)
    }

    // MARK: - Image drawing (ported from imageAdditions.m)

    private func scaleImageSize(_ imageSize: NSSize, toFitIn canvasSize: NSSize, scaling: NSImageScaling) -> NSSize {
        switch scaling {
        case .scaleProportionallyDown:
            return scaleProportionally(imageSize, canvasSize, false)
        case .scaleAxesIndependently:
            return canvasSize
        case .scaleProportionallyUpOrDown:
            return scaleProportionally(imageSize, canvasSize, true)
        default:
            return imageSize
        }
    }

    private func scaleProportionally(_ imageSize: NSSize, _ canvasSize: NSSize, _ scaleUpOrDown: Bool) -> NSSize {
        guard imageSize.width > 0 && imageSize.height > 0 else { return .zero }
        let ratio = min(canvasSize.width / imageSize.width, canvasSize.height / imageSize.height)
        if ratio < 1.0 || scaleUpOrDown {
            return NSSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
        }
        return imageSize
    }

    private func realRect(for theImage: NSImage, inFrame cellFrame: NSRect, scaling: NSImageScaling, alignment: NSImageAlignment) -> NSRect {
        let imageSize = scaleImageSize(theImage.size, toFitIn: cellFrame.size, scaling: scaling)
        let isFlipped = self.isFlipped
        var position: NSPoint = .zero

        switch alignment {
        case .alignLeft:
            position.x = cellFrame.minX
            position.y = cellFrame.midY - imageSize.height / 2.0
        case .alignRight:
            position.x = cellFrame.maxX - imageSize.width
            position.y = cellFrame.midY - imageSize.height / 2.0
        case .alignCenter:
            position.x = cellFrame.midX - imageSize.width / 2.0
            position.y = cellFrame.midY - imageSize.height / 2.0
        case .alignTop:
            position.x = cellFrame.midX - imageSize.width / 2.0
            position.y = isFlipped ? cellFrame.minY : cellFrame.maxY - imageSize.height
        case .alignBottom:
            position.x = cellFrame.midX - imageSize.width / 2.0
            position.y = isFlipped ? cellFrame.maxY - imageSize.height : cellFrame.minY
        case .alignTopLeft:
            position.x = cellFrame.minX
            position.y = isFlipped ? cellFrame.minY : cellFrame.maxY - imageSize.height
        case .alignTopRight:
            position.x = cellFrame.maxX - imageSize.width
            position.y = isFlipped ? cellFrame.minY : cellFrame.maxY - imageSize.height
        case .alignBottomLeft:
            position.x = cellFrame.minX
            position.y = isFlipped ? cellFrame.maxY - imageSize.height : cellFrame.minY
        case .alignBottomRight:
            position.x = cellFrame.maxX - imageSize.width
            position.y = isFlipped ? cellFrame.maxY - imageSize.height : cellFrame.minY
        @unknown default:
            position.x = cellFrame.minX
            position.y = cellFrame.midY - imageSize.height / 2.0
        }

        return centerScanRect(NSMakeRect(position.x, position.y, imageSize.width, imageSize.height))
    }

    func drawImage(_ theImage: NSImage, atIndex idx: UInt, inRect cellFrame: NSRect, operation compositeType: UInt) {
        guard !cellFrame.isEmpty else { return }

        let alignmentString = getElementValue(for: "imageAlignment", atIndex: idx, onlyIfSet: false) as? String ?? "center"
        let alignment = NSImageAlignment(rawValue: IMAGEALIGNMENT_TYPES[alignmentString]?.uintValue ?? 0) ?? .alignCenter

        let scalingString = getElementValue(for: "imageScaling", atIndex: idx, onlyIfSet: false) as? String ?? "none"
        let scaling = NSImageScaling(rawValue: IMAGESCALING_TYPES[scalingString]?.uintValue ?? 0) ?? .scaleNone

        let alpha: Double
        if theImage.isTemplate {
            alpha = (getElementValue(for: "imageAlpha", atIndex: idx, onlyIfSet: true) as? NSNumber)?.doubleValue ?? 0.5
        } else {
            alpha = (getElementValue(for: "imageAlpha", atIndex: idx) as? NSNumber)?.doubleValue ?? 1.0
        }

        let rect = realRect(for: theImage, inFrame: cellFrame, scaling: scaling, alignment: alignment)

        let gc = NSGraphicsContext.current!
        gc.saveGraphicsState()
        NSBezierPath.clip(cellFrame)

        let realImageSize = theImage.size
        theImage.draw(in: rect,
                      from: NSMakeRect(0, 0, realImageSize.width, realImageSize.height),
                      operation: NSCompositingOperation(rawValue: compositeType) ?? .sourceOver,
                      fraction: CGFloat(alpha),
                      respectFlipped: true,
                      hints: nil)

        gc.restoreGraphicsState()
    }

    // see https://www.stairways.com/blog/2009-04-21-nsimage-from-nsview
    func imageWithSubviews() -> NSImage {
        autoreleasepool {
            let bir = bitmapImageRepForCachingDisplay(in: self.bounds)!
            bir.size = self.bounds.size
            cacheDisplay(in: self.bounds, to: bir)
            let image = NSImage(size: self.bounds.size)
            image.addRepresentation(bir)
            return image
        }
    }
}
