import Cocoa
import HSDSTCore
import IOKit
import IOKit.graphics
import os.log

// MARK: - Private API declarations

@_silgen_name("CoreDisplay_Display_SetUserBrightness")
private func CoreDisplay_Display_SetUserBrightness(_ display: CGDirectDisplayID, _ brightness: Double)

@_silgen_name("CoreDisplay_Display_GetUserBrightness")
private func CoreDisplay_Display_GetUserBrightness(_ display: CGDirectDisplayID) -> Double

@_silgen_name("DisplayServicesGetBrightness")
private func DisplayServicesGetBrightness(_ display: CGDirectDisplayID, _ brightness: UnsafeMutablePointer<Float>) -> Int32

@_silgen_name("DisplayServicesSetBrightness")
private func DisplayServicesSetBrightness(_ display: CGDirectDisplayID, _ brightness: Float) -> Int32

// MARK: - CoreGraphics private display mode APIs

private struct CGSDisplayMode {
    var modeNumber: UInt32 = 0
    var flags: UInt32 = 0
    var width: UInt32 = 0
    var height: UInt32 = 0
    var depth: UInt32 = 0
    var unknown: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0) // 170 bytes
    var freq: UInt16 = 0
    var more_unknown: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0) // 16 bytes
    var density: Float = 0
}

@_silgen_name("CGSGetCurrentDisplayMode")
private func CGSGetCurrentDisplayMode(_ display: CGDirectDisplayID, _ modeNum: UnsafeMutablePointer<Int32>)

@_silgen_name("CGSConfigureDisplayMode")
private func CGSConfigureDisplayMode(_ config: CGDisplayConfigRef, _ display: CGDirectDisplayID, _ modeNum: Int32)

@_silgen_name("CGSGetNumberOfDisplayModes")
private func CGSGetNumberOfDisplayModes(_ display: CGDirectDisplayID, _ nModes: UnsafeMutablePointer<Int32>)

@_silgen_name("CGSGetDisplayModeDescriptionOfLength")
private func CGSGetDisplayModeDescriptionOfLength(_ display: CGDirectDisplayID, _ idx: Int32, _ mode: UnsafeMutablePointer<CGSDisplayMode>, _ length: Int32)

// Dynamic load for CGDisplayCreateImageForRect (obsoleted in macOS 15 SDK)
private typealias CGDisplayCreateImageForRectFunc = @convention(c) (CGDirectDisplayID, CGRect) -> Unmanaged<CGImage>?
private let hs_CGDisplayCreateImageForRect: CGDisplayCreateImageForRectFunc? = {
    guard let sym = dlsym(nil, "CGDisplayCreateImageForRect") else { return nil }
    return unsafeBitCast(sym, to: CGDisplayCreateImageForRectFunc.self)
}()

// MARK: - Accessibility display private APIs

@_silgen_name("CGDisplayUsesForceToGray")
private func CGDisplayUsesForceToGray() -> Bool

@_silgen_name("CGDisplayForceToGray")
private func CGDisplayForceToGray(_ forceToGray: Bool)

@_silgen_name("CGDisplayUsesInvertedPolarity")
private func CGDisplayUsesInvertedPolarity() -> Bool

@_silgen_name("CGDisplaySetInvertedPolarity")
private func CGDisplaySetInvertedPolarity(_ invertedPolarity: Bool)

// IOKit private constant
private let kIOFBSetTransform: UInt32 = 0x00000400

final class ProductionScreen: ScreenProtocol {

    // MARK: - Screen enumeration

    func allScreens() -> [ScreenInfo] {
        NSScreen.screens.map { screenInfoFrom($0) }
    }

    func mainScreen() -> ScreenInfo? {
        NSScreen.main.map { screenInfoFrom($0) }
    }

    func primaryScreen() -> ScreenInfo? {
        NSScreen.screens.first.map { screenInfoFrom($0) }
    }

    func screenInfo(forScreenID id: UInt32) -> ScreenInfo? {
        guard let screen = nsScreen(forID: id) else { return nil }
        return screenInfoFrom(screen)
    }

    // MARK: - Brightness

    func getBrightness(forScreenID id: UInt32) -> Float? {
        var brightness: Float = 0
        let err = DisplayServicesGetBrightness(id, &brightness)
        return err == 0 ? brightness : nil
    }

    func setBrightness(_ value: Double, forScreenID id: UInt32) -> Bool {
        let result = DisplayServicesSetBrightness(id, Float(value))
        return result == 0
    }

    // MARK: - Rotation

