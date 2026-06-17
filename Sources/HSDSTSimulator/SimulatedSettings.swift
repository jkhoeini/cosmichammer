import Foundation
import HSDSTCore

public final class SimulatedSettings: SettingsProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    public var store: [String: Any] = [:]

    private var nextObserverID: UInt64 = 1
    private var observers: [(id: UInt64, key: String, handler: (String) -> Void)] = []

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    public func object(forKey key: String) -> Any? {
        if rng.boolean(probability: faults.settingsReadFailProbability) { return nil }
        return store[key]
    }

    public func set(_ value: Any?, forKey key: String) {
        if let v = value {
            store[key] = v
        } else {
            store.removeValue(forKey: key)
        }
        notifyObservers(forKey: key)
    }

    public func removeObject(forKey key: String) {
        store.removeValue(forKey: key)
        notifyObservers(forKey: key)
    }

    private func notifyObservers(forKey key: String) {
        for entry in observers where entry.key == key {
            entry.handler(key)
        }
    }

    public func bool(forKey key: String) -> Bool { (object(forKey: key) as? Bool) ?? false }
    public func integer(forKey key: String) -> Int { (object(forKey: key) as? Int) ?? 0 }
    public func double(forKey key: String) -> Double { (object(forKey: key) as? Double) ?? 0 }
    public func string(forKey key: String) -> String? { object(forKey: key) as? String }
    public func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    public func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
    public func synchronize() -> Bool { true }
    public func allKeys() -> [String] { Array(store.keys).sorted() }
    public func objectIsForced(forKey key: String) -> Bool { false }

    public func addObserver(forKey key: String, handler: @escaping (String) -> Void) -> UInt64 {
        let id = nextObserverID
        nextObserverID += 1
        observers.append((id: id, key: key, handler: handler))
        return id
    }

    public func removeObserver(id: UInt64) {
        observers.removeAll { $0.id == id }
    }
}
