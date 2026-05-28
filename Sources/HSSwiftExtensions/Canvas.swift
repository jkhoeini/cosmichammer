import Cocoa
import LuaSkin

// MARK: - HSGifAnimator stub
// HSGifAnimator is defined in Canvas.h / imageAdditions.m (ObjC). Since this
// Swift file is compiled in the HSSwiftExtensions target without direct
// visibility of those ObjC headers, we provide a minimal Swift stand-in that
// mirrors the ObjC interface just enough for Canvas.swift to compile.

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

let canvas_USERDATA_TAG = "hs.canvas"
var canvas_refTable: LSRefTable = LUA_NOREF
var canvas_defaultCustomSubRole: Bool = true

// Can't have "static" or "constant" dynamic NSObjects like NSArray, so define in lua_open
var canvas_languageDictionary: NSDictionary!

func canvas_get_objectFromUserdata<T>(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32, _ tag: UnsafePointer<CChar>) -> T {
    let ptr = luaL_checkudata(L, idx, tag)!
    return ptr.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee.assumingMemoryBound(to: T.self).pointee
}

enum AttributeValidity: Int {
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

func canvas_parentIsWindow(_ theView: NSView) -> Bool {
    guard let owningWindow = theView.window else { return false }
    return owningWindow.contentView === theView
}

func canvas_defineLanguageDictionary() -> NSDictionary {
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

func canvas_isValueValidForDictionary(_ keyName: NSString, _ keyValue: Any?, _ attributeDefinition: NSDictionary) -> AttributeValidity {
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
                                    validity = canvas_isValueValidForDictionary(subKey as NSString, obj, subKeyDef)
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
        LuaSkin.skin(with: nil).logError("\(canvas_USERDATA_TAG):\(msg)")
        validity = .invalid
    }
    return validity
}

func canvas_isValueValidForAttribute(_ keyName: NSString, _ keyValue: Any?) -> AttributeValidity {
    guard let attributeDefinition = canvas_languageDictionary[keyName] as? NSDictionary else {
        LuaSkin.skin(with: nil).logError("\(canvas_USERDATA_TAG):\(keyName) is not a valid canvas attribute")
        return .invalid
    }
    return canvas_isValueValidForDictionary(keyName, keyValue, attributeDefinition)
}

func canvas_convertPercentageStringToNumber(_ stringValue: String) -> NSNumber? {
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

func canvas_RectWithFlippedYCoordinate(_ theRect: NSRect) -> NSRect {
    return NSMakeRect(theRect.origin.x,
                      NSScreen.screens[0].frame.size.height - theRect.origin.y - theRect.size.height,
                      theRect.size.width,
                      theRect.size.height)
}

func canvas_orderHelper(_ L: UnsafeMutablePointer<lua_State>!, mode: NSWindow.OrderingMode) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG,
                   LS_TBREAK | LS_TVARARG)

