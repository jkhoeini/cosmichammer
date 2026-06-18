import AppKit
import Foundation
import HSDSTCore

// NOTE: SkyLight private API declarations are already module-visible from Spaces.swift:
//   SLSMainConnectionID, SLSCopyManagedDisplaySpaces, SLSSpaceGetType,
//   SLSCopyWindowsWithOptionsAndTags, SLSMoveWindowsToManagedSpace,
//   SLSCopySpacesForWindows, SLSSpaceSetCompatID, SLSGetActiveSpace

final class ProductionSpaces: SpacesProtocol {
    private var nextCallbackID: UInt64 = 1
    private var callbacks: [UInt64: (observer: NSObjectProtocol, callback: (Int) -> Void)] = [:]
    private var cid: Int32 { SLSMainConnectionID() }

    func allSpaces() -> [SpaceInfo] {
        guard let managed = SLSCopyManagedDisplaySpaces(cid) else { return [] }
        let displays = managed as NSArray
        var result: [SpaceInfo] = []

        for displayEntry in displays {
            guard let displayDict = displayEntry as? NSDictionary,
                  let spaces = displayDict["Spaces"] as? NSArray,
                  let displayID = displayDict["Display Identifier"] as? String
            else { continue }

            let screenID = displayIDToScreenID(displayID)
            var currentSpaceID: Int = 0
            if let currentSpace = displayDict["Current Space"] as? NSDictionary,
               let csid = currentSpace["ManagedSpaceID"] as? Int
            {
                currentSpaceID = csid
            }

            for spaceEntry in spaces {
                guard let spaceDict = spaceEntry as? NSDictionary,
                      let sid = spaceDict["ManagedSpaceID"] as? Int
                else { continue }

                let rawType = SLSSpaceGetType(cid, UInt64(sid))
                let st: SpaceType
                switch rawType {
                case 0: st = .user
                case 4: st = .fullscreen
                case 2: st = .system
                default: st = .unknown
                }

                result.append(SpaceInfo(
                    id: sid, type: st, screenID: screenID,
                    isActive: sid == currentSpaceID,
                    managedWindowIDs: windowsOnSpace(spaceID: sid)
                ))
            }
        }
        return result
    }

    func activeSpaceOnScreen(screenID: UInt32) -> SpaceInfo? {
        allSpaces().first { $0.screenID == screenID && $0.isActive }
    }

    func spaceType(spaceID: Int) -> SpaceType {
        let rawType = SLSSpaceGetType(cid, UInt64(spaceID))
        switch rawType {
        case 0: return .user
        case 4: return .fullscreen
        case 2: return .system
        default: return .unknown
        }
    }

    func windowsOnSpace(spaceID: Int) -> [UInt32] {
        let spacesList = [NSNumber(value: spaceID)] as CFArray
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        guard let windowListRef = SLSCopyWindowsWithOptionsAndTags(
            cid, 0, spacesList, 0x7, &setTags, &clearTags)
        else { return [] }
        let arr = windowListRef as NSArray
        return arr.compactMap { ($0 as? NSNumber)?.uint32Value }
    }

    func moveWindowToSpace(windowID: UInt32, spaceID: Int) -> Bool {
        let windows = [NSNumber(value: windowID)] as CFArray
        guard let sourceSpaces = SLSCopySpacesForWindows(cid, 0x7, windows) else { return false }
        let arr = sourceSpaces as NSArray
        if arr.contains(NSNumber(value: spaceID)) { return true }

        _ = SLSSpaceSetCompatID(cid, UInt64(spaceID), 0x79616265)
        SLSMoveWindowsToManagedSpace(cid, windows, UInt64(spaceID))
        _ = SLSSpaceSetCompatID(cid, UInt64(spaceID), 0x0)
        return true
    }

    func addWindowToSpace(windowID: UInt32, spaceID: Int) -> Bool {
        return moveWindowToSpace(windowID: windowID, spaceID: spaceID)
    }

    func removeWindowFromSpace(windowID: UInt32, spaceID: Int) -> Bool {
        assertionFailure("removeWindowFromSpace not routed through protocol by any extension")
        return false
    }

    func spaceForWindow(windowID: UInt32) -> [Int] {
        let windowList = [NSNumber(value: windowID)] as CFArray
        guard let spacesRef = SLSCopySpacesForWindows(cid, 0x7, windowList) else { return [] }
        let arr = spacesRef as NSArray
        return arr.compactMap { ($0 as? NSNumber)?.intValue }
    }

    func activeSpace() -> Int? {
        let sid = SLSGetActiveSpace(cid)
        return sid > 0 ? Int(sid) : nil
    }

    func setActiveSpace(spaceID: Int) -> Bool {
        assertionFailure("setActiveSpace not routed through protocol by any extension")
        return false
    }

    func spaceCount() -> Int {
        allSpaces().count
    }

    func addSpaceChangeCallback(callback: @escaping (Int) -> Void) -> UInt64 {
        let id = nextCallbackID
        nextCallbackID += 1
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if let active = self.activeSpace() { callback(active) }
        }
        callbacks[id] = (observer: observer, callback: callback)
        return id
    }

    func removeSpaceChangeCallback(id: UInt64) -> Bool {
        guard let entry = callbacks.removeValue(forKey: id) else { return false }
        NSWorkspace.shared.notificationCenter.removeObserver(entry.observer)
        return true
    }

    // MARK: - Private

    private func displayIDToScreenID(_ displayID: String) -> UInt32 {
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            {
                let cgDisplayID = screenNumber.uint32Value
                if let uuid = CGDisplayCreateUUIDFromDisplayID(cgDisplayID) {
                    let uuidStr = CFUUIDCreateString(nil, uuid.takeUnretainedValue()) as String?
                    if uuidStr == displayID { return cgDisplayID }
                }
            }
        }
        return (NSScreen.screens.first?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 1
    }
}
