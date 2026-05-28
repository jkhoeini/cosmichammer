import Cocoa
import LuaSkin
import os.log

// MARK: - HSCanvasView

@objc class HSCanvasView: NSView {
    @objc var selfRef: Int32 = LUA_NOREF     // used during fadeOut to make sure collection doesn't interrupt
    @objc var selfRefCount: Int32 = 0
    @objc var wrapperWindow: HSCanvasWindow?
    @objc var mouseCallbackRef: Int32 = LUA_NOREF
    @objc var draggingCallbackRef: Int32 = LUA_NOREF
    @objc var mouseTracking: Bool = false
    @objc var canvasMouseDown: Bool = false
    @objc var canvasMouseUp: Bool = false
    @objc var canvasMouseEnterExit: Bool = false
    @objc var canvasMouseMove: Bool = false
    @objc var previousTrackedIndex: UInt = UInt(NSNotFound)
    @objc var canvasDefaults: NSMutableDictionary = NSMutableDictionary()
    @objc var elementList: NSMutableArray = NSMutableArray()
    @objc var elementBounds: NSMutableArray = NSMutableArray()
    @objc var canvasTransform: NSAffineTransform = NSAffineTransform()
    @objc var imageAnimations: NSMapTable<NSImage, HSGifAnimator> = NSMapTable<NSImage, HSGifAnimator>.weakToStrongObjects()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        selfRef = LUA_NOREF
        selfRefCount = 0
        wrapperWindow = nil

        mouseCallbackRef = LUA_NOREF
        draggingCallbackRef = LUA_NOREF
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

        guard mouseCallbackRef != LUA_NOREF, mouseTracking || canvasMouseEvents else { return }

        let eventLocation = theEvent.locationInWindow
        let localPoint = convert(eventLocation, from: nil)

        var targetIndex = UInt(NSNotFound)
        var actualPoint = localPoint

        for i in stride(from: elementBounds.count - 1, through: 0, by: -1) {
            guard let box = elementBounds[i] as? NSDictionary,
                  let elementIdx = (box["index"] as? NSNumber)?.uintValue else { continue }
            let trackEnterExit = (getElementValue(for: "trackMouseEnterExit", atIndex: elementIdx) as? NSNumber)?.boolValue ?? false
            let trackMove = (getElementValue(for: "trackMouseMove", atIndex: elementIdx) as? NSNumber)?.boolValue ?? false
            if trackEnterExit || trackMove {
                let pointTransform = canvasTransform.copy() as! NSAffineTransform
                if let elemTransform = getElementValue(for: "transformation", atIndex: elementIdx) as? NSAffineTransform {
                    pointTransform.append(elemTransform as AffineTransform)
                }
                pointTransform.invert()
                let isView = (getElementValue(for: "type", atIndex: elementIdx) as? String) == "canvas"
                actualPoint = isView ? localPoint : pointTransform.transform(localPoint)

                if let imageByBounds = box["imageByBounds"] as? NSNumber, !imageByBounds.boolValue {
                    if let theImage = (elementList[Int(elementIdx)] as? NSDictionary)?["image"] as? NSImage {
                        let hitRect = NSMakeRect(actualPoint.x, actualPoint.y, 1.0, 1.0)
                        let imageRect = (box["frame"] as! NSValue).rectValue
                        if theImage.hitTest(hitRect, withDestinationRect: imageRect, context: nil, hints: nil, flipped: true) {
                            targetIndex = UInt(i)
                            break
                        }
                    }
                } else if let frame = box["frame"] as? NSValue, NSPointInRect(actualPoint, frame.rectValue) {
                    targetIndex = UInt(i)
                    break
                } else if let path = box["path"] as? NSBezierPath, path.contains(actualPoint) {
                    targetIndex = UInt(i)
                    break
                }
            }
        }

        let realTargetIndex: UInt = (targetIndex != UInt(NSNotFound)) ?
            ((elementBounds[Int(targetIndex)] as! NSDictionary)["index"] as! NSNumber).uintValue : UInt(NSNotFound)
        let realPrevIndex: UInt = (previousTrackedIndex != UInt(NSNotFound)) ?
            ((elementBounds[Int(previousTrackedIndex)] as! NSDictionary)["index"] as! NSNumber).uintValue : UInt(NSNotFound)

        if previousTrackedIndex == targetIndex {
            if targetIndex != UInt(NSNotFound),
               (getElementValue(for: "trackMouseMove", atIndex: realPrevIndex) as? NSNumber)?.boolValue ?? false {
                var targetID: Any = getElementValue(for: "id", atIndex: realPrevIndex, onlyIfSet: true) ?? NSNumber(value: realPrevIndex + 1)
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

        if (canvasMouseEnterExit || canvasMouseMove) && targetIndex == UInt(NSNotFound) {
            if previousTrackedIndex == UInt(NSNotFound) && canvasMouseMove {
                doMouseCallback("mouseMove", for: "_canvas_", at: localPoint)
            } else if previousTrackedIndex != UInt(NSNotFound) && canvasMouseEnterExit {
                doMouseCallback("mouseEnter", for: "_canvas_", at: localPoint)
            }
        }
        previousTrackedIndex = targetIndex
    }

    override func mouseEntered(with theEvent: NSEvent) {
        if mouseCallbackRef != LUA_NOREF && canvasMouseEnterExit {
            let eventLocation = theEvent.locationInWindow
            let localPoint = convert(eventLocation, from: nil)
            doMouseCallback("mouseEnter", for: "_canvas_", at: localPoint)
        }
    }

    override func mouseExited(with theEvent: NSEvent) {
        let canvasMouseEvents = canvasMouseEnterExit || canvasMouseMove

        guard mouseCallbackRef != LUA_NOREF, mouseTracking || canvasMouseEvents else { return }

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
        guard mouseCallbackRef != LUA_NOREF else { return }
        let skin = LuaSkin.skin(with: nil)
        let L = LuaSkin.skin(with: nil).l!
        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(mouseCallbackRef))
        lua_pushany(L, self)
        lua_pushany(L, message as NSString)
        lua_pushany(L, elementIdentifier as AnyObject)
        lua_pushnumber(L, lua_Number(location.x))
        lua_pushnumber(L, lua_Number(location.y))
        if lua_pcall(L, 5, 0, 0) != LUA_OK { lua_pop(L, 1) }
    }

