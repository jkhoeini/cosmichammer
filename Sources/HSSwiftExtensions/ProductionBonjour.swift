import Foundation
import HSDSTCore

final class ProductionBonjour: BonjourProtocol {
    func createBrowser() -> UInt64 { 0 }
    func browse(browserID: UInt64, type: String, domain: String) -> Bool { false }
    func browseDomains(browserID: UInt64, browsable: Bool) -> Bool { false }
    func stopBrowsing(browserID: UInt64) -> Bool { false }
    func destroyBrowser(browserID: UInt64) -> Bool { false }
    func setBrowserPeerToPeer(browserID: UInt64, enabled: Bool) -> Bool { false }
    func setBrowseCallback(browserID: UInt64,
                           callback: @escaping (BonjourBrowseEvent) -> Void) -> Bool { false }
    func createServiceForPublishing(domain: String, type: String,
                                    name: String, port: UInt16) -> UInt64 { 0 }
    func publish(serviceID: UInt64, noAutoRename: Bool) -> Bool { false }
    func stopPublishing(serviceID: UInt64) -> Bool { false }
    func destroyService(serviceID: UInt64) -> Bool { false }
    func setPublishCallback(serviceID: UInt64,
                            callback: @escaping (Bool, String?) -> Void) -> Bool { false }
    func createServiceForResolution(domain: String, type: String,
                                    name: String) -> UInt64 { 0 }
    func resolve(serviceID: UInt64, timeout: Double) -> Bool { false }
    func stopResolving(serviceID: UInt64) -> Bool { false }
    func resolvedAddresses(serviceID: UInt64) -> [String] { [] }
    func setResolveCallback(serviceID: UInt64,
                            callback: @escaping (BonjourServiceInfo) -> Void) -> Bool { false }
    func txtRecord(serviceID: UInt64) -> [String: String]? { nil }
    func setTxtRecord(serviceID: UInt64, record: [String: String]) -> Bool { false }
    func startMonitoringTxtRecord(serviceID: UInt64,
                                  callback: @escaping ([String: String]) -> Void) -> Bool { false }
    func stopMonitoringTxtRecord(serviceID: UInt64) -> Bool { false }
    func serviceInfo(serviceID: UInt64) -> BonjourServiceInfo? { nil }
}
