import Foundation
import HSDSTCore

public final class SimulatedSpaces: SpacesProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    public var spaces: [SpaceInfo] = [
        SpaceInfo(id: 1, type: .user, screenID: 1, isActive: true, managedWindowIDs: []),
        SpaceInfo(id: 2, type: .user, screenID: 1, isActive: false, managedWindowIDs: []),
    ]
    public var activeSpaceID: Int = 1

    private var nextCallbackID: UInt64 = 1
    private var callbacks: [UInt64: (Int) -> Void] = [:]

    /// Records of space changes for test verification.
    public private(set) var spaceChangeLog: [(from: Int, to: Int)] = []
    public private(set) var windowMoveLog: [(windowID: UInt32, spaceID: Int, action: String)] = []

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    public func allSpaces() -> [SpaceInfo] { spaces }

    public func activeSpaceOnScreen(screenID: UInt32) -> SpaceInfo? {
        spaces.first { $0.screenID == screenID && $0.isActive }
    }

    public func spaceType(spaceID: Int) -> SpaceType {
        spaces.first { $0.id == spaceID }?.type ?? .unknown
    }

    public func windowsOnSpace(spaceID: Int) -> [UInt32] {
        guard let space = spaces.first(where: { $0.id == spaceID }) else { return [] }
        return space.managedWindowIDs
    }

    public func moveWindowToSpace(windowID: UInt32, spaceID: Int) -> Bool {
        guard let destIdx = spaces.firstIndex(where: { $0.id == spaceID }) else { return false }

        // Remove from all current spaces
        for i in spaces.indices {
            spaces[i].managedWindowIDs.removeAll { $0 == windowID }
        }

        // Add to destination
        spaces[destIdx].managedWindowIDs.append(windowID)
        windowMoveLog.append((windowID: windowID, spaceID: spaceID, action: "move"))
        return true
    }

    public func addWindowToSpace(windowID: UInt32, spaceID: Int) -> Bool {
        guard let idx = spaces.firstIndex(where: { $0.id == spaceID }) else { return false }
        if !spaces[idx].managedWindowIDs.contains(windowID) {
            spaces[idx].managedWindowIDs.append(windowID)
        }
        windowMoveLog.append((windowID: windowID, spaceID: spaceID, action: "add"))
        return true
    }

    public func removeWindowFromSpace(windowID: UInt32, spaceID: Int) -> Bool {
        guard let idx = spaces.firstIndex(where: { $0.id == spaceID }) else { return false }
        guard spaces[idx].managedWindowIDs.contains(windowID) else { return false }
        spaces[idx].managedWindowIDs.removeAll { $0 == windowID }
        windowMoveLog.append((windowID: windowID, spaceID: spaceID, action: "remove"))
        return true
    }

    public func spaceForWindow(windowID: UInt32) -> [Int] {
        spaces.filter { $0.managedWindowIDs.contains(windowID) }.map(\.id)
    }

    public func activeSpace() -> Int? { activeSpaceID }

    public func setActiveSpace(spaceID: Int) -> Bool {
        guard spaces.contains(where: { $0.id == spaceID }) else { return false }
        let oldID = activeSpaceID

        // Deactivate previous
        if let oldIdx = spaces.firstIndex(where: { $0.id == oldID }) {
            spaces[oldIdx] = SpaceInfo(
                id: spaces[oldIdx].id, type: spaces[oldIdx].type,
                screenID: spaces[oldIdx].screenID, isActive: false,
                managedWindowIDs: spaces[oldIdx].managedWindowIDs
            )
        }

        // Activate new
        if let newIdx = spaces.firstIndex(where: { $0.id == spaceID }) {
            spaces[newIdx] = SpaceInfo(
                id: spaces[newIdx].id, type: spaces[newIdx].type,
                screenID: spaces[newIdx].screenID, isActive: true,
                managedWindowIDs: spaces[newIdx].managedWindowIDs
            )
        }

        activeSpaceID = spaceID
        spaceChangeLog.append((from: oldID, to: spaceID))

        // Fire callbacks
        for cb in callbacks.values {
            cb(spaceID)
        }

        return true
    }

    public func spaceCount() -> Int { spaces.count }

    public func addSpaceChangeCallback(callback: @escaping (Int) -> Void) -> UInt64 {
        let id = nextCallbackID
        nextCallbackID += 1
        callbacks[id] = callback
        return id
    }

    public func removeSpaceChangeCallback(id: UInt64) -> Bool {
        callbacks.removeValue(forKey: id) != nil
    }
}