    func getRotation(forScreenID id: UInt32) -> Double {
        Double(CGDisplayRotation(id))
    }

    func setRotation(_ degrees: Double, forScreenID id: UInt32) -> Bool {
        let rotation: Int32
        switch Int(degrees) {
        case 0:   rotation = Int32(kIOScaleRotate0)
        case 90:  rotation = Int32(kIOScaleRotate90)
        case 180: rotation = Int32(kIOScaleRotate180)
        case 270: rotation = Int32(kIOScaleRotate270)
        default:  return false
        }

        // Verify the display is online
        let onlineIDs = onlineDisplayIDs()
        guard onlineIDs.contains(id) else { return false }

        guard let service = findIODisplayService(for: id) else { return false }
        let options = IOOptionBits(kIOFBSetTransform | (UInt32(rotation) << 16))
        let result = IOServiceRequestProbe(service, options)
        IOObjectRelease(service)
        return result == KERN_SUCCESS
    }

    // MARK: - Display modes

    func availableDisplayModes(forScreenID id: UInt32) -> [DisplayModeInfo] {
        var numberOfModes: Int32 = 0
        CGSGetNumberOfDisplayModes(id, &numberOfModes)

        var currentModeNumber: Int32 = 0
        CGSGetCurrentDisplayMode(id, &currentModeNumber)

        var modes: [DisplayModeInfo] = []
        for i in 0..<numberOfModes {
            var mode = CGSDisplayMode()
            CGSGetDisplayModeDescriptionOfLength(id, i, &mode, Int32(MemoryLayout<CGSDisplayMode>.size))
            modes.append(DisplayModeInfo(
                modeNumber: i,
                width: mode.width,
                height: mode.height,
                depth: mode.depth,
                frequency: mode.freq,
                density: mode.density,
                isCurrent: i == currentModeNumber
            ))
        }
        return modes
    }

    func currentDisplayMode(forScreenID id: UInt32) -> DisplayModeInfo? {
        var currentModeNumber: Int32 = 0
        CGSGetCurrentDisplayMode(id, &currentModeNumber)

        var mode = CGSDisplayMode()
        CGSGetDisplayModeDescriptionOfLength(id, currentModeNumber, &mode, Int32(MemoryLayout<CGSDisplayMode>.size))

        return DisplayModeInfo(
            modeNumber: currentModeNumber,
            width: mode.width,
            height: mode.height,
            depth: mode.depth,
            frequency: mode.freq,
            density: mode.density,
            isCurrent: true
        )
    }

