import Foundation
import HSDSTCore

public final class SimulatedBonjour: BonjourProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    public var services: [UInt64: BonjourServiceInfo] = [:]
    public var browsers: [UInt64: (type: String, domain: String, isBrowsing: Bool, peerToPeer: Bool)] = [:]
    public var publishedServices: Set<UInt64> = []
    public var resolvingServices: Set<UInt64> = []
    public var monitoredServices: Set<UInt64> = []

    private var nextID: UInt64 = 1
    private var browseCallbacks: [UInt64: (BonjourBrowseEvent) -> Void] = [:]
    private var publishCallbacks: [UInt64: (Bool, String?) -> Void] = [:]
    private var resolveCallbacks: [UInt64: (BonjourServiceInfo) -> Void] = [:]
    private var txtMonitorCallbacks: [UInt64: ([String: String]) -> Void] = [:]

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    // MARK: - Browser

    public func createBrowser() -> UInt64 {
        let id = nextID
        nextID += 1
        browsers[id] = (type: "", domain: "", isBrowsing: false, peerToPeer: false)
        return id
    }

    public func browse(browserID: UInt64, type: String, domain: String) -> Bool {
        guard var browser = browsers[browserID] else { return false }
        if rng.boolean(probability: faults.connectionFailProbability) { return false }
        browser.type = type
        browser.domain = domain
        browser.isBrowsing = true
        browsers[browserID] = browser
        return true
    }

    public func browseDomains(browserID: UInt64, browsable: Bool) -> Bool {
        guard var browser = browsers[browserID] else { return false }
        if rng.boolean(probability: faults.connectionFailProbability) { return false }
        browser.isBrowsing = true
        browsers[browserID] = browser
        return true
    }

    public func stopBrowsing(browserID: UInt64) -> Bool {
        guard var browser = browsers[browserID] else { return false }
        browser.isBrowsing = false
        browsers[browserID] = browser
        return true
    }

    public func destroyBrowser(browserID: UInt64) -> Bool {
        guard browsers.removeValue(forKey: browserID) != nil else { return false }
        browseCallbacks.removeValue(forKey: browserID)
        return true
    }

    public func setBrowserPeerToPeer(browserID: UInt64, enabled: Bool) -> Bool {
        guard var browser = browsers[browserID] else { return false }
        browser.peerToPeer = enabled
        browsers[browserID] = browser
        return true
    }

    public func setBrowseCallback(browserID: UInt64,
                                  callback: @escaping (BonjourBrowseEvent) -> Void) -> Bool {
        guard browsers[browserID] != nil else { return false }
        browseCallbacks[browserID] = callback
        return true
    }

    // MARK: - Service Publishing

    public func createServiceForPublishing(domain: String, type: String,
                                           name: String, port: UInt16) -> UInt64 {
        let id = nextID
        nextID += 1
        services[id] = BonjourServiceInfo(name: name, type: type, domain: domain,
                                          port: port)
        return id
    }

    public func publish(serviceID: UInt64, noAutoRename: Bool) -> Bool {
        guard var info = services[serviceID] else { return false }
        if rng.boolean(probability: faults.connectionFailProbability) {
            publishCallbacks[serviceID]?(false, "Publish failed (simulated)")
            return false
        }
        info.isPublished = true
        services[serviceID] = info
        publishedServices.insert(serviceID)
        publishCallbacks[serviceID]?(true, nil)
        return true
    }

    public func stopPublishing(serviceID: UInt64) -> Bool {
        guard var info = services[serviceID] else { return false }
        info.isPublished = false
        services[serviceID] = info
        publishedServices.remove(serviceID)
        return true
    }

    public func destroyService(serviceID: UInt64) -> Bool {
        guard services.removeValue(forKey: serviceID) != nil else { return false }
        publishedServices.remove(serviceID)
        resolvingServices.remove(serviceID)
        monitoredServices.remove(serviceID)
        publishCallbacks.removeValue(forKey: serviceID)
        resolveCallbacks.removeValue(forKey: serviceID)
        txtMonitorCallbacks.removeValue(forKey: serviceID)
        return true
    }

    public func setPublishCallback(serviceID: UInt64,
                                   callback: @escaping (Bool, String?) -> Void) -> Bool {
        guard services[serviceID] != nil else { return false }
        publishCallbacks[serviceID] = callback
        return true
    }

    // MARK: - Service Resolution

    public func createServiceForResolution(domain: String, type: String,
                                           name: String) -> UInt64 {
        let id = nextID
        nextID += 1
        services[id] = BonjourServiceInfo(name: name, type: type, domain: domain)
        return id
    }

    public func resolve(serviceID: UInt64, timeout: Double) -> Bool {
        guard var info = services[serviceID] else { return false }
        if rng.boolean(probability: faults.connectionFailProbability) { return false }
        info.isResolved = true
        info.hostName = info.hostName ?? "\(info.name).local."
        info.port = info.port ?? 80
        info.addresses = info.addresses.isEmpty ? ["192.168.1.\(serviceID)"] : info.addresses
        services[serviceID] = info
        resolvingServices.insert(serviceID)
        resolveCallbacks[serviceID]?(info)
        return true
    }

    public func stopResolving(serviceID: UInt64) -> Bool {
        guard services[serviceID] != nil else { return false }
        resolvingServices.remove(serviceID)
        return true
    }

    public func resolvedAddresses(serviceID: UInt64) -> [String] {
        guard let info = services[serviceID], info.isResolved else { return [] }
        return info.addresses
    }

    public func setResolveCallback(serviceID: UInt64,
                                   callback: @escaping (BonjourServiceInfo) -> Void) -> Bool {
        guard services[serviceID] != nil else { return false }
        resolveCallbacks[serviceID] = callback
        return true
    }

    // MARK: - TXT Records

    public func txtRecord(serviceID: UInt64) -> [String: String]? {
        guard let info = services[serviceID] else { return nil }
        return info.txtRecord
    }

    public func setTxtRecord(serviceID: UInt64, record: [String: String]) -> Bool {
        guard var info = services[serviceID] else { return false }
        info.txtRecord = record
        services[serviceID] = info
        txtMonitorCallbacks[serviceID]?(record)
        return true
    }

    public func startMonitoringTxtRecord(serviceID: UInt64,
                                         callback: @escaping ([String: String]) -> Void) -> Bool {
        guard services[serviceID] != nil else { return false }
        monitoredServices.insert(serviceID)
        txtMonitorCallbacks[serviceID] = callback
        return true
    }

    public func stopMonitoringTxtRecord(serviceID: UInt64) -> Bool {
        guard services[serviceID] != nil else { return false }
        monitoredServices.remove(serviceID)
        txtMonitorCallbacks.removeValue(forKey: serviceID)
        return true
    }

    // MARK: - Service Accessors

    public func serviceInfo(serviceID: UInt64) -> BonjourServiceInfo? {
        services[serviceID]
    }

    // MARK: - Test Helpers

    /// Simulate a service being discovered by a browser.
    public func deliverBrowseEvent(_ event: BonjourBrowseEvent, toBrowserID browserID: UInt64) {
        browseCallbacks[browserID]?(event)
    }

    /// Simulate a TXT record change arriving for a monitored service.
    public func deliverTxtRecordChange(_ record: [String: String], forServiceID serviceID: UInt64) {
        if var info = services[serviceID] {
            info.txtRecord = record
            services[serviceID] = info
        }
        txtMonitorCallbacks[serviceID]?(record)
    }
}
