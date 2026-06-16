import Foundation
import HSDSTCore

public final class SimulatedDrawing: DrawingProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    private var nextID: UInt64 = 1

    public enum PathElement: Sendable {
        case rect(DrawingRect)
        case oval(DrawingRect)
        case roundedRect(DrawingRect, xRadius: Double, yRadius: Double)
        case arc(center: DrawingPoint, radius: Double, startAngle: Double, endAngle: Double, clockwise: Bool)
        case moveTo(DrawingPoint)
        case lineTo(DrawingPoint)
        case curveTo(DrawingPoint, control1: DrawingPoint, control2: DrawingPoint)
        case close
    }

    public var images: [UInt64: (size: DrawingSize, colorSpace: String)] = [:]
    public var imageData: [UInt64: Data] = [:]
    public var loadedFilePaths: [UInt64: String] = [:]
    public var paths: [UInt64: [PathElement]] = [:]
    public var namedColors: [String: DrawingColor] = [
        "red": DrawingColor(red: 1, green: 0, blue: 0, alpha: 1),
        "green": DrawingColor(red: 0, green: 1, blue: 0, alpha: 1),
        "blue": DrawingColor(red: 0, green: 0, blue: 1, alpha: 1),
        "black": .black,
        "white": .white,
    ]
    public var colorLists: [String: [String: DrawingColor]] = [
        "System": [
            "systemRedColor": DrawingColor(red: 1, green: 0.23, blue: 0.19, alpha: 1),
            "systemBlueColor": DrawingColor(red: 0, green: 0.48, blue: 1, alpha: 1),
        ]
    ]
    public var fonts: [String] = ["Helvetica", "Helvetica-Bold", "Courier", "Times-Roman", "Menlo"]
    public var fontMetricsMap: [String: (ascender: Double, descender: Double, lineHeight: Double)] = [:]

    // 1x1 PNG stub for export operations
    private static let pngStub = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
        0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
        0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
        0x00, 0x00, 0x02, 0x00, 0x01, 0xE2, 0x21, 0xBC,
        0x33, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
        0x44, 0xAE, 0x42, 0x60, 0x82,
    ])

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    private func allocateID() -> UInt64 {
        let id = nextID
        nextID += 1
        return id
    }

    // MARK: - Image operations

    public func loadImage(fromFile path: String) -> UInt64? {
        if rng.boolean(probability: faults.fileReadFailProbability) { return nil }
        let id = allocateID()
        images[id] = (size: DrawingSize(width: 100, height: 100), colorSpace: "sRGB")
        loadedFilePaths[id] = path
        return id
    }

    public func loadImage(fromData data: Data) -> UInt64? {
        guard !data.isEmpty else { return nil }
        let id = allocateID()
        images[id] = (size: DrawingSize(width: 100, height: 100), colorSpace: "sRGB")
        imageData[id] = data
        return id
    }

    public func createImage(width: Int, height: Int, colorSpace: String) -> UInt64? {
        guard width > 0, height > 0 else { return nil }
        let id = allocateID()
        images[id] = (size: DrawingSize(width: Double(width), height: Double(height)),
                      colorSpace: colorSpace)
        return id
    }

    public func imageSize(imageID: UInt64) -> DrawingSize? {
        images[imageID]?.size
    }

    public func exportImage(imageID: UInt64, format: ImageFormat, properties: [String: Any]) -> Data? {
        guard images[imageID] != nil else { return nil }
        return Self.pngStub
    }

    public func cropImage(imageID: UInt64, rect: DrawingRect) -> UInt64? {
        guard let img = images[imageID] else { return nil }
        let id = allocateID()
        let w = min(rect.width, img.size.width - rect.x)
        let h = min(rect.height, img.size.height - rect.y)
        images[id] = (size: DrawingSize(width: max(0, w), height: max(0, h)),
                      colorSpace: img.colorSpace)
        return id
    }

    public func resizeImage(imageID: UInt64, size: DrawingSize) -> UInt64? {
        guard let img = images[imageID] else { return nil }
        let id = allocateID()
        images[id] = (size: size, colorSpace: img.colorSpace)
        return id
    }

    public func rotateImage(imageID: UInt64, degrees: Double) -> UInt64? {
        guard let img = images[imageID] else { return nil }
        let id = allocateID()
        images[id] = (size: img.size, colorSpace: img.colorSpace)
        return id
    }

    public func flipImage(imageID: UInt64, horizontal: Bool) -> UInt64? {
        guard let img = images[imageID] else { return nil }
        let id = allocateID()
        images[id] = (size: img.size, colorSpace: img.colorSpace)
        return id
    }

    public func pixelColor(imageID: UInt64, x: Int, y: Int) -> DrawingColor? {
        guard images[imageID] != nil else { return nil }
        return DrawingColor(
            red: Double(rng.next() & 0xFF) / 255.0,
            green: Double(rng.next() & 0xFF) / 255.0,
            blue: Double(rng.next() & 0xFF) / 255.0,
            alpha: 1.0
        )
    }

    public func iconForFile(path: String) -> UInt64? {
        if rng.boolean(probability: faults.fileReadFailProbability) { return nil }
        let id = allocateID()
        images[id] = (size: DrawingSize(width: 32, height: 32), colorSpace: "sRGB")
        loadedFilePaths[id] = path
        return id
    }

    public func iconForFileType(type: String) -> UInt64? {
        let id = allocateID()
        images[id] = (size: DrawingSize(width: 32, height: 32), colorSpace: "sRGB")
        return id
    }

    public func extractVideoThumbnail(path: String, atTime: Double) -> UInt64? {
        if rng.boolean(probability: faults.fileReadFailProbability) { return nil }
        let id = allocateID()
        images[id] = (size: DrawingSize(width: 1920, height: 1080), colorSpace: "sRGB")
        loadedFilePaths[id] = path
        return id
    }

    public func destroyImage(imageID: UInt64) -> Bool {
        guard images.removeValue(forKey: imageID) != nil else { return false }
        imageData.removeValue(forKey: imageID)
        loadedFilePaths.removeValue(forKey: imageID)
        return true
    }

    // MARK: - Color operations

    public func colorFromHex(_ hex: String) -> DrawingColor? {
        DrawingColor.hex(hex)
    }

    public func colorFromName(_ name: String) -> DrawingColor? {
        namedColors[name.lowercased()]
    }

    public func availableColorLists() -> [String] {
        Array(colorLists.keys).sorted()
    }

    public func colorsInList(named name: String) -> [String: DrawingColor] {
        colorLists[name] ?? [:]
    }

    // MARK: - Font operations

    public func availableFonts() -> [String] { fonts }

    public func fontMetrics(name: String, size: Double) -> (ascender: Double, descender: Double, lineHeight: Double)? {
        if let m = fontMetricsMap[name] {
            return (m.ascender, m.descender, m.lineHeight)
        }
        guard fonts.contains(name) else { return nil }
        return (ascender: size * 0.8, descender: size * -0.2, lineHeight: size * 1.2)
    }

    // MARK: - Path operations

    public func createPath() -> UInt64 {
        let id = allocateID()
        paths[id] = []
        return id
    }

    public func pathAddRect(pathID: UInt64, rect: DrawingRect) {
        paths[pathID]?.append(.rect(rect))
    }

    public func pathAddOval(pathID: UInt64, inRect rect: DrawingRect) {
        paths[pathID]?.append(.oval(rect))
    }

    public func pathAddRoundedRect(pathID: UInt64, rect: DrawingRect, xRadius: Double, yRadius: Double) {
        paths[pathID]?.append(.roundedRect(rect, xRadius: xRadius, yRadius: yRadius))
    }

    public func pathAddArc(pathID: UInt64, center: DrawingPoint, radius: Double,
                           startAngle: Double, endAngle: Double, clockwise: Bool) {
        paths[pathID]?.append(.arc(center: center, radius: radius,
                                   startAngle: startAngle, endAngle: endAngle, clockwise: clockwise))
    }

    public func pathMoveTo(pathID: UInt64, point: DrawingPoint) {
        paths[pathID]?.append(.moveTo(point))
    }

    public func pathLineTo(pathID: UInt64, point: DrawingPoint) {
        paths[pathID]?.append(.lineTo(point))
    }

    public func pathCurveTo(pathID: UInt64, point: DrawingPoint,
                            control1: DrawingPoint, control2: DrawingPoint) {
        paths[pathID]?.append(.curveTo(point, control1: control1, control2: control2))
    }

    public func pathClose(pathID: UInt64) {
        paths[pathID]?.append(.close)
    }

    public func pathContains(pathID: UInt64, point: DrawingPoint, rule: WindingRule) -> Bool {
        guard let elements = paths[pathID], !elements.isEmpty else { return false }
        for element in elements {
            switch element {
            case .rect(let r), .oval(let r), .roundedRect(let r, _, _):
                if point.x >= r.x && point.x <= r.x + r.width &&
                   point.y >= r.y && point.y <= r.y + r.height {
                    return true
                }
            case .arc(let center, let radius, _, _, _):
                let dx = point.x - center.x
                let dy = point.y - center.y
                if dx * dx + dy * dy <= radius * radius {
                    return true
                }
            default:
                break
            }
        }
        return false
    }

    public func destroyPath(pathID: UInt64) -> Bool {
        paths.removeValue(forKey: pathID) != nil
    }
}
