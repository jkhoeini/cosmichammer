import Cocoa
import LuaSkin

// MARK: - Module Functions

/// hs.canvas.useCustomAccessibilitySubrole([state]) -> boolean
/// Function
/// Get or set whether or not canvas objects use a custom accessibility subrole for the containing system window.
func canvas_useCustomAccessibilitySubrole(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)

    if lua_gettop(L) == 1 {
        canvas_defaultCustomSubRole = lua_toboolean(L, 1) != 0
    }
    lua_pushboolean(L, canvas_defaultCustomSubRole ? 1 : 0)
    return 1
}

/// hs.canvas.new(rect) -> canvasObject
/// Constructor
/// Create a new canvas object at the specified coordinates
func canvas_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TTABLE, LS_TBREAK)

    let canvasWindow = HSCanvasWindow(contentRect: skin.tableToRect(at: 1),
                                       styleMask: .borderless,
                                       backing: .buffered,
                                       defer: true)
    let canvasView = HSCanvasView(frame: canvasWindow.contentView!.bounds)
    canvasView.wrapperWindow = canvasWindow
    canvasWindow.contentView = canvasView

    skin.pushNSObject(canvasView)
    return 1
}

/// hs.canvas.elementSpec() -> table
/// Function
/// Returns the list of attributes and their specifications that are recognized for canvas elements by this module.
func dumpLanguageDictionary(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)
    skin.pushNSObject(canvas_languageDictionary, withOptions: LS_NSConversionOptions.nsDescribeUnknownTypes.rawValue)
    return 1
}

/// hs.canvas.defaultTextStyle() -> `hs.styledtext` attributes table
/// Function
/// Returns a table containing the default font, size, color, and paragraphStyle used by `hs.canvas` for text drawing objects.
func default_textAttributes(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)
    lua_newtable(L)
    if let fontName = (canvas_languageDictionary["textFont"] as? NSDictionary)?["default"] as? String {
        let size = ((canvas_languageDictionary["textSize"] as? NSDictionary)?["default"] as? NSNumber)?.doubleValue ?? 27.0
        skin.pushNSObject(NSFont(name: fontName, size: CGFloat(size)))
        lua_setfield(L, -2, "font")
        skin.pushNSObject((canvas_languageDictionary["textColor"] as? NSDictionary)?["default"])
        lua_setfield(L, -2, "color")
        skin.pushNSObject(NSParagraphStyle.default)
        lua_setfield(L, -2, "paragraphStyle")
    } else {
        return luaL_error(L, "\(canvas_USERDATA_TAG):unable to get default font name from element language dictionary")
    }
    return 1
}


// MARK: - Module Methods

