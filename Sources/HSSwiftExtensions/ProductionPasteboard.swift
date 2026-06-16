import Cocoa
import HSDSTCore

final class ProductionPasteboard: PasteboardProtocol {
    private let pb = NSPasteboard.general

    var changeCount: Int { pb.changeCount }

    func string(forType type: String) -> String? {
        pb.string(forType: NSPasteboard.PasteboardType(type))
    }

    func data(forType type: String) -> Data? {
        pb.data(forType: NSPasteboard.PasteboardType(type))
    }

    func setString(_ string: String, forType type: String) -> Bool {
        pb.clearContents()
        return pb.setString(string, forType: NSPasteboard.PasteboardType(type))
    }

    func setData(_ data: Data, forType type: String) -> Bool {
        pb.clearContents()
        return pb.setData(data, forType: NSPasteboard.PasteboardType(type))
    }

    func clearContents() { pb.clearContents() }

    func availableTypes() -> [String] {
        pb.types?.map(\.rawValue) ?? []
    }

    func pasteboardItems() -> [[String: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var dict: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type.rawValue] = data }
            }
            return dict
        }
    }

    func writeObjects(_ items: [[String: Data]]) -> Bool {
        pb.clearContents()
        for item in items {
            let pbItem = NSPasteboardItem()
            for (type, data) in item {
                pbItem.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            pb.writeObjects([pbItem])
        }
        return true
    }
}
