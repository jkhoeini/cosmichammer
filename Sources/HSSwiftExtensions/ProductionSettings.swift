import Foundation
import HSDSTCore

final class ProductionSettings: SettingsProtocol {
    private let defaults = UserDefaults.standard

    func object(forKey key: String) -> Any? { defaults.object(forKey: key) }
    func set(_ value: Any?, forKey key: String) { defaults.set(value, forKey: key) }
    func removeObject(forKey key: String) { defaults.removeObject(forKey: key) }
    func bool(forKey key: String) -> Bool { defaults.bool(forKey: key) }
    func integer(forKey key: String) -> Int { defaults.integer(forKey: key) }
    func double(forKey key: String) -> Double { defaults.double(forKey: key) }
    func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    func array(forKey key: String) -> [Any]? { defaults.array(forKey: key) }
    func dictionary(forKey key: String) -> [String: Any]? { defaults.dictionary(forKey: key) }
    func synchronize() -> Bool { defaults.synchronize() }

    func allKeys() -> [String] {
        let mainID = Bundle.main.bundleIdentifier ?? ""
        return defaults.persistentDomain(forName: mainID)?.keys.sorted() ?? []
    }

    func objectIsForced(forKey key: String) -> Bool { defaults.objectIsForced(forKey: key) }
}