/// hs.canvas:draggingCallback(fn) -> canvasObject
func canvas_draggingCallback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG, LS_TFUNCTION | LS_TNIL, LS_TBREAK)
    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView

    canvasView.draggingCallbackRef = skin.luaUnref(canvas_refTable, ref: canvasView.draggingCallbackRef)
    canvasView.unregisterDraggedTypes()
    if skin.luaType(at: 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        canvasView.draggingCallbackRef = skin.luaRef(canvas_refTable)
        canvasView.registerForDraggedTypes([.fileURL])
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.canvas:_accessibilitySubrole([subrole]) -> canvasObject | current value
func canvas_accessibilitySubrole(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG, LS_TSTRING | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)
    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    let canvasWindow = canvasView.window as? HSCanvasWindow

    if lua_gettop(L) == 1 {
        skin.pushNSObject(canvasWindow?.subroleOverride as NSString?)
    } else {
        canvasWindow?.subroleOverride = lua_isstring(L, 2) != 0 ? (skin.toNSObject(atIndex: 2) as? String) : nil
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.canvas:show([fadeInTime]) -> canvasObject
func canvas_show(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG,
                   LS_TNUMBER | LS_TOPTIONAL,
                   LS_TBREAK)

    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView

    if lua_gettop(L) == 1 {
        if canvas_parentIsWindow(canvasView) {
            (canvasView.window as? HSCanvasWindow)?.makeKeyAndOrderFront(nil)
        } else {
            canvasView.isHidden = false
        }
    } else {
        if canvas_parentIsWindow(canvasView) {
            (canvasView.window as? HSCanvasWindow)?.fadeIn(lua_tonumber(L, 2))
        } else {
            canvasView.fadeIn(lua_tonumber(L, 2))
        }
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.canvas:hide([fadeOutTime]) -> canvasObject
func canvas_hide(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG,
                   LS_TNUMBER | LS_TOPTIONAL,
                   LS_TBREAK)

    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    let canvasWindow = canvasView.window as? HSCanvasWindow

    if lua_gettop(L) == 1 {
        if canvas_parentIsWindow(canvasView) {
            canvasWindow?.orderOut(nil)
        } else {
            canvasView.isHidden = true
        }
    } else {
        if canvas_parentIsWindow(canvasView) {
            canvasWindow?.fadeOut(lua_tonumber(L, 2), andDelete: false, withState: L)
        } else {
            canvasView.fadeOut(lua_tonumber(L, 2), andDelete: false, withState: L)
        }
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.canvas:mouseCallback(mouseCallbackFn) -> canvasObject
func canvas_mouseCallback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG,
                   LS_TFUNCTION | LS_TNIL,
                   LS_TBREAK)

    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    let canvasWindow = canvasView.wrapperWindow

    canvasView.mouseCallbackRef = skin.luaUnref(canvas_refTable, ref: canvasView.mouseCallbackRef)
    canvasView.previousTrackedIndex = UInt(NSNotFound)
    canvasWindow?.ignoresMouseEvents = true

    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        canvasView.mouseCallbackRef = skin.luaRef(canvas_refTable)
        canvasWindow?.ignoresMouseEvents = false
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.canvas:clickActivating([flag]) -> canvasObject | currentValue
func canvas_clickActivating(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG,
                   LS_TBOOLEAN | LS_TOPTIONAL,
                   LS_TBREAK)

    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    let canvasWindow = canvasView.wrapperWindow!

    if lua_type(L, 2) != LUA_TNONE {
        if lua_toboolean(L, 2) != 0 {
            canvasWindow.styleMask.remove(.nonactivatingPanel)
        } else {
            canvasWindow.styleMask.insert(.nonactivatingPanel)
        }
        lua_pushvalue(L, 1)
    } else {
        lua_pushboolean(L, !canvasWindow.styleMask.contains(.nonactivatingPanel) ? 1 : 0)
    }

    return 1
}

/// hs.canvas:canvasMouseEvents([down], [up], [enterExit], [move]) -> canvasObject | current values
func canvas_canvasMouseEvents(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG,
                   LS_TBOOLEAN | LS_TNIL | LS_TOPTIONAL,
                   LS_TBOOLEAN | LS_TNIL | LS_TOPTIONAL,
                   LS_TBOOLEAN | LS_TNIL | LS_TOPTIONAL,
                   LS_TBOOLEAN | LS_TNIL | LS_TOPTIONAL,
                   LS_TBREAK)

    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView

    if lua_gettop(L) == 1 {
        lua_pushboolean(L, canvasView.canvasMouseDown ? 1 : 0)
        lua_pushboolean(L, canvasView.canvasMouseUp ? 1 : 0)
        lua_pushboolean(L, canvasView.canvasMouseEnterExit ? 1 : 0)
        lua_pushboolean(L, canvasView.canvasMouseMove ? 1 : 0)
        return 4
    } else {
        if lua_type(L, 2) == LUA_TBOOLEAN { canvasView.canvasMouseDown      = lua_toboolean(L, 2) != 0 }
        if lua_type(L, 3) == LUA_TBOOLEAN { canvasView.canvasMouseUp        = lua_toboolean(L, 3) != 0 }
        if lua_type(L, 4) == LUA_TBOOLEAN { canvasView.canvasMouseEnterExit = lua_toboolean(L, 4) != 0 }
        if lua_type(L, 5) == LUA_TBOOLEAN { canvasView.canvasMouseMove      = lua_toboolean(L, 5) != 0 }

        lua_pushvalue(L, 1)
        return 1
    }
}

/// hs.canvas:topLeft([point]) -> canvasObject | currentValue
func canvas_topLeft(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG,
                   LS_TTABLE | LS_TOPTIONAL,
                   LS_TBREAK)

    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    if canvas_parentIsWindow(canvasView) {
        let canvasWindow = canvasView.window as! HSCanvasWindow
        let oldFrame = canvas_RectWithFlippedYCoordinate(canvasWindow.frame)

        if lua_gettop(L) == 1 {
            skin.pushNSPoint(oldFrame.origin)
        } else {
            let newCoord = skin.tableToPoint(at: 2)
            let newFrame = canvas_RectWithFlippedYCoordinate(NSMakeRect(newCoord.x, newCoord.y, oldFrame.size.width, oldFrame.size.height))
            canvasWindow.setFrame(newFrame, display: true, animate: false)
            lua_pushvalue(L, 1)
        }
    } else {
        return luaL_argerror(L, 1, "method unavailable for canvas as a subview")
    }
    return 1
}

