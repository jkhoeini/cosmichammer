import Cocoa
import LuaSkin

// MARK: - HSGifAnimator stub
// HSGifAnimator is defined in Canvas.h / imageAdditions.m (ObjC). Since this
// Swift file is compiled in the HSSwiftExtensions target without direct
// visibility of those ObjC headers, we provide a minimal Swift stand-in that
// mirrors the ObjC interface just enough for libcanvas.swift to compile.

@objc class HSGifAnimator: NSObject {
    @objc weak var animatingRepresentation: NSBitmapImageRep?
    @objc weak var inCanvas: HSCanvasView?
    @objc var isRunning: Bool = false

    @objc init(image: NSImage, forCanvas canvas: HSCanvasView) {
        self.inCanvas = canvas
        super.init()
        for case let rep as NSBitmapImageRep in image.representations {
            if (rep.value(forProperty: .frameCount) as? NSNumber)?.intValue ?? 0 > 1 {
                self.animatingRepresentation = rep
                break
            }
        }
    }

    @objc func startAnimating() {
        guard !isRunning, let rep = animatingRepresentation else { return }
        isRunning = true
        let frameCount = (rep.value(forProperty: .frameCount) as? NSNumber)?.intValue ?? 1
        guard frameCount > 1 else { return }
        advanceFrame(rep: rep, frameCount: frameCount)
    }

    @objc func stopAnimating() {
        isRunning = false
    }

    private func advanceFrame(rep: NSBitmapImageRep, frameCount: Int) {
        guard isRunning else { return }
        let current = (rep.value(forProperty: .currentFrame) as? NSNumber)?.intValue ?? 0
        let next = (current + 1) % frameCount
        rep.setProperty(.currentFrame, withValue: NSNumber(value: next))
        inCanvas?.needsDisplay = true
        let delay = (rep.value(forProperty: .currentFrameDuration) as? NSNumber)?.doubleValue ?? 0.1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.advanceFrame(rep: rep, frameCount: frameCount)
        }
    }
}

// #define VIEW_DEBUG

private let USERDATA_TAG = "hs.canvas"
private var refTable: LSRefTable = LUA_NOREF
private var defaultCustomSubRole: Bool = true

// Can't have "static" or "constant" dynamic NSObjects like NSArray, so define in lua_open
private var languageDictionary: NSDictionary!

private func get_objectFromUserdata<T>(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32, _ tag: UnsafePointer<CChar>) -> T {
    let ptr = luaL_checkudata(L, idx, tag)!
    return ptr.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee.assumingMemoryBound(to: T.self).pointee
}

private enum AttributeValidity: Int {
    case valid
    case nulling
    case invalid
}

// MARK: - Lookup dictionaries (bridged from Canvas.h macros)

let ALL_TYPES: [String] = ["arc", "circle", "ellipticalArc", "image", "oval", "points", "rectangle", "resetClip", "segments", "text", "canvas"]
let VISIBLE: [String] = ["arc", "circle", "ellipticalArc", "image", "oval", "points", "rectangle", "segments", "text", "canvas"]
let PRIMITIVES: [String] = ["arc", "circle", "ellipticalArc", "oval", "points", "rectangle", "segments"]
let CLOSED: [String] = ["arc", "circle", "ellipticalArc", "oval", "rectangle", "segments"]

let STROKE_JOIN_STYLES: [String: NSNumber] = [
    "miter": NSNumber(value: NSBezierPath.LineJoinStyle.miter.rawValue),
    "round": NSNumber(value: NSBezierPath.LineJoinStyle.bevel.rawValue),
    "bevel": NSNumber(value: NSBezierPath.LineJoinStyle.bevel.rawValue),
]

let STROKE_CAP_STYLES: [String: NSNumber] = [
    "butt":   NSNumber(value: NSBezierPath.LineCapStyle.butt.rawValue),
    "round":  NSNumber(value: NSBezierPath.LineCapStyle.round.rawValue),
    "square": NSNumber(value: NSBezierPath.LineCapStyle.square.rawValue),
]

let COMPOSITING_TYPES: [String: NSNumber] = [
    "clear":           NSNumber(value: NSCompositingOperation.clear.rawValue),
    "copy":            NSNumber(value: NSCompositingOperation.copy.rawValue),
    "sourceOver":      NSNumber(value: NSCompositingOperation.sourceOver.rawValue),
    "sourceIn":        NSNumber(value: NSCompositingOperation.sourceIn.rawValue),
    "sourceOut":       NSNumber(value: NSCompositingOperation.sourceOut.rawValue),
    "sourceAtop":      NSNumber(value: NSCompositingOperation.sourceAtop.rawValue),
    "destinationOver": NSNumber(value: NSCompositingOperation.destinationOver.rawValue),
    "destinationIn":   NSNumber(value: NSCompositingOperation.destinationIn.rawValue),
    "destinationOut":  NSNumber(value: NSCompositingOperation.destinationOut.rawValue),
    "destinationAtop": NSNumber(value: NSCompositingOperation.destinationAtop.rawValue),
    "XOR":             NSNumber(value: NSCompositingOperation.xor.rawValue),
    "plusDarker":      NSNumber(value: NSCompositingOperation.plusDarker.rawValue),
    "plusLighter":     NSNumber(value: NSCompositingOperation.plusLighter.rawValue),
]

let WINDING_RULES: [String: NSNumber] = [
    "evenOdd": NSNumber(value: NSBezierPath.WindingRule.evenOdd.rawValue),
    "nonZero": NSNumber(value: NSBezierPath.WindingRule.nonZero.rawValue),
]

let TEXTALIGNMENT_TYPES: [String: NSNumber] = [
    "left":      NSNumber(value: NSTextAlignment.left.rawValue),
    "right":     NSNumber(value: NSTextAlignment.right.rawValue),
    "center":    NSNumber(value: NSTextAlignment.center.rawValue),
    "justified": NSNumber(value: NSTextAlignment.justified.rawValue),
    "natural":   NSNumber(value: NSTextAlignment.natural.rawValue),
]

let TEXTWRAP_TYPES: [String: NSNumber] = [
    "wordWrap":       NSNumber(value: NSLineBreakMode.byWordWrapping.rawValue),
    "charWrap":       NSNumber(value: NSLineBreakMode.byCharWrapping.rawValue),
    "clip":           NSNumber(value: NSLineBreakMode.byClipping.rawValue),
    "truncateHead":   NSNumber(value: NSLineBreakMode.byTruncatingHead.rawValue),
    "truncateMiddle": NSNumber(value: NSLineBreakMode.byTruncatingMiddle.rawValue),
    "truncateTail":   NSNumber(value: NSLineBreakMode.byTruncatingTail.rawValue),
]

let IMAGEALIGNMENT_TYPES: [String: NSNumber] = [
    "center":      NSNumber(value: NSImageAlignment.alignCenter.rawValue),
    "bottom":      NSNumber(value: NSImageAlignment.alignBottom.rawValue),
    "bottomLeft":  NSNumber(value: NSImageAlignment.alignBottomLeft.rawValue),
    "bottomRight": NSNumber(value: NSImageAlignment.alignBottomRight.rawValue),
    "left":        NSNumber(value: NSImageAlignment.alignLeft.rawValue),
    "right":       NSNumber(value: NSImageAlignment.alignRight.rawValue),
    "top":         NSNumber(value: NSImageAlignment.alignTop.rawValue),
    "topLeft":     NSNumber(value: NSImageAlignment.alignTopLeft.rawValue),
    "topRight":    NSNumber(value: NSImageAlignment.alignTopRight.rawValue),
]

let IMAGESCALING_TYPES: [String: NSNumber] = [
    "none":                NSNumber(value: NSImageScaling.scaleNone.rawValue),
    "scaleToFit":          NSNumber(value: NSImageScaling.scaleAxesIndependently.rawValue),
    "scaleProportionally": NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
    "shrinkToFit":         NSNumber(value: NSImageScaling.scaleProportionallyDown.rawValue),
]

// MARK: - Support Functions and Classes

// cg_windowLevels is defined later in this file (MARK: - Module Constants)

private func parentIsWindow(_ theView: NSView) -> Bool {
    guard let owningWindow = theView.window else { return false }
    return owningWindow.contentView === theView
}

