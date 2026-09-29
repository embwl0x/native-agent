import Foundation
import Observation
import Darwin
import AppKit
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import TrustCenter
import DreamREMCycle
import DoctorChecks
import CommandPalette
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser

typealias MacControlRunResult = MacControl.MacControlRunResult

// MARK: - Wave 3 runtime seam wrappers
// Consolidates direct-URLSession callers in PairMobileView, VoiceOutputController,
// KnowledgeGraphView, InboxSettingsView, ContentView, MacControlPermissionsView,
// and ConnectorWizardView behind NativeClient so each subsystem has one
// app-owned Swift entry point.

extension NativeClient {
    // --- Context feedback ---------------------------------------------------
    // Exact, payload-free feedback after validating the canonical transcript
    // row. `dataRoot` is injectable so alternate runtimes and tests cannot
    // leak ratings into Agent's personal root. Persona is deliberately not
    // persisted: message/turn identity already supplies exact correlation.
    func postContextFeedback(
        messageId: String,
        sessionId: String,
        rating: String,
        persona _: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws {
        _ = try await OutcomeFeedbackStore(dataRoot: dataRoot).record(
            sessionID: sessionId,
            messageID: messageId,
            rating: rating
        )
    }

    // --- Screen vision (v1, 2026-06-06) ------------------------------------
    // Swift-native one-shot screen capture. Two-layer fail-closed contract:
    //
    //   Layer 1 (ScreenVision module): SwiftNativeScreenVision.captureScreen()
    //     THROWS on permission denial, missing display, or capture failure.
    //     There is no mock fallback, no empty-Data return, no daemon HTTP
    //     path — that's where the fail-closed rule lives.
    //
    //   Layer 2 (this seam): preserves that typed failure for chat callers.
    //     Returning nil/empty data here is not a benign convenience: it lets
    //     a turn proceed as though it has a screen attachment when capture was
    //     denied or produced no image bytes.
    //
    // v1 callers: none yet — this is a public seam for future
    // vision-decision-loop work (e.g. /show slash command, autonomous
    // execution step). The composer button still goes through
    // ContentView.NativeScreenCapture.captureImageBase64() which delegates
    // to the SAME ScreenVision module under the hood.
    @MainActor
    func captureScreenForChat(
        capture: @escaping @Sendable () async throws -> Data = {
            try await SwiftNativeScreenVision().captureScreen()
        }
    ) async throws -> Data {
        let image = try await capture()
        guard !image.isEmpty else {
            throw ScreenVisionError.captureFailed("capture returned no image bytes")
        }
        return image
    }

    // --- Mac control --------------------------------------------------------
    // Zero-daemon Swift path: implemented MacControl actions execute in-process
    // behind the Swift TrustCenter-backed gate. Unknown/unimplemented actions
    // return Swift error envelopes; there is no raw HTTP fallback.
    func macControlNotify(title: String, message: String) async throws -> Bool {
        let impl = makeMacControl(
            policyProvider: macControlPolicyProvider,
            auditAppendPath: macControlAuditPath,
            notificationCenterAdapter: NativeAgentMacControlNotificationAdapter()
        )
        let r = try await impl.dispatch(action: "notify", body: [
            "title": .string(title),
            "message": .string(message),
        ])
        return r.ok
    }

    /// Path to the app-owned `mac_control_audit.jsonl`. Threaded into
    /// `makeMacControl` so in-process gate refusals can append the same audit
    /// shape as older records. Isolated/recovered clients keep this write in
    /// their supplied canonical root; production falls back to the process
    /// default root.
    var macControlAuditPath: URL {
        MacControlActionRoutes.auditPath(dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot())
    }

    var macControlPolicyProvider: any MacControlPolicyProvider {
        TrustCenterMacControlPolicyProvider()
    }

    func macControlRun(path: String, bodyData: Data, timeout: TimeInterval = 90, localWorkbench: Bool = false) async throws -> MacControlRunResult {
        let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        return try await MacControlActionRoutes.run(
            path: path, bodyData: bodyData, dataRoot: root, localWorkbench: localWorkbench
        ) { operatorOrigin, auditPath in
            makeMacControl(
                policyProvider: TrustCenterMacControlPolicyProvider(
                    dataRoot: root, operatorOrigin: operatorOrigin
                ),
                auditAppendPath: auditPath,
                notificationCenterAdapter: NativeAgentMacControlNotificationAdapter()
            )
        }
    }

    func getConnectorRegistrationStatus(provider: String) async throws -> ConnectorRegistrationStatus {
        try await ConnectorWizardActions.getConnectorRegistrationStatus(provider: provider)
    }

    func registerConnectorApp(provider: String) async throws -> ConnectorRegisterAppResponse {
        try await ConnectorWizardActions.registerConnectorApp(provider: provider)
    }

}
