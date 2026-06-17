import Foundation
import HSDSTCore

final class ProductionSettings: SettingsProtocol {
    private let defaults = UserDefaults.standard
    private var nextObserverID: UInt64 = 1
    private var kvoWrappers: [UInt64: KVOWrapper] = [:]

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

    func addObserver(forKey key: String, handler: @escaping (String) -> Void) -> UInt64 {
        let id = nextObserverID
        nextObserverID += 1
        let wrapper = KVOWrapper(defaults: defaults, keyPath: key) { changedKey in
            handler(changedKey)
        }
        kvoWrappers[id] = wrapper
        return id
    }

    func removeObserver(id: UInt64) {
        kvoWrappers.removeValue(forKey: id)?.invalidate()
    }
}

/// KVO observer that watches a single UserDefaults key path and calls a Swift closure.
private class KVOWrapper: NSObject {
    private let keyPath: String
    private let defaults: UserDefaults
    private let handler: (String) -> Void
    private var observing = true
    private static var kvoContext = 0

    init(defaults: UserDefaults, keyPath: String, handler: @escaping (String) -> Void) {
        self.defaults = defaults
        self.keyPath = keyPath
        self.handler = handler
        super.init()
        defaults.addObserver(self, forKeyPath: keyPath, options: [.new], context: &KVOWrapper.kvoContext)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                change: [NSKeyValueChangeKey: Any]?,
                                context: UnsafeMutableRawPointer?) {
        guard context == &KVOWrapper.kvoContext else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        if let kp = keyPath {
            handler(kp)
        }
    }

    func invalidate() {
        guard observing else { return }
        observing = false
        defaults.removeObserver(self, forKeyPath: keyPath, context: &KVOWrapper.kvoContext)
    }

    deinit {
        invalidate()
    }
}
