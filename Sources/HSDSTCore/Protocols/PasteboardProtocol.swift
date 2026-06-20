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

    // Rich-object pasteboard operations (readObjects, writeObjects with typed
    // classes, canReadObject, propertyList get/set).  These cover the
    // NSPasteboard APIs that the earlier protocol surface did not abstract.

    /// Read pasteboard objects matching the given class names.
    /// `classNames` uses well-known keys: "NSString", "NSAttributedString",
    /// "NSImage", "NSSound", "NSURL", "NSColor".
    func readObjects(forClassNames classNames: [String]) -> [Any]

    /// Returns true when at least one item matches any of the given class names.
    func canReadObject(forClassNames classNames: [String]) -> Bool

    /// Read a property-list value for the given UTI type string.
    func propertyList(forType type: String) -> Any?

    /// Write a property-list value for the given UTI type string.
    @discardableResult
    func setPropertyList(_ plist: Any, forType type: String) -> Bool

    /// Write an array of rich objects (NSPasteboardWriting-conforming) to the
    /// pasteboard, clearing existing contents first.  The `objects` array is
    /// typed as `[Any]` so the protocol can stay in the Foundation-only
    /// HSDSTCore module; production implementations downcast to
    /// `[NSPasteboardWriting]`.
    @discardableResult
    func writeRichObjects(_ objects: [Any]) -> Bool
}
