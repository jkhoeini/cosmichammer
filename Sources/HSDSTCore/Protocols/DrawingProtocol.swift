import Foundation

// MARK: - Value types

public struct DrawingColor: Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double = 0, green: Double = 0, blue: Double = 0, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static func hex(_ hex: String) -> DrawingColor? {
        var h = hex
        if h.hasPrefix("#") { h = String(h.dropFirst()) }
        guard h.count == 6 || h.count == 8 else { return nil }
        guard let value = UInt64(h, radix: 16) else { return nil }
        if h.count == 6 {
            return DrawingColor(
                red: Double((value >> 16) & 0xFF) / 255.0,
                green: Double((value >> 8) & 0xFF) / 255.0,
                blue: Double(value & 0xFF) / 255.0,
                alpha: 1.0
            )
        } else {
            return DrawingColor(
                red: Double((value >> 24) & 0xFF) / 255.0,
                green: Double((value >> 16) & 0xFF) / 255.0,
                blue: Double((value >> 8) & 0xFF) / 255.0,
                alpha: Double(value & 0xFF) / 255.0
            )
        }
    }

    public static func hsb(hue: Double, saturation: Double, brightness: Double,
                           alpha: Double = 1.0) -> DrawingColor {
        let h = hue.truncatingRemainder(dividingBy: 360) / 60
        let c = brightness * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let (r, g, b): (Double, Double, Double)
        switch Int(h) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return DrawingColor(red: r + m, green: g + m, blue: b + m, alpha: alpha)
    }

    public static func grayscale(_ white: Double, alpha: Double = 1.0) -> DrawingColor {
        DrawingColor(red: white, green: white, blue: white, alpha: alpha)
    }

    public static let black = DrawingColor(red: 0, green: 0, blue: 0, alpha: 1)
    public static let white = DrawingColor(red: 1, green: 1, blue: 1, alpha: 1)
    public static let clear = DrawingColor(red: 0, green: 0, blue: 0, alpha: 0)
}

public struct DrawingPoint: Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }
}

public struct DrawingSize: Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double = 0, height: Double = 0) {
        self.width = width
        self.height = height
    }
}

public struct DrawingRect: Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct DrawingFont: Sendable {
    public var name: String
    public var size: Double

    public init(name: String = "Helvetica", size: Double = 12) {
        self.name = name
        self.size = size
    }
}

public struct DrawingShadow: Sendable {
    public var offset: DrawingPoint
    public var blurRadius: Double
    public var color: DrawingColor

    public init(offset: DrawingPoint = DrawingPoint(), blurRadius: Double = 0,
                color: DrawingColor = .black) {
        self.offset = offset
        self.blurRadius = blurRadius
        self.color = color
    }
}

public struct DrawingTransform: Sendable {
    public var m11: Double
    public var m12: Double
    public var m21: Double
    public var m22: Double
    public var tX: Double
    public var tY: Double

    public init(m11: Double = 1, m12: Double = 0, m21: Double = 0, m22: Double = 1,
                tX: Double = 0, tY: Double = 0) {
        self.m11 = m11
        self.m12 = m12
        self.m21 = m21
        self.m22 = m22
        self.tX = tX
        self.tY = tY
    }

    public static let identity = DrawingTransform()
}

public enum CompositingOperation: Int, Sendable {
    case clear
    case copy
    case sourceOver
    case sourceIn
    case sourceOut
    case sourceAtop
    case destinationOver
    case destinationIn
    case destinationOut
    case destinationAtop
    case xor
    case plusDarker
    case plusLighter
}

public enum LineJoinStyle: Int, Sendable {
    case miter
    case round
    case bevel
}

public enum LineCapStyle: Int, Sendable {
    case butt
    case round
    case square
}

public enum WindingRule: Int, Sendable {
    case evenOdd
    case nonZero
}

public enum ImageFormat: Int, Sendable {
    case png
    case tiff
    case bmp
    case gif
    case jpeg
}

public enum GradientType: Int, Sendable {
    case linear
    case radial
}

public struct GradientInfo: Sendable {
    public var colors: [DrawingColor]
    public var type: GradientType
    public var angle: Double

    public init(colors: [DrawingColor] = [], type: GradientType = .linear, angle: Double = 0) {
        self.colors = colors
        self.type = type
        self.angle = angle
    }
}

// MARK: - Protocol

public protocol DrawingProtocol: AnyObject {

    // MARK: Image operations

    func loadImage(fromFile path: String) -> UInt64?
    func loadImage(fromData data: Data) -> UInt64?
    func createImage(width: Int, height: Int, colorSpace: String) -> UInt64?
    func imageSize(imageID: UInt64) -> DrawingSize?
    func exportImage(imageID: UInt64, format: ImageFormat, properties: [String: Any]) -> Data?
    func cropImage(imageID: UInt64, rect: DrawingRect) -> UInt64?
    func resizeImage(imageID: UInt64, size: DrawingSize) -> UInt64?
    func rotateImage(imageID: UInt64, degrees: Double) -> UInt64?
    func flipImage(imageID: UInt64, horizontal: Bool) -> UInt64?
    func pixelColor(imageID: UInt64, x: Int, y: Int) -> DrawingColor?
    func iconForFile(path: String) -> UInt64?
    func iconForFileType(type: String) -> UInt64?
    func extractVideoThumbnail(path: String, atTime: Double) -> UInt64?
    func destroyImage(imageID: UInt64) -> Bool

    // MARK: Color operations

    func colorFromHex(_ hex: String) -> DrawingColor?
    func colorFromName(_ name: String) -> DrawingColor?
    func availableColorLists() -> [String]
    func colorsInList(named: String) -> [String: DrawingColor]

    // MARK: Font operations

    func availableFonts() -> [String]
    func fontMetrics(name: String, size: Double) -> (ascender: Double, descender: Double, lineHeight: Double)?

    // MARK: Path operations

    func createPath() -> UInt64
    func pathAddRect(pathID: UInt64, rect: DrawingRect)
    func pathAddOval(pathID: UInt64, inRect: DrawingRect)
    func pathAddRoundedRect(pathID: UInt64, rect: DrawingRect, xRadius: Double, yRadius: Double)
    func pathAddArc(pathID: UInt64, center: DrawingPoint, radius: Double,
                    startAngle: Double, endAngle: Double, clockwise: Bool)
    func pathMoveTo(pathID: UInt64, point: DrawingPoint)
    func pathLineTo(pathID: UInt64, point: DrawingPoint)
    func pathCurveTo(pathID: UInt64, point: DrawingPoint,
                     control1: DrawingPoint, control2: DrawingPoint)
    func pathClose(pathID: UInt64)
    func pathContains(pathID: UInt64, point: DrawingPoint, rule: WindingRule) -> Bool
    func destroyPath(pathID: UInt64) -> Bool
}
