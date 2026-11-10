import Testing
@testable import RuSwitcher

@Suite @MainActor
struct UpdateChannelTests {
    @Test func stableUsersNeverReceiveBeta() {
        #expect(!UpdateChecker.selectsBeta(stable: "1.1.6", beta: "1.2.0a", enabled: false))
        #expect(UpdateChecker.selectsBeta(stable: "1.1.6", beta: "1.2.0a", enabled: true))
    }

    @Test func missingOrInvalidBetaFallsBackToStable() {
        for beta: String? in [nil, "", "garbage", "1.2.0", "1.2.0a/path"] {
            #expect(!UpdateChecker.selectsBeta(stable: "1.1.6", beta: beta, enabled: true))
        }
    }

    @Test func finalReleaseSupersedesAllItsBetas() {
        #expect(!UpdateChecker.selectsBeta(stable: "1.2.0", beta: "1.2.0a", enabled: true))
        #expect(UpdateChecker.compareVersions("1.2.0", isNewerThan: "1.2.0z"))
        #expect(UpdateChecker.compareVersions("1.2.0b", isNewerThan: "1.2.0a"))
        #expect(UpdateChecker.compareVersions("1.2.0a", isNewerThan: "1.1.6"))
        #expect(!UpdateChecker.compareVersions("1.1.6", isNewerThan: "1.2.0a"))
    }
}
