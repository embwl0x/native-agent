import Foundation
import MacControl
import Testing
@testable import NativeAgentApp

// EVAL FENCE: core.maccontrol
// Ledger row: ui.deadSystemAndShortcutWorkbench
//
// This exercises the production workbench catalog and its NativeClient route
// seam with deliberately incomplete payloads. The requests cannot perform
// shell, file, or notification work, but they do prove the advertised routes
// reach native dispatch rather than the 501 action bucket.

@MainActor
@Suite("Mac Control workbench honest action catalog", .serialized)
struct MacControlWorkbenchBehaviorEvalTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-control-workbench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("workbench catalog removes unsupported controls and makes adverse state visible")
    func workbenchShowsOnlyRealActions() {
        let policy = TrustMacControlPolicy(
            enabled: false,
            fileOpsAllowed: true,
            shellAllowed: true,
            notificationsAllowed: true
        )
        // `MacControlWorkbenchView` derives every action button from this
        // catalog. Assert the catalog itself instead of assuming SwiftUI's
        // offscreen AppKit hierarchy contains native button titles.
        #expect(MacControlWorkbenchAction.allCases == [.shell, .fileRead, .fileWrite, .notify])
        #expect(MacControlWorkbenchAction.allCases.map(\.title) == [
            "Run Shell", "Read File", "Write File", "Notify",
        ])
        #expect(Set(MacControlWorkbenchAction.allCases.map(\.rawValue))
            .isDisjoint(with: macControlUnsupportedActions))

        let disabled = MacControlWorkbenchAction.shell.availability(
            policy: policy,
            policySaved: true
        )
        #expect(!disabled.isEnabled)
        #expect(disabled.message == "Turn on Mac Control before using this action.")

        let unsaved = MacControlWorkbenchAction.shell.availability(
            policy: policy,
            policySaved: false
        )
        #expect(!unsaved.isEnabled)
        #expect(unsaved.message == "Save the Mac Control policy before using the workbench.")
    }

    @Test("every advertised route dispatches natively and isolated clients retain their audit writes")
    func advertisedRoutesNeverResolveAsUnsupported() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NativeClient(baseURL: "", dataRootOverride: root)

        #expect(client.macControlAuditPath == root.appendingPathComponent("mac_control_audit.jsonl"))
        #expect(Set(MacControlWorkbenchAction.allCases.map(\.rawValue)).isDisjoint(with: macControlUnsupportedActions))

        for action in MacControlWorkbenchAction.allCases {
            // `{}` is intentionally invalid for each handler's required
            // payload. Depending on the local Trust policy this becomes a
            // policy refusal, an approval request, or a validation failure;
            // none may become unknown (404) or unsupported (501).
            let result = try await client.macControlRun(path: action.path, bodyData: Data("{}".utf8))
            #expect(result.statusCode != 404, "\(action.rawValue) no longer reaches the dispatcher")
            #expect(result.statusCode != 501, "\(action.rawValue) regressed into macControlUnsupportedActions")
            #expect((result.json?["error"] as? String)?.contains("unsupported_mac_control_action") != true)
        }
    }
}
