import Foundation

public struct BonjourServiceInfo: Sendable {
    public var name: String
    public var type: String
    public var domain: String
    public var hostName: String?
    public var port: UInt16?
    public var addresses: [String]
    public var txtRecord: [String: String]
    public var includesPeerToPeer: Bool
    public var isPublished: Bool
    public var isResolved: Bool

    public init(name: String = "", type: String = "_http._tcp.",
                domain: String = "local.", hostName: String? = nil,
                port: UInt16? = nil, addresses: [String] = [],
                txtRecord: [String: String] = [:],
                includesPeerToPeer: Bool = false,
                isPublished: Bool = false, isResolved: Bool = false) {
        self.name = name
        self.type = type
        self.domain = domain
        self.hostName = hostName
        self.port = port
        self.addresses = addresses
        self.txtRecord = txtRecord
        self.includesPeerToPeer = includesPeerToPeer
        self.isPublished = isPublished
        self.isResolved = isResolved
    }
}

public enum BonjourBrowseEvent: Sendable {
    case found(BonjourServiceInfo)
    case removed(BonjourServiceInfo)
}

public protocol BonjourProtocol: AnyObject {
    // MARK: - Browser

    func createBrowser() -> UInt64
    func browse(browserID: UInt64, type: String, domain: String) -> Bool
    func browseDomains(browserID: UInt64, browsable: Bool) -> Bool
    func stopBrowsing(browserID: UInt64) -> Bool
    func destroyBrowser(browserID: UInt64) -> Bool
    func setBrowserPeerToPeer(browserID: UInt64, enabled: Bool) -> Bool
    func setBrowseCallback(browserID: UInt64,
                           callback: @escaping (BonjourBrowseEvent) -> Void) -> Bool

    // MARK: - Service Publishing

    func createServiceForPublishing(domain: String, type: String,
                                    name: String, port: UInt16) -> UInt64
    func publish(serviceID: UInt64, noAutoRename: Bool) -> Bool
    func stopPublishing(serviceID: UInt64) -> Bool
    func destroyService(serviceID: UInt64) -> Bool
    func setPublishCallback(serviceID: UInt64,
                            callback: @escaping (Bool, String?) -> Void) -> Bool

    // MARK: - Service Resolution

    func createServiceForResolution(domain: String, type: String,
                                    name: String) -> UInt64
    func resolve(serviceID: UInt64, timeout: Double) -> Bool
    func stopResolving(serviceID: UInt64) -> Bool
    func resolvedAddresses(serviceID: UInt64) -> [String]
    func setResolveCallback(serviceID: UInt64,
                            callback: @escaping (BonjourServiceInfo) -> Void) -> Bool

    // MARK: - TXT Records

    func txtRecord(serviceID: UInt64) -> [String: String]?
    func setTxtRecord(serviceID: UInt64, record: [String: String]) -> Bool
    func startMonitoringTxtRecord(serviceID: UInt64,
                                  callback: @escaping ([String: String]) -> Void) -> Bool
    func stopMonitoringTxtRecord(serviceID: UInt64) -> Bool

    // MARK: - Service Accessors

    func serviceInfo(serviceID: UInt64) -> BonjourServiceInfo?
}