private func defineLanguageDictionary() -> NSDictionary {
    // the default shadow has no offset or blur radius, so lets setup one that is at least visible
    let defaultShadow = NSShadow()
    defaultShadow.shadowOffset = NSMakeSize(5.0, -5.0)
    defaultShadow.shadowBlurRadius = 5.0

    return [
        "action": [
            "class":       [NSString.self],
            "luaClass":    "string",
            "default":     "strokeAndFill",
            "values":      ["stroke", "fill", "strokeAndFill", "clip", "build", "skip"],
            "nullable":    NSNumber(value: true),
            "optionalFor": ALL_TYPES,
        ] as [String: Any],
        "absolutePosition": [
            "class":       [NSNumber.self],
            "luaClass":    "boolean",
            "objCType":    String(cString: NSNumber(value: true).objCType),
            "nullable":    NSNumber(value: true),
            "default":     NSNumber(value: true),
            "optionalFor": VISIBLE,
        ] as [String: Any],
        "absoluteSize": [
            "class":       [NSNumber.self],
            "luaClass":    "boolean",
            "objCType":    String(cString: NSNumber(value: true).objCType),
            "nullable":    NSNumber(value: true),
            "default":     NSNumber(value: true),
            "optionalFor": VISIBLE,
        ] as [String: Any],
        "antialias": [
            "class":       [NSNumber.self],
            "luaClass":    "boolean",
            "objCType":    String(cString: NSNumber(value: true).objCType),
            "nullable":    NSNumber(value: true),
            "default":     NSNumber(value: true),
            "optionalFor": VISIBLE,
        ] as [String: Any],
        "arcRadii": [
            "class":       [NSNumber.self],
            "luaClass":    "boolean",
            "objCType":    String(cString: NSNumber(value: true).objCType),
            "nullable":    NSNumber(value: true),
            "default":     NSNumber(value: true),
            "optionalFor": ["arc", "ellipticalArc"],
        ] as [String: Any],
        "arcClockwise": [
            "class":       [NSNumber.self],
            "luaClass":    "boolean",
            "objCType":    String(cString: NSNumber(value: true).objCType),
            "nullable":    NSNumber(value: true),
            "default":     NSNumber(value: true),
            "optionalFor": ["arc", "ellipticalArc"],
        ] as [String: Any],
        "clipToPath": [
            "class":       [NSNumber.self],
            "luaClass":    "boolean",
            "objCType":    String(cString: NSNumber(value: true).objCType),
            "nullable":    NSNumber(value: true),
            "default":     NSNumber(value: false),
            "optionalFor": CLOSED,
        ] as [String: Any],
        "compositeRule": [
            "class":       [NSString.self],
            "luaClass":    "string",
            "values":      Array(COMPOSITING_TYPES.keys),
            "nullable":    NSNumber(value: true),
            "default":     "sourceOver",
            "optionalFor": VISIBLE,
        ] as [String: Any],
        "center": [
            "class":       [NSDictionary.self],
            "luaClass":    "table",
            "keys":        [
                "x": ["class": [NSString.self, NSNumber.self], "luaClass": "number or string"],
                "y": ["class": [NSString.self, NSNumber.self], "luaClass": "number or string"],
            ],
            "default":     ["x": "50%", "y": "50%"],
            "nullable":    NSNumber(value: false),
            "requiredFor": ["circle", "arc"],
        ] as [String: Any],
        "closed": [
            "class":       [NSNumber.self],
            "luaClass":    "boolean",
            "objCType":    String(cString: NSNumber(value: true).objCType),
            "nullable":    NSNumber(value: false),
            "default":     NSNumber(value: false),
            "requiredFor": ["segments"],
        ] as [String: Any],
        "coordinates": [
            "class":           [NSArray.self],
            "luaClass":        "table",
            "default":         [] as [Any],
            "nullable":        NSNumber(value: false),
            "requiredFor":     ["segments", "points"],
            "memberClass":     NSDictionary.self,
            "memberLuaClass":  "point table",
            "memberClassKeys": [
                "x":   ["class": [NSNumber.self, NSString.self], "luaClass": "number or string", "default": "0.0", "requiredFor": ["segments", "points"], "nullable": NSNumber(value: false)] as [String: Any],
                "y":   ["class": [NSNumber.self, NSString.self], "luaClass": "number or string", "default": "0.0", "requiredFor": ["segments", "points"], "nullable": NSNumber(value: false)] as [String: Any],
                "c1x": ["class": [NSNumber.self, NSString.self], "luaClass": "number or string", "default": "0.0", "optionalFor": ["segments"], "nullable": NSNumber(value: true)] as [String: Any],
                "c1y": ["class": [NSNumber.self, NSString.self], "luaClass": "number or string", "default": "0.0", "optionalFor": ["segments"], "nullable": NSNumber(value: true)] as [String: Any],
                "c2x": ["class": [NSNumber.self, NSString.self], "luaClass": "number or string", "default": "0.0", "optionalFor": ["segments"], "nullable": NSNumber(value: true)] as [String: Any],
                "c2y": ["class": [NSNumber.self, NSString.self], "luaClass": "number or string", "default": "0.0", "optionalFor": ["segments"], "nullable": NSNumber(value: true)] as [String: Any],
            ],
        ] as [String: Any],
        "endAngle": [
            "class":       [NSNumber.self],
            "luaClass":    "number",
            "default":     NSNumber(value: 360.0),
            "nullable":    NSNumber(value: false),
            "requiredFor": ["arc", "ellipticalArc"],
        ] as [String: Any],
        "fillColor": [
            "class":       [NSColor.self],
            "luaClass":    "hs.drawing.color table",
            "nullable":    NSNumber(value: true),
            "default":     NSColor.red,
            "optionalFor": CLOSED,
        ] as [String: Any],
        "fillGradient": [
            "class":       [NSString.self],
            "luaClass":    "string",
            "values":      ["none", "linear", "radial"],
            "nullable":    NSNumber(value: true),
            "default":     "none",
            "optionalFor": CLOSED,
        ] as [String: Any],
        "fillGradientAngle": [
            "class":       [NSNumber.self],
            "luaClass":    "number",
            "nullable":    NSNumber(value: true),
            "default":     NSNumber(value: 0.0),
            "optionalFor": CLOSED,
        ] as [String: Any],
        "fillGradientCenter": [
            "class":       [NSDictionary.self],
            "luaClass":    "table",
            "keys":        [
                "x": ["class": [NSNumber.self], "luaClass": "number", "maxNumber": NSNumber(value: 1.0), "minNumber": NSNumber(value: -1.0)],
                "y": ["class": [NSNumber.self], "luaClass": "number", "maxNumber": NSNumber(value: 1.0), "minNumber": NSNumber(value: -1.0)],
            ],
            "default":     ["x": NSNumber(value: 0.0), "y": NSNumber(value: 0.0)],
            "nullable":    NSNumber(value: true),
            "optionalFor": CLOSED,
        ] as [String: Any],
        "fillGradientColors": [
            "class":          [NSArray.self],
            "luaClass":       "table",
            "default":        [NSColor.black, NSColor.white],
            "memberClass":    NSColor.self,
            "memberLuaClass": "hs.drawing.color table",
            "nullable":       NSNumber(value: true),
            "optionalFor":    CLOSED,
        ] as [String: Any],
        "flatness": [
            "class":       [NSNumber.self],
            "luaClass":    "number",
            "nullable":    NSNumber(value: true),
            "default":     NSNumber(value: NSBezierPath.defaultFlatness),
            "optionalFor": PRIMITIVES,
        ] as [String: Any],
        "flattenPath": [
            "class":       [NSNumber.self],
            "luaClass":    "boolean",
            "objCType":    String(cString: NSNumber(value: true).objCType),
            "nullable":    NSNumber(value: true),
            "default":     NSNumber(value: false),
            "optionalFor": PRIMITIVES,
        ] as [String: Any],
        "frame": [
            "class":       [NSDictionary.self],
            "luaClass":    "table",
            "keys":        [
                "x": ["class": [NSString.self, NSNumber.self], "luaClass": "number or string"],
                "y": ["class": [NSString.self, NSNumber.self], "luaClass": "number or string"],
                "h": ["class": [NSString.self, NSNumber.self], "luaClass": "number or string"],
                "w": ["class": [NSString.self, NSNumber.self], "luaClass": "number or string"],
            ],
            "default":     ["x": "0%", "y": "0%", "h": "100%", "w": "100%"],
            "nullable":    NSNumber(value: false),
            "requiredFor": ["rectangle", "oval", "ellipticalArc", "text", "image", "canvas"],
        ] as [String: Any],
        "id": [
            "class":       [NSString.self, NSNumber.self],
            "luaClass":    "string or number",
            "nullable":    NSNumber(value: true),
            "optionalFor": VISIBLE,
        ] as [String: Any],
        "image": [
            "class":       [NSImage.self],
            "luaClass":    "hs.image object",
            "nullable":    NSNumber(value: true),
            "default":     NSNull(),
            "optionalFor": ["image"],
        ] as [String: Any],
        "imageAlpha": [
            "class":       [NSNumber.self],
            "luaClass":    "number",
            "nullable":    NSNumber(value: true),
            "default":     NSNumber(value: 1.0),
            "minNumber":   NSNumber(value: 0.0),
            "maxNumber":   NSNumber(value: 1.0),
            "optionalFor": ["image"],
        ] as [String: Any],
        "imageAlignment": [
            "class":       [NSString.self],
            "luaClass":    "string",
            "values":      Array(IMAGEALIGNMENT_TYPES.keys),
            "nullable":    NSNumber(value: true),
            "default":     "center",
            "optionalFor": ["image"],
        ] as [String: Any],
        "imageAnimationFrame": [
            "class":       [NSNumber.self],
            "objCType":    String(cString: NSNumber(integerLiteral: 1).objCType),
            "luaClass":    "integer",
            "nullable":    NSNumber(value: true),
            "default":     NSNumber(value: 0),
            "optionalFor": ["image"],
        ] as [String: Any],
        "imageAnimates": [
            "class":       [NSNumber.self],
            "luaClass":    "boolean",
            "objCType":    String(cString: NSNumber(value: true).objCType),
            "nullable":    NSNumber(value: false),
            "default":     NSNumber(value: false),
            "requiredFor": ["image"],
        ] as [String: Any],
        "imageScaling": [
            "class":       [NSString.self],
            "luaClass":    "string",
            "values":      Array(IMAGESCALING_TYPES.keys),
            "nullable":    NSNumber(value: true),
            "default":     "scaleProportionally",
            "optionalFor": ["image"],
        ] as [String: Any],
        "miterLimit": [
            "class":       [NSNumber.self],
            "luaClass":    "number",
            "default":     NSNumber(value: NSBezierPath.defaultMiterLimit),
            "nullable":    NSNumber(value: true),
            "optionalFor": PRIMITIVES,
        ] as [String: Any],
        "padding": [
            "class":       [NSNumber.self],
            "luaClass":    "number",
            "default":     NSNumber(value: 0.0),
            "nullable":    NSNumber(value: true),
            "optionalFor": VISIBLE,
        ] as [String: Any],
        "radius": [
            "class":       [NSNumber.self, NSString.self],
            "luaClass":    "number or string",
            "nullable":    NSNumber(value: false),
            "default":     "50%",
            "requiredFor": ["arc", "circle"],
        ] as [String: Any],
        "reversePath": [
            "class":       [NSNumber.self],
            "luaClass":    "boolean",
            "objCType":    String(cString: NSNumber(value: true).objCType),
            "nullable":    NSNumber(value: true),
            "default":     NSNumber(value: false),
            "optionalFor": PRIMITIVES,
        ] as [String: Any],
        "roundedRectRadii": [
            "class":       [NSDictionary.self],
            "luaClass":    "table",
            "keys":        [
                "xRadius": ["class": [NSNumber.self], "luaClass": "number"],
                "yRadius": ["class": [NSNumber.self], "luaClass": "number"],
            ],
            "default":     ["xRadius": NSNumber(value: 0.0), "yRadius": NSNumber(value: 0.0)],
            "nullable":    NSNumber(value: true),
            "optionalFor": ["rectangle"],
        ] as [String: Any],
        "shadow": [
            "class":       [NSShadow.self],
            "luaClass":    "shadow table",
            "nullable":    NSNumber(value: true),
            "default":     defaultShadow,
            "optionalFor": PRIMITIVES,
        ] as [String: Any],
        "startAngle": [
            "class":       [NSNumber.self],
            "luaClass":    "number",
            "default":     NSNumber(value: 0.0),
            "nullable":    NSNumber(value: false),
            "requiredFor": ["arc", "ellipticalArc"],
        ] as [String: Any],
        "strokeCapStyle": [
            "class":       [NSString.self],
            "luaClass":    "string",
            "values":      Array(STROKE_CAP_STYLES.keys),
            "nullable":    NSNumber(value: true),
            "default":     "butt",
            "optionalFor": PRIMITIVES,
        ] as [String: Any],
        "strokeColor": [
            "class":       [NSColor.self],
            "luaClass":    "hs.drawing.color table",
            "nullable":    NSNumber(value: true),
            "default":     NSColor.black,
            "optionalFor": PRIMITIVES,
        ] as [String: Any],
        "strokeDashPattern": [
            "class":          [NSArray.self],
            "luaClass":       "table",
            "nullable":       NSNumber(value: true),
            "default":        [] as [Any],
            "memberClass":    NSNumber.self,
            "memberLuaClass": "number",
            "optionalFor":    PRIMITIVES,
        ] as [String: Any],
        "strokeDashPhase": [
            "class":       [NSNumber.self],
            "luaClass":    "number",
            "default":     NSNumber(value: 0.0),
            "nullable":    NSNumber(value: true),
            "optionalFor": PRIMITIVES,
        ] as [String: Any],
        "strokeJoinStyle": [
            "class":       [NSString.self],
            "luaClass":    "string",
            "values":      Array(STROKE_JOIN_STYLES.keys),
            "nullable":    NSNumber(value: true),
            "default":     "miter",
            "optionalFor": PRIMITIVES,
        ] as [String: Any],
        "strokeWidth": [
            "class":       [NSNumber.self],
            "luaClass":    "number",
            "default":     NSNumber(value: NSBezierPath.defaultLineWidth),
            "nullable":    NSNumber(value: true),
            "optionalFor": PRIMITIVES,
        ] as [String: Any],
        "text": [
            "class":       [NSString.self, NSNumber.self, NSAttributedString.self],
            "luaClass":    "string or hs.styledText object",
            "default":     "",
            "nullable":    NSNumber(value: true),
            "requiredFor": ["text"],
        ] as [String: Any],
        "textAlignment": [
            "class":       [NSString.self],
            "luaClass":    "string",
            "values":      Array(TEXTALIGNMENT_TYPES.keys),
            "nullable":    NSNumber(value: true),
            "default":     "natural",
            "optionalFor": ["text"],
        ] as [String: Any],
        "textColor": [
            "class":       [NSColor.self],
            "luaClass":    "hs.drawing.color table",
            "nullable":    NSNumber(value: true),
            "default":     NSColor(calibratedWhite: 1.0, alpha: 1.0),
            "optionalFor": ["text"],
        ] as [String: Any],
        "textFont": [
            "class":       [NSString.self],
            "luaClass":    "string",
            "nullable":    NSNumber(value: true),
            "default":     NSFont.systemFont(ofSize: 0).fontName,
            "optionalFor": ["text"],
        ] as [String: Any],
        "textLineBreak": [
            "class":       [NSString.self],
            "luaClass":    "string",
            "values":      Array(TEXTWRAP_TYPES.keys),
            "nullable":    NSNumber(value: true),
            "default":     "wordWrap",
            "optionalFor": ["text"],
        ] as [String: Any],
        "textSize": [
            "class":       [NSNumber.self],
            "luaClass":    "number",
            "nullable":    NSNumber(value: true),
            "default":     NSNumber(value: 27.0),
            "optionalFor": ["text"],
        ] as [String: Any],
        "trackMouseByBounds": [
            "class":       [NSNumber.self],
            "luaClass":    "boolean",
            "objCType":    String(cString: NSNumber(value: true).objCType),
            "nullable":    NSNumber(value: true),
            "default":     NSNumber(value: false),
            "optionalFor": VISIBLE,
        ] as [String: Any],
        "trackMouseEnterExit": [
            "class":       [NSNumber.self],
            "luaClass":    "boolean",
            "objCType":    String(cString: NSNumber(value: true).objCType),
            "nullable":    NSNumber(value: true),
            "default":     NSNumber(value: false),
            "optionalFor": VISIBLE,
        ] as [String: Any],
        "trackMouseDown": [
            "class":       [NSNumber.self],
            "luaClass":    "boolean",
            "objCType":    String(cString: NSNumber(value: true).objCType),
            "nullable":    NSNumber(value: true),
            "default":     NSNumber(value: false),
            "optionalFor": VISIBLE,
        ] as [String: Any],
        "trackMouseUp": [
            "class":       [NSNumber.self],
            "luaClass":    "boolean",
            "objCType":    String(cString: NSNumber(value: true).objCType),
            "nullable":    NSNumber(value: true),
            "default":     NSNumber(value: false),
            "optionalFor": VISIBLE,
        ] as [String: Any],
        "trackMouseMove": [
            "class":       [NSNumber.self],
            "luaClass":    "boolean",
            "objCType":    String(cString: NSNumber(value: true).objCType),
            "nullable":    NSNumber(value: true),
            "default":     NSNumber(value: false),
            "optionalFor": VISIBLE,
        ] as [String: Any],
        "transformation": [
            "class":       [NSAffineTransform.self],
            "luaClass":    "transform table",
            "nullable":    NSNumber(value: true),
            "default":     NSAffineTransform(),
            "optionalFor": VISIBLE,
        ] as [String: Any],
        "type": [
            "class":       [NSString.self],
            "luaClass":    "string",
            "values":      ALL_TYPES,
            "nullable":    NSNumber(value: false),
            "requiredFor": ALL_TYPES,
        ] as [String: Any],
        "canvas": [
            "class":       [NSView.self],
            "luaClass":    "userdata object subclassing NSView",
            "nullable":    NSNumber(value: true),
            "default":     NSNull(),
            "requiredFor": ["canvas"],
        ] as [String: Any],
        "canvasAlpha": [
            "class":       [NSNumber.self],
            "luaClass":    "number",
            "nullable":    NSNumber(value: true),
            "default":     NSNumber(value: 1.0),
            "minNumber":   NSNumber(value: 0.0),
            "maxNumber":   NSNumber(value: 1.0),
            "optionalFor": ["canvas"],
        ] as [String: Any],
        "windingRule": [
            "class":       [NSString.self],
            "luaClass":    "string",
            "values":      Array(WINDING_RULES.keys),
            "nullable":    NSNumber(value: true),
            "default":     "nonZero",
            "optionalFor": PRIMITIVES,
        ] as [String: Any],
        "withShadow": [
            "class":       [NSNumber.self],
            "luaClass":    "boolean",
            "objCType":    String(cString: NSNumber(value: true).objCType),
            "nullable":    NSNumber(value: true),
            "default":     NSNumber(value: false),
            "optionalFor": PRIMITIVES,
        ] as [String: Any],
    ]
}

