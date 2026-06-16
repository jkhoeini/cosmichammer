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
}
