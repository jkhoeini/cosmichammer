import Testing
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) struct VersionUtils {
        @Test func appVersionUsesMarketingVersion() {
            let info: [String: Any] = [
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "456",
            ]

            #expect(MJVersionFromInfoDictionary(info) == 10203)
        }

        @Test func appVersionIgnoresBuildNumberWhenMarketingVersionMissing() {
            #expect(MJVersionFromInfoDictionary(["CFBundleVersion": "456"]) == 0)
        }

        @Test func appVersionHandlesPartialAndInvalidMarketingVersions() {
            #expect(MJVersionFromInfoDictionary(["CFBundleShortVersionString": "1.2"]) == 10200)
            #expect(MJVersionFromInfoDictionary(["CFBundleShortVersionString": "1.2.3-beta"]) == 10203)
            #expect(MJVersionFromInfoDictionary(["CFBundleShortVersionString": "abc"]) == 0)
        }
    }
}