// MARK: - Validation Functions

private func isValueValidForDictionary(_ keyName: NSString, _ keyValue: Any?, _ attributeDefinition: NSDictionary) -> AttributeValidity {
    var validity = AttributeValidity.valid
    var errorMessage: String? = nil

    repeat {
        guard let keyValue = keyValue, !(keyValue is NSNull) else {
            if let nullable = attributeDefinition["nullable"] as? NSNumber, nullable.boolValue {
                validity = .nulling
            } else {
                errorMessage = "\(keyName) is not nullable"
            }
            break
        }

        if let classArray = attributeDefinition["class"] as? [AnyClass] {
            var found = false
            for cls in classArray {
                if (keyValue as AnyObject).isKind(of: cls) {
                    found = true
                    break
                }
            }
            if !found {
                errorMessage = "\(keyName) must be a \(attributeDefinition["luaClass"] ?? "unknown")"
                break
            }
        }

        if let expectedObjCType = attributeDefinition["objCType"] as? String,
           let nsValue = keyValue as? NSNumber {
            if String(cString: nsValue.objCType) != expectedObjCType {
                errorMessage = "\(keyName) must be a \(attributeDefinition["luaClass"] ?? "unknown")"
                break
            }
        }

        if let nsNumber = keyValue as? NSNumber, attributeDefinition["objCType"] == nil {
            if !nsNumber.doubleValue.isFinite {
                errorMessage = "\(keyName) must be a finite number"
                break
            }
        }

        if let values = attributeDefinition["values"] as? [String], let strVal = keyValue as? String {
            if !values.contains(strVal) {
                errorMessage = "\(keyName) must be one of \(values.joined(separator: ", "))"
                break
            }
        }

        if let maxNumber = attributeDefinition["maxNumber"] as? NSNumber, let numVal = keyValue as? NSNumber {
            if numVal.doubleValue > maxNumber.doubleValue {
                errorMessage = "\(keyName) must be <= \(maxNumber.doubleValue)"
                break
            }
        }

        if let minNumber = attributeDefinition["minNumber"] as? NSNumber, let numVal = keyValue as? NSNumber {
            if numVal.doubleValue < minNumber.doubleValue {
                errorMessage = "\(keyName) must be >= \(minNumber.doubleValue)"
                break
            }
        }

        if let dictValue = keyValue as? NSDictionary, let subKeys = attributeDefinition["keys"] as? NSDictionary {
            for case let subKeyName as String in subKeys.allKeys {
                guard let subKeyDef = subKeys[subKeyName] as? NSDictionary else { continue }
                let subVal = dictValue[subKeyName]

                if let subClassArray = subKeyDef["class"] as? [AnyClass] {
                    var found = false
                    for cls in subClassArray {
                        if let obj = subVal as AnyObject?, obj.isKind(of: cls) {
                            found = true
                            break
                        }
                    }
                    if !found {
                        errorMessage = "field \(subKeyName) of \(keyName) must be a \(subKeyDef["luaClass"] ?? "unknown")"
                        break
                    }
                }

                if let expectedObjCType = subKeyDef["objCType"] as? String,
                   let nsValue = subVal as? NSNumber {
                    if String(cString: nsValue.objCType) != expectedObjCType {
                        errorMessage = "field \(subKeyName) of \(keyName) must be a \(subKeyDef["luaClass"] ?? "unknown")"
                        break
                    }
                }

                if let nsNumber = subVal as? NSNumber, subKeyDef["objCType"] == nil {
                    if !nsNumber.doubleValue.isFinite {
                        errorMessage = "field \(subKeyName) of \(keyName) must be a finite number"
                        break
                    }
                }

                if let values = subKeyDef["values"] as? [String], let strVal = subVal as? String {
                    if !values.contains(strVal) {
                        errorMessage = "field \(subKeyName) of \(keyName) must be one of \(values.joined(separator: ", "))"
                        break
                    }
                }

                if let maxNumber = subKeyDef["maxNumber"] as? NSNumber, let numVal = subVal as? NSNumber {
                    if numVal.doubleValue > maxNumber.doubleValue {
                        errorMessage = "field \(subKeyName) of \(keyName) must be <= \(maxNumber.doubleValue)"
                        break
                    }
                }

                if let minNumber = subKeyDef["minNumber"] as? NSNumber, let numVal = subVal as? NSNumber {
                    if numVal.doubleValue < minNumber.doubleValue {
                        errorMessage = "field \(subKeyName) of \(keyName) must be >= \(minNumber.doubleValue)"
                        break
                    }
                }
            }
            if errorMessage != nil { break }
        }

        if let arrayValue = keyValue as? NSArray {
            if arrayValue.count > 0 {
                var isGood = true
                if let memberClass = attributeDefinition["memberClass"] as? AnyClass {
                    for i in 0..<arrayValue.count {
                        if !(arrayValue[i] as AnyObject).isKind(of: memberClass) {
                            isGood = false
                            break
                        } else if let dictItem = arrayValue[i] as? NSDictionary,
                                  let memberClassKeys = attributeDefinition["memberClassKeys"] as? NSDictionary {
                            for case let (subKey as String, obj) in dictItem {
                                if let subKeyDef = memberClassKeys[subKey] as? NSDictionary {
                                    validity = isValueValidForDictionary(subKey as NSString, obj, subKeyDef)
                                } else {
                                    validity = .invalid
                                    errorMessage = "\(subKey) is not a valid subkey for a \(attributeDefinition["memberLuaClass"] ?? "unknown") value"
                                }
                                if validity != .valid { break }
                            }
                        }
                    }
                }
                if !isGood {
                    errorMessage = "\(keyName) must be an array of \(attributeDefinition["memberLuaClass"] ?? "unknown") values"
                    break
                }
            }
        }

        if keyName.isEqual(to: "textFont"), let fontName = keyValue as? String {
            if NSFont(name: fontName, size: 0.0) == nil {
                errorMessage = "\(fontName) is not a recognized font name"
                break
            }
        }

        break // always exit the pseudo-loop
    } while false

    if let msg = errorMessage {
        LuaSkin.skin(with: nil).logError("\(USERDATA_TAG):\(msg)")
        validity = .invalid
    }
    return validity
}

