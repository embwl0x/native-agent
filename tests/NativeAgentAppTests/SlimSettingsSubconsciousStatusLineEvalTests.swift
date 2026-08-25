import CognitiveSubstrate
import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.SlimSettings.subconsciousStatusLine

@Suite("Slim Settings Subconscious status line")
struct SlimSettingsSubconsciousStatusLineEvalTests {
    @Test("a complete runtime and ready reflection route are the only healthy state")
    func runningReceiptRequiresEveryLaneAndReadyRoute() {
        let status = SlimSettingsSubconsciousStatusLine.state(
            runtime: runtime(),
            reflectionRoute: route(model: "gpt-5.2", ready: true, detail: "Reflection route is ready.")
        )

        #expect(status == .init(
            text: "Running with gpt-5.2",
            detail: nil,
            tone: .healthy,
            systemImage: "checkmark.circle.fill"
        ))
        #expect(!status.requiresAttention)
    }

    @Test("disabled, incomplete, and unreadable routes remain visibly distinct")
    func adverseStatesDoNotLookLikeAHealthySubconscious() {
        let off = SlimSettingsSubconsciousStatusLine.state(
            runtime: runtime(enabled: false),
            reflectionRoute: nil
        )
        let partial = SlimSettingsSubconsciousStatusLine.state(
            runtime: runtime(capsuleEnabled: false),
            reflectionRoute: route(model: "gpt-5.2", ready: true, detail: "Reflection route is ready.")
        )
        let unavailable = SlimSettingsSubconsciousStatusLine.state(
            runtime: runtime(),
            reflectionRoute: route(
                model: "gpt-5.2",
                ready: false,
                detail: "Reflection routing is unavailable: authority read failed"
            )
        )

        #expect(off.text == "Off")
        #expect(off.tone == .neutral)
        #expect(!off.requiresAttention)
        #expect(partial.text == "Partially enabled")
        #expect(partial.detail == "Inactive: capsule")
        #expect(partial.tone == .warning)
        #expect(partial.requiresAttention)
        #expect(unavailable.text == "Reflection route unavailable")
        #expect(unavailable.tone == .unavailable)
        #expect(unavailable.requiresAttention)
        #expect(unavailable.detail?.contains("authority read failed") == true)
    }

    @Test("an enabled runtime without a reflection receipt stays in a checking state")
    func missingRuntimeReceiptNeverFallsThroughToRunning() {
        let checkingRuntime = SlimSettingsSubconsciousStatusLine.state(
            runtime: nil,
            reflectionRoute: nil
        )
        let checkingRoute = SlimSettingsSubconsciousStatusLine.state(
            runtime: runtime(),
            reflectionRoute: nil
        )

        #expect(checkingRuntime.text == "Checking runtime status…")
        #expect(checkingRoute.text == "Checking reflection route…")
        #expect(checkingRuntime.tone == .progress)
        #expect(checkingRoute.tone == .progress)
    }

    @Test("the real cognition-runtime read drives the disabled status")
    func ownerReceiptDoesNotBecomeHealthyThroughTheSettingsPresentation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SlimSettingsSubconsciousStatus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: .disabled,
            microcycleSchedulingMode: .manuallyFlushed
        )
        let receipt = await runtime.subconsciousRuntimeState()
        let status = SlimSettingsSubconsciousStatusLine.state(
            runtime: receipt,
            reflectionRoute: nil
        )

        #expect(!receipt.enabled)
        #expect(status.text == "Off")
        #expect(status.tone == .neutral)
    }

    private func runtime(
        enabled: Bool = true,
        capsuleEnabled: Bool = true,
        backgroundEnabled: Bool = true,
        reflectionEnabled: Bool = true,
        reflectionBudget: Int = 2,
        organismEnabled: Bool = true
    ) -> NativeSubconsciousRuntimeState {
        .init(
            enabled: enabled,
            capsuleEnabled: capsuleEnabled,
            backgroundEnabled: backgroundEnabled,
            reflectionEnabled: reflectionEnabled,
            reflectionBudget: reflectionBudget,
            organismEnabled: organismEnabled
        )
    }

    private func route(model: String, ready: Bool, detail: String) -> NativeReflectionRouteStatus {
        .init(
            model: model,
            providerID: "provider",
            providerReady: ready,
            modelKnown: ready ? true : nil,
            detail: detail
        )
    }
}