    let canvasView = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    if canvas_parentIsWindow(canvasView) {
        let canvasWindow = canvasView.window as! HSCanvasWindow

        var relativeTo: Int = 0

        if lua_gettop(L) > 1 {
            if lua_type(L, 2) == LUA_TNIL {
                skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG, LS_TNIL, LS_TBREAK)
            } else {
                skin.checkArgs(LS_TUSERDATA, canvas_USERDATA_TAG,
                               LS_TUSERDATA, canvas_USERDATA_TAG,
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


// HSCanvasWindow -> CanvasWindow.swift
// HSCanvasView -> CanvasView.swift
// Module Functions/Methods -> CanvasLuaMethods.swift

// MARK: - Module Constants

func canvas_pushCompositeTypes(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    LuaSkin.skin(with: L).pushNSObject(COMPOSITING_TYPES as NSDictionary)
    return 1
}

func canvas_pushCollectionTypeTable(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
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

func canvas_cg_windowLevels(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
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

func canvas_pushHSCanvasView(_ L: UnsafeMutablePointer<lua_State>!, obj: Any!) -> Int32 {
    let value = obj as! HSCanvasView
    value.selfRefCount += 1
    let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
    valuePtr.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee = Unmanaged.passRetained(value).toOpaque()
    luaL_getmetatable(L, canvas_USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

func canvas_toHSCanvasViewFromLua(_ L: UnsafeMutablePointer<lua_State>!, idx: Int32) -> Any! {
    let skin = LuaSkin.skin(with: L)
    if luaL_testudata(L, idx, canvas_USERDATA_TAG) != nil {
        let ptr = luaL_checkudata(L, idx, canvas_USERDATA_TAG)!
        let opaque = ptr.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee
        return Unmanaged<HSCanvasView>.fromOpaque(opaque).takeUnretainedValue()
    } else {
        skin.logError("expected \(canvas_USERDATA_TAG) object, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
        return nil
    }
}

// MARK: - Cosmic Hammer/Lua Infrastructure

func canvas_userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let obj = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
    let title: String
    if canvas_parentIsWindow(obj) {
        title = NSStringFromRect(canvas_RectWithFlippedYCoordinate(obj.window!.frame))
    } else {
        title = NSStringFromRect(obj.frame)
    }
    skin.pushNSObject("\(canvas_USERDATA_TAG): \(title) (\(Unmanaged.passUnretained(obj).toOpaque()))" as NSString)
    return 1
}

func canvas_userdata_eq(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if luaL_testudata(L, 1, canvas_USERDATA_TAG) != nil && luaL_testudata(L, 2, canvas_USERDATA_TAG) != nil {
        let skin = LuaSkin.skin(with: L)
        let obj1 = skin.luaObject(at:1, toClass: "HSCanvasView") as! HSCanvasView
        let obj2 = skin.luaObject(at:2, toClass: "HSCanvasView") as! HSCanvasView
        lua_pushboolean(L, obj1 === obj2 ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

func canvas_userdata_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let ptr = luaL_checkudata(L, 1, canvas_USERDATA_TAG)!
    let opaque = ptr.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee
    let theView = Unmanaged<HSCanvasView>.fromOpaque(opaque).takeRetainedValue()

    theView.selfRefCount -= 1
    if theView.selfRefCount == 0 {
        if !canvas_parentIsWindow(theView) { theView.removeFromSuperview() }
        theView.mouseCallbackRef    = skin.luaUnref(canvas_refTable, ref: theView.mouseCallbackRef)
        theView.draggingCallbackRef = skin.luaUnref(canvas_refTable, ref: theView.draggingCallbackRef)

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
    luaL_Reg(name: strdup("__tostring"),             func: canvas_userdata_tostring),
    luaL_Reg(name: strdup("__eq"),                   func: canvas_userdata_eq),
    luaL_Reg(name: strdup("__gc"),                   func: canvas_userdata_gc),
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
    // Create ref table in registry
    lua_newtable(L)
    canvas_refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    // Register userdata metatable
    luaL_newmetatable(L, canvas_USERDATA_TAG)
    lua_pushvalue(L, -1)
    lua_setfield(L, -2, "__index")
    luaL_setfuncs(L, &userdata_metaLib, 0)
    lua_pop(L, 1)

    // Create module table
    lua_createtable(L, 0, Int32(moduleLib.count - 1))
    luaL_setfuncs(L, &moduleLib, 0)

    if canvas_languageDictionary == nil { canvas_languageDictionary = canvas_defineLanguageDictionary() }

    canvas_pushCompositeTypes(L);      lua_setfield(L, -2, "compositeTypes")
    canvas_pushCollectionTypeTable(L); lua_setfield(L, -2, "windowBehaviors")
    canvas_cg_windowLevels(L);         lua_setfield(L, -2, "windowLevels")

    // in case we're reloaded, return to default state
    canvas_defaultCustomSubRole = true

    return 1
}
