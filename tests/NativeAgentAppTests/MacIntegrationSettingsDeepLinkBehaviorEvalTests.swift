import Foundation
import Testing
@testable import NativeAgentApp

@Suite("app.mac · Mac Integration System Settings deep links")
struct MacIntegrationSettingsDeepLinkBehaviorEvalTests {
    @Test("every supported privacy capability opens through the canonical URL builder")
    func supportedCapabilitiesUseCanonicalURLAndReportSuccess() {
        let capabilities: [SystemPermissionCapability] = [
            .speechRecognition, .microphone, .calendars, .reminders,
            .contacts, .automation,
        ]

        for capability in capabilities {
            var openedURL: URL?
            let outcome = MacIntegrationSettingsDeepLink.open(capability) { url in
                openedURL = url
                return true
            }
            #expect(outcome == .opened(capability))
            #expect(openedURL == SystemPermissionPreflight.settingsURL(for: capability))
        }
    }

    @Test("a failed System Settings handoff is explicit and an unsupported pane is never opened")
    func failedAndUnavailableLinksRemainAdverse() {
        let failed = MacIntegrationSettingsDeepLink.open(.microphone) { _ in false }
        #expect(failed == .failed(.microphone))
        #expect(failed.failureMessage?.contains("Microphone") == true)
        #expect(failed.failureMessage?.contains("System Settings") == true)

        var openerWasCalled = false
        let unavailable = MacIntegrationSettingsDeepLink.open(.notifications) { _ in
            openerWasCalled = true
            return true
        }
        #expect(unavailable == .unavailable(.notifications))
        #expect(!openerWasCalled)
        #expect(unavailable.failureMessage?.contains("Notifications") == true)
    }

    @Test("the mounted panel routes every privacy recovery click through the checked handoff owner")
    func productionPanelHasNoUncheckedSettingsOpenCallSites() throws {
        let source = try AppSourceScraping.appSource("MacIntegrationView.swift")
        #expect(source.contains("MacIntegrationSettingsDeepLink.open(capability, using: opener)"))
        #expect(source.contains("openSystemSettings(permission.capability)"))
        #expect(source.contains("openSystemSettings(.automation)"))
        #expect(source.contains("openSystemSettings(capability).failureMessage"))
        #expect(!source.contains("_ = NSWorkspace.shared.open(url)"))
    }
}
