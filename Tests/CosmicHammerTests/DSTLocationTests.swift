import Testing
import Foundation
import HSDSTCore
import HSDSTSimulator

extension CosmicHammerTests {
    @Suite("DST Location Simulator") final class DSTLocationTests {

        // MARK: - Basic state

        @Test func defaultLocationIsSet() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let loc = env.location as! SimulatedLocation

            let coord = loc.currentLocation()
            #expect(coord != nil)
            #expect(coord?.latitude == 37.7749)
            #expect(coord?.longitude == -122.4194)
        }

        @Test func authorizationStatusDefaultsToAuthorized() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()

            #expect(env.location.authorizationStatus() == 3)
        }

        @Test func requestAuthorizationSetsAuthorized() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let loc = env.location as! SimulatedLocation

            loc.authStatus = 0  // notDetermined
            #expect(env.location.authorizationStatus() == 0)

            env.location.requestAuthorization()
            #expect(env.location.authorizationStatus() == 3)
        }

        // MARK: - Location updates

        @Test func startUpdatingDeliversCurrentLocation() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            var received: LocationCoordinate?

            env.location.startUpdating { coord, _ in received = coord }
            #expect(received != nil)
            #expect(received?.latitude == 37.7749)
        }

        @Test func pushLocationDeliversToHandler() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let loc = env.location as! SimulatedLocation
            var updates: [LocationCoordinate] = []

            loc.startUpdating { coord, _ in
                if let c = coord { updates.append(c) }
            }
            #expect(updates.count == 1)  // initial delivery

            loc.pushLocation(LocationCoordinate(latitude: 59.3293, longitude: 18.0686))
            #expect(updates.count == 2)
            #expect(updates[1].latitude == 59.3293)
            #expect(updates[1].longitude == 18.0686)
        }

        @Test func stopUpdatingPreventsDelivery() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let loc = env.location as! SimulatedLocation
            var callCount = 0

            loc.startUpdating { _, _ in callCount += 1 }
            #expect(callCount == 1)

            loc.stopUpdating()
            loc.pushLocation(LocationCoordinate(latitude: 0, longitude: 0))
            #expect(callCount == 1)  // no further deliveries
        }

        @Test func pushErrorDeliversToHandler() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let loc = env.location as! SimulatedLocation
            var receivedError: Error?

            loc.startUpdating { _, error in receivedError = error }
            receivedError = nil  // clear the initial nil error

            loc.pushError(SimulatedError.injectedFault("GPS lost"))
            #expect(receivedError != nil)
            #expect(receivedError?.localizedDescription.contains("GPS lost") == true)
        }

        // MARK: - Geocode with configurable state

        @Test func geocodeReturnsDefaultForUnknownCoordinate() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            var addresses: [String]?

            env.location.geocode(latitude: 0, longitude: 0) { result, _ in
                addresses = result
            }
            #expect(addresses == ["1 Infinite Loop, Cupertino, CA 95014"])
        }

        @Test func geocodeReturnsRegisteredResult() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let loc = env.location as! SimulatedLocation

            loc.registerGeocodeResult(
                latitude: 59.3293, longitude: 18.0686,
                addresses: ["Kungsgatan 1, Stockholm, Sweden"]
            )

            var addresses: [String]?
            env.location.geocode(latitude: 59.3293, longitude: 18.0686) { result, _ in
                addresses = result
            }
            #expect(addresses == ["Kungsgatan 1, Stockholm, Sweden"])
        }

        @Test func geocodeReturnsErrorWhenNoDefaultAndNoMatch() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let loc = env.location as! SimulatedLocation

            loc.defaultGeocodeResults = nil  // no fallback
            var error: Error?

            env.location.geocode(latitude: 99.0, longitude: 99.0) { _, err in
                error = err
            }
            #expect(error != nil)
        }

        @Test func geocodeWithMultipleRegisteredLocations() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let loc = env.location as! SimulatedLocation

            loc.registerGeocodeResult(
                latitude: 37.7749, longitude: -122.4194,
                addresses: ["San Francisco, CA"]
            )
            loc.registerGeocodeResult(
                latitude: 40.7128, longitude: -74.0060,
                addresses: ["New York, NY"]
            )

            var sfAddresses: [String]?
            env.location.geocode(latitude: 37.7749, longitude: -122.4194) { result, _ in
                sfAddresses = result
            }
            #expect(sfAddresses == ["San Francisco, CA"])

            var nyAddresses: [String]?
            env.location.geocode(latitude: 40.7128, longitude: -74.0060) { result, _ in
                nyAddresses = result
            }
            #expect(nyAddresses == ["New York, NY"])
        }

        // MARK: - Authorization state changes

        @Test func setAuthorizationStatusDeliversDeniedError() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let loc = env.location as! SimulatedLocation
            var receivedError: Error?

            loc.startUpdating { _, error in receivedError = error }
            receivedError = nil  // clear initial delivery

            loc.setAuthorizationStatus(2)  // denied
            #expect(receivedError != nil)
            #expect(loc.authorizationStatus() == 2)
        }

        @Test func setAuthorizationToAuthorizedDoesNotError() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let loc = env.location as! SimulatedLocation
            var receivedError: Error?

            loc.startUpdating { _, error in receivedError = error }
            receivedError = nil

            loc.setAuthorizationStatus(3)  // authorized
            #expect(receivedError == nil)
        }

        // MARK: - Fault injection

        @Test func locationPermissionDeniedFault() {
            var faults = FaultConfig()
            faults.locationPermissionDenied = true
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)

            #expect(env.location.authorizationStatus() == 2)
            #expect(env.location.currentLocation() != nil)  // location itself is set, but updates fail

            var error: Error?
            env.location.startUpdating { _, e in error = e }
            #expect(error != nil)
        }

        @Test func locationPermissionDeniedBlocksGeocode() {
            var faults = FaultConfig()
            faults.locationPermissionDenied = true
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)

            var error: Error?
            env.location.geocode(latitude: 0, longitude: 0) { _, e in error = e }
            #expect(error != nil)
        }

        @Test func locationUnavailableFault() {
            var faults = FaultConfig()
            faults.locationUnavailable = true
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)

            #expect(env.location.currentLocation() == nil)
        }

        @Test func requestAuthorizationDeniedUnderFault() {
            var faults = FaultConfig()
            faults.locationPermissionDenied = true
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)
            let loc = env.location as! SimulatedLocation

            loc.authStatus = 0
            env.location.requestAuthorization()
            // Under permission denied fault, requestAuthorization should not change status
            #expect(loc.authStatus == 0)
        }

        // MARK: - Determinism

        @Test func locationBehaviorIsDeterministic() {
            for _ in 0..<2 {
                let harness = SimulatorHarness(seed: 42)
                let env = harness.createEnvironment()
                let loc = env.location as! SimulatedLocation

                let coord = loc.currentLocation()
                #expect(coord?.latitude == 37.7749)
                #expect(coord?.longitude == -122.4194)
                #expect(loc.authorizationStatus() == 3)
            }
        }
    }
}
