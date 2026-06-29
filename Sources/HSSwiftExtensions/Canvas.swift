import Cocoa
import CLua
import HSDSTCore
import Lua
import os.log

// MARK: - HSGifAnimator stub
// HSGifAnimator is defined in Canvas.h / imageAdditions.m (ObjC). Since this
// Swift file is compiled in the HSSwiftExtensions target without direct
// visibility of those ObjC headers, we provide a minimal Swift stand-in that
// mirrors the ObjC interface just enough for Canvas.swift to compile.

class HSGifAnimator: NSObject {
    weak var animatingRepresentation: NSBitmapImageRep?
    weak var inCanvas: HSCanvasView?
    var isRunning: Bool = false

    init(image: NSImage, forCanvas canvas: HSCanvasView) {
        self.inCanvas = canvas
        super.init()
        for case let rep as NSBitmapImageRep in image.representations {
            if (rep.value(forProperty: .frameCount) as? NSNumber)?.intValue ?? 0 > 1 {
                self.animatingRepresentation = rep
                break
            }
        }
    }

    func startAnimating() {
        guard !isRunning, let rep = animatingRepresentation else { return }
        isRunning = true
        let frameCount = (rep.value(forProperty: .frameCount) as? NSNumber)?.intValue ?? 1
        assert(frameCount >= 1, "startAnimating: frameCount must be at least 1")
        guard frameCount > 1 else { return }
        advanceFrame(rep: rep, frameCount: frameCount)
    }

    func stopAnimating() {
        isRunning = false
    }