private func isValueValidForAttribute(_ keyName: NSString, _ keyValue: Any?) -> AttributeValidity {
    guard let attributeDefinition = languageDictionary[keyName] as? NSDictionary else {
        LuaSkin.skin(with: nil).logError("\(USERDATA_TAG):\(keyName) is not a valid canvas attribute")
        return .invalid
    }
    return isValueValidForDictionary(keyName, keyValue, attributeDefinition)
}

private func convertPercentageStringToNumber(_ stringValue: String) -> NSNumber? {
    let formatter = NumberFormatter()
    formatter.locale = Locale.current

    formatter.numberStyle = .decimal
    var tmpValue = formatter.number(from: stringValue)
    if tmpValue == nil {
        formatter.numberStyle = .percent
        tmpValue = formatter.number(from: stringValue)
    }
    // just to be sure, let's also check with the en_US locale
    if tmpValue == nil {
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        tmpValue = formatter.number(from: stringValue)
        if tmpValue == nil {
            formatter.numberStyle = .percent
            tmpValue = formatter.number(from: stringValue)
        }
    }
    return tmpValue
}

private func RectWithFlippedYCoordinate(_ theRect: NSRect) -> NSRect {
    return NSMakeRect(theRect.origin.x,
                      NSScreen.screens[0].frame.size.height - theRect.origin.y - theRect.size.height,
                      theRect.size.width,
                      theRect.size.height)
}

private func canvas_orderHelper(_ L: UnsafeMutablePointer<lua_State>!, mode: NSWindow.OrderingMode) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG,
                   LS_TBREAK | LS_TVARARG)

    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    if parentIsWindow(canvasView) {
        let canvasWindow = canvasView.window as! HSCanvasWindow

        var relativeTo: Int = 0

        if lua_gettop(L) > 1 {
            if lua_type(L, 2) == LUA_TNIL {
                skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNIL, LS_TBREAK)
            } else {
                skin.checkArgs(LS_TUSERDATA, USERDATA_TAG,
                               LS_TUSERDATA, USERDATA_TAG,
                               LS_TBREAK)
                let otherView = skin.luaObject(at:2, toClass: "HSCanvasView") as! HSCanvasView
                if let otherWindow = otherView.window as? HSCanvasWindow {
                    relativeTo = otherWindow.windowNumber
                }
            }
        }

        canvasWindow.order(mode, relativeTo: relativeTo)
        lua_pushvalue(L, 1)
    } else {
        return luaL_argerror(L, 1, "method unavailable for canvas as a subview")
    }

    return 1
}

// userdata_gc is defined later in this file (MARK: - Cosmic Hammer/Lua Infrastructure)

// MARK: - HSCanvasWindow

