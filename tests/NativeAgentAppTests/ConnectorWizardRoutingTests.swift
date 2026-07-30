import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Connector wizard routing")
struct ConnectorWizardRoutingTests {
    @Test func verifiedConnectorRoutesRemainExplicit() {
        #expect(ConnectorWizardSetupRoute.resolve(provider: "slack") == .manualToken)
        #expect(ConnectorWizardSetupRoute.resolve(provider: "GitHub") == .manualToken)
        #expect(ConnectorWizardSetupRoute.resolve(provider: "x") == .nativeOAuth(connectorId: "x"))
        #expect(ConnectorWizardSetupRoute.resolve(provider: "twitter") == .nativeOAuth(connectorId: "x"))
        #expect(ConnectorWizardSetupRoute.resolve(provider: "email") == .nativeOAuth(connectorId: "gmail"))
        #expect(ConnectorWizardSetupRoute.resolve(provider: "gmail") == .nativeOAuth(connectorId: "gmail"))
        #expect(ConnectorWizardSetupRoute.resolve(provider: "calendar") == .nativeOAuth(connectorId: "calendar"))
        #expect(ConnectorWizardSetupRoute.resolve(provider: "gcal") == .nativeOAuth(connectorId: "calendar"))
        #expect(ConnectorWizardSetupRoute.resolve(provider: "google_calendar") == .nativeOAuth(connectorId: "calendar"))
        #expect(ConnectorWizardSetupRoute.resolve(provider: "notion") == .notionToken)
    }

    @Test func unsupportedConnectorsFailClosedBeforeSetupWork() {
        for provider in ["linear", "unknown", "  custom-provider  "] {
            #expect(ConnectorWizardSetupRoute.resolve(provider: provider) == .unavailable)
        }
    }

    @Test func publicOAuthRoutesUseExactLoopbackCallbacksAndLeastPrivilegeGoogleScopes() throws {
        for id in ["x", "gmail", "calendar"] {
            let config = try #require(NativeOAuthFlow.connectorOAuthConfig(connectorId: id))
            let url = try #require(URL(string: config.redirectURI))
            #expect(url.scheme == "http")
            #expect(url.host == "127.0.0.1")
            #expect(url.port != nil)
            #expect(url.path == "/oauth/callback")
        }

        let gmail = try #require(NativeOAuthFlow.connectorOAuthConfig(connectorId: "gmail"))
        #expect(gmail.scopes.contains("gmail.readonly"))
        #expect(!gmail.scopes.contains("gmail.send"))
        let calendar = try #require(NativeOAuthFlow.connectorOAuthConfig(connectorId: "calendar"))
        #expect(calendar.scopes.contains("calendar.readonly"))
        #expect(calendar.scopes != "https://www.googleapis.com/auth/calendar")
    }

    @Test func sharedLoopbackCallbackRejectsPrefixAndResultlessRequests() {
        let path = "/oauth/callback"
        let port: UInt16 = 53683
        #expect(
            NativeOAuthLoopbackCallbackServer.validCallbackURL(
                target: "\(path)?code=ok&state=s",
                path: path,
                port: port
            ) != nil
        )
        #expect(
            NativeOAuthLoopbackCallbackServer.validCallbackURL(
                target: "\(path)/extra?code=ok",
                path: path,
                port: port
            ) == nil
        )
        #expect(
            NativeOAuthLoopbackCallbackServer.validCallbackURL(
                target: "\(path)?state=s",
                path: path,
                port: port
            ) == nil
        )
    }

    @Test func connectorRowsExposeOnlyRealActions() {
        #expect(
            ConnectorRowActionPolicy.resolve(
                id: "telegram",
                authState: "not_connected",
                healthStatus: "needs_auth"
            ) == ConnectorRowActionPolicy(
                primaryTitle: "Configure",
                primaryAction: .openTelegramSettings,
                showsEnabledMutation: false
            )
        )
        #expect(
            ConnectorRowActionPolicy.resolve(
                id: "notion",
                authState: "needs_auth",
                healthStatus: "needs_auth"
            ) == ConnectorRowActionPolicy(
                primaryTitle: "Connect",
                primaryAction: .openWizard(provider: "notion"),
                showsEnabledMutation: false
            )
        )
        #expect(
            ConnectorRowActionPolicy.resolve(
                id: "gmail",
                authState: "coming_soon",
                healthStatus: "coming_soon"
            ).primaryAction == .openWizard(provider: "gmail")
        )
        #expect(
            ConnectorRowActionPolicy.resolve(
                id: "github",
                authState: "not_connected",
                healthStatus: "needs_auth"
            ).primaryAction == .openWizard(provider: "github")
        )
        #expect(
            ConnectorRowActionPolicy.resolve(
                id: "browser",
                authState: "not_required",
                healthStatus: "ready"
            ).primaryAction == .showBrowser
        )
        #expect(
            ConnectorRowActionPolicy.resolve(
                id: "shortcuts",
                authState: "not_required",
                healthStatus: "ready"
            ) == ConnectorRowActionPolicy(
                primaryTitle: nil,
                primaryAction: nil,
                showsEnabledMutation: false
            )
        )
    }

    @Test func connectorWizardPresentationIsExplicitRepeatableAndFailClosed() {
        var presentation = ConnectorWizardPresentationState()
        #expect(!presentation.isPresented)
        #expect(presentation.provider == nil)

        for provider in ["gmail", "calendar", "notion", "x"] {
            presentation.present(provider: "  \(provider.uppercased())  ")
            #expect(presentation.isPresented)
            #expect(presentation.provider == provider)

            presentation.dismiss()
            #expect(!presentation.isPresented)
            #expect(presentation.provider == nil)
        }

        presentation.present(provider: "unsupported")
        #expect(!presentation.isPresented)
        #expect(presentation.provider == nil)
    }

    @Test func connectorViewUsesDirectPresentationBindingInsteadOfItemIdentity() throws {
        let source = try AppSourceScraping.appSource("ConnectorsView.swift")
        #expect(source.contains(".sheet("))
        #expect(source.contains("isPresented: Binding("))
        #expect(source.contains("wizardPresentation.present(provider: provider)"))
        #expect(!source.contains(".sheet(item: $connectingProvider)"))
    }

    @Test func retiredDeviceFlowCannotPollOrForgeConnectedState() throws {
        let wizard = try AppSourceScraping.appSource("ConnectorWizardView.swift")
        let appModel = try AppSourceScraping.appSource("AppModel+ViewClientOps.swift")
        let seams = try AppSourceScraping.appSource("NativeClient+CutoverSeams.swift")

        #expect(!wizard.contains("startPollingDeviceFlow"))
        #expect(!wizard.contains("pollTask"))
        #expect(!wizard.contains("waitingDeviceAuth"))
        #expect(!wizard.contains("ConnectorConnectResponse"))
        #expect(!appModel.contains("func connectConnector(provider:"))
        #expect(!appModel.contains("func getConnectorConnectStatus("))
        #expect(!seams.contains("func connectConnector(provider:"))
        #expect(!seams.contains("func getConnectorConnectStatus("))
        #expect(!seams.contains("entry[\"connected\"] = .bool(true)"))
    }

    // Source readers (appSource / repositoryRoot) live in the shared
    // AppSourceScraping enum.
}