/// hs.canvas:imageFromCanvas() -> hs.image object
func canvas_canvasAsImage(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG, LS_TBREAK)

    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    let image = canvasView.imageWithSubviews()
    skin.pushNSObject(image)
    return 1
}

/// hs.canvas:size([size]) -> canvasObject | currentValue
func canvas_size(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG,
                   LS_TTABLE | LS_TOPTIONAL,
                   LS_TBREAK)

    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    if canvas_parentIsWindow(canvasView) {
        let canvasWindow = canvasView.window as! HSCanvasWindow
        let oldFrame = canvasWindow.frame

        if lua_gettop(L) == 1 {
            skin.pushNSSize(oldFrame.size)
        } else {
            let newSize = skin.tableToSize(at: 2)
            let newFrame = NSMakeRect(oldFrame.origin.x,
                                      oldFrame.origin.y + oldFrame.size.height - newSize.height,
                                      newSize.width,
                                      newSize.height)
            let xFactor = newFrame.size.width / oldFrame.size.width
            let yFactor = newFrame.size.height / oldFrame.size.height

            for i in 0..<canvasView.elementList.count {
                let absPos = canvasView.getElementValue(for: "absolutePosition", atIndex: UInt(i)) as? NSNumber
                let absSiz = canvasView.getElementValue(for: "absoluteSize", atIndex: UInt(i)) as? NSNumber
                if let absPos = absPos, let absSiz = absSiz {
                    let absolutePosition = absPos.boolValue
                    let absoluteSize = absSiz.boolValue
                    guard let attributeDefinition = canvasView.elementList[i] as? NSMutableDictionary else { continue }

                    if !absolutePosition {
                        for (key, val) in attributeDefinition {
                            guard let keyName = key as? String, let keyValue = val as? NSMutableDictionary else { continue }
                            if keyName == "center" || keyName == "frame" {
                                if let x = keyValue["x"] as? NSNumber { keyValue["x"] = NSNumber(value: x.doubleValue * xFactor) }
                                if let y = keyValue["y"] as? NSNumber { keyValue["y"] = NSNumber(value: y.doubleValue * yFactor) }
                            } else if keyName == "coordinates", let coords = keyValue as? NSMutableArray {
                                for subItem in coords {
                                    guard let sub = subItem as? NSMutableDictionary else { continue }
                                    for field in ["x", "y", "c1x", "c1y", "c2x", "c2y"] {
                                        if let num = sub[field] as? NSNumber {
                                            let factor = field.hasSuffix("x") ? xFactor : yFactor
                                            sub[field] = NSNumber(value: num.doubleValue * Double(factor))
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if !absoluteSize {
                        for (key, val) in attributeDefinition {
                            guard let keyName = key as? String else { continue }
                            if keyName == "frame", let keyValue = val as? NSMutableDictionary {
                                if let h = keyValue["h"] as? NSNumber { keyValue["h"] = NSNumber(value: h.doubleValue * Double(yFactor)) }
                                if let w = keyValue["w"] as? NSNumber { keyValue["w"] = NSNumber(value: w.doubleValue * Double(xFactor)) }
                            } else if keyName == "radius", let num = val as? NSNumber {
                                attributeDefinition[keyName] = NSNumber(value: num.doubleValue * Double(xFactor))
                            }
                        }
                    }
                } else {
                    skin.logError("\(canvas_USERDATA_TAG):unable to get absolute positioning info for index position \(i + 1)")
                }
            }
            canvasWindow.setFrame(newFrame, display: true, animate: false)
            lua_pushvalue(L, 1)
        }
    } else {
        return luaL_argerror(L, 1, "method unavailable for canvas as a subview")
    }
    return 1
}

/// hs.canvas:alpha([alpha]) -> canvasObject | currentValue
func canvas_alpha(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG,
                   LS_TNUMBER | LS_TOPTIONAL,
                   LS_TBREAK)

    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    let canvasWindow = canvasView.window as? HSCanvasWindow

    if lua_gettop(L) == 1 {
        if canvas_parentIsWindow(canvasView) {
            lua_pushnumber(L, lua_Number(canvasWindow!.alphaValue))
        } else {
            lua_pushnumber(L, lua_Number(canvasView.alphaValue))
        }
    } else {
        let newLevel = CGFloat(luaL_checknumber(L, 2))
        let clamped = max(0.0, min(1.0, newLevel))
        if canvas_parentIsWindow(canvasView) {
            canvasWindow!.alphaValue = clamped
        } else {
            canvasView.alphaValue = clamped
        }
        lua_pushvalue(L, 1)
    }

    return 1
}

/// hs.canvas:orderAbove([canvas2]) -> canvasObject
func canvas_orderAbove(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    return canvas_orderHelper(L, mode: .above)
}

/// hs.canvas:orderBelow([canvas2]) -> canvasObject
func canvas_orderBelow(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    return canvas_orderHelper(L, mode: .below)
}

/// hs.canvas:level([level]) -> canvasObject | currentValue
func canvas_level(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG,
                   LS_TNUMBER | LS_TSTRING | LS_TOPTIONAL,
                   LS_TBREAK)

    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    if canvas_parentIsWindow(canvasView) {
        let canvasWindow = canvasView.window!

        if lua_gettop(L) == 1 {
            lua_pushinteger(L, lua_Integer(canvasWindow.level.rawValue))
        } else {
            var targetLevel: lua_Integer
            if lua_type(L, 2) == LUA_TNUMBER {
                skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG,
                               LS_TNUMBER | LS_TINTEGER,
                               LS_TBREAK)
                targetLevel = lua_tointeger(L, 2)
            } else {
                canvas_cg_windowLevels(L)
                if lua_getfield(L, -1, (skin.toNSObject(atIndex: 2) as! NSString).utf8String) == LUA_TNUMBER {
                    targetLevel = lua_tointeger(L, -1)
                    lua_pop(L, 2)
                } else {
                    lua_pop(L, 2)
                    return luaL_error(L, "unrecognized window level: \(skin.toNSObject(atIndex: 2) ?? "unknown")")
                }
            }

            let minLevel = lua_Integer(CGWindowLevelForKey(.minimumWindow))
            let maxLevel = lua_Integer(CGWindowLevelForKey(.maximumWindow))
            targetLevel = max(minLevel, min(maxLevel, targetLevel))
            canvasWindow.level = NSWindow.Level(rawValue: Int(targetLevel))
            lua_pushvalue(L, 1)
        }
    } else {
        return luaL_argerror(L, 1, "method unavailable for canvas as a subview")
    }

    return 1
}

/// hs.canvas:wantsLayer([flag]) -> canvasObject | currentValue
func canvas_wantsLayer(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG,
                   LS_TBOOLEAN | LS_TOPTIONAL,
                   LS_TBREAK)

    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView

    if lua_type(L, 2) != LUA_TNONE {
        canvasView.wantsLayer = lua_toboolean(L, 2) != 0
        canvasView.needsDisplay = true
        lua_pushvalue(L, 1)
    } else {
        lua_pushboolean(L, canvasView.wantsLayer ? 1 : 0)
    }

    return 1
}

func canvas_behavior(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG,
                   LS_TNUMBER | LS_TOPTIONAL,
                   LS_TBREAK)

    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    if canvas_parentIsWindow(canvasView) {
        let canvasWindow = canvasView.window!

        if lua_gettop(L) == 1 {
            lua_pushinteger(L, lua_Integer(canvasWindow.collectionBehavior.rawValue))
        } else {
            skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG,
                           LS_TNUMBER | LS_TINTEGER,
                           LS_TBREAK)
            let newLevel = lua_tointeger(L, 2)
            canvasWindow.collectionBehavior = NSWindow.CollectionBehavior(rawValue: UInt(newLevel))
            lua_pushvalue(L, 1)
        }
    } else {
        return luaL_argerror(L, 1, "method unavailable for canvas as a subview")
    }

    return 1
}