@objc class HSCanvasWindow: NSPanel, NSWindowDelegate {
    @objc var subroleOverride: String?

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        guard contentRect.origin.x.isFinite && contentRect.origin.y.isFinite &&
              contentRect.size.height.isFinite && contentRect.size.width.isFinite else {
            LuaSkin.skin(with: nil).logError("\(USERDATA_TAG):coordinates must be finite numbers")
            // Cannot return nil from a non-failable init in Swift; the ObjC version returned nil.
            // We initialize with zero rect and the caller checks for validity.
            super.init(contentRect: .zero, styleMask: style, backing: backingStoreType, defer: flag)
            return
        }

        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)

        self.delegate = self

        self.setFrameOrigin(RectWithFlippedYCoordinate(contentRect).origin)

        // Configure the window
        self.isReleasedWhenClosed = false
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.isRestorable = false
        self.hidesOnDeactivate = false
        self.animationBehavior = .none
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        subroleOverride = nil
    }

    override func accessibilitySubrole() -> NSAccessibility.Subrole? {
        let defaultSubrole = super.accessibilitySubrole()
        let defaultStr = defaultSubrole?.rawValue ?? ""
        let customSubrole = NSAccessibility.Subrole(rawValue: defaultStr + ".Cosmic Hammer")

        if let override = subroleOverride {
            if override.isEmpty {
                return defaultCustomSubRole ? defaultSubrole : customSubrole
            } else {
                return NSAccessibility.Subrole(rawValue: override)
            }
        } else {
            return defaultCustomSubRole ? customSubrole : defaultSubrole
        }
    }

    override var canBecomeKey: Bool {
        var allowKey = false
        if let canvasView = self.contentView as? HSCanvasView {
            for element in canvasView.elementList {
                if let dict = element as? NSDictionary,
                   let canvas = dict["canvas"] as? NSView,
                   canvas.canBecomeKeyView {
                    allowKey = true
                    break
                }
            }
        }
        return allowKey
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return false
    }

    // MARK: Window Animation Methods

    func fadeIn(_ fadeTime: TimeInterval) {
        let alphaSetting = self.alphaValue
        self.alphaValue = 0.0
        self.makeKeyAndOrderFront(nil)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = fadeTime
        self.animator().alphaValue = alphaSetting
        NSAnimationContext.endGrouping()
    }

    func fadeOut(_ fadeTime: TimeInterval, andDelete deleteCanvas: Bool, withState L: UnsafeMutablePointer<lua_State>!) {
        let skin = LuaSkin.skin(with: L)
        guard let theView = self.contentView as? HSCanvasView else { return }
        if theView.selfRef != LUA_NOREF { return } // already in a fade
        skin.pushNSObject(theView)
        theView.selfRef = skin.luaRef(refTable)

        let alphaSetting = self.alphaValue
        NSAnimationContext.beginGrouping()
        weak let bself = self
        let canary = skin.createGCCanary()

        NSAnimationContext.current.duration = fadeTime
        NSAnimationContext.current.completionHandler = {
            DispatchQueue.main.async {
                guard let mySelf = bself,
                      let myView = mySelf.contentView as? HSCanvasView,
                      myView.selfRef != LUA_NOREF else { return }

                let bSkin = LuaSkin.skin(with: nil)
                _lua_stackguard_entry(bSkin.l)

                if skin.check(canary) {
                    myView.selfRef = bSkin.luaUnref(refTable, ref: myView.selfRef)
                }
                var mutableCanary = canary
                skin.destroy(&mutableCanary)
                _lua_stackguard_exit(bSkin.l)

                mySelf.orderOut(nil)
                mySelf.alphaValue = alphaSetting
            }
        }
        self.animator().alphaValue = 0.0
        NSAnimationContext.endGrouping()
    }
}

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
        _lua_stackguard_entry(skin.l)
        skin.pushLuaRef(refTable, ref: mouseCallbackRef)
        skin.pushNSObject(self)
        skin.pushNSObject(message as NSString)
        skin.pushNSObject(elementIdentifier as AnyObject)
        lua_pushnumber(skin.l, lua_Number(location.x))
        lua_pushnumber(skin.l, lua_Number(location.y))
        skin.protectedCallAndError("hs.canvas:clickCallback for \(message)", nargs: 5, nresults: 0)
        _lua_stackguard_exit(skin.l)
    }

    func subviewCallback(_ sender: Any) {
        guard mouseCallbackRef != LUA_NOREF else { return }
        let skin = LuaSkin.skin(with: nil)
        _lua_stackguard_entry(skin.l)
        skin.pushLuaRef(refTable, ref: mouseCallbackRef)
        skin.pushNSObject(self)
        skin.pushNSObject("_subview_" as NSString)
        skin.pushNSObject(sender as AnyObject)
        skin.protectedCallAndError("hs.canvas:buttonCallback", nargs: 3, nresults: 0)
        _lua_stackguard_exit(skin.l)
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
            skin.pushNSObject(dict)
            lua_pushstring(L, "NSColor")
            lua_setfield(L, -2, "__luaSkinType")
            newValue = skin.toNSObject(atIndex: -1)
            lua_pop(L, 1)
        } else if keyName.hasSuffix("Color"), let arr = oldValue as? NSArray {
            skin.pushNSObject(arr)
            lua_pushstring(L, "NSColor")
            lua_setfield(L, -2, "__luaSkinType")
            newValue = skin.toNSObject(atIndex: -1)
            lua_pop(L, 1)

        // fillGradientColors is an array of colors
        } else if keyName == "fillGradientColors" {
            let result = NSMutableArray()
            if let oldArray = oldValue as? NSMutableArray {
                oldArray.enumerateObjects { (anItem, idx, _) in
                    var item = anItem
                    if let dict = item as? NSDictionary {
                        skin.pushNSObject(dict)
                        lua_pushstring(L, "NSColor")
                        lua_setfield(L, -2, "__luaSkinType")
                        item = skin.toNSObject(atIndex: -1) as Any
                        lua_pop(L, 1)
                    }
                    if let color = item as? NSColor, color.usingColorSpace(.genericRGB) != nil {
                        result.add(color)
                    } else {
                        LuaSkin.skin(with: nil).logWarn("\(USERDATA_TAG):not a proper color at index \(idx + 1) of fillGradientColor; using Black")
                        result.add(NSColor.black)
                    }
                }
            }
            if result.count < 2 {
                LuaSkin.skin(with: nil).logWarn("\(USERDATA_TAG):fillGradientColor requires at least 2 colors; using default")
                newValue = getDefaultValue(for: keyName, onlyIfSet: false)
            } else {
                newValue = result
            }

        // fix NSAffineTransform table
        } else if keyName == "transformation", (oldValue is NSDictionary || oldValue is NSArray) {
            skin.pushNSObject(oldValue as AnyObject)
            lua_pushstring(L, "NSAffineTransform")
            lua_setfield(L, -2, "__luaSkinType")
            newValue = skin.toNSObject(atIndex: -1)
            lua_pop(L, 1)

        // fix NSShadow table
        } else if keyName == "shadow", (oldValue is NSDictionary || oldValue is NSArray) {
            skin.pushNSObject(oldValue as AnyObject)
            lua_pushstring(L, "NSShadow")
            lua_setfield(L, -2, "__luaSkinType")
            newValue = skin.toNSObject(atIndex: -1)
            lua_pop(L, 1)

        // fix hs.styledText as Table
        } else if keyName == "text", (oldValue is NSDictionary || oldValue is NSArray) {
            skin.pushNSObject(oldValue as AnyObject)
            lua_pushstring(L, "NSAttributedString")
            lua_setfield(L, -2, "__luaSkinType")
            newValue = skin.toNSObject(atIndex: -1)
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
        guard let attributeDefinition = languageDictionary[keyName] as? NSDictionary else { return nil }
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
        guard let langEntry = languageDictionary[keyName] as? NSDictionary,
              (langEntry["nullable"] as? NSNumber)?.boolValue == true else {
            self.needsDisplay = true
            return validityStatus.rawValue
        }
        let massaged = massageKeyValue(keyValue, forKey: keyName, withState: L)
        validityStatus = isValueValidForAttribute(keyName as NSString, massaged)
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
                    if let percentage = convertPercentageStringToNumber(stringVal) {
                        foundObject = NSNumber(value: percentage.doubleValue * paddedWidth)
                    }
                }
            } else if keyName == "center" {
                if let dict = foundObject as? NSMutableDictionary {
                    if let xStr = dict["x"] as? String, let pct = convertPercentageStringToNumber(xStr) {
                        dict["x"] = NSNumber(value: padding + pct.doubleValue * paddedWidth)
                    }
                    if let yStr = dict["y"] as? String, let pct = convertPercentageStringToNumber(yStr) {
                        dict["y"] = NSNumber(value: padding + pct.doubleValue * paddedHeight)
                    }
                }
            } else if keyName == "frame" {
                if let dict = foundObject as? NSMutableDictionary {
                    if let xStr = dict["x"] as? String, let pct = convertPercentageStringToNumber(xStr) {
                        dict["x"] = NSNumber(value: padding + pct.doubleValue * paddedWidth)
                    }
                    if let yStr = dict["y"] as? String, let pct = convertPercentageStringToNumber(yStr) {
                        dict["y"] = NSNumber(value: padding + pct.doubleValue * paddedHeight)
                    }
                    if let wStr = dict["w"] as? String, let pct = convertPercentageStringToNumber(wStr) {
                        dict["w"] = NSNumber(value: pct.doubleValue * paddedWidth)
                    }
                    if let hStr = dict["h"] as? String, let pct = convertPercentageStringToNumber(hStr) {
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
                                    if let pct = convertPercentageStringToNumber(strVal) {
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
        var validityStatus = isValueValidForAttribute(keyName as NSString, massaged)

        switch validityStatus {
        case .valid:
            // Percentage string validation for radius/center/frame/coordinates
            if keyName == "radius", let strVal = massaged as? String {
                if convertPercentageStringToNumber(strVal) == nil {
                    LuaSkin.skin(with: nil).logError("\(USERDATA_TAG):invalid percentage string specified for \(keyName) for element \(index + 1)")
                    validityStatus = .invalid
                    break
                }
            } else if keyName == "center", let dict = massaged as? NSDictionary {
                for field in ["x", "y"] {
                    if let str = dict[field] as? String, convertPercentageStringToNumber(str) == nil {
                        LuaSkin.skin(with: nil).logError("\(USERDATA_TAG):invalid percentage string specified for field \(field) of \(keyName) for element \(index + 1)")
                        validityStatus = .invalid
                        break
                    }
                }
                if validityStatus == .invalid { break }
            } else if keyName == "frame", let dict = massaged as? NSDictionary {
                for field in ["x", "y", "w", "h"] {
                    if let str = dict[field] as? String, convertPercentageStringToNumber(str) == nil {
                        LuaSkin.skin(with: nil).logError("\(USERDATA_TAG):invalid percentage string specified for field \(field) of \(keyName) for element \(index + 1)")
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
                                if let str = subDict[field] as? String, convertPercentageStringToNumber(str) == nil {
                                    LuaSkin.skin(with: nil).logError("\(USERDATA_TAG):invalid percentage string specified for field \(field) at index \(idx + 1) of \(keyName) for element \(index + 1)")
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
                            LuaSkin.skin(with: nil).logError("\(USERDATA_TAG):index \(idx + 1) of \(keyName) for element \(index + 1) does not specify a valid point or curve with control points")
                            validityStatus = .invalid
                        } else if goodForPoint && partialCurve {
                            LuaSkin.skin(with: nil).logWarn("\(USERDATA_TAG):index \(idx + 1) of \(keyName) for element \(index + 1) does not contain complete curve control points; treating as a singular point")
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
                            LuaSkin.skin(with: nil).logWarn("\(USERDATA_TAG):view for element \(index + 1) is already in use")
                            validityStatus = .invalid
                            break
                        }
                    }
                }
            } else if keyName == "imageAnimationFrame" {
                if (getElementValue(for: "imageAnimates", atIndex: index) as? NSNumber)?.boolValue == true {
                    LuaSkin.skin(with: nil).logWarn("\(USERDATA_TAG):\(keyName) cannot be changed when element \(index + 1) is animating")
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
                let defaultsForType = languageDictionary.keysSortedByValue(comparator: { _, _ in .orderedSame })
                    // Actually use keysOfEntries to find required keys for this type
                let requiredKeys = (languageDictionary as! [String: NSDictionary]).filter { (typeName, typeDefinition) in
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
                    LuaSkin.skin(with: nil).logWarn("\(USERDATA_TAG):\(keyName) cannot be changed when element \(index + 1) is animating")
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
                            LuaSkin.skin(with: nil).logWarn("\(USERDATA_TAG):drawRect - un-nested resetClip at index \(idx + 1)")
                        }
                    } else {
                        LuaSkin.skin(with: nil).logWarn("\(USERDATA_TAG):drawRect - unrecognized type \(elementType) at index \(idx + 1)")
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
                        LuaSkin.skin(with: nil).logWarn("\(USERDATA_TAG):drawRect - unrecognized action \(action) at index \(idx + 1)")
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
        let skin = LuaSkin.skin(with: L)
        if selfRef != LUA_NOREF { return } // already in a fade
        skin.pushNSObject(self)
        selfRef = skin.luaRef(refTable)

        let alphaSetting = self.alphaValue
        NSAnimationContext.beginGrouping()
        weak let bself = self
        NSAnimationContext.current.duration = fadeTime
        NSAnimationContext.current.completionHandler = {
            guard let mySelf = bself else { return }
            let bSkin = LuaSkin.skin(with: nil)
            mySelf.selfRef = bSkin.luaUnref(refTable, ref: mySelf.selfRef)

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
        let L = skin.l!
        _lua_stackguard_entry(L)
        var argCount: Int32 = 2
        skin.pushLuaRef(refTable, ref: draggingCallbackRef)
        skin.pushNSObject(self)
        skin.pushNSObject(message as NSString)

        if let sender = sender {
            lua_newtable(L)
            let pasteboard = sender.draggingPasteboard
            skin.pushNSObject(pasteboard.name.rawValue as NSString)
            lua_setfield(L, -2, "pasteboard")

            lua_pushinteger(L, lua_Integer(sender.draggingSequenceNumber))
            lua_setfield(L, -2, "sequence")

            skin.pushNSPoint(sender.draggingLocation)
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

        if skin.protectedCallAndTraceback(argCount, nresults: 1) {
            isAllGood = lua_isnoneornil(L, -1) ? true : (lua_toboolean(L, -1) != 0)
        } else {
            skin.logError("\(USERDATA_TAG):draggingCallback error: \(skin.toNSObject(atIndex: -1) ?? "unknown" as NSString)")
        }
        lua_pop(L, 1)
        _lua_stackguard_exit(L)

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

// MARK: - Module Functions

/// hs.canvas.useCustomAccessibilitySubrole([state]) -> boolean
/// Function
/// Get or set whether or not canvas objects use a custom accessibility subrole for the containing system window.
private func canvas_useCustomAccessibilitySubrole(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)

    if lua_gettop(L) == 1 {
        defaultCustomSubRole = lua_toboolean(L, 1) != 0
    }
    lua_pushboolean(L, defaultCustomSubRole ? 1 : 0)
    return 1
}

/// hs.canvas.new(rect) -> canvasObject
/// Constructor
/// Create a new canvas object at the specified coordinates
private func canvas_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
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
private func dumpLanguageDictionary(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)
    skin.pushNSObject(languageDictionary, withOptions: LS_NSConversionOptions.nsDescribeUnknownTypes.rawValue)
    return 1
}

/// hs.canvas.defaultTextStyle() -> `hs.styledtext` attributes table
/// Function
/// Returns a table containing the default font, size, color, and paragraphStyle used by `hs.canvas` for text drawing objects.
private func default_textAttributes(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBREAK)
    lua_newtable(L)
    if let fontName = (languageDictionary["textFont"] as? NSDictionary)?["default"] as? String {
        let size = ((languageDictionary["textSize"] as? NSDictionary)?["default"] as? NSNumber)?.doubleValue ?? 27.0
        skin.pushNSObject(NSFont(name: fontName, size: CGFloat(size)))
        lua_setfield(L, -2, "font")
        skin.pushNSObject((languageDictionary["textColor"] as? NSDictionary)?["default"])
        lua_setfield(L, -2, "color")
        skin.pushNSObject(NSParagraphStyle.default)
        lua_setfield(L, -2, "paragraphStyle")
    } else {
        return luaL_error(L, "\(USERDATA_TAG):unable to get default font name from element language dictionary")
    }
    return 1
}

// MARK: - Module Methods

/// hs.canvas:draggingCallback(fn) -> canvasObject
private func canvas_draggingCallback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TFUNCTION | LS_TNIL, LS_TBREAK)
    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView

    canvasView.draggingCallbackRef = skin.luaUnref(refTable, ref: canvasView.draggingCallbackRef)
    canvasView.unregisterDraggedTypes()
    if skin.luaType(at: 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        canvasView.draggingCallbackRef = skin.luaRef(refTable)
        canvasView.registerForDraggedTypes([.fileURL])
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.canvas:_accessibilitySubrole([subrole]) -> canvasObject | current value
private func canvas_accessibilitySubrole(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)
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
private func canvas_show(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG,
                   LS_TNUMBER | LS_TOPTIONAL,
                   LS_TBREAK)

    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView

    if lua_gettop(L) == 1 {
        if parentIsWindow(canvasView) {
            (canvasView.window as? HSCanvasWindow)?.makeKeyAndOrderFront(nil)
        } else {
            canvasView.isHidden = false
        }
    } else {
        if parentIsWindow(canvasView) {
            (canvasView.window as? HSCanvasWindow)?.fadeIn(lua_tonumber(L, 2))
        } else {
            canvasView.fadeIn(lua_tonumber(L, 2))
        }
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.canvas:hide([fadeOutTime]) -> canvasObject
private func canvas_hide(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG,
                   LS_TNUMBER | LS_TOPTIONAL,
                   LS_TBREAK)

    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    let canvasWindow = canvasView.window as? HSCanvasWindow

    if lua_gettop(L) == 1 {
        if parentIsWindow(canvasView) {
            canvasWindow?.orderOut(nil)
        } else {
            canvasView.isHidden = true
        }
    } else {
        if parentIsWindow(canvasView) {
            canvasWindow?.fadeOut(lua_tonumber(L, 2), andDelete: false, withState: L)
        } else {
            canvasView.fadeOut(lua_tonumber(L, 2), andDelete: false, withState: L)
        }
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.canvas:mouseCallback(mouseCallbackFn) -> canvasObject
private func canvas_mouseCallback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG,
                   LS_TFUNCTION | LS_TNIL,
                   LS_TBREAK)

    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    let canvasWindow = canvasView.wrapperWindow

    canvasView.mouseCallbackRef = skin.luaUnref(refTable, ref: canvasView.mouseCallbackRef)
    canvasView.previousTrackedIndex = UInt(NSNotFound)
    canvasWindow?.ignoresMouseEvents = true

    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        canvasView.mouseCallbackRef = skin.luaRef(refTable)
        canvasWindow?.ignoresMouseEvents = false
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.canvas:clickActivating([flag]) -> canvasObject | currentValue
private func canvas_clickActivating(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG,
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
private func canvas_canvasMouseEvents(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG,
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
private func canvas_topLeft(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG,
                   LS_TTABLE | LS_TOPTIONAL,
                   LS_TBREAK)

    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    if parentIsWindow(canvasView) {
        let canvasWindow = canvasView.window as! HSCanvasWindow
        let oldFrame = RectWithFlippedYCoordinate(canvasWindow.frame)

        if lua_gettop(L) == 1 {
            skin.pushNSPoint(oldFrame.origin)
        } else {
            let newCoord = skin.tableToPoint(at: 2)
            let newFrame = RectWithFlippedYCoordinate(NSMakeRect(newCoord.x, newCoord.y, oldFrame.size.width, oldFrame.size.height))
            canvasWindow.setFrame(newFrame, display: true, animate: false)
            lua_pushvalue(L, 1)
        }
    } else {
        return luaL_argerror(L, 1, "method unavailable for canvas as a subview")
    }
    return 1
}

/// hs.canvas:imageFromCanvas() -> hs.image object
private func canvas_canvasAsImage(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)

    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    let image = canvasView.imageWithSubviews()
    skin.pushNSObject(image)
    return 1
}

/// hs.canvas:size([size]) -> canvasObject | currentValue
private func canvas_size(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG,
                   LS_TTABLE | LS_TOPTIONAL,
                   LS_TBREAK)

    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    if parentIsWindow(canvasView) {
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
                    skin.logError("\(USERDATA_TAG):unable to get absolute positioning info for index position \(i + 1)")
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
private func canvas_alpha(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG,
                   LS_TNUMBER | LS_TOPTIONAL,
                   LS_TBREAK)

    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    let canvasWindow = canvasView.window as? HSCanvasWindow

    if lua_gettop(L) == 1 {
        if parentIsWindow(canvasView) {
            lua_pushnumber(L, lua_Number(canvasWindow!.alphaValue))
        } else {
            lua_pushnumber(L, lua_Number(canvasView.alphaValue))
        }
    } else {
        let newLevel = CGFloat(luaL_checknumber(L, 2))
        let clamped = max(0.0, min(1.0, newLevel))
        if parentIsWindow(canvasView) {
            canvasWindow!.alphaValue = clamped
        } else {
            canvasView.alphaValue = clamped
        }
        lua_pushvalue(L, 1)
    }

    return 1
}

/// hs.canvas:orderAbove([canvas2]) -> canvasObject
private func canvas_orderAbove(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    return canvas_orderHelper(L, mode: .above)
}

/// hs.canvas:orderBelow([canvas2]) -> canvasObject
private func canvas_orderBelow(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    return canvas_orderHelper(L, mode: .below)
}

/// hs.canvas:level([level]) -> canvasObject | currentValue
private func canvas_level(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG,
                   LS_TNUMBER | LS_TSTRING | LS_TOPTIONAL,
                   LS_TBREAK)

    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    if parentIsWindow(canvasView) {
        let canvasWindow = canvasView.window!

        if lua_gettop(L) == 1 {
            lua_pushinteger(L, lua_Integer(canvasWindow.level.rawValue))
        } else {
            var targetLevel: lua_Integer
            if lua_type(L, 2) == LUA_TNUMBER {
                skin.checkArgs(LS_TUSERDATA, USERDATA_TAG,
                               LS_TNUMBER | LS_TINTEGER,
                               LS_TBREAK)
                targetLevel = lua_tointeger(L, 2)
            } else {
                cg_windowLevels(L)
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
private func canvas_wantsLayer(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG,
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

private func canvas_behavior(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG,
                   LS_TNUMBER | LS_TOPTIONAL,
                   LS_TBREAK)

    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    if parentIsWindow(canvasView) {
        let canvasWindow = canvasView.window!

        if lua_gettop(L) == 1 {
            lua_pushinteger(L, lua_Integer(canvasWindow.collectionBehavior.rawValue))
        } else {
            skin.checkArgs(LS_TUSERDATA, USERDATA_TAG,
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
private func canvas_delete(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG,
                   LS_TNUMBER | LS_TOPTIONAL,
                   LS_TBREAK)

    canvas_hide(L)
    lua_pop(L, 1) // remove userdata pushed by hide

    lua_pushnil(L)
    return 1
}

/// hs.canvas:isShowing() -> boolean
private func canvas_isShowing(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)

    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    let canvasWindow = canvasView.window as? HSCanvasWindow
    if parentIsWindow(canvasView) {
        lua_pushboolean(L, (canvasWindow?.isVisible ?? false) ? 1 : 0)
    } else {
        lua_pushboolean(L, (!canvasView.isHidden && (canvasWindow?.isVisible ?? false)) ? 1 : 0)
    }
    return 1
}

/// hs.canvas:isOccluded() -> boolean
private func canvas_isOccluded(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)

    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    let canvasWindow = canvasView.window as? HSCanvasWindow
    if parentIsWindow(canvasView) {
        let visible = canvasWindow?.occlusionState.contains(.visible) ?? false
        lua_pushboolean(L, visible ? 0 : 1)
    } else {
        let visible = canvasWindow?.occlusionState.contains(.visible) ?? false
        lua_pushboolean(L, (canvasView.isHidden || !visible) ? 1 : 0)
    }
    return 1
}

/// hs.canvas:transformation([matrix]) -> canvasObject | current value
private func canvas_canvasTransformation(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TTABLE | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)
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
private func canvas_elementCount(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    lua_pushinteger(L, lua_Integer(canvasView.elementList.count))
    return 1
}

/// hs.canvas:minimumTextSize([index], text) -> table
private func canvas_getTextElementSize(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK | LS_TVARARG)
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
private func canvas_canvasDefaultFor(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG,
                   LS_TSTRING,
                   LS_TANY | LS_TOPTIONAL,
                   LS_TBREAK)

    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    let keyName = skin.toNSObject(atIndex: 2) as! String

    guard languageDictionary[keyName] != nil else {
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
            if let langEntry = languageDictionary[keyName] as? NSDictionary,
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
private func canvas_insertElementAtIndex(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG,
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
private func canvas_removeElementAtIndex(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG,
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
private func canvas_elementAttributeAtIndex(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG,
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

    if languageDictionary[keyName] == nil {
        if lua_gettop(L) == 3 {
            // check if keyname ends with _raw
            if keyName.hasSuffix("_raw") {
                let trimmedName = String(keyName.dropLast(4))
                if languageDictionary[trimmedName] != nil {
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
private func canvas_elementKeysAtIndex(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG,
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
        (languageDictionary as! [String: NSDictionary]).forEach { (keyName, keyValue) in
            if let optionalFor = keyValue["optionalFor"] as? [String], let t = ourType, optionalFor.contains(t) {
                list.add(keyName)
            }
        }
    }
    skin.pushNSObject(list)
    return 1
}

/// hs.canvas:canvasDefaults([module]) -> table
private func canvas_canvasDefaults(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG,
                   LS_TBOOLEAN | LS_TOPTIONAL,
                   LS_TBREAK)
    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView

    if lua_gettop(L) == 2 && lua_toboolean(L, 2) != 0 {
        lua_newtable(L)
        for key in (languageDictionary as! [String: Any]).keys {
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
private func canvas_canvasDefaultKeys(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG,
                   LS_TBOOLEAN | LS_TOPTIONAL,
                   LS_TBREAK)
    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView

    let list = NSMutableSet(array: canvasView.canvasDefaults.allKeys)
    if lua_gettop(L) == 2 && lua_toboolean(L, 2) != 0 {
        (languageDictionary as! [String: NSDictionary]).forEach { (keyName, keyValue) in
            if keyValue["default"] != nil {
                list.add(keyName)
            }
        }
    }
    skin.pushNSObject(list)
    return 1
}

/// hs.canvas:canvasElements() -> table
private func canvas_canvasElements(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    skin.pushNSObject(canvasView.elementList, withOptions: LS_NSConversionOptions.nsDescribeUnknownTypes.rawValue)
    return 1
}

/// hs.canvas:elementBounds(index) -> rectTable
private func canvas_elementBoundsAtIndex(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG,
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
private func canvas_assignElementAtIndex(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG,
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

// MARK: - Module Constants

private func pushCompositeTypes(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    LuaSkin.skin(with: L).pushNSObject(COMPOSITING_TYPES as NSDictionary)
    return 1
}

private func pushCollectionTypeTable(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_newtable(L)
    lua_pushinteger(L, lua_Integer(NSWindow.CollectionBehavior([]).rawValue));          lua_setfield(L, -2, "default")
    lua_pushinteger(L, lua_Integer(NSWindow.CollectionBehavior.canJoinAllSpaces.rawValue)); lua_setfield(L, -2, "canJoinAllSpaces")
    lua_pushinteger(L, lua_Integer(NSWindow.CollectionBehavior.moveToActiveSpace.rawValue)); lua_setfield(L, -2, "moveToActiveSpace")
    lua_pushinteger(L, lua_Integer(NSWindow.CollectionBehavior.managed.rawValue));          lua_setfield(L, -2, "managed")
    lua_pushinteger(L, lua_Integer(NSWindow.CollectionBehavior.transient.rawValue));        lua_setfield(L, -2, "transient")
    lua_pushinteger(L, lua_Integer(NSWindow.CollectionBehavior.stationary.rawValue));       lua_setfield(L, -2, "stationary")
    lua_pushinteger(L, lua_Integer(NSWindow.CollectionBehavior.participatesInCycle.rawValue)); lua_setfield(L, -2, "participatesInCycle")
    lua_pushinteger(L, lua_Integer(NSWindow.CollectionBehavior.ignoresCycle.rawValue));     lua_setfield(L, -2, "ignoresCycle")
    lua_pushinteger(L, lua_Integer(NSWindow.CollectionBehavior.fullScreenPrimary.rawValue)); lua_setfield(L, -2, "fullScreenPrimary")
    lua_pushinteger(L, lua_Integer(NSWindow.CollectionBehavior.fullScreenAuxiliary.rawValue)); lua_setfield(L, -2, "fullScreenAuxiliary")
    lua_pushinteger(L, lua_Integer(NSWindow.CollectionBehavior.fullScreenAllowsTiling.rawValue)); lua_setfield(L, -2, "fullScreenAllowsTiling")
    lua_pushinteger(L, lua_Integer(NSWindow.CollectionBehavior.fullScreenDisallowsTiling.rawValue)); lua_setfield(L, -2, "fullScreenDisallowsTiling")
    return 1
}

private func cg_windowLevels(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_newtable(L)
    lua_pushinteger(L, lua_Integer(CGWindowLevelForKey(.minimumWindow)));           lua_setfield(L, -2, "_MinimumWindowLevelKey")
    lua_pushinteger(L, lua_Integer(CGWindowLevelForKey(.desktopWindow)));           lua_setfield(L, -2, "desktop")
    lua_pushinteger(L, lua_Integer(CGWindowLevelForKey(.normalWindow)));            lua_setfield(L, -2, "normal")
    lua_pushinteger(L, lua_Integer(CGWindowLevelForKey(.floatingWindow)));          lua_setfield(L, -2, "floating")
    lua_pushinteger(L, lua_Integer(CGWindowLevelForKey(.tornOffMenuWindow)));       lua_setfield(L, -2, "tornOffMenu")
    lua_pushinteger(L, lua_Integer(CGWindowLevelForKey(.dockWindow)));              lua_setfield(L, -2, "dock")
    lua_pushinteger(L, lua_Integer(CGWindowLevelForKey(.mainMenuWindow)));          lua_setfield(L, -2, "mainMenu")
    lua_pushinteger(L, lua_Integer(CGWindowLevelForKey(.statusWindow)));            lua_setfield(L, -2, "status")
    lua_pushinteger(L, lua_Integer(CGWindowLevelForKey(.modalPanelWindow)));        lua_setfield(L, -2, "modalPanel")
    lua_pushinteger(L, lua_Integer(CGWindowLevelForKey(.popUpMenuWindow)));         lua_setfield(L, -2, "popUpMenu")
    lua_pushinteger(L, lua_Integer(CGWindowLevelForKey(.draggingWindow)));          lua_setfield(L, -2, "dragging")
    lua_pushinteger(L, lua_Integer(CGWindowLevelForKey(.screenSaverWindow)));       lua_setfield(L, -2, "screenSaver")
    lua_pushinteger(L, lua_Integer(CGWindowLevelForKey(.maximumWindow)));           lua_setfield(L, -2, "_MaximumWindowLevelKey")
    lua_pushinteger(L, lua_Integer(CGWindowLevelForKey(.overlayWindow)));           lua_setfield(L, -2, "overlay")
    lua_pushinteger(L, lua_Integer(CGWindowLevelForKey(.helpWindow)));              lua_setfield(L, -2, "help")
    lua_pushinteger(L, lua_Integer(CGWindowLevelForKey(.utilityWindow)));           lua_setfield(L, -2, "utility")
    lua_pushinteger(L, lua_Integer(CGWindowLevelForKey(.desktopIconWindow)));       lua_setfield(L, -2, "desktopIcon")
    lua_pushinteger(L, lua_Integer(CGWindowLevelForKey(.cursorWindow)));            lua_setfield(L, -2, "cursor")
    lua_pushinteger(L, lua_Integer(CGWindowLevelForKey(.assistiveTechHighWindow))); lua_setfield(L, -2, "assistiveTechHigh")
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions

private func pushHSCanvasView(_ L: UnsafeMutablePointer<lua_State>!, obj: Any!) -> Int32 {
    let value = obj as! HSCanvasView
    value.selfRefCount += 1
    let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
    valuePtr.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee = Unmanaged.passRetained(value).toOpaque()
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private func toHSCanvasViewFromLua(_ L: UnsafeMutablePointer<lua_State>!, idx: Int32) -> Any! {
    let skin = LuaSkin.skin(with: L)
    if luaL_testudata(L, idx, USERDATA_TAG) != nil {
        let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
        let opaque = ptr.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee
        return Unmanaged<HSCanvasView>.fromOpaque(opaque).takeUnretainedValue()
    } else {
        skin.logError("expected \(USERDATA_TAG) object, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
        return nil
    }
}

// MARK: - Cosmic Hammer/Lua Infrastructure

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let obj = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    let title: String
    if parentIsWindow(obj) {
        title = NSStringFromRect(RectWithFlippedYCoordinate(obj.window!.frame))
    } else {
        title = NSStringFromRect(obj.frame)
    }
    skin.pushNSObject("\(USERDATA_TAG): \(title) (\(Unmanaged.passUnretained(obj).toOpaque()))" as NSString)
    return 1
}

private func userdata_eq(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let skin = LuaSkin.skin(with: L)
        let obj1 = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
        let obj2 = skin.luaObject(at:2, toClass: "HSCanvasView") as! HSCanvasView
        lua_pushboolean(L, obj1 === obj2 ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func userdata_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!
    let opaque = ptr.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee
    let theView = Unmanaged<HSCanvasView>.fromOpaque(opaque).takeRetainedValue()

    theView.selfRefCount -= 1
    if theView.selfRefCount == 0 {
        if !parentIsWindow(theView) { theView.removeFromSuperview() }
        theView.mouseCallbackRef    = skin.luaUnref(refTable, ref: theView.mouseCallbackRef)
        theView.draggingCallbackRef = skin.luaUnref(refTable, ref: theView.draggingCallbackRef)

        let tile = NSApplication.shared.dockTile
        if let tileView = tile.contentView, tileView === theView {
            tile.contentView = nil
        }

        let theWindow = theView.wrapperWindow
        theWindow?.close()
        theView.wrapperWindow = nil
    }

    // Remove the Metatable so future use of the variable in Lua won't think its valid
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

// Metatable for userdata objects
private var userdata_metaLib: [luaL_Reg] = [
    // affects drawing elements
    luaL_Reg(name: strdup("assignElement"),          func: canvas_assignElementAtIndex),
    luaL_Reg(name: strdup("canvasElements"),         func: canvas_canvasElements),
    luaL_Reg(name: strdup("canvasDefaults"),         func: canvas_canvasDefaults),
    luaL_Reg(name: strdup("canvasMouseEvents"),      func: canvas_canvasMouseEvents),
    luaL_Reg(name: strdup("canvasDefaultKeys"),      func: canvas_canvasDefaultKeys),
    luaL_Reg(name: strdup("canvasDefaultFor"),       func: canvas_canvasDefaultFor),
    luaL_Reg(name: strdup("elementAttribute"),       func: canvas_elementAttributeAtIndex),
    luaL_Reg(name: strdup("elementBounds"),          func: canvas_elementBoundsAtIndex),
    luaL_Reg(name: strdup("elementCount"),           func: canvas_elementCount),
    luaL_Reg(name: strdup("elementKeys"),            func: canvas_elementKeysAtIndex),
    luaL_Reg(name: strdup("imageFromCanvas"),        func: canvas_canvasAsImage),
    luaL_Reg(name: strdup("insertElement"),          func: canvas_insertElementAtIndex),
    luaL_Reg(name: strdup("minimumTextSize"),        func: canvas_getTextElementSize),
    luaL_Reg(name: strdup("removeElement"),          func: canvas_removeElementAtIndex),
    // affects whole canvas
    luaL_Reg(name: strdup("alpha"),                  func: canvas_alpha),
    luaL_Reg(name: strdup("behavior"),               func: canvas_behavior),
    luaL_Reg(name: strdup("clickActivating"),        func: canvas_clickActivating),
    luaL_Reg(name: strdup("delete"),                 func: canvas_delete),
    luaL_Reg(name: strdup("hide"),                   func: canvas_hide),
    luaL_Reg(name: strdup("isOccluded"),             func: canvas_isOccluded),
    luaL_Reg(name: strdup("isShowing"),              func: canvas_isShowing),
    luaL_Reg(name: strdup("level"),                  func: canvas_level),
    luaL_Reg(name: strdup("mouseCallback"),          func: canvas_mouseCallback),
    luaL_Reg(name: strdup("orderAbove"),             func: canvas_orderAbove),
    luaL_Reg(name: strdup("orderBelow"),             func: canvas_orderBelow),
    luaL_Reg(name: strdup("show"),                   func: canvas_show),
    luaL_Reg(name: strdup("size"),                   func: canvas_size),
    luaL_Reg(name: strdup("topLeft"),                func: canvas_topLeft),
    luaL_Reg(name: strdup("transformation"),         func: canvas_canvasTransformation),
    luaL_Reg(name: strdup("wantsLayer"),             func: canvas_wantsLayer),
    luaL_Reg(name: strdup("draggingCallback"),       func: canvas_draggingCallback),
    luaL_Reg(name: strdup("_accessibilitySubrole"),  func: canvas_accessibilitySubrole),
    luaL_Reg(name: strdup("__tostring"),             func: userdata_tostring),
    luaL_Reg(name: strdup("__eq"),                   func: userdata_eq),
    luaL_Reg(name: strdup("__gc"),                   func: userdata_gc),
    luaL_Reg(name: nil, func: nil),
]

// Functions for returned object when module loads
private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("defaultTextStyle"), func: default_textAttributes),
    luaL_Reg(name: strdup("elementSpec"),      func: dumpLanguageDictionary),
    luaL_Reg(name: strdup("new"),              func: canvas_new),
    luaL_Reg(name: strdup("useCustomAccessibilitySubrole"), func: canvas_useCustomAccessibilitySubrole),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libcanvas")
public func luaopen_hs_libcanvas(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    refTable = skin.registerLibrary(withObject: USERDATA_TAG,
                                    functions: &moduleLib,
                                    metaFunctions: nil,
                                    objectFunctions: &userdata_metaLib)

    if languageDictionary == nil { languageDictionary = defineLanguageDictionary() }

    skin.registerPushNSHelper(pushHSCanvasView, forClass: "HSCanvasView")
    skin.registerLuaObjectHelper(toHSCanvasViewFromLua, forClass: "HSCanvasView",
                                 withUserdataMapping: USERDATA_TAG)

    pushCompositeTypes(L);      lua_setfield(L, -2, "compositeTypes")
    pushCollectionTypeTable(L); lua_setfield(L, -2, "windowBehaviors")
    cg_windowLevels(L);         lua_setfield(L, -2, "windowLevels")

    // in case we're reloaded, return to default state
    defaultCustomSubRole = true

    return 1
}