    func subviewCallback(_ sender: Any) {
        guard mouseCallbackRef != LUA_NOREF else { return }
        let skin = LuaSkin.skin(with: nil)
        let L = LuaSkin.skin(with: nil).l!
        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(mouseCallbackRef))
        lua_pushany(L, self)
        lua_pushany(L, "_subview_" as NSString)
        lua_pushany(L, sender as AnyObject)
        if lua_pcall(L, 3, 0, 0) != LUA_OK { lua_pop(L, 1) }
    }

    override func mouseDown(with theEvent: NSEvent) {
        NSApp.preventWindowOrdering()
        guard mouseCallbackRef != LUA_NOREF else { return }

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
            LuaSkin.skin(with: nil).logError("view removed from canvas superview does not belong to any known canvas element")
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
        var elementPath: NSBezierPath? = nil
        let elementType = getElementValue(for: "type", atIndex: idx) as? String

        // ARC
        if elementType == "arc" {
            let center = getElementValue(for: "center", atIndex: idx, resolvePercentages: true) as? NSDictionary
            let cx = (center?["x"] as? NSNumber)?.doubleValue ?? 0
            let cy = (center?["y"] as? NSNumber)?.doubleValue ?? 0
            let r = (getElementValue(for: "radius", atIndex: idx, resolvePercentages: true) as? NSNumber)?.doubleValue ?? 0
            let myCenterPoint = NSMakePoint(CGFloat(cx), CGFloat(cy))
            elementPath = NSBezierPath()
            let startAngle = ((getElementValue(for: "startAngle", atIndex: idx) as? NSNumber)?.doubleValue ?? 0) - 90
            let endAngle = ((getElementValue(for: "endAngle", atIndex: idx) as? NSNumber)?.doubleValue ?? 0) - 90
            let arcDir = (getElementValue(for: "arcClockwise", atIndex: idx) as? NSNumber)?.boolValue ?? true
            let arcLegs = (getElementValue(for: "arcRadii", atIndex: idx) as? NSNumber)?.boolValue ?? true
            if arcLegs { elementPath!.move(to: myCenterPoint) }
            elementPath!.appendArc(withCenter: myCenterPoint,
                                   radius: CGFloat(r),
                                   startAngle: CGFloat(startAngle),
                                   endAngle: CGFloat(endAngle),
                                   clockwise: !arcDir) // because our canvas is flipped, we have to reverse this
            if arcLegs { elementPath!.line(to: myCenterPoint) }
        }
        // CIRCLE
        else if elementType == "circle" {
            let center = getElementValue(for: "center", atIndex: idx, resolvePercentages: true) as? NSDictionary
            let cx = (center?["x"] as? NSNumber)?.doubleValue ?? 0
            let cy = (center?["y"] as? NSNumber)?.doubleValue ?? 0
            let r = (getElementValue(for: "radius", atIndex: idx, resolvePercentages: true) as? NSNumber)?.doubleValue ?? 0
            elementPath = NSBezierPath()
            elementPath!.appendOval(in: NSMakeRect(CGFloat(cx - r), CGFloat(cy - r), CGFloat(r * 2), CGFloat(r * 2)))
        }
        // ELLIPTICALARC
        else if elementType == "ellipticalArc" {
            let cx = frameRect.origin.x + frameRect.size.width / 2
            let cy = frameRect.origin.y + frameRect.size.height / 2
            let r = frameRect.size.width / 2

            let moveTransform = NSAffineTransform()
            moveTransform.translateX(by: cx, yBy: cy)
            let scaleTransform = NSAffineTransform()
            scaleTransform.scaleX(by: 1.0, yBy: frameRect.size.height / frameRect.size.width)
            let finalTransform = NSAffineTransform(transform: scaleTransform as AffineTransform)
            finalTransform.append(moveTransform as AffineTransform)
            elementPath = NSBezierPath()
            let startAngle = ((getElementValue(for: "startAngle", atIndex: idx) as? NSNumber)?.doubleValue ?? 0) - 90
            let endAngle = ((getElementValue(for: "endAngle", atIndex: idx) as? NSNumber)?.doubleValue ?? 0) - 90
            let arcDir = (getElementValue(for: "arcClockwise", atIndex: idx) as? NSNumber)?.boolValue ?? true
            let arcLegs = (getElementValue(for: "arcRadii", atIndex: idx) as? NSNumber)?.boolValue ?? true
            if arcLegs { elementPath!.move(to: .zero) }
            elementPath!.appendArc(withCenter: .zero, radius: r,
                                   startAngle: CGFloat(startAngle),
                                   endAngle: CGFloat(endAngle),
                                   clockwise: !arcDir)
            if arcLegs { elementPath!.line(to: .zero) }
            elementPath = finalTransform.transform(elementPath!)
        }
        // OVAL
        else if elementType == "oval" {
            elementPath = NSBezierPath()
            elementPath!.appendOval(in: frameRect)
        }
        // RECTANGLE
        else if elementType == "rectangle" {
            elementPath = NSBezierPath()
            let roundedRect = getElementValue(for: "roundedRectRadii", atIndex: idx) as? NSDictionary
            elementPath!.appendRoundedRect(frameRect,
                                           xRadius: CGFloat((roundedRect?["xRadius"] as? NSNumber)?.doubleValue ?? 0),
                                           yRadius: CGFloat((roundedRect?["yRadius"] as? NSNumber)?.doubleValue ?? 0))
        }
        // POINTS
        else if elementType == "points" {
            elementPath = NSBezierPath()
            let coordinates = getElementValue(for: "coordinates", atIndex: idx, resolvePercentages: true) as? [NSDictionary] ?? []
            for aPoint in coordinates {
                let x = (aPoint["x"] as? NSNumber)?.doubleValue ?? 0
                let y = (aPoint["y"] as? NSNumber)?.doubleValue ?? 0
                elementPath!.appendRect(NSMakeRect(CGFloat(x), CGFloat(y), 1.0, 1.0))
            }
        }
        // SEGMENTS
        else if elementType == "segments" {
            elementPath = NSBezierPath()
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
                    elementPath!.move(to: NSMakePoint(CGFloat(x), CGFloat(y)))
                } else if !goodForCurve {
                    elementPath!.line(to: NSMakePoint(CGFloat(x), CGFloat(y)))
                } else {
                    elementPath!.curve(to: NSMakePoint(CGFloat(x), CGFloat(y)),
                                       controlPoint1: NSMakePoint(CGFloat(c1x!.doubleValue), CGFloat(c1y!.doubleValue)),
                                       controlPoint2: NSMakePoint(CGFloat(c2x!.doubleValue), CGFloat(c2y!.doubleValue)))
                }
            }
            if (getElementValue(for: "closed", atIndex: idx) as? NSNumber)?.boolValue ?? false {
                elementPath!.close()
            }
        }

        return elementPath
    }

    // MARK: - massageKeyValue / getDefaultValue / setDefault / getElementValue / setElementValue

    @objc func massageKeyValue(_ oldValue: Any!, forKey keyName: String, withState L: UnsafeMutablePointer<lua_State>!) -> Any! {
        let skin = LuaSkin.skin(with: L)
        var newValue: Any! = oldValue

        // fix "...Color" tables
        if keyName.hasSuffix("Color"), let dict = oldValue as? NSDictionary {
            lua_pushany(L, dict)
            lua_pushstring(L, "NSColor")
            lua_setfield(L, -2, "__luaSkinType")
            newValue = lua_tovalue(L, at: -1)
            lua_pop(L, 1)
        } else if keyName.hasSuffix("Color"), let arr = oldValue as? NSArray {
            lua_pushany(L, arr)
            lua_pushstring(L, "NSColor")
            lua_setfield(L, -2, "__luaSkinType")
            newValue = lua_tovalue(L, at: -1)
            lua_pop(L, 1)

        // fillGradientColors is an array of colors
        } else if keyName == "fillGradientColors" {
            let result = NSMutableArray()
            if let oldArray = oldValue as? NSMutableArray {
                oldArray.enumerateObjects { (anItem, idx, _) in
                    var item = anItem
                    if let dict = item as? NSDictionary {
                        lua_pushany(L, dict)
                        lua_pushstring(L, "NSColor")
                        lua_setfield(L, -2, "__luaSkinType")
                        item = lua_tovalue(L, at: -1) as Any
                        lua_pop(L, 1)
                    }
                    if let color = item as? NSColor, color.usingColorSpace(.genericRGB) != nil {
                        result.add(color)
                    } else {
                        LuaSkin.skin(with: nil).logWarn("\(canvas_USERDATA_TAG):not a proper color at index \(idx + 1) of fillGradientColor; using Black")
                        result.add(NSColor.black)
                    }
                }
            }
            if result.count < 2 {
                LuaSkin.skin(with: nil).logWarn("\(canvas_USERDATA_TAG):fillGradientColor requires at least 2 colors; using default")
                newValue = getDefaultValue(for: keyName, onlyIfSet: false)
            } else {
                newValue = result
            }

        // fix NSAffineTransform table
        } else if keyName == "transformation", (oldValue is NSDictionary || oldValue is NSArray) {
            lua_pushany(L, oldValue as AnyObject)
            lua_pushstring(L, "NSAffineTransform")
            lua_setfield(L, -2, "__luaSkinType")
            newValue = lua_tovalue(L, at: -1)
            lua_pop(L, 1)

        // fix NSShadow table
        } else if keyName == "shadow", (oldValue is NSDictionary || oldValue is NSArray) {
            lua_pushany(L, oldValue as AnyObject)
            lua_pushstring(L, "NSShadow")
            lua_setfield(L, -2, "__luaSkinType")
            newValue = lua_tovalue(L, at: -1)
            lua_pop(L, 1)

        // fix hs.styledText as Table
        } else if keyName == "text", (oldValue is NSDictionary || oldValue is NSArray) {
            lua_pushany(L, oldValue as AnyObject)
            lua_pushstring(L, "NSAttributedString")
            lua_setfield(L, -2, "__luaSkinType")
            newValue = lua_tovalue(L, at: -1)
            lua_pop(L, 1)

        // recurse into fields which have subfields
        } else if let dict = oldValue as? NSDictionary {
            let blockValue = NSMutableDictionary()
            dict.enumerateKeysAndObjects { (blockKeyName, valueForKey, _) in
                blockValue.setObject(self.massageKeyValue(valueForKey, forKey: blockKeyName as! String, withState: L) as Any, forKey: blockKeyName as! NSCopying)
            }
            newValue = blockValue
        }

        return newValue
    }

    @objc func getDefaultValue(for keyName: String, onlyIfSet: Bool) -> Any? {
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

    @objc func setDefault(for keyName: String, to keyValue: Any!, withState L: UnsafeMutablePointer<lua_State>!) -> Int {
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

    @objc func getElementValue(for keyName: String, atIndex index: UInt) -> Any? {
        return getElementValue(for: keyName, atIndex: index, resolvePercentages: false, onlyIfSet: false)
    }

    @objc func getElementValue(for keyName: String, atIndex index: UInt, onlyIfSet: Bool) -> Any? {
        return getElementValue(for: keyName, atIndex: index, resolvePercentages: false, onlyIfSet: onlyIfSet)
    }

    @objc func getElementValue(for keyName: String, atIndex index: UInt, resolvePercentages: Bool) -> Any? {
        return getElementValue(for: keyName, atIndex: index, resolvePercentages: resolvePercentages, onlyIfSet: false)
    }

    @objc func getElementValue(for keyName: String, atIndex index: UInt, resolvePercentages: Bool, onlyIfSet: Bool) -> Any? {
        guard index < elementList.count else { return nil }
        let elementAttributes = elementList[Int(index)] as! NSDictionary
        var foundObject: Any? = elementAttributes[keyName] ?? (onlyIfSet ? nil : getDefaultValue(for: keyName, onlyIfSet: false))

        if let mutableCopyable = foundObject as? NSMutableCopying {
            foundObject = mutableCopyable.mutableCopy(with: nil)
        } else if let copyable = foundObject as? NSCopying {
            foundObject = copyable.copy(with: nil)
        }

        if keyName == "imageAnimationFrame" {
            if let theImage = (elementList[Int(index)] as? NSDictionary)?["image"] as? NSImage {
                for case let representation as NSBitmapImageRep in theImage.representations {
                    if let currentFrame = representation.value(forProperty: .currentFrame) {
                        foundObject = currentFrame
                        break
                    }
                }
            }
        }

        if foundObject != nil && resolvePercentages {
            let padding = (getElementValue(for: "padding", atIndex: index) as? NSNumber)?.doubleValue ?? 0.0
            let paddedWidth = Double(self.frame.size.width) - padding * 2
            let paddedHeight = Double(self.frame.size.height) - padding * 2

            if keyName == "radius" {
                if let stringVal = foundObject as? String {
                    if let percentage = canvas_convertPercentageStringToNumber(stringVal) {
                        foundObject = NSNumber(value: percentage.doubleValue * paddedWidth)
                    }
                }
            } else if keyName == "center" {
                if let dict = foundObject as? NSMutableDictionary {
                    if let xStr = dict["x"] as? String, let pct = canvas_convertPercentageStringToNumber(xStr) {
                        dict["x"] = NSNumber(value: padding + pct.doubleValue * paddedWidth)
                    }
                    if let yStr = dict["y"] as? String, let pct = canvas_convertPercentageStringToNumber(yStr) {
                        dict["y"] = NSNumber(value: padding + pct.doubleValue * paddedHeight)
                    }
                }
            } else if keyName == "frame" {
                if let dict = foundObject as? NSMutableDictionary {
                    if let xStr = dict["x"] as? String, let pct = canvas_convertPercentageStringToNumber(xStr) {
                        dict["x"] = NSNumber(value: padding + pct.doubleValue * paddedWidth)
                    }
                    if let yStr = dict["y"] as? String, let pct = canvas_convertPercentageStringToNumber(yStr) {
                        dict["y"] = NSNumber(value: padding + pct.doubleValue * paddedHeight)
                    }
                    if let wStr = dict["w"] as? String, let pct = canvas_convertPercentageStringToNumber(wStr) {
                        dict["w"] = NSNumber(value: pct.doubleValue * paddedWidth)
                    }
                    if let hStr = dict["h"] as? String, let pct = canvas_convertPercentageStringToNumber(hStr) {
                        dict["h"] = NSNumber(value: pct.doubleValue * paddedHeight)
                    }
                }
            } else if keyName == "coordinates" {
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
                foundObject = ourCopy
            }
        }

        return foundObject
    }

    @objc func setElementValue(for keyName: String, atIndex index: UInt, to keyValue: Any!, withState L: UnsafeMutablePointer<lua_State>!) -> Int {
        guard index < elementList.count else { return AttributeValidity.invalid.rawValue }
        let massaged = massageKeyValue(keyValue, forKey: keyName, withState: L)
        var validityStatus = canvas_isValueValidForAttribute(keyName as NSString, massaged)

        switch validityStatus {
        case .valid:
            // Percentage string validation for radius/center/frame/coordinates
            if keyName == "radius", let strVal = massaged as? String {
                if canvas_convertPercentageStringToNumber(strVal) == nil {
                    LuaSkin.skin(with: nil).logError("\(canvas_USERDATA_TAG):invalid percentage string specified for \(keyName) for element \(index + 1)")
                    validityStatus = .invalid
                    break
                }
            } else if keyName == "center", let dict = massaged as? NSDictionary {
                for field in ["x", "y"] {
                    if let str = dict[field] as? String, canvas_convertPercentageStringToNumber(str) == nil {
                        LuaSkin.skin(with: nil).logError("\(canvas_USERDATA_TAG):invalid percentage string specified for field \(field) of \(keyName) for element \(index + 1)")
                        validityStatus = .invalid
                        break
                    }
                }
                if validityStatus == .invalid { break }
            } else if keyName == "frame", let dict = massaged as? NSDictionary {
                for field in ["x", "y", "w", "h"] {
                    if let str = dict[field] as? String, canvas_convertPercentageStringToNumber(str) == nil {
                        LuaSkin.skin(with: nil).logError("\(canvas_USERDATA_TAG):invalid percentage string specified for field \(field) of \(keyName) for element \(index + 1)")
                        validityStatus = .invalid
                        break
                    }
                }
                if validityStatus == .invalid { break }
            } else if keyName == "coordinates", let arr = massaged as? NSMutableArray {
                var earlyBreak = false
                arr.enumerateObjects { (subItem, idx, stop) in
                    if let subDict = subItem as? NSMutableDictionary {
                        var seenFields = Set<String>()
                        for field in ["x", "y", "c1x", "c1y", "c2x", "c2y"] {
                            if subDict[field] != nil {
                                seenFields.insert(field)
                                if let str = subDict[field] as? String, canvas_convertPercentageStringToNumber(str) == nil {
                                    LuaSkin.skin(with: nil).logError("\(canvas_USERDATA_TAG):invalid percentage string specified for field \(field) at index \(idx + 1) of \(keyName) for element \(index + 1)")
                                    validityStatus = .invalid
                                    stop.pointee = true
                                    earlyBreak = true
                                    return
                                }
                            }
                        }
                        let goodForPoint = seenFields.contains("x") && seenFields.contains("y")
                        let goodForCurve = goodForPoint && seenFields.contains("c1x") && seenFields.contains("c1y") && seenFields.contains("c2x") && seenFields.contains("c2y")
                        let partialCurve = (seenFields.contains("c1x") || seenFields.contains("c1y") || seenFields.contains("c2x") || seenFields.contains("c2y")) && !goodForCurve
                        if !goodForPoint {
                            LuaSkin.skin(with: nil).logError("\(canvas_USERDATA_TAG):index \(idx + 1) of \(keyName) for element \(index + 1) does not specify a valid point or curve with control points")
                            validityStatus = .invalid
                        } else if goodForPoint && partialCurve {
                            LuaSkin.skin(with: nil).logWarn("\(canvas_USERDATA_TAG):index \(idx + 1) of \(keyName) for element \(index + 1) does not contain complete curve control points; treating as a singular point")
                        }
                    }
                }
                if validityStatus == .invalid { break }
            } else if keyName == "canvas" {
                if let newView = massaged as? NSView {
                    let oldView = (elementList[Int(index)] as? NSMutableDictionary)?[keyName] as? NSView
                    if newView != oldView {
                        if !newView.isDescendant(of: self) && (newView.window == nil || !(newView.window?.isVisible ?? false)) {
                            oldView?.removeFromSuperview()
                            self.addSubview(newView)
                        } else {
                            LuaSkin.skin(with: nil).logWarn("\(canvas_USERDATA_TAG):view for element \(index + 1) is already in use")
                            validityStatus = .invalid
                            break
                        }
                    }
                }
            } else if keyName == "imageAnimationFrame" {
                if (getElementValue(for: "imageAnimates", atIndex: index) as? NSNumber)?.boolValue == true {
                    LuaSkin.skin(with: nil).logWarn("\(canvas_USERDATA_TAG):\(keyName) cannot be changed when element \(index + 1) is animating")
                    validityStatus = .invalid
                    break
                } else {
                    if let theImage = (elementList[Int(index)] as? NSDictionary)?["image"] as? NSImage {
                        for case let rep as NSBitmapImageRep in theImage.representations {
                            if let maxFrames = rep.value(forProperty: .frameCount) as? NSNumber {
                                var newFrame = (massaged as? NSNumber)?.intValue ?? 0
                                newFrame = newFrame % maxFrames.intValue
                                while newFrame < 0 { newFrame = maxFrames.intValue + newFrame }
                                rep.setProperty(.currentFrame, withValue: NSNumber(value: newFrame))
                                break
                            }
                        }
                    }
                }
            } else if keyName == "imageAnimates" {
                if let currentImage = (elementList[Int(index)] as? NSDictionary)?["image"] as? NSImage {
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
            } else if keyName == "image" {
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

            if keyName != "imageAnimationFrame" {
                (elementList[Int(index)] as! NSMutableDictionary)[keyName] = massaged
            }

            // add defaults, if not already present, for type
            if keyName == "type" {
                let defaultsForType = canvas_languageDictionary.keysSortedByValue(comparator: { _, _ in .orderedSame })
                    // Actually use keysOfEntries to find required keys for this type
                let requiredKeys = (canvas_languageDictionary as! [String: NSDictionary]).filter { (typeName, typeDefinition) in
                    typeName != "type" && (typeDefinition["requiredFor"] as? [String])?.contains(massaged as! String) == true
                }.map { $0.key }
                let elemDict = elementList[Int(index)] as! NSMutableDictionary
                for additionalKey in requiredKeys {
                    if elemDict[additionalKey] == nil {
                        _ = setElementValue(for: additionalKey, atIndex: index, to: getDefaultValue(for: additionalKey, onlyIfSet: false), withState: L)
                    }
                }
            }

        case .nulling:
            if keyName == "canvas" {
                if let oldView = (elementList[Int(index)] as? NSMutableDictionary)?[keyName] as? NSView {
                    oldView.removeFromSuperview()
                }
            } else if keyName == "imageAnimationFrame" {
                if (getElementValue(for: "imageAnimates", atIndex: index) as? NSNumber)?.boolValue == true {
                    LuaSkin.skin(with: nil).logWarn("\(canvas_USERDATA_TAG):\(keyName) cannot be changed when element \(index + 1) is animating")
                    validityStatus = .invalid
                    break
                } else {
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
                }
            } else if keyName == "imageAnimates" {
                if let currentImage = (elementList[Int(index)] as? NSDictionary)?["image"] as? NSImage {
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
            } else if keyName == "image" {
                if let currentImage = (elementList[Int(index)] as? NSDictionary)?["image"] as? NSImage {
                    if let animator = imageAnimations.object(forKey: currentImage) {
                        animator.stopAnimating()
                        imageAnimations.removeObject(forKey: currentImage)
                    }
                }
            }
            (elementList[Int(index)] as! NSMutableDictionary).removeObject(forKey: keyName)

        case .invalid:
            break
        }

        self.needsDisplay = true
        return validityStatus.rawValue
    }

    // MARK: - drawRect

    override func draw(_ rect: NSRect) {
        let gc = NSGraphicsContext.current!
        gc.saveGraphicsState()

        canvasTransform.concat()

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
            var elementPath: NSBezierPath? = nil
            let elementType = elementDict["type"] as? String ?? ""
            let action = self.getElementValue(for: "action", atIndex: UInt(idx)) as? String ?? "strokeAndFill"

            if action != "skip" {
                if !needMouseTracking {
                    needMouseTracking = (self.getElementValue(for: "trackMouseEnterExit", atIndex: UInt(idx)) as? NSNumber)?.boolValue ?? false
                    if !needMouseTracking {
                        needMouseTracking = (self.getElementValue(for: "trackMouseMove", atIndex: UInt(idx)) as? NSNumber)?.boolValue ?? false
                    }
                }

                var wasClippingChanged = false
                gc.saveGraphicsState()

                let hasShadow = (self.getElementValue(for: "withShadow", atIndex: UInt(idx)) as? NSNumber)?.boolValue ?? false
                if hasShadow, let shadow = self.getElementValue(for: "shadow", atIndex: UInt(idx)) as? NSShadow {
                    shadow.set()
                }

                if let shouldAntialias = self.getElementValue(for: "antialias", atIndex: UInt(idx), onlyIfSet: true) as? NSNumber {
                    gc.shouldAntialias = shouldAntialias.boolValue
                }
                if let compositingString = self.getElementValue(for: "compositeRule", atIndex: UInt(idx), onlyIfSet: true) as? String {
                    gc.compositingOperation = NSCompositingOperation(rawValue: COMPOSITING_TYPES[compositingString]?.uintValue ?? 2) ?? .sourceOver
                }
                if let fillColor = self.getElementValue(for: "fillColor", atIndex: UInt(idx), onlyIfSet: true) as? NSColor {
                    fillColor.setFill()
                }
                if let strokeColor = self.getElementValue(for: "strokeColor", atIndex: UInt(idx), onlyIfSet: true) as? NSColor {
                    strokeColor.setStroke()
                }

                if let elementTransform = self.getElementValue(for: "transformation", atIndex: UInt(idx)) as? NSAffineTransform {
                    elementTransform.concat()
                }

                let frame = self.getElementValue(for: "frame", atIndex: UInt(idx), resolvePercentages: true) as? NSDictionary ?? [:]
                let frameRect = NSMakeRect(CGFloat((frame["x"] as? NSNumber)?.doubleValue ?? 0),
                                           CGFloat((frame["y"] as? NSNumber)?.doubleValue ?? 0),
                                           CGFloat((frame["w"] as? NSNumber)?.doubleValue ?? 0),
                                           CGFloat((frame["h"] as? NSNumber)?.doubleValue ?? 0))

                elementPath = self.pathForElement(atIndex: UInt(idx), withFrame: frameRect)

                if elementPath == nil {
                    // IMAGE
                    if elementType == "image" {
                        if let theImage = self.elementList[idx] as? NSDictionary, let img = theImage["image"] as? NSImage {
                            self.drawImage(img, atIndex: UInt(idx), inRect: frameRect,
                                           operation: UInt(COMPOSITING_TYPES[CS]?.uintValue ?? 2))
                            self.elementBounds.add([
                                "index": NSNumber(value: idx),
                                "frame": NSValue(rect: frameRect),
                                "imageByBounds": self.getElementValue(for: "trackMouseByBounds", atIndex: UInt(idx)) ?? NSNumber(value: true)
                            ])
                        }
                    // TEXT
                    } else if elementType == "text" {
                        var textEntry: Any? = self.getElementValue(for: "text", atIndex: UInt(idx), onlyIfSet: true)
                        if textEntry == nil { textEntry = "" }
                        else if let num = textEntry as? NSNumber { textEntry = num.stringValue }

                        if let plainText = textEntry as? String {
                            let myFont = self.getElementValue(for: "textFont", atIndex: UInt(idx), onlyIfSet: false) as? String ?? "Helvetica"
                            let mySize = (self.getElementValue(for: "textSize", atIndex: UInt(idx), onlyIfSet: false) as? NSNumber)?.doubleValue ?? 27.0
                            let theParagraphStyle = (NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle)
                            if let alignment = self.getElementValue(for: "textAlignment", atIndex: UInt(idx), onlyIfSet: false) as? String {
                                theParagraphStyle.alignment = NSTextAlignment(rawValue: TEXTALIGNMENT_TYPES[alignment]?.intValue ?? 0) ?? .left
                            }
                            if let wrap = self.getElementValue(for: "textLineBreak", atIndex: UInt(idx), onlyIfSet: false) as? String {
                                theParagraphStyle.lineBreakMode = NSLineBreakMode(rawValue: UInt(TEXTWRAP_TYPES[wrap]?.intValue ?? 0)) ?? .byWordWrapping
                            }
                            let color = self.getElementValue(for: "textColor", atIndex: UInt(idx), onlyIfSet: false) as? NSColor ?? .white
                            let attributes: [NSAttributedString.Key: Any] = [
                                .foregroundColor: color,
                                .font: NSFont(name: myFont, size: CGFloat(mySize)) ?? NSFont.systemFont(ofSize: CGFloat(mySize)),
                                .paragraphStyle: theParagraphStyle,
                            ]
                            (plainText as NSString).draw(in: frameRect, withAttributes: attributes)
                        } else if let attrText = textEntry as? NSAttributedString {
                            attrText.draw(in: frameRect)
                        }
                        self.elementBounds.add([
                            "index": NSNumber(value: idx),
                            "frame": NSValue(rect: frameRect)
                        ])
                    // CANVAS (VIEW)
                    } else if elementType == "canvas" {
                        if let externalView = self.getElementValue(for: "canvas", atIndex: UInt(idx), onlyIfSet: false) as? NSView {
                            externalView.needsDisplay = true
                            if externalView.isHidden { externalView.isHidden = false }
                            if let alpha = self.getElementValue(for: "canvasAlpha", atIndex: UInt(idx), onlyIfSet: true) as? NSNumber {
                                externalView.alphaValue = CGFloat(alpha.doubleValue)
                            }
                            externalView.frame = frameRect
                            self.elementBounds.add([
                                "index": NSNumber(value: idx),
                                "frame": NSValue(rect: frameRect)
                            ])
                        }
                    // RESETCLIP
                    } else if elementType == "resetClip" {
                        gc.restoreGraphicsState()
                        wasClippingChanged = true
                        if clippingModified {
                            gc.restoreGraphicsState()
                            clippingModified = false
                        } else {
                            LuaSkin.skin(with: nil).logWarn("\(canvas_USERDATA_TAG):drawRect - un-nested resetClip at index \(idx + 1)")
                        }
                    } else {
                        LuaSkin.skin(with: nil).logWarn("\(canvas_USERDATA_TAG):drawRect - unrecognized type \(elementType) at index \(idx + 1)")
                    }
                }

                // Render Logic
                if let path = elementPath {
                    if let miterLimit = self.getElementValue(for: "miterLimit", atIndex: UInt(idx), onlyIfSet: true) as? NSNumber {
                        path.miterLimit = CGFloat(miterLimit.doubleValue)
                    }
                    if let flatness = self.getElementValue(for: "flatness", atIndex: UInt(idx), onlyIfSet: true) as? NSNumber {
                        path.flatness = CGFloat(flatness.doubleValue)
                    }
                    var currentPath = path
                    if (self.getElementValue(for: "flattenPath", atIndex: UInt(idx)) as? NSNumber)?.boolValue == true {
                        currentPath = currentPath.flattened
                    }
                    if (self.getElementValue(for: "reversePath", atIndex: UInt(idx)) as? NSNumber)?.boolValue == true {
                        currentPath = currentPath.reversed
                    }
                    if let windingRule = self.getElementValue(for: "windingRule", atIndex: UInt(idx), onlyIfSet: true) as? String {
                        currentPath.windingRule = NSBezierPath.WindingRule(rawValue: WINDING_RULES[windingRule]?.uintValue ?? 0) ?? .nonZero
                    }

                    if renderPath != nil {
                        renderPath!.append(currentPath)
                    } else {
                        renderPath = currentPath
                    }

                    if action == "clip" {
                        gc.restoreGraphicsState()
                        wasClippingChanged = true
                        if !clippingModified {
                            gc.saveGraphicsState()
                            clippingModified = true
                        }
                        renderPath!.addClip()
                        renderPath = nil

                    } else if action == "fill" || action == "stroke" || action == "strokeAndFill" {
                        let clipToPath = (self.getElementValue(for: "clipToPath", atIndex: UInt(idx)) as? NSNumber)?.boolValue ?? false
                        if CLOSED.contains(elementType) && clipToPath {
                            gc.saveGraphicsState()
                            renderPath!.addClip()
                        }

                        if elementType != "points" && (action == "fill" || action == "strokeAndFill") {
                            let fillGradient = self.getElementValue(for: "fillGradient", atIndex: UInt(idx)) as? String ?? "none"
                            if fillGradient != "none" && !renderPath!.isEmpty {
                                let gradientColors = self.getElementValue(for: "fillGradientColors", atIndex: UInt(idx)) as? [NSColor] ?? [.white, .black]
                                let gradient = NSGradient(colors: gradientColors)
                                if fillGradient == "linear" {
                                    let angle = (self.getElementValue(for: "fillGradientAngle", atIndex: UInt(idx)) as? NSNumber)?.doubleValue ?? 0
                                    gradient?.draw(in: renderPath!, angle: CGFloat(angle))
                                } else if fillGradient == "radial" {
                                    let centerPoint = self.getElementValue(for: "fillGradientCenter", atIndex: UInt(idx)) as? NSDictionary ?? [:]
                                    gradient?.draw(in: renderPath!, relativeCenterPosition: NSMakePoint(
                                        CGFloat((centerPoint["x"] as? NSNumber)?.doubleValue ?? 0),
                                        CGFloat((centerPoint["y"] as? NSNumber)?.doubleValue ?? 0)))
                                }
                            } else {
                                renderPath!.fill()
                            }
                        }

                        if action == "stroke" || action == "strokeAndFill" {
                            if let strokeWidth = self.getElementValue(for: "strokeWidth", atIndex: UInt(idx), onlyIfSet: true) as? NSNumber {
                                renderPath!.lineWidth = CGFloat(strokeWidth.doubleValue)
                            }
                            if let lineJoinStyle = self.getElementValue(for: "strokeJoinStyle", atIndex: UInt(idx), onlyIfSet: true) as? String {
                                renderPath!.lineJoinStyle = NSBezierPath.LineJoinStyle(rawValue: STROKE_JOIN_STYLES[lineJoinStyle]?.uintValue ?? 0) ?? .miter
                            }
                            if let lineCapStyle = self.getElementValue(for: "strokeCapStyle", atIndex: UInt(idx), onlyIfSet: true) as? String {
                                renderPath!.lineCapStyle = NSBezierPath.LineCapStyle(rawValue: STROKE_CAP_STYLES[lineCapStyle]?.uintValue ?? 0) ?? .butt
                            }
                            if let strokeDashes = self.getElementValue(for: "strokeDashPattern", atIndex: UInt(idx)) as? [NSNumber], strokeDashes.count > 0 {
                                let phase = (self.getElementValue(for: "strokeDashPhase", atIndex: UInt(idx)) as? NSNumber)?.doubleValue ?? 0
                                var pattern = strokeDashes.map { CGFloat($0.doubleValue) }
                                renderPath!.setLineDash(&pattern, count: pattern.count, phase: CGFloat(phase))
                            }
                            renderPath!.stroke()
                        }

                        if CLOSED.contains(elementType) && clipToPath {
                            gc.restoreGraphicsState()
                        }

                        if (self.getElementValue(for: "trackMouseByBounds", atIndex: UInt(idx)) as? NSNumber)?.boolValue == true {
                            var objectBounds = NSZeroRect
                            if !renderPath!.isEmpty { objectBounds = renderPath!.bounds }
                            self.elementBounds.add([
                                "index": NSNumber(value: idx),
                                "frame": NSValue(rect: objectBounds),
                            ])
                        } else {
                            self.elementBounds.add([
                                "index": NSNumber(value: idx),
                                "path": renderPath!,
                            ])
                        }
                        renderPath = nil

                    } else if action != "build" {
                        LuaSkin.skin(with: nil).logWarn("\(canvas_USERDATA_TAG):drawRect - unrecognized action \(action) at index \(idx + 1)")
                    }
                }

                if !wasClippingChanged { gc.restoreGraphicsState() }

                if UInt(idx) == previousTrackedRealIndex {
                    self.previousTrackedIndex = UInt(self.elementBounds.count - 1)
                }
            } else {
                // skip action -- hide canvas views
                if elementType == "canvas" {
                    if let externalView = self.getElementValue(for: "canvas", atIndex: UInt(idx), onlyIfSet: false) as? NSView {
                        if !externalView.isHidden { externalView.isHidden = true }
                    }
                }
            }
        }

        if clippingModified { gc.restoreGraphicsState() }

        mouseTracking = needMouseTracking
        gc.restoreGraphicsState()
    }

    // MARK: - View Animation Methods

    func fadeIn(_ fadeTime: TimeInterval) {
        let alphaSetting = self.alphaValue
        self.alphaValue = 0.0
        self.isHidden = false
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = fadeTime
        self.animator().alphaValue = alphaSetting
        NSAnimationContext.endGrouping()
    }

    func fadeOut(_ fadeTime: TimeInterval, andDelete deleteView: Bool, withState L: UnsafeMutablePointer<lua_State>!) {
        if selfRef != LUA_NOREF { return } // already in a fade
        lua_pushany(L, self)
        selfRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

        let alphaSetting = self.alphaValue
        NSAnimationContext.beginGrouping()
        weak var bself = self
        NSAnimationContext.current.duration = fadeTime
        NSAnimationContext.current.completionHandler = {
            guard let mySelf = bself else { return }
            let bL = LuaSkin.skin(with: nil).l!
            luaL_unref(bL, LUA_REGISTRYINDEX_VALUE, mySelf.selfRef)
            mySelf.selfRef = LUA_NOREF

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

    func draggingCallback(_ message: String, with sender: NSDraggingInfo?) -> Bool {
        var isAllGood = false
        guard draggingCallbackRef != LUA_NOREF else { return isAllGood }

        let skin = LuaSkin.skin(with: nil)
        let L = LuaSkin.skin(with: nil).l!
        var argCount: Int32 = 2
        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(draggingCallbackRef))
        lua_pushany(L, self)
        lua_pushany(L, message as NSString)

        if let sender = sender {
            lua_newtable(L)
            let pasteboard = sender.draggingPasteboard
            lua_pushany(L, pasteboard.name.rawValue as NSString)
            lua_setfield(L, -2, "pasteboard")

            lua_pushinteger(L, lua_Integer(sender.draggingSequenceNumber))
            lua_setfield(L, -2, "sequence")

            lua_pushNSPoint(L, sender.draggingLocation)
            lua_setfield(L, -2, "mouse")

            let operation = sender.draggingSourceOperationMask
            lua_newtable(L)
            if operation == [] {
                lua_pushstring(L, "none"); lua_rawseti(L, -2, luaL_len(L, -2) + 1)
            } else {
                if operation.contains(.copy)    { lua_pushstring(L, "copy");    lua_rawseti(L, -2, luaL_len(L, -2) + 1) }
                if operation.contains(.link)    { lua_pushstring(L, "link");    lua_rawseti(L, -2, luaL_len(L, -2) + 1) }
                if operation.contains(.generic) { lua_pushstring(L, "generic"); lua_rawseti(L, -2, luaL_len(L, -2) + 1) }
                if operation.contains(.private) { lua_pushstring(L, "private"); lua_rawseti(L, -2, luaL_len(L, -2) + 1) }
                if operation.contains(.move)    { lua_pushstring(L, "move");    lua_rawseti(L, -2, luaL_len(L, -2) + 1) }
                if operation.contains(.delete)  { lua_pushstring(L, "delete");  lua_rawseti(L, -2, luaL_len(L, -2) + 1) }
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
        return draggingCallback("enter", with: sender) ? .generic : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        _ = draggingCallback("exit", with: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return draggingCallback("receive", with: sender)
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

