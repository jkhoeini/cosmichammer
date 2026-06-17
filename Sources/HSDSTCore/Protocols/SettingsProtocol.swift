import Foundation

public protocol SettingsProtocol: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    func bool(forKey key: String) -> Bool
    func integer(forKey key: String) -> Int
    func double(forKey key: String) -> Double
    func string(forKey key: String) -> String?
    func array(forKey key: String) -> [Any]?
    func dictionary(forKey key: String) -> [String: Any]?
    func synchronize() -> Bool
    func allKeys() -> [String]
    func objectIsForced(forKey key: String) -> Bool

    /// Register a handler invoked when the value for `key` changes.
    /// Returns a monotonic observer ID that can be passed to `removeObserver(id:)`.
    func addObserver(forKey key: String, handler: @escaping (String) -> Void) -> UInt64

    /// Remove a previously registered observer by its ID.
    func removeObserver(id: UInt64)
}

