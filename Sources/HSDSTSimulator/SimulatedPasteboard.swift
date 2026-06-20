import Foundation
import HSDSTCore

public final class SimulatedPasteboard: PasteboardProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    private var contents: [String: Data] = [:]
    private var _changeCount: Int = 0

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    public var changeCount: Int { _changeCount }

    public func string(forType type: String) -> String? {
        if faults.pasteboardUnavailable { return nil }
        guard let data = contents[type] else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func data(forType type: String) -> Data? {
        if faults.pasteboardUnavailable { return nil }
        return contents[type]
    }

    public func setString(_ string: String, forType type: String) -> Bool {
        if faults.pasteboardUnavailable { return false }
        contents[type] = string.data(using: .utf8)
        _changeCount += 1
        return true
    }

    public func setData(_ data: Data, forType type: String) -> Bool {
        if faults.pasteboardUnavailable { return false }
        contents[type] = data
        _changeCount += 1
        return true
    }

    public func clearContents() {
        contents.removeAll()
        _changeCount += 1
    }

    public func availableTypes() -> [String] {
        Array(contents.keys)
    }

    public func pasteboardItems() -> [[String: Data]] {
        if contents.isEmpty { return [] }
        return [contents]
    }

    public func writeObjects(_ items: [[String: Data]]) -> Bool {
        if faults.pasteboardUnavailable { return false }
        contents.removeAll()
        for item in items {
            for (key, value) in item { contents[key] = value }
        }
        _changeCount += 1
        return true
    }

    // MARK: - Rich-object operations (simulated)

    // In simulation, rich-object reads return data reconstructed from the
    // raw `contents` dictionary.  The class-name filter selects which
    // UTI keys are eligible:
    //   NSString / NSAttributedString  → public.utf8-plain-text
    //   NSImage                        → public.tiff / public.png
    //   NSURL                          → public.url / public.file-url
    //   NSColor                        → com.apple.cocoa.pasteboard.color (NSKeyedArchiver data)
    //   NSSound                        → com.apple.cocoa.pasteboard.sound (NSKeyedArchiver data)
    //
    // Because we cannot truly instantiate AppKit objects inside the
    // simulator, we return *string* representations for text-like classes
    // and *Data* for binary classes.  The Lua-side callers that ultimately
    // push values onto the Lua stack handle both Any types gracefully.

    private static let classToTypes: [String: [String]] = [
        "NSString": ["public.utf8-plain-text"],
        "NSAttributedString": ["public.utf8-plain-text"],
        "NSImage": ["public.tiff", "public.png"],
        "NSURL": ["public.url", "public.file-url"],
        "NSColor": ["com.apple.cocoa.pasteboard.color"],
        "NSSound": ["com.apple.cocoa.pasteboard.sound"],
    ]

    public func readObjects(forClassNames classNames: [String]) -> [Any] {
        if faults.pasteboardUnavailable { return [] }
        var results: [Any] = []
        for className in classNames {
            guard let types = Self.classToTypes[className] else { continue }
            for type in types {
                if let data = contents[type] {
                    // For string-like classes, decode to String; otherwise
                    // return raw Data.
                    if className == "NSString" || className == "NSAttributedString" {
                        if let str = String(data: data, encoding: .utf8) {
                            results.append(str as NSString)
                        }
                    } else {
                        results.append(data)
                    }
                }
            }
        }
        return results
    }

    public func canReadObject(forClassNames classNames: [String]) -> Bool {
        if faults.pasteboardUnavailable { return false }
        for className in classNames {
            guard let types = Self.classToTypes[className] else { continue }
            for type in types {
                if contents[type] != nil { return true }
            }
        }
        return false
    }

    /// Property-list storage in simulation: store and retrieve from `contents`
    /// by serializing the plist to JSON data.
    public func propertyList(forType type: String) -> Any? {
        if faults.pasteboardUnavailable { return nil }
        guard let data = contents[type] else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    @discardableResult
    public func setPropertyList(_ plist: Any, forType type: String) -> Bool {
        if faults.pasteboardUnavailable { return false }
        guard let data = try? JSONSerialization.data(withJSONObject: plist, options: .fragmentsAllowed) else {
            return false
        }
        contents[type] = data
        _changeCount += 1
        return true
    }

    /// Rich-object writes in simulation: we accept the objects array but only
    /// record string representations so that subsequent reads see data.
    @discardableResult
    public func writeRichObjects(_ objects: [Any]) -> Bool {
        if faults.pasteboardUnavailable { return false }
        contents.removeAll()
        for obj in objects {
            if let str = obj as? String {
                contents["public.utf8-plain-text"] = str.data(using: .utf8)
            } else if let nsStr = obj as? NSString {
                contents["public.utf8-plain-text"] = (nsStr as String).data(using: .utf8)
            }
            // Other object types (images, sounds, etc.) are opaque in simulation;
            // we don't attempt to serialize them but we do count the write.
        }
        _changeCount += 1
        return true
    }
}
