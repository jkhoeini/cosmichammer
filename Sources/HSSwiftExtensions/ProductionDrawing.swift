import Foundation
import HSDSTCore

final class ProductionDrawing: DrawingProtocol {
    func loadImage(fromFile path: String) -> UInt64? { nil }
    func loadImage(fromData data: Data) -> UInt64? { nil }
    func createImage(width: Int, height: Int, colorSpace: String) -> UInt64? { nil }
    func imageSize(imageID: UInt64) -> DrawingSize? { nil }
    func exportImage(imageID: UInt64, format: ImageFormat, properties: [String: Any]) -> Data? { nil }
    func cropImage(imageID: UInt64, rect: DrawingRect) -> UInt64? { nil }
    func resizeImage(imageID: UInt64, size: DrawingSize) -> UInt64? { nil }
    func rotateImage(imageID: UInt64, degrees: Double) -> UInt64? { nil }
    func flipImage(imageID: UInt64, horizontal: Bool) -> UInt64? { nil }
    func pixelColor(imageID: UInt64, x: Int, y: Int) -> DrawingColor? { nil }
    func iconForFile(path: String) -> UInt64? { nil }
    func iconForFileType(type: String) -> UInt64? { nil }
    func extractVideoThumbnail(path: String, atTime: Double) -> UInt64? { nil }
    func destroyImage(imageID: UInt64) -> Bool { false }

    func colorFromHex(_ hex: String) -> DrawingColor? { DrawingColor.hex(hex) }
    func colorFromName(_ name: String) -> DrawingColor? { nil }
    func availableColorLists() -> [String] { [] }
    func colorsInList(named: String) -> [String: DrawingColor] { [:] }

    func availableFonts() -> [String] { [] }
    func fontMetrics(name: String, size: Double) -> (ascender: Double, descender: Double, lineHeight: Double)? { nil }

    func createPath() -> UInt64 { 0 }
    func pathAddRect(pathID: UInt64, rect: DrawingRect) {}
    func pathAddOval(pathID: UInt64, inRect: DrawingRect) {}
    func pathAddRoundedRect(pathID: UInt64, rect: DrawingRect, xRadius: Double, yRadius: Double) {}
    func pathAddArc(pathID: UInt64, center: DrawingPoint, radius: Double,
                    startAngle: Double, endAngle: Double, clockwise: Bool) {}
    func pathMoveTo(pathID: UInt64, point: DrawingPoint) {}
    func pathLineTo(pathID: UInt64, point: DrawingPoint) {}
    func pathCurveTo(pathID: UInt64, point: DrawingPoint,
                     control1: DrawingPoint, control2: DrawingPoint) {}
    func pathClose(pathID: UInt64) {}
    func pathContains(pathID: UInt64, point: DrawingPoint, rule: WindingRule) -> Bool { false }
    func destroyPath(pathID: UInt64) -> Bool { false }
}