/// hs.canvas:delete([fadeOutTime]) -> none
func canvas_delete(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG,
                   LS_TNUMBER | LS_TOPTIONAL,
                   LS_TBREAK)

    canvas_hide(L)
    lua_pop(L, 1) // remove userdata pushed by hide

    lua_pushnil(L)
    return 1
}

/// hs.canvas:isShowing() -> boolean
func canvas_isShowing(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG, LS_TBREAK)

    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    let canvasWindow = canvasView.window as? HSCanvasWindow
    if canvas_parentIsWindow(canvasView) {
        lua_pushboolean(L, (canvasWindow?.isVisible ?? false) ? 1 : 0)
    } else {
        lua_pushboolean(L, (!canvasView.isHidden && (canvasWindow?.isVisible ?? false)) ? 1 : 0)
    }
    return 1
}

/// hs.canvas:isOccluded() -> boolean
func canvas_isOccluded(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG, LS_TBREAK)

    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    let canvasWindow = canvasView.window as? HSCanvasWindow
    if canvas_parentIsWindow(canvasView) {
        let visible = canvasWindow?.occlusionState.contains(.visible) ?? false
        lua_pushboolean(L, visible ? 0 : 1)
    } else {
        let visible = canvasWindow?.occlusionState.contains(.visible) ?? false
        lua_pushboolean(L, (canvasView.isHidden || !visible) ? 1 : 0)
    }
    return 1
}

