import Foundation

public enum SpaceType: Int, Sendable {
    case user = 0
    case fullscreen = 4
    case system = 2
    case unknown = -1
}

public struct SpaceInfo: Sendable {
    public var id: Int
    public var type: SpaceType
    public var screenID: UInt32
    public var isActive: Bool
    public var managedWindowIDs: [UInt32]

    public init(id: Int = 1, type: SpaceType = .user, screenID: UInt32 = 1,
                isActive: Bool = true, managedWindowIDs: [UInt32] = []) {
        self.id = id
        self.type = type
        self.screenID = screenID
        self.isActive = isActive
        self.managedWindowIDs = managedWindowIDs
    }
}

public protocol SpacesProtocol: AnyObject {
    func allSpaces() -> [SpaceInfo]
    func activeSpaceOnScreen(screenID: UInt32) -> SpaceInfo?
    func spaceType(spaceID: Int) -> SpaceType
    func windowsOnSpace(spaceID: Int) -> [UInt32]
    func moveWindowToSpace(windowID: UInt32, spaceID: Int) -> Bool
    func addWindowToSpace(windowID: UInt32, spaceID: Int) -> Bool
    func removeWindowFromSpace(windowID: UInt32, spaceID: Int) -> Bool
    func spaceForWindow(windowID: UInt32) -> [Int]
    func activeSpace() -> Int?
    func setActiveSpace(spaceID: Int) -> Bool
    func spaceCount() -> Int
    func addSpaceChangeCallback(callback: @escaping (Int) -> Void) -> UInt64
    func removeSpaceChangeCallback(id: UInt64) -> Bool
}
