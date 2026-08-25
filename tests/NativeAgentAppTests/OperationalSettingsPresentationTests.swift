import Foundation
import AppKit
import Testing
import BackgroundLoops
@testable import NativeAgentApp

@Suite("Operational settings presentation")
struct OperationalSettingsPresentationTests {
    @Test func providerRowsHaveStableLabelsAndCompactControlWidths() {
        #expect(ProviderSettingsSurfaceLabel.presentation(for: "chat") == .named("Chat"))
        #expect(ProviderSettingsSurfaceLabel.presentation(for: " telegram") == .malformed)
        #expect(ProviderSettingsSurfaceLabel.presentation(for: "future") == .unrecognized("future"))
        #expect(ProviderSurfaceRowLayout.reasoningPickerWidth == 148)
        #expect(ProviderSurfaceRowLayout.fastToggleWidth == 88)
        #expect(ProviderConfigModelPickerPresentation.resolve(
            selectedModel: "stale",
            advertisedModelIDs: ["current"]
        ).needsReplacement)
    }

    @Test func macPermissionPresentationKeepsSystemAndToolGatesSeparate() {
        #expect(MacIntegrationSystemPermissionPresentation.statusKeys == [
            "speech_recognition", "microphone", "calendar", "reminders", "contacts",
            "apple_events_mail", "apple_events_messages", "apple_events_notes", "apple_events_music",
        ])
        #expect(!MacIntegrationSystemPermissionPresentation.allGranted([:]))
        #expect(MacIntegrationSystemPermissionPresentation.allGranted(
            Dictionary(uniqueKeysWithValues: MacIntegrationSystemPermissionPresentation.statusKeys.map { ($0, "granted") })
        ))
        #expect(MacIntegrationPermissionLoadPresentation.resolve(isLoading: false, loadError: "damaged")
            == .unavailable(detail: "damaged", retrying: false))
        #expect(MacIntegrationPermissionFailurePresentation.saveAlertIsPresented(
            persistenceError: "write failed", requestError: nil
        ))
        #expect(!MacIntegrationPermissionFailurePresentation.requestAlertIsPresented(
            persistenceError: "write failed", requestError: nil
        ))
    }

    @Test func operationalControlsHaveExactlyOneVisibleOwner() {
        let owners = Dictionary(grouping: OperationalSettingsControlPresentation.Control.allCases) {
            OperationalSettingsControlPresentation.owner(for: $0)
        }
        #expect(owners[.providers] ?? [] == [.providerRoute])
        #expect(owners[.macIntegration] ?? [] == [.macIntegrationPermission])
        #expect(Set(owners[.settings] ?? []) == [.subconsciousMaster, .fluidContext, .softwareUpdate, .globalHotkey])
        #expect(OperationalSettingsControlPresentation.title(for: .fluidContext) == "Fluid Context")
        #expect(OperationalSettingsControlPresentation.fluidContextLabel(.shadow) == "Observe Only")
    }

    @Test func providerRefreshSeparatesEmptyCatalogFromAuthorityFailure() {
        #expect(ProviderSettingsRefreshPresentation.resolve(providerCount: 2, loadError: "failure") == .available)
        #expect(ProviderSettingsRefreshPresentation.resolve(providerCount: 0, loadError: nil) == .empty)
        #expect(ProviderSettingsRefreshPresentation.resolve(providerCount: 0, loadError: "unreachable") == .unavailable("unreachable"))
    }

    @Test @MainActor func softwareUpdateConfigurationRequiresOneRealPublishedFeed() {
        let validKey = Data(repeating: 7, count: 32).base64EncodedString()
        let usable: [String: Any] = [
            "SUFeedURL": "https://updates.nativeagent.dev/appcast.xml",
            "SUPublicEDKey": validKey,
            "NativeAgentUpdateFeedPublished": true,
        ]
        #expect(UpdateController.resolveUnavailability(info: usable) == nil)
        #expect(UpdateController.resolveUnavailability(info: usable.merging([
            "NativeAgentUpdateFeedPublished": false,
        ]) { _, new in new }) == .feedNotPublished)
        #expect(UpdateController.resolveUnavailability(info: usable.merging([
            "SUFeedURL": "https://example.com/nativeagent/appcast.xml",
        ]) { _, new in new }) == .notConfigured)
    }

    @Test @MainActor func softwareUpdateSettingsCopyNamesEveryAvailabilityState() {
        #expect(UpdateController.settingsDetail(for: nil).contains("signed release feed"))
        #expect(UpdateController.settingsDetail(for: .feedNotPublished)
            == UpdateController.Unavailability.feedNotPublished.detail)
        #expect(UpdateController.settingsDetail(for: .notConfigured)
            == UpdateController.Unavailability.notConfigured.detail)
    }

    @Test func backgroundLoopFacadePreservesHealthFieldsForWatchdogConsumers() {
        let lastRun = Date(timeIntervalSince1970: 1_000)
        let nextRun = Date(timeIntervalSince1970: 1_300)
        let core = BackgroundLoops.LoopStatus(
            name: "fixture-loop", lastRun: lastRun, nextRun: nextRun,
            runCount: 7, lastError: "fixture failure", running: true,
            executing: true, executionStartedAt: lastRun,
            executionTimeout: 42,
            eventListener: .init(active: false, restartCount: 2,
                                 consecutiveEnds: 1, lastError: "stream ended")
        )
        let facade = BackgroundLoopsManager.LoopStatus(core)
        #expect(facade.loopId == "fixture-loop")
        #expect(facade.lastRun == lastRun)
        #expect(facade.nextRun == nextRun)
        #expect(facade.runCount == 7)
        #expect(facade.lastError == "fixture failure")
        #expect(facade.running && facade.executing)
        #expect(facade.executionStartedAt == lastRun)
        #expect(facade.executionTimeout == 42)
        #expect(facade.eventListener?.lastError == "stream ended")
    }

    @MainActor
    @Test func paletteInputAndGlobalHotkeyTransitionsStayScoped() {
        #expect(commandPaletteShouldAdoptHover(true, eventType: .mouseMoved))
        #expect(!commandPaletteShouldAdoptHover(true, eventType: .keyDown))
        #expect(commandPaletteIsBareKeyEvent([.function, .numericPad]))
        #expect(!commandPaletteIsBareKeyEvent([.command]))
        #expect(CommandPaletteKeyCatcherMonitor.action(
            eventBelongsToPaletteWindow: true,
            paletteWindowIsKey: true,
            modifierFlags: [.function, .numericPad],
            keyCode: 126
        ) == .moveUp)
        #expect(GlobalHotkeyManager.registrationTransition(enabled: true, isRegistered: false) == .register)
        #expect(GlobalHotkeyManager.registrationTransition(enabled: false, isRegistered: true) == .unregister)
        #expect(GlobalHotkeyManager.registrationTransition(enabled: true, isRegistered: true) == .none)
    }
}
