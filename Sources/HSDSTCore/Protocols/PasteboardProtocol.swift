import Foundation

public protocol PasteboardProtocol: AnyObject {
    var changeCount: Int { get }
    func string(forType type: String) -> String?
    func data(forType type: String) -> Data?
    func setString(_ string: String, forType type: String) -> Bool
    func setData(_ data: Data, forType type: String) -> Bool
    func clearContents()
    func availableTypes() -> [String]
    func pasteboardItems() -> [[String: Data]]
    func writeObjects(_ items: [[String: Data]]) -> Bool
}
