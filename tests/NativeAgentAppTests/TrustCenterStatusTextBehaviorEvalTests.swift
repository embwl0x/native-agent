import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.TrustCenter.actions
@MainActor
@Suite("Trust Center action outcomes")
struct TrustCenterStatusTextBehaviorEvalTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trust-action-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("a root-scoped access save records a typed receipt and commits its policy")
    func accessSaveUsesTypedOutcomeAndDurablePolicy() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)

        #expect(await app.saveAgentAccessMode("workspace"))
        #expect(app.trustCenterActionOutcome == .saved("Agent access saved: Workspace"))
        let presentation = TrustCenterActionPresentation.state(
            for: try #require(app.trustCenterActionOutcome)
        )
        #expect(presentation.badgeText == "Saved")
        #expect(presentation.badgeStatus == "ok")

        let persisted = try await NativeClient(baseURL: "", dataRootOverride: root).getTrustPolicy()
        #expect(persisted.permissionLevel == "balanced")
        #expect(persisted.autonomyDefault == "workspace_autonomous")
        #expect(persisted.filePolicy?.outsideWorkspaceDefault == "deny")
        #expect(persisted.filePolicy?.requireBackupBeforeWrite == true)
    }

    @Test("Trust failures retain their own severity and bounded detail")
    func trustFailureUsesTypedPresentation() {
        let failure = TrustCenterActionPresentation.state(
            for: .failed("Agent access save failed: write rejected")
        )
        #expect(failure.label == "Latest Trust action")
        #expect(failure.badgeText == "Failed")
        #expect(failure.badgeStatus == "warn")

        let longDetail = "Trust save failed: " + String(repeating: "x", count: 281)
        let bounded = TrustCenterActionPresentation.state(for: .failed(longDetail))
        #expect(bounded.text.count == 281)
        #expect(bounded.text.hasSuffix("…"))
    }
}