/// hs.canvas:transformation([matrix]) -> canvasObject | current value
func canvas_canvasTransformation(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG, LS_TTABLE | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)
    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView

    if lua_gettop(L) == 1 {
        skin.pushNSObject(canvasView.canvasTransform)
    } else {
        var transform = NSAffineTransform()
        if lua_type(L, 2) == LUA_TTABLE {
            transform = skin.luaObject(at:2, toClass: "NSAffineTransform") as! NSAffineTransform
        }
        canvasView.canvasTransform = transform
        canvasView.needsDisplay = true
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.canvas:elementCount() -> integer
func canvas_elementCount(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG, LS_TBREAK)
    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    lua_pushinteger(L, lua_Integer(canvasView.elementList.count))
    return 1
}

/// hs.canvas:minimumTextSize([index], text) -> table
func canvas_getTextElementSize(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG, LS_TBREAK | LS_TVARARG)
    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    var textIndex: Int32 = 2
    var elementIndex = UInt(NSNotFound)

    if lua_gettop(L) == 3 {
        elementIndex = UInt(lua_tointeger(L, 2)) - 1
        textIndex = 3
    }

    let theSize: NSSize
    if lua_type(L, textIndex) == LUA_TSTRING {
        let theText = skin.toNSObject(atIndex: textIndex) as? String ?? ""
        let myFont: String
        let mySize: NSNumber
        let alignment: String
        let wrap: String
        let color: NSColor

        if elementIndex == UInt(NSNotFound) {
            myFont = canvasView.getDefaultValue(for: "textFont", onlyIfSet: false) as? String ?? ""
            mySize = canvasView.getDefaultValue(for: "textSize", onlyIfSet: false) as? NSNumber ?? NSNumber(value: 27.0)
            alignment = canvasView.getDefaultValue(for: "textAlignment", onlyIfSet: false) as? String ?? "natural"
            wrap = canvasView.getDefaultValue(for: "textLineBreak", onlyIfSet: false) as? String ?? "wordWrap"
            color = canvasView.getDefaultValue(for: "textColor", onlyIfSet: false) as? NSColor ?? .white
        } else {
            myFont = canvasView.getElementValue(for: "textFont", atIndex: elementIndex) as? String ?? ""
            mySize = canvasView.getElementValue(for: "textSize", atIndex: elementIndex) as? NSNumber ?? NSNumber(value: 27.0)
            alignment = canvasView.getElementValue(for: "textAlignment", atIndex: elementIndex) as? String ?? "natural"
            wrap = canvasView.getElementValue(for: "textLineBreak", atIndex: elementIndex) as? String ?? "wordWrap"
            color = canvasView.getElementValue(for: "textColor", atIndex: elementIndex) as? NSColor ?? .white
        }

        let paragraphStyle = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
        paragraphStyle.alignment = NSTextAlignment(rawValue: TEXTALIGNMENT_TYPES[alignment]?.intValue ?? 0) ?? .natural
        paragraphStyle.lineBreakMode = NSLineBreakMode(rawValue: UInt(TEXTWRAP_TYPES[wrap]?.intValue ?? 0)) ?? .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont(name: myFont, size: CGFloat(mySize.doubleValue)) ?? NSFont.systemFont(ofSize: CGFloat(mySize.doubleValue)),
            .paragraphStyle: paragraphStyle,
        ]
        theSize = (theText as NSString).size(withAttributes: attributes)
    } else {
        let attrStr = skin.toNSObject(atIndex: textIndex) as? NSAttributedString ?? NSAttributedString()
        theSize = attrStr.size()
    }
    skin.pushNSSize(theSize)
    return 1
}

