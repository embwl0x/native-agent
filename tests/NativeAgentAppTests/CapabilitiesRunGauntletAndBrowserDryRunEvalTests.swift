import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Capabilities.runGauntletAndBrowserDryRun

@Suite("Capabilities browser dry-run and gauntlet actions", .serialized)
struct CapabilitiesRunGauntletAndBrowserDryRunEvalTests {
    @Test("the real action owners persist dry-run and failed gauntlet evidence with honest outcome presentation")
    func browserAndGauntletOutcomesRoundTripWithoutClaimingFailedChecksPassed() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NativeClient(baseURL: "", dataRootOverride: root)

        let browserRun = try await client.runBrowser(url: "https://example.com", dryRun: true)
        #expect(browserRun.dryRun == true)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("native_power/browser/runs.json").path
        ))
        let browserStatus = try await client.getBrowserStatus()
        #expect(browserStatus.latestReceipt?.id == browserRun.id)
        #expect(browserStatus.profilePath?.hasPrefix(root.path) == true,
                "The browser status reader must use the same injected root as the dry-run writer.")
        let browserPresentation = CapabilitiesRunActionPresentation.browserOutcome(for: browserRun)
        #expect(browserPresentation.title == "Latest Browser Run")
        #expect(browserPresentation.detail == "Dry run · https://example.com")
        #expect(browserPresentation.status == browserRun.status)
        #expect(browserPresentation.failedCheckTitles.isEmpty)

        let gauntletRun = try await client.runImprovementGauntlet { executable, _, _, _ in
            if executable == "/usr/bin/swift" {
                return (status: 0, stdout: "fixture build passed", stderr: "")
            }
            if executable == "/bin/zsh" {
                return (status: 1, stdout: "", stderr: "fixture smoke failure")
            }
            return (status: 1, stdout: "", stderr: "fixture signature failure")
        }
        #expect(gauntletRun.status == "failed")
        #expect(gauntletRun.dryRun == false)
        #expect(gauntletRun.checks?.first(where: { $0.id == "isolated_smoke" })?.passed == false)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("improvements/gauntlet/runs.json").path
        ))

        let reloadedGauntlet = try await NativeClient(baseURL: "", dataRootOverride: root)
            .getImprovementGauntlet()
        #expect(reloadedGauntlet.latestRun?.id == gauntletRun.id)
        #expect(reloadedGauntlet.latestRun?.status == "failed")
        let gauntletPresentation = CapabilitiesRunActionPresentation.gauntletOutcome(for: gauntletRun)
        #expect(gauntletPresentation.title == "Latest Gauntlet")
        #expect(gauntletPresentation.detail == "1/3 checks passed")
        #expect(gauntletPresentation.status == "failed")
        #expect(gauntletPresentation.failedCheckTitles == [
            "Native smoke sweep passes",
            "Installed app verifies",
        ])
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capabilities-run-actions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

}