    private func advanceFrame(rep: NSBitmapImageRep, frameCount: Int) {
        precondition(frameCount > 0, "advanceFrame: frameCount must be positive")
        guard isRunning else { return }
        let current = (rep.value(forProperty: .currentFrame) as? NSNumber)?.intValue ?? 0
        assert(current >= 0, "advanceFrame: current frame must be non-negative")
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
// canvas_refTable removed — LuaValue? manages callback lifetime
var canvas_defaultCustomSubRole: Bool = true
private var activeCanvasMouseCallbackCount = 0
private var activeCanvasDraggingCallbackCount = 0

private func recordActiveCanvasMouseCallbackGauge(_ L: UnsafeMutablePointer<lua_State>? = lua_getCurrentState()) {
    let telemetry = L.map { environmentGet($0).telemetry } ?? environmentGetGlobalOrNil()?.telemetry
    telemetry?.recordMetric(
        name: "cosmichammer.canvas.mouse.callback.active",
        kind: .gauge,
        value: Double(activeCanvasMouseCallbackCount),
        attributes: [:],
        unit: "1"
    )
}

func setCanvasMouseCallbackCounted(_ view: HSCanvasView, _ active: Bool, L: UnsafeMutablePointer<lua_State>? = lua_getCurrentState()) {
    guard view.countedMouseCallbackActive != active else { return }
    view.countedMouseCallbackActive = active
    if active {
        activeCanvasMouseCallbackCount += 1
    } else {
        activeCanvasMouseCallbackCount = max(0, activeCanvasMouseCallbackCount - 1)
    }
    recordActiveCanvasMouseCallbackGauge(L)
}

private func recordActiveCanvasDraggingCallbackGauge(_ L: UnsafeMutablePointer<lua_State>? = lua_getCurrentState()) {
    let telemetry = L.map { environmentGet($0).telemetry } ?? environmentGetGlobalOrNil()?.telemetry
    telemetry?.recordMetric(
        name: "cosmichammer.canvas.dragging.callback.active",
        kind: .gauge,
        value: Double(activeCanvasDraggingCallbackCount),
        attributes: [:],
        unit: "1"
    )
}

func setCanvasDraggingCallbackCounted(_ view: HSCanvasView, _ active: Bool, L: UnsafeMutablePointer<lua_State>? = lua_getCurrentState()) {
    guard view.countedDraggingCallbackActive != active else { return }
    view.countedDraggingCallbackActive = active
    if active {
        activeCanvasDraggingCallbackCount += 1
    } else {
        activeCanvasDraggingCallbackCount = max(0, activeCanvasDraggingCallbackCount - 1)
    }
    recordActiveCanvasDraggingCallbackGauge(L)
}

// Can't have "static" or "constant" dynamic NSObjects like NSArray, so define in lua_open
var canvas_languageDictionary: NSDictionary!

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
    precondition(keyName.length > 0, "canvas_isValueValidForDictionary: keyName must not be empty")
    precondition(attributeDefinition.count > 0, "canvas_isValueValidForDictionary: attributeDefinition must not be empty")

    guard let keyValue = keyValue, !(keyValue is NSNull) else {
        return canvas_validateNullability(keyName, attributeDefinition)
    }

    if let err = canvas_validateTypeAndRange(keyName, keyValue, attributeDefinition) {
        os_log(.error, "%{public}s:%{public}s", canvas_USERDATA_TAG, err)
        return .invalid
    }
    if let err = canvas_validateSubKeys(keyName, keyValue, attributeDefinition) {
        os_log(.error, "%{public}s:%{public}s", canvas_USERDATA_TAG, err)
        return .invalid
    }
    let (validity, err) = canvas_validateArrayMembers(keyName, keyValue, attributeDefinition)
    if let err = err {
        os_log(.error, "%{public}s:%{public}s", canvas_USERDATA_TAG, err)
        return .invalid
    }
    if validity != .valid { return validity }

    if keyName.isEqual(to: "textFont"), let fontName = keyValue as? String {
        if NSFont(name: fontName, size: 0.0) == nil {
            os_log(.error, "%{public}s:%{public}s", canvas_USERDATA_TAG, "\(fontName) is not a recognized font name")
            return .invalid
        }
    }
    return .valid
}

private func canvas_validateNullability(_ keyName: NSString, _ attributeDefinition: NSDictionary) -> AttributeValidity {
    if let nullable = attributeDefinition["nullable"] as? NSNumber, nullable.boolValue {
        return .nulling
    }
    os_log(.error, "%{public}s:%{public}s", canvas_USERDATA_TAG, "\(keyName) is not nullable")
    return .invalid
}

private func canvas_validateTypeAndRange(_ keyName: NSString, _ keyValue: Any, _ def: NSDictionary) -> String? {
    if let classArray = def["class"] as? [AnyClass] {
        if !classArray.contains(where: { (keyValue as AnyObject).isKind(of: $0) }) {
            return "\(keyName) must be a \(def["luaClass"] ?? "unknown")"
        }
    }
    if let expectedObjCType = def["objCType"] as? String, let nsValue = keyValue as? NSNumber {
        if String(cString: nsValue.objCType) != expectedObjCType {
            return "\(keyName) must be a \(def["luaClass"] ?? "unknown")"
        }
    }
    if let nsNumber = keyValue as? NSNumber, def["objCType"] == nil {
        if !nsNumber.doubleValue.isFinite { return "\(keyName) must be a finite number" }
    }
    if let values = def["values"] as? [String], let strVal = keyValue as? String {
        if !values.contains(strVal) { return "\(keyName) must be one of \(values.joined(separator: ", "))" }
    }
    if let maxNumber = def["maxNumber"] as? NSNumber, let numVal = keyValue as? NSNumber {
        if numVal.doubleValue > maxNumber.doubleValue { return "\(keyName) must be <= \(maxNumber.doubleValue)" }
    }
    if let minNumber = def["minNumber"] as? NSNumber, let numVal = keyValue as? NSNumber {
        if numVal.doubleValue < minNumber.doubleValue { return "\(keyName) must be >= \(minNumber.doubleValue)" }
    }
    return nil
}

private func canvas_validateSubKeys(_ keyName: NSString, _ keyValue: Any, _ def: NSDictionary) -> String? {
    guard let dictValue = keyValue as? NSDictionary, let subKeys = def["keys"] as? NSDictionary else { return nil }

    for case let subKeyName as String in subKeys.allKeys {
        guard let subKeyDef = subKeys[subKeyName] as? NSDictionary else { continue }
        let subVal = dictValue[subKeyName]
        let prefix = "field \(subKeyName) of \(keyName)"

        if let subClassArray = subKeyDef["class"] as? [AnyClass] {
            if !subClassArray.contains(where: { (subVal as AnyObject?)?.isKind(of: $0) == true }) {
                return "\(prefix) must be a \(subKeyDef["luaClass"] ?? "unknown")"
            }
        }
        if let expectedObjCType = subKeyDef["objCType"] as? String, let nsValue = subVal as? NSNumber {
            if String(cString: nsValue.objCType) != expectedObjCType {
                return "\(prefix) must be a \(subKeyDef["luaClass"] ?? "unknown")"
            }
        }
        if let nsNumber = subVal as? NSNumber, subKeyDef["objCType"] == nil {
            if !nsNumber.doubleValue.isFinite { return "\(prefix) must be a finite number" }
        }
        if let values = subKeyDef["values"] as? [String], let strVal = subVal as? String {
            if !values.contains(strVal) { return "\(prefix) must be one of \(values.joined(separator: ", "))" }
        }
        if let maxNumber = subKeyDef["maxNumber"] as? NSNumber, let numVal = subVal as? NSNumber {
            if numVal.doubleValue > maxNumber.doubleValue { return "\(prefix) must be <= \(maxNumber.doubleValue)" }
        }
        if let minNumber = subKeyDef["minNumber"] as? NSNumber, let numVal = subVal as? NSNumber {
            if numVal.doubleValue < minNumber.doubleValue { return "\(prefix) must be >= \(minNumber.doubleValue)" }
        }
    }
    return nil
}

private func canvas_validateArrayMembers(_ keyName: NSString, _ keyValue: Any, _ def: NSDictionary) -> (AttributeValidity, String?) {
    guard let arrayValue = keyValue as? NSArray, arrayValue.count > 0 else { return (.valid, nil) }
    guard let memberClass = def["memberClass"] as? AnyClass else { return (.valid, nil) }

    for i in 0..<arrayValue.count {
        if !(arrayValue[i] as AnyObject).isKind(of: memberClass) {
            return (.invalid, "\(keyName) must be an array of \(def["memberLuaClass"] ?? "unknown") values")
        }
        if let dictItem = arrayValue[i] as? NSDictionary,
           let memberClassKeys = def["memberClassKeys"] as? NSDictionary {
            for case let (subKey as String, obj) in dictItem {
                if let subKeyDef = memberClassKeys[subKey] as? NSDictionary {
                    let v = canvas_isValueValidForDictionary(subKey as NSString, obj, subKeyDef)
                    if v != .valid { return (v, nil) }
                } else {
                    return (.invalid, "\(subKey) is not a valid subkey for a \(def["memberLuaClass"] ?? "unknown") value")
                }
            }
        }
    }
    return (.valid, nil)
}

func canvas_isValueValidForAttribute(_ keyName: NSString, _ keyValue: Any?) -> AttributeValidity {
    precondition(keyName.length > 0, "canvas_isValueValidForAttribute: keyName must not be empty")
    guard let attributeDefinition = canvas_languageDictionary[keyName] as? NSDictionary else {
        os_log(.error, "%{public}s:%{public}@ is not a valid canvas attribute", canvas_USERDATA_TAG, keyName)
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
    let primaryHeight: Double
    if let env = environmentGetGlobalOrNil(),
       let primary = env.screen.primaryScreen() {
        primaryHeight = primary.frame.height
    } else {
        primaryHeight = NSScreen.screens[0].frame.size.height
    }
    return NSMakeRect(theRect.origin.x,
                      primaryHeight - theRect.origin.y - theRect.size.height,
                      theRect.size.width,
                      theRect.size.height)
}

func canvas_orderHelper(_ L: UnsafeMutablePointer<lua_State>!, mode: NSWindow.OrderingMode) -> Int32 {
    precondition(L != nil, "canvas_orderHelper: Lua state must not be nil")
    luaL_checkudata(L, 1, canvas_USERDATA_TAG)

    let canvasView = canvas_toHSCanvasViewFromLua(L, idx: 1) as! HSCanvasView
    if canvas_parentIsWindow(canvasView) {
        let canvasWindow = canvasView.window as! HSCanvasWindow

        var relativeTo: Int = 0

        if lua_gettop(L) > 1 {
            if lua_type(L, 2) != LUA_TNIL {
                luaL_checkudata(L, 2, canvas_USERDATA_TAG)
                let otherView = canvas_toHSCanvasViewFromLua(L, idx: 2) as! HSCanvasView
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

// HSCanvasWindow -> CanvasWindow.swift
// HSCanvasView -> CanvasView.swift
// Module Functions/Methods -> CanvasLuaMethods.swift

// MARK: - Module Constants

func canvas_pushCompositeTypes(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_pushany(L, COMPOSITING_TYPES)
    return 1
}

func canvas_pushCollectionTypeTable(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_newtable(L)
    L.push(lua_Integer(NSWindow.CollectionBehavior([]).rawValue));          lua_setfield(L, -2, "default")
    L.push(lua_Integer(NSWindow.CollectionBehavior.canJoinAllSpaces.rawValue)); lua_setfield(L, -2, "canJoinAllSpaces")
    L.push(lua_Integer(NSWindow.CollectionBehavior.moveToActiveSpace.rawValue)); lua_setfield(L, -2, "moveToActiveSpace")
    L.push(lua_Integer(NSWindow.CollectionBehavior.managed.rawValue));          lua_setfield(L, -2, "managed")
    L.push(lua_Integer(NSWindow.CollectionBehavior.transient.rawValue));        lua_setfield(L, -2, "transient")
    L.push(lua_Integer(NSWindow.CollectionBehavior.stationary.rawValue));       lua_setfield(L, -2, "stationary")
    L.push(lua_Integer(NSWindow.CollectionBehavior.participatesInCycle.rawValue)); lua_setfield(L, -2, "participatesInCycle")
    L.push(lua_Integer(NSWindow.CollectionBehavior.ignoresCycle.rawValue));     lua_setfield(L, -2, "ignoresCycle")
    L.push(lua_Integer(NSWindow.CollectionBehavior.fullScreenPrimary.rawValue)); lua_setfield(L, -2, "fullScreenPrimary")
    L.push(lua_Integer(NSWindow.CollectionBehavior.fullScreenAuxiliary.rawValue)); lua_setfield(L, -2, "fullScreenAuxiliary")
    L.push(lua_Integer(NSWindow.CollectionBehavior.fullScreenAllowsTiling.rawValue)); lua_setfield(L, -2, "fullScreenAllowsTiling")
    L.push(lua_Integer(NSWindow.CollectionBehavior.fullScreenDisallowsTiling.rawValue)); lua_setfield(L, -2, "fullScreenDisallowsTiling")
    return 1
}

func canvas_cg_windowLevels(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_newtable(L)
    L.push(lua_Integer(CGWindowLevelForKey(.minimumWindow)));           lua_setfield(L, -2, "_MinimumWindowLevelKey")
    L.push(lua_Integer(CGWindowLevelForKey(.desktopWindow)));           lua_setfield(L, -2, "desktop")
    L.push(lua_Integer(CGWindowLevelForKey(.normalWindow)));            lua_setfield(L, -2, "normal")
    L.push(lua_Integer(CGWindowLevelForKey(.floatingWindow)));          lua_setfield(L, -2, "floating")
    L.push(lua_Integer(CGWindowLevelForKey(.tornOffMenuWindow)));       lua_setfield(L, -2, "tornOffMenu")
    L.push(lua_Integer(CGWindowLevelForKey(.dockWindow)));              lua_setfield(L, -2, "dock")
    L.push(lua_Integer(CGWindowLevelForKey(.mainMenuWindow)));          lua_setfield(L, -2, "mainMenu")
    L.push(lua_Integer(CGWindowLevelForKey(.statusWindow)));            lua_setfield(L, -2, "status")
    L.push(lua_Integer(CGWindowLevelForKey(.modalPanelWindow)));        lua_setfield(L, -2, "modalPanel")
    L.push(lua_Integer(CGWindowLevelForKey(.popUpMenuWindow)));         lua_setfield(L, -2, "popUpMenu")
    L.push(lua_Integer(CGWindowLevelForKey(.draggingWindow)));          lua_setfield(L, -2, "dragging")
    L.push(lua_Integer(CGWindowLevelForKey(.screenSaverWindow)));       lua_setfield(L, -2, "screenSaver")
    L.push(lua_Integer(CGWindowLevelForKey(.maximumWindow)));           lua_setfield(L, -2, "_MaximumWindowLevelKey")
    L.push(lua_Integer(CGWindowLevelForKey(.overlayWindow)));           lua_setfield(L, -2, "overlay")
    L.push(lua_Integer(CGWindowLevelForKey(.helpWindow)));              lua_setfield(L, -2, "help")
    L.push(lua_Integer(CGWindowLevelForKey(.utilityWindow)));           lua_setfield(L, -2, "utility")
    L.push(lua_Integer(CGWindowLevelForKey(.desktopIconWindow)));       lua_setfield(L, -2, "desktopIcon")
    L.push(lua_Integer(CGWindowLevelForKey(.cursorWindow)));            lua_setfield(L, -2, "cursor")
    L.push(lua_Integer(CGWindowLevelForKey(.assistiveTechHighWindow))); lua_setfield(L, -2, "assistiveTechHigh")
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions

func canvas_pushHSCanvasView(_ L: UnsafeMutablePointer<lua_State>!, obj: Any!) -> Int32 {
    precondition(L != nil, "canvas_pushHSCanvasView: Lua state must not be nil")
    precondition(obj != nil, "canvas_pushHSCanvasView: obj must not be nil")
    let value = obj as! HSCanvasView
    assert(value.selfRefCount >= 0, "canvas_pushHSCanvasView: selfRefCount must be non-negative before increment")
    value.selfRefCount += 1
    L.push(userdata: value)
    return 1
}

func canvas_toHSCanvasViewFromLua(_ L: UnsafeMutablePointer<lua_State>!, idx: Int32) -> Any! {
    precondition(L != nil, "canvas_toHSCanvasViewFromLua: Lua state must not be nil")
    if let view: HSCanvasView = L.touserdata(idx) {
        return view
    } else {
        os_log(.error, "expected %{public}s object, found %{public}s",
               canvas_USERDATA_TAG, String(cString: lua_typename(L, lua_type(L, idx))))
        return nil
    }
}

// MARK: - Cosmic Hammer/Lua Infrastructure

func canvas_userdata_tostring(_ L: LuaState) throws -> CInt {
    let obj: HSCanvasView = try L.checkArgument(1)
    let title: String
    if canvas_parentIsWindow(obj) {
        title = NSStringFromRect(canvas_RectWithFlippedYCoordinate(obj.window!.frame))
    } else {
        title = NSStringFromRect(obj.frame)
    }
    L.push("\(canvas_USERDATA_TAG): \(title) (\(lua_topointer(L, 1)!))")
    return 1
}

// Custom __gc is installed via the post-registration closure below.
// This standalone function is only used for the __gc closure and is kept
// private to signal that callers should not invoke it directly.
private func canvas_teardownView(_ theView: HSCanvasView) {
    assert(theView.selfRefCount > 0, "canvas_teardownView: selfRefCount must be positive before decrement")
    theView.selfRefCount -= 1
    if theView.selfRefCount == 0 {
        if !canvas_parentIsWindow(theView) { theView.removeFromSuperview() }
        setCanvasMouseCallbackCounted(theView, false)
        setCanvasDraggingCallbackCounted(theView, false)
        theView.mouseCallbackFn = nil
        theView.draggingCallbackFn = nil
        theView.selfRef = nil  // release any fade-animation registry reference

        let tile = NSApplication.shared.dockTile
        if let tileView = tile.contentView, tileView === theView {
            tile.contentView = nil
        }

        let theWindow = theView.wrapperWindow
        theWindow?.close()
        theView.wrapperWindow = nil
    }
}

@_cdecl("luaopen_hs_libcanvas")
public func luaopen_hs_libcanvas(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    precondition(L != nil, "luaopen_hs_libcanvas: Lua state must not be nil")
    return runEntryPoint(L) { L in
        // Register idiomatic Metatable<HSCanvasView> with LuaSwift.
        // This creates an internal metatable "LuaSwift_Type_HSCanvasView" and sets __gc
        // to LuaSwift's gcUserdata (which deinitializes the Any box).
        L.register(Metatable<HSCanvasView>(
            fields: [:],
            tostring: .closure(canvas_userdata_tostring)
        ))

        // -- Post-registration metatable patching --
        // LuaSwift's register() always installs its own gcUserdata as __gc, which
        // only deinitializes the Any box. We MUST replace it with a custom __gc
        // that first tears down the view (close window, drop callbacks)
        // and THEN deinitializes the Any box.
        L.pushMetatable(for: HSCanvasView.self)

        // Replace __gc with our explicit teardown + deinitialize
        L.push({ (L: LuaState!) -> CInt in
            if let theView: HSCanvasView = L.touserdata(1) {
                canvas_teardownView(theView)
            }
            // Now deinitialize the Any box (same as LuaSwift's gcUserdata)
            let rawptr = lua_touserdata(L, 1)!
            let anyPtr = rawptr.assumingMemoryBound(to: Any.self)
            anyPtr.deinitialize(count: 1)
            // Remove the Metatable so future use of the variable in Lua won't think its valid
            lua_pushnil(L)
            lua_setmetatable(L, 1)
            return 0
        })
        lua_setfield(L, -2, "__gc")

        // __eq
        L.push({ (L: LuaState!) -> CInt in
            if let obj1: HSCanvasView = L.touserdata(1),
               let obj2: HSCanvasView = L.touserdata(2) {
                L.push(obj1 === obj2)
            } else {
                L.push(false)
            }
            return 1
        })
        lua_setfield(L, -2, "__eq")

        // __index = self (metatable is its own __index)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")

        // Set __type and __name for assertIsUserdataOfType and tostring
        L.push(canvas_USERDATA_TAG)
        lua_setfield(L, -2, "__type")
        L.push(canvas_USERDATA_TAG)
        lua_setfield(L, -2, "__name")

        // Register all methods on the metatable
        // affects drawing elements
        L.push(canvas_assignElementAtIndex);    lua_setfield(L, -2, "assignElement")
        L.push(canvas_canvasElements);          lua_setfield(L, -2, "canvasElements")
        L.push(canvas_canvasDefaults);          lua_setfield(L, -2, "canvasDefaults")
        L.push(canvas_canvasMouseEvents);       lua_setfield(L, -2, "canvasMouseEvents")
        L.push(canvas_canvasDefaultKeys);       lua_setfield(L, -2, "canvasDefaultKeys")
        L.push(canvas_canvasDefaultFor);        lua_setfield(L, -2, "canvasDefaultFor")
        L.push(canvas_elementAttributeAtIndex); lua_setfield(L, -2, "elementAttribute")
        L.push(canvas_elementBoundsAtIndex);    lua_setfield(L, -2, "elementBounds")
        L.push(canvas_elementCount);            lua_setfield(L, -2, "elementCount")
        L.push(canvas_elementKeysAtIndex);      lua_setfield(L, -2, "elementKeys")
        L.push(canvas_canvasAsImage);           lua_setfield(L, -2, "imageFromCanvas")
        L.push(canvas_insertElementAtIndex);    lua_setfield(L, -2, "insertElement")
        L.push(canvas_getTextElementSize);      lua_setfield(L, -2, "minimumTextSize")
        L.push(canvas_removeElementAtIndex);    lua_setfield(L, -2, "removeElement")
        // affects whole canvas
        L.push(canvas_alpha);                   lua_setfield(L, -2, "alpha")
        L.push(canvas_behavior);                lua_setfield(L, -2, "behavior")
        L.push(canvas_clickActivating);         lua_setfield(L, -2, "clickActivating")
        L.push(canvas_delete);                  lua_setfield(L, -2, "delete")
        L.push(canvas_hide);                    lua_setfield(L, -2, "hide")
        L.push(canvas_isOccluded);              lua_setfield(L, -2, "isOccluded")
        L.push(canvas_isShowing);               lua_setfield(L, -2, "isShowing")
        L.push(canvas_level);                   lua_setfield(L, -2, "level")
        L.push(canvas_mouseCallback);           lua_setfield(L, -2, "mouseCallback")
        L.push(canvas_orderAbove);              lua_setfield(L, -2, "orderAbove")
        L.push(canvas_orderBelow);              lua_setfield(L, -2, "orderBelow")
        L.push(canvas_show);                    lua_setfield(L, -2, "show")
        L.push(canvas_size);                    lua_setfield(L, -2, "size")
        L.push(canvas_topLeft);                 lua_setfield(L, -2, "topLeft")
        L.push(canvas_canvasTransformation);    lua_setfield(L, -2, "transformation")
        L.push(canvas_wantsLayer);              lua_setfield(L, -2, "wantsLayer")
        L.push(canvas_draggingCallback);        lua_setfield(L, -2, "draggingCallback")
        L.push(canvas_accessibilitySubrole);    lua_setfield(L, -2, "_accessibilitySubrole")

        // Alias the metatable under the legacy registry name "hs.canvas" so that
        // core_getObjectMetatable("hs.canvas") and luaL_testudata still resolve.
        lua_setfield(L, LUA_REGISTRYINDEX_VALUE, canvas_USERDATA_TAG)

        // Create module table
        lua_createtable(L, 0, 4)
        L.push(default_textAttributes);                lua_setfield(L, -2, "defaultTextStyle")
        L.push(dumpLanguageDictionary);                lua_setfield(L, -2, "elementSpec")
        L.push(canvas_new);                            lua_setfield(L, -2, "new")
        L.push(canvas_useCustomAccessibilitySubrole);  lua_setfield(L, -2, "useCustomAccessibilitySubrole")

        if canvas_languageDictionary == nil { canvas_languageDictionary = canvas_defineLanguageDictionary() }

        canvas_pushCompositeTypes(L);      lua_setfield(L, -2, "compositeTypes")
        canvas_pushCollectionTypeTable(L); lua_setfield(L, -2, "windowBehaviors")
        canvas_cg_windowLevels(L);         lua_setfield(L, -2, "windowLevels")

        // in case we're reloaded, return to default state
        canvas_defaultCustomSubRole = true
    }
}