/// hs.canvas:canvasDefaultFor(keyName, [newValue]) -> canvasObject | currentValue
func canvas_canvasDefaultFor(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG,
                   LS_TSTRING,
                   LS_TANY | LS_TOPTIONAL,
                   LS_TBREAK)

    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    let keyName = skin.toNSObject(atIndex: 2) as! String

    guard canvas_languageDictionary[keyName] != nil else {
        return luaL_argerror(L, 2, "attribute name \(keyName) unrecognized")
    }

    guard let attributeDefault = canvasView.getDefaultValue(for: keyName, onlyIfSet: false) else {
        return luaL_argerror(L, 2, "attribute \(keyName) has no default value")
    }

    if lua_gettop(L) == 2 {
        skin.pushNSObject(attributeDefault as AnyObject)
    } else {
        let keyValue = skin.toNSObject(atIndex: 3, withOptions: .nsRawTables)
        let result = AttributeValidity(rawValue: canvasView.setDefault(for: keyName, to: keyValue, withState: L)) ?? .invalid
        switch result {
        case .valid, .nulling:
            break
        case .invalid:
            if let langEntry = canvas_languageDictionary[keyName] as? NSDictionary,
               (langEntry["nullable"] as? NSNumber)?.boolValue == true {
                return luaL_argerror(L, 3, "invalid argument type for \(keyName) specified")
            } else {
                return luaL_argerror(L, 2, "attribute default for \(keyName) cannot be changed")
            }
        }
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.canvas:insertElement(elementTable, [index]) -> canvasObject
func canvas_insertElementAtIndex(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG,
                   LS_TTABLE,
                   LS_TNUMBER | LS_TINTEGER | LS_TOPTIONAL,
                   LS_TBREAK)
    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    let elementCount = canvasView.elementList.count
    let tablePosition = (lua_gettop(L) == 3) ? Int(lua_tointeger(L, 3)) - 1 : elementCount

    guard tablePosition >= 0 && tablePosition <= elementCount else {
        return luaL_argerror(L, 3, "index \(tablePosition + 1) out of bounds")
    }

    guard let element = skin.toNSObject(atIndex: 2, withOptions: .nsRawTables) as? NSDictionary else {
        return luaL_argerror(L, 2, "invalid element definition; must contain key-value pairs")
    }

    guard let elementType = element["type"] as? String, ALL_TYPES.contains(elementType) else {
        return luaL_argerror(L, 2, "invalid type \(element["type"] ?? "nil"); must be one of \(ALL_TYPES.joined(separator: ", "))")
    }

    canvasView.elementList.insert(NSMutableDictionary(), at: tablePosition)
    element.enumerateKeysAndObjects { (keyName, keyValue, _) in
        if let key = keyName as? String, key != "type" {
            _ = canvasView.setElementValue(for: key, atIndex: UInt(tablePosition), to: keyValue, withState: L)
        }
    }
    _ = canvasView.setElementValue(for: "type", atIndex: UInt(tablePosition), to: elementType, withState: L)

    canvasView.needsDisplay = true
    lua_pushvalue(L, 1)
    return 1
}

/// hs.canvas:removeElement([index]) -> canvasObject
func canvas_removeElementAtIndex(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG,
                   LS_TNUMBER | LS_TINTEGER | LS_TOPTIONAL,
                   LS_TBREAK)
    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    let elementCount = canvasView.elementList.count
    let tablePosition = (lua_gettop(L) == 2) ? Int(lua_tointeger(L, 2)) - 1 : elementCount - 1

    guard tablePosition >= 0 && tablePosition < elementCount else {
        return luaL_argerror(L, 2, "index \(tablePosition + 1) out of bounds")
    }

    let realIndex = tablePosition
    if let elemDict = canvasView.elementList[realIndex] as? NSDictionary,
       let canvasSubview = elemDict["canvas"] as? NSView {
        canvasSubview.removeFromSuperview()
    }
    canvasView.elementList.removeObject(at: realIndex)

    canvasView.needsDisplay = true
    lua_pushvalue(L, 1)
    return 1
}