    func setDisplayMode(_ modeNumber: Int32, forScreenID id: UInt32) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        CGSConfigureDisplayMode(config!, id, modeNumber)
        return CGCompleteDisplayConfiguration(config!, .permanently) == .success
    }

    // MARK: - Gamma

    func getGammaTable(forScreenID id: UInt32) -> GammaTable? {
        let capacity = CGDisplayGammaTableCapacity(id)
        guard capacity > 0 else { return nil }
        var sampleCount: UInt32 = 0

        let redTable = UnsafeMutablePointer<CGGammaValue>.allocate(capacity: Int(capacity))
        let greenTable = UnsafeMutablePointer<CGGammaValue>.allocate(capacity: Int(capacity))
        let blueTable = UnsafeMutablePointer<CGGammaValue>.allocate(capacity: Int(capacity))
        defer {
            redTable.deallocate()
            greenTable.deallocate()
            blueTable.deallocate()
        }

        guard CGGetDisplayTransferByTable(id, capacity, redTable, greenTable, blueTable, &sampleCount) == .success else {
            return nil
        }

        var red = [Float]()
        var green = [Float]()
        var blue = [Float]()
        for i in 0..<Int(sampleCount) {
            red.append(redTable[i])
            green.append(greenTable[i])
            blue.append(blueTable[i])
        }

        return GammaTable(red: red, green: green, blue: blue)
    }

    func setGammaTable(_ table: GammaTable, forScreenID id: UInt32) -> Bool {
        let count = table.red.count
        guard count > 0 && table.green.count == count && table.blue.count == count else { return false }

        let redTable = UnsafeMutablePointer<CGGammaValue>.allocate(capacity: count)
        let greenTable = UnsafeMutablePointer<CGGammaValue>.allocate(capacity: count)
        let blueTable = UnsafeMutablePointer<CGGammaValue>.allocate(capacity: count)
        defer {
            redTable.deallocate()
            greenTable.deallocate()
            blueTable.deallocate()
        }

        for i in 0..<count {
            redTable[i] = table.red[i]
            greenTable[i] = table.green[i]
            blueTable[i] = table.blue[i]
        }

        return CGSetDisplayTransferByTable(id, UInt32(count), redTable, greenTable, blueTable) == .success
    }

    func restoreGamma() {
        CGDisplayRestoreColorSyncSettings()
    }

    // MARK: - Accessibility display settings

    func usesForceToGray() -> Bool {
        CGDisplayUsesForceToGray()
    }

    func setForceToGray(_ enabled: Bool) {
        CGDisplayForceToGray(enabled)
    }

    func usesInvertedPolarity() -> Bool {
        CGDisplayUsesInvertedPolarity()
    }

    func setInvertedPolarity(_ enabled: Bool) {
        CGDisplaySetInvertedPolarity(enabled)
    }

    func accessibilityDisplaySettings() -> [String: Bool] {
        let ws = NSWorkspace.shared
        return [
            "InvertColors": ws.accessibilityDisplayShouldInvertColors,
            "ReduceMotion": ws.accessibilityDisplayShouldReduceMotion,
            "ReduceTransparency": ws.accessibilityDisplayShouldReduceTransparency,
            "IncreaseContrast": ws.accessibilityDisplayShouldIncreaseContrast,
            "DifferentiateWithoutColor": ws.accessibilityDisplayShouldDifferentiateWithoutColor,
        ]
    }

    // MARK: - Screen capture

    func captureScreenRect(displayID: UInt32, rect: (x: Double, y: Double, width: Double, height: Double)) -> Data? {
        let captureRect = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)

        guard let captureFunc = hs_CGDisplayCreateImageForRect,
              let cgImageRef = captureFunc(displayID, captureRect) else {
            return nil
        }

        let cgImage = cgImageRef.takeRetainedValue()
        let nsImage = NSImage(cgImage: cgImage, size: NSZeroSize)

        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return pngData
    }

    // MARK: - UUID

    func getUUID(forScreenID id: UInt32) -> String? {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(id) else { return nil }
        return CFUUIDCreateString(nil, cfUUID.takeRetainedValue()) as String?
    }

    // MARK: - Display info (IOKit-derived)

    func getDisplayInfo(forScreenID id: UInt32) -> [String: Any]? {
        var iter: io_iterator_t = 0
        let matching = IOServiceMatching("IODisplayConnect")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return nil
        }

        var result: [String: Any]? = nil
        var service = IOIteratorNext(iter)
        while service != 0 {
            if let info = IODisplayCreateInfoDictionary(service, UInt32(kIODisplayOnlyPreferredName))?.takeRetainedValue() as NSDictionary? {
                if let vendorID = info[kDisplayVendorID] as? UInt32,
                   let productID = info[kDisplayProductID] as? UInt32,
                   vendorID == CGDisplayVendorNumber(id),
                   productID == CGDisplayModelNumber(id) {
                    result = info as? [String: Any]
                    IOObjectRelease(service)
                    break
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iter)
        }
        IOObjectRelease(iter)
        return result
    }

    // MARK: - Display topology

    func setPrimary(screenID: UInt32) -> Bool {
        let mainID = CGMainDisplayID()
        if screenID == mainID { return true }

        let maxDisplays: CGDisplayCount = 32
        let onlineDisplays = UnsafeMutablePointer<CGDirectDisplayID>.allocate(capacity: Int(maxDisplays))
        defer { onlineDisplays.deallocate() }

        var displayCount: CGDisplayCount = 0
        guard CGGetOnlineDisplayList(maxDisplays, onlineDisplays, &displayCount) == .success else {
            return false
        }

        let deltaX = -Int32(CGDisplayBounds(screenID).minX)
        let deltaY = -Int32(CGDisplayBounds(screenID).minY)

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }

        for i in 0..<Int(displayCount) {
            let dID = onlineDisplays[i]
            let err = CGConfigureDisplayOrigin(config!, dID,
                                               Int32(CGDisplayBounds(dID).minX) + deltaX,
                                               Int32(CGDisplayBounds(dID).minY) + deltaY)
            if err != .success {
                CGCancelDisplayConfiguration(config!)
                return false
            }
        }

        return CGCompleteDisplayConfiguration(config!, .forSession) == .success
    }

    func setOrigin(screenID: UInt32, x: Int32, y: Int32) -> Bool {
        let maxDisplays: CGDisplayCount = 32
        let onlineDisplays = UnsafeMutablePointer<CGDirectDisplayID>.allocate(capacity: Int(maxDisplays))
        defer { onlineDisplays.deallocate() }

        var displayCount: CGDisplayCount = 0
        guard CGGetOnlineDisplayList(maxDisplays, onlineDisplays, &displayCount) == .success else {
            return false
        }

        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        for i in 0..<Int(displayCount) {
            let dID = onlineDisplays[i]
            if dID == screenID {
                CGConfigureDisplayOrigin(config!, dID, x, y)
            }
        }

        return CGCompleteDisplayConfiguration(config!, .permanently) == .success
    }

    func mirrorOf(targetScreenID: UInt32, sourceScreenID: UInt32, permanent: Bool) -> Bool {
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        let result = CGConfigureDisplayMirrorOfDisplay(config!, targetScreenID, sourceScreenID)
        CGCompleteDisplayConfiguration(config!, permanent ? .permanently : .forSession)
        return result == .success
    }

    func mirrorStop(screenID: UInt32, permanent: Bool) -> Bool {
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        let result = CGConfigureDisplayMirrorOfDisplay(config!, screenID, kCGNullDirectDisplay)
        CGCompleteDisplayConfiguration(config!, permanent ? .permanently : .forSession)
        return result == .success
    }

    // MARK: - Desktop image

    func desktopImageURL(forScreenID id: UInt32) -> String? {
        guard let screen = nsScreen(forID: id) else { return nil }
        return NSWorkspace.shared.desktopImageURL(for: screen)?.absoluteString
    }

    func setDesktopImageURL(_ url: String, forScreenID id: UInt32) -> Bool {
        guard let screen = nsScreen(forID: id),
              let realURL = URL(string: url) else { return false }
        do {
            try NSWorkspace.shared.setDesktopImageURL(realURL, for: screen, options: [:])
            return true
        } catch {
            os_log(.error, "%{public}s", error.localizedDescription)
            return false
        }
    }

    // MARK: - Spaces

    func currentSpaceID(forScreenID id: UInt32) -> Int? { nil }

    // MARK: - Display bounds / topology helpers

    func displayBounds(forScreenID id: UInt32) -> (x: Double, y: Double, width: Double, height: Double) {
        let bounds = CGDisplayBounds(id)
        return (Double(bounds.origin.x), Double(bounds.origin.y),
                Double(bounds.size.width), Double(bounds.size.height))
    }

    func mainDisplayID() -> UInt32 {
        CGMainDisplayID()
    }

    func onlineDisplayIDs() -> [UInt32] {
        let maxDisplays: CGDisplayCount = 32
        let displays = UnsafeMutablePointer<CGDirectDisplayID>.allocate(capacity: Int(maxDisplays))
        defer { displays.deallocate() }

        var count: CGDisplayCount = 0
        guard CGGetOnlineDisplayList(maxDisplays, displays, &count) == .success else { return [] }
        return (0..<Int(count)).map { displays[$0] }
    }

    // MARK: - Private helpers

    private func nsScreen(forID id: UInt32) -> NSScreen? {
        NSScreen.screens.first { screen in
            let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
            return screenID == id
        }
    }

    private func screenInfoFrom(_ screen: NSScreen) -> ScreenInfo {
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
        let f = screen.frame
        let vf = screen.visibleFrame
        return ScreenInfo(
            id: id,
            name: screen.localizedName,
            frame: (f.origin.x, f.origin.y, f.size.width, f.size.height),
            visibleFrame: (vf.origin.x, vf.origin.y, vf.size.width, vf.size.height),
            scaleFactor: screen.backingScaleFactor,
            isBuiltIn: id == CGMainDisplayID(),
            rotation: Double(CGDisplayRotation(id)),
            brightness: Double(getBrightness(forScreenID: id) ?? 0.5),
            colorSpaceName: screen.colorSpace?.localizedName ?? "sRGB"
        )
    }

    private func findIODisplayService(for displayID: CGDirectDisplayID) -> io_service_t? {
        var iter: io_iterator_t = 0
        let matching = IOServiceMatching("IODisplayConnect")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return nil
        }

        var s = IOIteratorNext(iter)
        while s != 0 {
            if let info = IODisplayCreateInfoDictionary(s, UInt32(kIODisplayOnlyPreferredName))?.takeRetainedValue() as NSDictionary? {
                if let vendorID = info[kDisplayVendorID] as? UInt32,
                   let productID = info[kDisplayProductID] as? UInt32,
                   vendorID == CGDisplayVendorNumber(displayID),
                   productID == CGDisplayModelNumber(displayID) {
                    IOObjectRelease(iter)
                    return s
                }
            }
            IOObjectRelease(s)
            s = IOIteratorNext(iter)
        }
        IOObjectRelease(iter)
        return nil
    }
}
