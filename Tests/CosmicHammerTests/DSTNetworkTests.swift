import Testing
import Foundation
import HSDSTCore
import HSDSTSimulator

extension CosmicHammerTests {
    @Suite("DST Network Simulator") final class DSTNetworkTests {

        // MARK: - HTTP basics

        @Test func httpRequestReturnsConfiguredResponse() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let net = env.network as! SimulatedNetwork

            net.httpResponses["https://api.example.com/data"] = HTTPResponse(
                statusCode: 201,
                headers: ["Content-Type": "application/json"],
                body: "{\"ok\":true}".data(using: .utf8)
            )

            var response: HTTPResponse?
            env.network.httpRequest(url: "https://api.example.com/data", method: "POST",
                                    headers: [:], body: nil, redirect: true) { r, _ in
                response = r
            }
            #expect(response?.statusCode == 201)
            #expect(String(data: response!.body!, encoding: .utf8) == "{\"ok\":true}")
        }

        @Test func httpRequestReturnsDefaultForUnknownURL() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()

            var response: HTTPResponse?
            env.network.httpRequest(url: "https://unknown.example.com", method: "GET",
                                    headers: [:], body: nil, redirect: true) { r, _ in
                response = r
            }
            #expect(response?.statusCode == 200)
            #expect(String(data: response!.body!, encoding: .utf8) == "OK")
        }

        // MARK: - Reachability state machine

        @Test func defaultReachabilityIsReachable() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let net = env.network as! SimulatedNetwork

            #expect(net.getReachabilityFlags(host: "example.com") == 2)
        }

        @Test func setHostUnreachable() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let net = env.network as! SimulatedNetwork

            net.setUnreachable(host: "offline.example.com")
            #expect(net.getReachabilityFlags(host: "offline.example.com") == 0)
            // Other hosts remain reachable
            #expect(net.getReachabilityFlags(host: "online.example.com") == 2)
        }

        @Test func setHostReachableAfterUnreachable() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let net = env.network as! SimulatedNetwork

            net.setUnreachable(host: "flaky.example.com")
            #expect(net.getReachabilityFlags(host: "flaky.example.com") == 0)

            net.setReachable(host: "flaky.example.com")
            #expect(net.getReachabilityFlags(host: "flaky.example.com") == 2)
        }

        @Test func reachabilityCallbackFiresOnChange() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let net = env.network as! SimulatedNetwork
            var receivedFlags: [UInt32] = []

            _ = net.addReachabilityListener(host: "example.com") { flags in
                receivedFlags.append(flags)
            }

            net.setUnreachable(host: "example.com")
            #expect(receivedFlags == [0])

            net.setReachable(host: "example.com")
            #expect(receivedFlags == [0, 2])
        }

        @Test func reachabilityCallbackDoesNotFireForSameState() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let net = env.network as! SimulatedNetwork
            var callCount = 0

            _ = net.addReachabilityListener(host: "example.com") { _ in
                callCount += 1
            }

            // Setting to the same default flags should not fire
            net.setReachabilityFlags(host: "example.com", flags: 2)
            #expect(callCount == 0)
        }

        @Test func reachabilityCallbackOnlyFiresForMatchingHost() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let net = env.network as! SimulatedNetwork
            var callbackHost: String?

            _ = net.addReachabilityListener(host: "target.com") { _ in
                callbackHost = "target.com"
            }

            net.setUnreachable(host: "other.com")
            #expect(callbackHost == nil)

            net.setUnreachable(host: "target.com")
            #expect(callbackHost == "target.com")
        }

        @Test func removeReachabilityListenerStopsCallbacks() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let net = env.network as! SimulatedNetwork
            var callCount = 0

            let id = net.addReachabilityListener(host: "example.com") { _ in
                callCount += 1
            }

            net.setUnreachable(host: "example.com")
            #expect(callCount == 1)

            #expect(net.removeReachabilityListener(id: id))
            net.setReachable(host: "example.com")
            #expect(callCount == 1)  // no further callback
        }

        @Test func removeNonexistentListenerReturnsFalse() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let net = env.network as! SimulatedNetwork

            #expect(!net.removeReachabilityListener(id: 999))
        }

        @Test func setDefaultReachabilityFiresCallbacksForDefaultHosts() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let net = env.network as! SimulatedNetwork
            var defaultCallCount = 0
            var overrideCallCount = 0

            // This host uses default flags
            _ = net.addReachabilityListener(host: "default-host.com") { _ in
                defaultCallCount += 1
            }

            // This host has explicit flags
            net.setReachabilityFlags(host: "override-host.com", flags: 2)
            _ = net.addReachabilityListener(host: "override-host.com") { _ in
                overrideCallCount += 1
            }

            // Change default: should fire for default-host but not override-host
            net.setDefaultReachabilityFlags(0)
            #expect(defaultCallCount == 1)
            #expect(overrideCallCount == 0)
        }

        @Test func customReachabilityFlags() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let net = env.network as! SimulatedNetwork

            // Set flags with WiFi characteristics (reachable + isDirect)
            let wifiFlags: UInt32 = 2 | 0x20000  // reachable | isDirect
            net.setReachabilityFlags(host: "wifi-host.com", flags: wifiFlags)
            #expect(net.getReachabilityFlags(host: "wifi-host.com") == wifiFlags)
        }

        // MARK: - TCP connections

        @Test func tcpConnectionSucceeds() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            var connected = false

            let conn = env.network.createTCPConnection(host: "localhost", port: 8080) { err in
                connected = (err == nil)
            }
            #expect(connected)
            #expect(conn.isConnected)
        }

        @Test func tcpConnectionTracksSentData() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()

            let conn = env.network.createTCPConnection(host: "localhost", port: 8080) { _ in }
            let simConn = conn as! SimulatedTCPConnection

            conn.send("hello".data(using: .utf8)!) { _ in }
            conn.send("world".data(using: .utf8)!) { _ in }

            #expect(simConn.sentData.count == 2)
            #expect(String(data: simConn.sentData[0], encoding: .utf8) == "hello")
        }

        @Test func tcpSendFailsWhenDisconnected() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            var sendError: Error?

            let conn = env.network.createTCPConnection(host: "localhost", port: 8080) { _ in }
            conn.cancel()  // disconnect

            conn.send("data".data(using: .utf8)!) { err in
                sendError = err
            }
            #expect(sendError != nil)
        }

        @Test func tcpConnectionEnqueueAndReceive() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()

            let conn = env.network.createTCPConnection(host: "localhost", port: 8080) { _ in }
            let simConn = conn as! SimulatedTCPConnection

            simConn.enqueue("response-1".data(using: .utf8)!)
            simConn.enqueue("response-2".data(using: .utf8)!)

            var data1: Data?
            var data2: Data?
            conn.receive(minimumLength: 1, maximumLength: 1024) { d, _ in data1 = d }
            conn.receive(minimumLength: 1, maximumLength: 1024) { d, _ in data2 = d }

            #expect(String(data: data1!, encoding: .utf8) == "response-1")
            #expect(String(data: data2!, encoding: .utf8) == "response-2")
        }

        // MARK: - TCP listener

        @Test func tcpListenerReceivesSimulatedConnection() throws {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let net = env.network as! SimulatedNetwork
            var receivedConnections: [any TCPConnectionHandle] = []

            _ = try env.network.createTCPListener(port: 9090) { conn in
                receivedConnections.append(conn)
            }

            let simConn = net.simulateIncomingConnection(port: 9090)
            #expect(simConn != nil)
            #expect(receivedConnections.count == 1)
            #expect(receivedConnections[0].isConnected)
        }

        @Test func tcpListenerCancelStopsAccepting() throws {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let net = env.network as! SimulatedNetwork
            var receivedConnections: [any TCPConnectionHandle] = []

            let listener = try env.network.createTCPListener(port: 9091) { conn in
                receivedConnections.append(conn)
            }

            listener.cancel()

            let result = net.simulateIncomingConnection(port: 9091)
            #expect(result == nil)
            #expect(receivedConnections.isEmpty)
        }

        @Test func simulateIncomingConnectionOnNonListeningPort() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let net = env.network as! SimulatedNetwork

            let result = net.simulateIncomingConnection(port: 1234)
            #expect(result == nil)
        }

        @Test func multipleListenersOnDifferentPorts() throws {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let net = env.network as! SimulatedNetwork
            var port8080Count = 0
            var port9090Count = 0

            _ = try env.network.createTCPListener(port: 8080) { _ in port8080Count += 1 }
            _ = try env.network.createTCPListener(port: 9090) { _ in port9090Count += 1 }

            net.simulateIncomingConnection(port: 8080)
            net.simulateIncomingConnection(port: 8080)
            net.simulateIncomingConnection(port: 9090)

            #expect(port8080Count == 2)
            #expect(port9090Count == 1)
        }

        // MARK: - Connection tracking

        @Test func createdConnectionsAreTracked() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let net = env.network as! SimulatedNetwork

            _ = env.network.createTCPConnection(host: "host-a", port: 80) { _ in }
            _ = env.network.createTCPConnection(host: "host-b", port: 443) { _ in }

            #expect(net.createdConnections.count == 2)
            #expect(net.createdConnections[0].host == "host-a")
            #expect(net.createdConnections[1].host == "host-b")
            #expect(net.createdConnections[1].port == 443)
        }

        // MARK: - Fault injection

        @Test func httpTimeoutFault() {
            var faults = FaultConfig()
            faults.httpTimeoutProbability = 1.0
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)
            var error: Error?

            env.network.httpRequest(url: "https://example.com", method: "GET",
                                    headers: [:], body: nil, redirect: true) { _, e in
                error = e
            }
            #expect(error != nil)
        }

        @Test func connectionFailFault() {
            var faults = FaultConfig()
            faults.connectionFailProbability = 1.0
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)
            var error: Error?

            _ = env.network.createTCPConnection(host: "localhost", port: 80) { err in
                error = err
            }
            #expect(error != nil)
        }

        @Test func packetDropFault() {
            var faults = FaultConfig()
            faults.packetDropProbability = 1.0
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)
            var sendError: Error?

            let conn = env.network.createTCPConnection(host: "localhost", port: 80) { _ in }
            conn.send("data".data(using: .utf8)!) { err in
                sendError = err
            }
            #expect(sendError != nil)
        }

        // MARK: - Determinism

        @Test func networkBehaviorIsDeterministic() {
            for _ in 0..<2 {
                let harness = SimulatorHarness(seed: 42)
                let env = harness.createEnvironment()
                let net = env.network as! SimulatedNetwork

                net.httpResponses["https://test.com"] = HTTPResponse(
                    statusCode: 200, headers: [:], body: "test".data(using: .utf8)
                )

                var response: HTTPResponse?
                env.network.httpRequest(url: "https://test.com", method: "GET",
                                        headers: [:], body: nil, redirect: true) { r, _ in
                    response = r
                }
                #expect(response?.statusCode == 200)
                #expect(net.getReachabilityFlags(host: "any") == 2)
            }
        }
    }
}