/// hs.canvas:elementAttribute(index, key, [value]) -> canvasObject | current value
func canvas_elementAttributeAtIndex(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG,
                   LS_TNUMBER | LS_TINTEGER,
                   LS_TSTRING,
                   LS_TANY | LS_TOPTIONAL,
                   LS_TBREAK)
    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    var keyName = skin.toNSObject(atIndex: 3) as! String

    let elementCount = canvasView.elementList.count
    let tablePosition = Int(lua_tointeger(L, 2)) - 1

    var resolvePercentages = false

    guard tablePosition >= 0 && tablePosition < elementCount else {
        return luaL_argerror(L, 2, "index \(tablePosition + 1) out of bounds")
    }

    if canvas_languageDictionary[keyName] == nil {
        if lua_gettop(L) == 3 {
            // check if keyname ends with _raw
            if keyName.hasSuffix("_raw") {
                let trimmedName = String(keyName.dropLast(4))
                if canvas_languageDictionary[trimmedName] != nil {
                    keyName = trimmedName
                    resolvePercentages = true
                }
            }
            if !resolvePercentages {
                lua_pushnil(L)
                return 1
            }
        } else {
            return luaL_argerror(L, 3, "attribute name \(keyName) unrecognized")
        }
    }

    if lua_gettop(L) == 3 {
        let value = canvasView.getElementValue(for: keyName, atIndex: UInt(tablePosition), resolvePercentages: resolvePercentages, onlyIfSet: false)
        skin.pushNSObject(value as AnyObject?)
    } else {
        let keyValue = skin.toNSObject(atIndex: 4, withOptions: .nsRawTables)
        let result = AttributeValidity(rawValue: canvasView.setElementValue(for: keyName, atIndex: UInt(tablePosition), to: keyValue, withState: L)) ?? .invalid
        switch result {
        case .valid, .nulling:
            lua_pushvalue(L, 1)
        case .invalid:
            return luaL_argerror(L, 4, "invalid argument type for \(keyName) specified")
        }
    }
    return 1
}

/// hs.canvas:elementKeys(index, [optional]) -> table
func canvas_elementKeysAtIndex(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG,
                   LS_TNUMBER | LS_TINTEGER,
                   LS_TBOOLEAN | LS_TOPTIONAL,
                   LS_TBREAK)
    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    let elementCount = canvasView.elementList.count
    let tablePosition = Int(lua_tointeger(L, 2)) - 1

    guard tablePosition >= 0 && tablePosition < elementCount else {
        return luaL_argerror(L, 2, "index \(tablePosition + 1) out of bounds")
    }

    let list = NSMutableSet(array: (canvasView.elementList[tablePosition] as! NSDictionary).allKeys)
    if lua_gettop(L) == 3 && lua_toboolean(L, 3) != 0 {
        let ourType = (canvasView.elementList[tablePosition] as! NSDictionary)["type"] as? String
        (canvas_languageDictionary as! [String: NSDictionary]).forEach { (keyName, keyValue) in
            if let optionalFor = keyValue["optionalFor"] as? [String], let t = ourType, optionalFor.contains(t) {
                list.add(keyName)
            }
        }
    }
    skin.pushNSObject(list)
    return 1
}

/// hs.canvas:canvasDefaults([module]) -> table
func canvas_canvasDefaults(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG,
                   LS_TBOOLEAN | LS_TOPTIONAL,
                   LS_TBREAK)
    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView

    if lua_gettop(L) == 2 && lua_toboolean(L, 2) != 0 {
        lua_newtable(L)
        for key in (canvas_languageDictionary as! [String: Any]).keys {
            if let keyValue = canvasView.getDefaultValue(for: key, onlyIfSet: false) {
                skin.pushNSObject(keyValue as AnyObject)
                lua_setfield(L, -2, key)
            }
        }
    } else {
        skin.pushNSObject(canvasView.canvasDefaults, withOptions: LS_NSConversionOptions.nsDescribeUnknownTypes.rawValue)
    }
    return 1
}

/// hs.canvas:canvasDefaultKeys([module]) -> table
func canvas_canvasDefaultKeys(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG,
                   LS_TBOOLEAN | LS_TOPTIONAL,
                   LS_TBREAK)
    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView

    let list = NSMutableSet(array: canvasView.canvasDefaults.allKeys)
    if lua_gettop(L) == 2 && lua_toboolean(L, 2) != 0 {
        (canvas_languageDictionary as! [String: NSDictionary]).forEach { (keyName, keyValue) in
            if keyValue["default"] != nil {
                list.add(keyName)
            }
        }
    }
    skin.pushNSObject(list)
    return 1
}

