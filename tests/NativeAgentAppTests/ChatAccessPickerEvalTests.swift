import Foundation
import Testing

@testable import NativeAgentApp

@Suite("Conversation settings access picker")
struct ChatAccessPickerEvalTests {
    @Test("a fresh policy requires confirmation before Full Mac while all ordinary selections save")
    func fullMacCannotBypassConfirmationForAnyNonFullPolicyShape() {
        let freshPolicyShapes: [(String?, String?)] = [
            (nil, nil),
            ("balanced", "deny"),
            ("strict", "ask"),
        ]
        for (permissionLevel, outsideDefault) in freshPolicyShapes {
            let alreadyFull = ChatAccessPickerPolicy.trustPolicyAlreadyFullMac(
                permissionLevel: permissionLevel,
                outsideWorkspaceDefault: outsideDefault
            )
            #expect(!alreadyFull)
            #expect(ChatAccessPickerPolicy.action(
                requestedMode: "full",
                currentMode: "workspace",
                trustPolicyAlreadyFullMac: alreadyFull
            ) == .requiresFullMacConfirmation(previousMode: "workspace"))
        }

        for mode in ["auto", "read_only"] {
            #expect(ChatAccessPickerPolicy.action(
                requestedMode: mode,
                currentMode: "workspace",
                trustPolicyAlreadyFullMac: false
            ) == .save(mode: mode, rollbackMode: "workspace"))
        }
        #expect(ChatAccessPickerPolicy.action(
            requestedMode: "workspace",
            currentMode: "workspace",
            trustPolicyAlreadyFullMac: false
        ) == .unchanged)
    }

    @Test("every canonical existing Full Mac policy shape may save without a duplicate confirmation")
    func existingFullMacPolicyShapesAreRecognizedExactly() {
        for (permissionLevel, outsideDefault) in [
            ("full_mac_os", "deny"),
            ("wide_open_receipts", "deny"),
            ("balanced", "allow"),
        ] {
            let alreadyFull = ChatAccessPickerPolicy.trustPolicyAlreadyFullMac(
                permissionLevel: permissionLevel,
                outsideWorkspaceDefault: outsideDefault
            )
            #expect(alreadyFull)
            #expect(ChatAccessPickerPolicy.action(
                requestedMode: "full",
                currentMode: "workspace",
                trustPolicyAlreadyFullMac: alreadyFull
            ) == .save(mode: "full", rollbackMode: "workspace"))
        }
    }

    @Test("failed saves roll the visible picker back to its previous durable value")
    func failureCannotLeaveThePickerAheadOfTheStore() {
        #expect(ChatAccessPickerPolicy.visibleMode(
            afterSaving: "full",
            rollbackMode: "read_only",
            succeeded: false
        ) == "read_only")
        #expect(ChatAccessPickerPolicy.visibleMode(
            afterSaving: "workspace",
            rollbackMode: "auto",
            succeeded: false
        ) == "auto")
        #expect(ChatAccessPickerPolicy.visibleMode(
            afterSaving: "workspace",
            rollbackMode: "auto",
            succeeded: true
        ) == "workspace")
    }

    @Test("the real access writer persists every picker mode across a cold policy read")
    func allPickerModesReachTheCanonicalTrustStore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-access-picker-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NativeClient(baseURL: "http://localhost", dataRootOverride: root)
        // Seed and reload solely through the canonical trust-policy writer so
        // saveAgentAccessMode never consults a process-global policy in this
        // hermetic evaluation.
        var current = try await NativeClient.applyTrustPolicyPatch(body: [:], dataRoot: root)

        for mode in ["auto", "read_only", "workspace", "full"] {
            current = try await client.saveAgentAccessMode(mode, currentPolicy: current)
            let reloaded = try await NativeClient.applyTrustPolicyPatch(body: [:], dataRoot: root)
            #expect(
                AppModel.agentAccessMode(from: reloaded, fallback: mode)
                    == AppModel.normalizedAgentAccessMode(mode),
                "\(mode) must survive the persistent policy boundary"
            )
            current = reloaded
        }
    }
}