/// hs.canvas:canvasElements() -> table
func canvas_canvasElements(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG, LS_TBREAK)
    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    skin.pushNSObject(canvasView.elementList, withOptions: LS_NSConversionOptions.nsDescribeUnknownTypes.rawValue)
    return 1
}

/// hs.canvas:elementBounds(index) -> rectTable
func canvas_elementBoundsAtIndex(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG,
                   LS_TNUMBER | LS_TINTEGER,
                   LS_TBREAK)
    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView

    let elementCount = canvasView.elementList.count
    let tablePosition = Int(lua_tointeger(L, 2)) - 1

    guard tablePosition >= 0 && tablePosition < elementCount else {
        return luaL_argerror(L, 2, "index \(tablePosition + 1) out of bounds")
    }

    let idx = UInt(tablePosition)
    var boundingBox = NSZeroRect
    if let itemPath = canvasView.pathForElement(atIndex: idx) {
        if itemPath.isEmpty {
            boundingBox = NSZeroRect
        } else {
            boundingBox = itemPath.bounds
        }
    } else {
        let itemType = (canvasView.elementList[tablePosition] as! NSDictionary)["type"] as? String
        if itemType == "image" || itemType == "text" || itemType == "canvas" {
            let frame = canvasView.getElementValue(for: "frame", atIndex: idx, resolvePercentages: true) as? NSDictionary ?? [:]
            boundingBox = NSMakeRect(CGFloat((frame["x"] as? NSNumber)?.doubleValue ?? 0),
                                     CGFloat((frame["y"] as? NSNumber)?.doubleValue ?? 0),
                                     CGFloat((frame["w"] as? NSNumber)?.doubleValue ?? 0),
                                     CGFloat((frame["h"] as? NSNumber)?.doubleValue ?? 0))
        } else {
            lua_pushnil(L)
            return 1
        }
    }
    skin.pushNSRect(boundingBox)
    return 1
}

/// hs.canvas:assignElement(elementTable, [index]) -> canvasObject
func canvas_assignElementAtIndex(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG,
                   LS_TTABLE | LS_TNIL,
                   LS_TNUMBER | LS_TINTEGER | LS_TOPTIONAL,
                   LS_TBREAK)
    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView

    let elementCount = canvasView.elementList.count
    let tablePosition = (lua_gettop(L) == 3) ? Int(lua_tointeger(L, 3)) - 1 : elementCount

    guard tablePosition >= 0 && tablePosition <= elementCount else {
        return luaL_argerror(L, 3, "index \(tablePosition + 1) out of bounds")
    }

    if lua_isnil(L, 2) {
        if tablePosition == elementCount - 1 {
            canvasView.elementList.removeLastObject()
        } else {
            return luaL_argerror(L, 3, "nil only valid for final element")
        }
    } else {
        guard let element = skin.toNSObject(atIndex: 2, withOptions: .nsRawTables) as? NSDictionary else {
            return luaL_argerror(L, 2, "invalid element definition; must contain key-value pairs")
        }
        guard let elementType = element["type"] as? String, ALL_TYPES.contains(elementType) else {
            return luaL_argerror(L, 2, "invalid type \(element["type"] ?? "nil"); must be one of \(ALL_TYPES.joined(separator: ", "))")
        }

        let realIndex = tablePosition
        if realIndex < elementCount {
            if let canvasSubview = (canvasView.elementList[realIndex] as? NSDictionary)?["canvas"] as? NSView {
                canvasSubview.removeFromSuperview()
            }
            canvasView.elementList[realIndex] = NSMutableDictionary()
        } else {
            canvasView.elementList.add(NSMutableDictionary())
        }

        element.enumerateKeysAndObjects { (keyName, keyValue, _) in
            if let key = keyName as? String, key != "type" {
                _ = canvasView.setElementValue(for: key, atIndex: UInt(realIndex), to: keyValue, withState: L)
            }
        }
        _ = canvasView.setElementValue(for: "type", atIndex: UInt(realIndex), to: elementType, withState: L)
    }

    canvasView.needsDisplay = true
    lua_pushvalue(L, 1)
    return 1
}

