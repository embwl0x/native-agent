// PATCH-2026-05-07: oauth-registration-2 Inline OAuth wizard — ConnectorWizardView
import SwiftUI
import AppKit

// MARK: - Models

struct ConnectorRegistrationStatus: Codable {
    var registered: Bool
    var registeredAt: String?
    var clientIdPresent: Bool

    enum CodingKeys: String, CodingKey {
        case registered
        case registeredAt = "registered_at"
        case clientIdPresent = "client_id_present"
    }
}

struct ConnectorRegisterAppResponse: Codable {
    var provider: String?
    var programmatic: Bool?
    var approvalUrl: String?
    var callbackPath: String?
    var portalUrl: String?
    var note: String?
    var reason: String?
    var nextSteps: [String]?

    enum CodingKeys: String, CodingKey {
        case provider, note, reason
        case programmatic
        case approvalUrl = "approval_url"
        case callbackPath = "callback_path"
        case portalUrl = "portal_url"
        case nextSteps = "next_steps"
    }
}

enum ConnectorWizardSetupRoute: Equatable {
    case manualToken
    case notionToken
    case nativeOAuth(connectorId: String)
    case unavailable

    static func resolve(provider: String) -> Self {
        switch provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "slack", "github":
            return .manualToken
        case "notion":
            return .notionToken
        case "x", "twitter":
            return .nativeOAuth(connectorId: "x")
        case "email", "gmail":
            return .nativeOAuth(connectorId: "gmail")
        case "calendar", "gcal", "google_calendar":
            return .nativeOAuth(connectorId: "calendar")
        default:
            return .unavailable
        }
    }
}

// MARK: - Wizard State

@Observable
@MainActor
final class ConnectorWizardState {
    var provider: String = ""
    var providerDisplayName: String = ""
    var step: WizardStep = .loading
    var registrationStatus: ConnectorRegistrationStatus?
    var registerAppResponse: ConnectorRegisterAppResponse?
    var errorMessage: String?
    var oauthClientId: String = ""
    var oauthClientSecret: String = ""
    // Tracks the Connect-button native OAuth flow so a sheet dismissed mid-flow
    // cannot mutate the torn-down wizard afterward.
    var flowTask: Task<Void, Never>?

    enum WizardStep {
        case loading
        case notRegistered
        case registering
        case waitingRegistration
        case manualToken
        case notionToken
        case deviceFlow
        case success
        case error
    }

    func reset() {
        step = .loading
        registrationStatus = nil
        registerAppResponse = nil
        errorMessage = nil
    }
}

// MARK: - ConnectorWizardView

struct ConnectorWizardView: View {
    let provider: String
    let onDismiss: () -> Void

    @Environment(AppModel.self) private var appModel
    @State private var state = ConnectorWizardState()
    @State private var githubToken: String = ""
    @State private var slackToken: String = ""
    @State private var slackAppToken: String = ""
    @State private var slackAllowedChannels: String = ""
    @State private var slackAllowedUsers: String = ""
    @State private var slackRequireMention = true
    @State private var notionToken: String = ""
    @State private var isSavingGitHubToken = false
    @State private var isSavingSlackToken = false
    @State private var isSavingNotionToken = false
    @State private var isSavingOAuthApp = false

    private var displayName: String {
        switch provider {
        case "github": "GitHub"
        case "slack": "Slack"
        case "notion": "Notion"
        case "email", "gmail": "Gmail"
        case "calendar", "gcal": "Google Calendar"
        case "x": "X (Twitter)"
        default: provider.capitalized
        }
    }

    private var providerSystemImage: String {
        switch provider {
        case "github": "chevron.left.forwardslash.chevron.right"
        case "slack": "bubble.left.and.bubble.right"
        case "notion": "doc.text"
        case "email", "gmail": "envelope"
        case "calendar", "gcal": "calendar"
        case "x": "bubble.left.and.text.bubble.right"
        default: "plug"
        }
    }

    // PATCH-2026-05-07: polish-ConnectorWizardView GradientText title, tinted icon
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: NativeAgentSpacing.md) {
                Image(systemName: providerSystemImage)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(NativeAgentBrand.accentDeep)
                VStack(alignment: .leading, spacing: 2) {
                    GradientText(
                        text: "Connect \(displayName)",
                        colors: [.blue, .purple],
                        font: NativeAgentFont.title
                    )
                    Text(stepSubtitle)
                        .font(NativeAgentFont.body)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
            }
            .padding(NativeAgentSpacing.xl)

            Divider()

            // Step content
            ScrollView {
                stepContent
                    .padding(NativeAgentSpacing.xl)
            }
        }
        .frame(width: 520, height: 520)
        .task {
            state.provider = provider
            state.providerDisplayName = displayName
            if provider.lowercased() == "slack" {
                loadSlackIngressPolicy()
            }
            await loadRegistrationStatus()
        }
        .onDisappear {
            state.flowTask?.cancel()
            state.flowTask = nil
        }
    }

    // MARK: - Step subtitle

    private var stepSubtitle: String {
        switch state.step {
        case .loading: "Checking status…"
        case .notRegistered: "One-time app setup required."
        case .registering: "Setting up OAuth app…"
        case .waitingRegistration: "Waiting for GitHub approval…"
        case .manualToken:
            provider.lowercased() == "github"
                ? "Paste a GitHub Personal Access Token."
                : "Paste the Slack token from your app."
        case .notionToken: "Paste a Notion integration token."
        case .deviceFlow: "Sign in to \(displayName)."
        case .success: "Connected successfully."
        case .error:
            ConnectorWizardSetupRoute.resolve(provider: provider) == .unavailable
                ? "No verified setup path is available."
                : "Something went wrong."
        }
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch state.step {
        case .loading:
            HStack { Spacer(); ProgressView("Loading…"); Spacer() }

        case .notRegistered:
            notRegisteredView

        case .registering:
            HStack { Spacer(); ProgressView("Opening browser…"); Spacer() }

        case .waitingRegistration:
            waitingRegistrationView

        case .manualToken:
            if provider.lowercased() == "github" {
                githubTokenView
            } else {
                slackTokenView
            }
        case .notionToken:
            notionTokenView

        case .deviceFlow:
            deviceFlowView

        case .success:
            successView

        case .error:
            errorView
        }
    }

    // MARK: - Not registered

    private var notRegisteredView: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.lg) {
            NativePanel(title: "First time? Set up the OAuth app.", systemImage: "app.badge.checkmark") {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                    if provider == "github" {
                        Text("Click Register to open GitHub. Approve the app — it only takes 30 seconds.")
                            .font(NativeAgentFont.body)
                        Text("Your credentials are stored locally. No sharing required.")
                            .font(NativeAgentFont.label)
                            .foregroundStyle(.secondary)
                    } else if case .nativeOAuth(let connectorId) =
                                ConnectorWizardSetupRoute.resolve(provider: provider) {
                        Text("Create an OAuth app for \(displayName), then paste its client credentials here. They stay on this Mac.")
                            .font(NativeAgentFont.body)
                        TextField("OAuth client ID", text: $state.oauthClientId)
                            .textFieldStyle(.roundedBorder)
                        SecureField("Client secret (only if your app requires one)", text: $state.oauthClientSecret)
                            .textFieldStyle(.roundedBorder)
                        Text("Redirect URI: \(NativeOAuthFlow.connectorOAuthConfig(connectorId: connectorId)?.redirectURI ?? "http://127.0.0.1")")
                            .font(NativeAgentFont.label)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if let steps = state.registerAppResponse?.nextSteps {
                            ForEach(steps, id: \.self) { step in
                                Text(step)
                                    .font(NativeAgentFont.label)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                if provider == "github" {
                    Button("Register App") {
                        Task { await startRegistration() }
                    }
                    .buttonStyle(.borderedProminent)
                } else if let portalUrl = state.registerAppResponse?.portalUrl,
                          let url = URL(string: portalUrl) {
                    Button("Open Portal") {
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.borderedProminent)
                }
                if provider != "github" {
                    Button(isSavingOAuthApp ? "Saving…" : "Save & Continue") {
                        state.flowTask?.cancel()
                        state.flowTask = Task { await saveOAuthAppAndContinue() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        isSavingOAuthApp
                        || state.oauthClientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
    }

    // MARK: - Waiting registration

    private var waitingRegistrationView: some View {
        VStack(spacing: NativeAgentSpacing.lg) {
            ProgressView()
            Text("Waiting for GitHub approval…")
                .font(NativeAgentFont.body)
            Text("Approve the NativeAgent app in your browser, then return here.")
                .font(NativeAgentFont.label)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Check Status") {
                    Task { await checkRegistrationAndProceed() }
                }
                .buttonStyle(.borderedProminent)
                Button("Start Over") {
                    state.step = .notRegistered
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, NativeAgentSpacing.xl)
    }

    // MARK: - Device flow

    private var deviceFlowView: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.lg) {
            NativePanel(title: "Sign in to \(displayName)", systemImage: "person.badge.key") {
                Text("Tap Connect to start the authorization flow. A browser window will open.")
                    .font(NativeAgentFont.body)
            }
            HStack {
                Spacer()
                Button("Connect") {
                    state.flowTask?.cancel()
                    state.flowTask = Task { await startDeviceFlow() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var slackTokenView: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.lg) {
            NativePanel(title: "Slack Bot User OAuth Token", systemImage: "key.fill") {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                    Text("Paste the Bot User OAuth Token from Slack's OAuth & Permissions page. Leave blank if it is already saved.")
                        .font(NativeAgentFont.body)
                    SecureField("xoxb-...", text: $slackToken)
                        .textFieldStyle(.roundedBorder)
                    Text("Saved locally under NativeAgent's data root. The token is validated with Slack before the connector is marked connected.")
                        .font(NativeAgentFont.label)
                        .foregroundStyle(.secondary)
                }
            }
            NativePanel(title: "Slack Socket Mode App Token", systemImage: "dot.radiowaves.left.and.right") {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                    Text("Paste the app-level token from Slack Basic Information > App-Level Tokens.")
                        .font(NativeAgentFont.body)
                    SecureField("xapp-...", text: $slackAppToken)
                        .textFieldStyle(.roundedBorder)
                    Text("Required only for inbound Slack chat. Enable Socket Mode and grant the app token connections:write.")
                        .font(NativeAgentFont.label)
                        .foregroundStyle(.secondary)
                    Text("After changing Slack scopes or bot event subscriptions, reinstall the Slack app before testing inbound chat.")
                        .font(NativeAgentFont.label)
                        .foregroundStyle(.secondary)
                }
            }
            NativePanel(title: "Who Can Message Your Agent", systemImage: "person.badge.shield.checkmark") {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                    TextField("Allowed channel IDs, such as C0123", text: $slackAllowedChannels)
                        .textFieldStyle(.roundedBorder)
                    TextField("Allowed user IDs, such as U0123", text: $slackAllowedUsers)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Require an @mention in channels and group chats", isOn: $slackRequireMention)
                    Text("Add at least one channel or user. Inbound Slack chat stays safely off when both lists are empty; direct messages never require an @mention.")
                        .font(NativeAgentFont.label)
                        .foregroundStyle(.secondary)
                }
            }
            NativePanel(title: "Useful Slack Scopes", systemImage: "checklist") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("channels:read, groups:read, im:read, mpim:read")
                    Text("app_mentions:read plus channels:history, groups:history, im:history, mpim:history for inbound chat")
                    Text("chat:write for direct posting")
                    Text("search:read requires a user token for legacy Slack search")
                }
                .font(NativeAgentFont.label)
                .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Open Slack Apps") {
                    if let url = URL(string: "https://api.slack.com/apps") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                Button(isSavingSlackToken ? "Saving..." : "Save Slack Settings") {
                    state.flowTask?.cancel()
                    state.flowTask = Task { await saveSlackToken() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSavingSlackToken)
            }
        }
    }

    private var githubTokenView: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.lg) {
            NativePanel(title: "GitHub Personal Access Token", systemImage: "key.fill") {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                    Text("Paste a GitHub Personal Access Token. Fine-grained tokens should allow repository metadata reads for repo listing.")
                        .font(NativeAgentFont.body)
                    SecureField("ghp_... or github_pat_...", text: $githubToken)
                        .textFieldStyle(.roundedBorder)
                    Text("Saved in your Mac Keychain. The token is validated against GitHub /user before the connector is marked connected.")
                        .font(NativeAgentFont.label)
                        .foregroundStyle(.secondary)
                }
            }
            NativePanel(title: "Useful GitHub Permissions", systemImage: "checklist") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Repository metadata read for listing repositories")
                    Text("Issues read for listing repository issues")
                    Text("No write permission is needed for the current GitHub read tools")
                }
                .font(NativeAgentFont.label)
                .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Open GitHub Tokens") {
                    if let url = URL(string: "https://github.com/settings/tokens") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                Button(isSavingGitHubToken ? "Saving..." : "Save Token") {
                    state.flowTask?.cancel()
                    state.flowTask = Task { await saveGitHubToken() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isSavingGitHubToken
                    || githubToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
    }

    private var notionTokenView: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.lg) {
            NativePanel(title: "Notion Internal Integration Token", systemImage: "key.fill") {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                    Text("Create an internal integration, share the pages or databases it should access with that integration, then paste its token here.")
                        .font(NativeAgentFont.body)
                    SecureField("ntn_... or secret_...", text: $notionToken)
                        .textFieldStyle(.roundedBorder)
                    Text("NativeAgent validates the token against Notion before marking the connector connected. Unshared pages remain inaccessible.")
                        .font(NativeAgentFont.label)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Open Notion Integrations") {
                    NSWorkspace.shared.open(
                        URL(string: "https://www.notion.so/profile/integrations")!
                    )
                }
                .buttonStyle(.bordered)
                Button(isSavingNotionToken ? "Validating…" : "Connect") {
                    state.flowTask?.cancel()
                    state.flowTask = Task { await saveNotionToken() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isSavingNotionToken
                    || notionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
    }

    // MARK: - Success
    // PATCH-2026-05-07: polish-ConnectorWizardView gradient success icon + AuroraBackground hint

    private var successView: some View {
        VStack(spacing: NativeAgentSpacing.lg) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 96, height: 96)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
            }
            GradientText(text: "\(displayName) connected!", colors: [.green, .teal], font: NativeAgentFont.title)
            Text("Try asking: \u{201C}List my \(provider == "github" ? "repos" : "recent items").\u{201D}")
                .font(NativeAgentFont.body)
                .foregroundStyle(.secondary)
            Button("Done") { onDismiss() }
                .buttonStyle(.borderedProminent)
                .tint(.green)
        }
        .padding(.vertical, NativeAgentSpacing.xl)
    }

    // MARK: - Error

    private var errorView: some View {
        VStack(spacing: NativeAgentSpacing.lg) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.12))
                    .frame(width: 80, height: 80)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
            }
            Text(state.errorMessage ?? "An error occurred.")
                .font(NativeAgentFont.body)
                .multilineTextAlignment(.center)
            HStack {
                if ConnectorWizardSetupRoute.resolve(provider: provider) != .unavailable {
                    Button("Retry") {
                        Task { await loadRegistrationStatus() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Dismiss") { onDismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, NativeAgentSpacing.xl)
    }

    // MARK: - Logic

    private func loadRegistrationStatus() async {
        state.step = .loading
        switch ConnectorWizardSetupRoute.resolve(provider: provider) {
        case .manualToken:
            state.step = .manualToken
            return
        case .notionToken:
            state.step = .notionToken
            return
        case .unavailable:
            state.errorMessage = "\(displayName) does not have a verified in-app setup path. Configure it manually outside this wizard; NativeAgent will not mark it connected without validated credentials."
            state.step = .error
            return
        case .nativeOAuth(let connectorId):
            if let credentials = NativeOAuthFlow.connectorOAuthAppCredentials(
                connectorId: connectorId
            ) {
                state.oauthClientId = credentials.clientId
                state.oauthClientSecret = credentials.clientSecret ?? ""
            }
            break
        }
        do {
            let status = try await appModel.getConnectorRegistrationStatus(provider: provider)
            state.registrationStatus = status
            if status.registered && status.clientIdPresent {
                state.step = .deviceFlow
            } else {
                // Pre-fetch portal info
                await fetchRegisterAppInfo()
                state.step = .notRegistered
            }
        } catch {
            state.errorMessage = error.localizedDescription
            state.step = .error
        }
    }

    private func fetchRegisterAppInfo() async {
        state.registerAppResponse = try? await appModel.registerConnectorApp(provider: provider)
    }

    private func startRegistration() async {
        state.step = .registering
        guard let response = try? await appModel.registerConnectorApp(provider: provider) else {
            state.errorMessage = "Failed to get registration URL."
            state.step = .error
            return
        }
        state.registerAppResponse = response
        if let approvalUrl = response.approvalUrl, let url = URL(string: approvalUrl) {
            NSWorkspace.shared.open(url)
            state.step = .waitingRegistration
        } else if let portalUrl = response.portalUrl, let url = URL(string: portalUrl) {
            NSWorkspace.shared.open(url)
            state.step = .notRegistered
        }
    }

    private func checkRegistrationAndProceed() async {
        if let status = try? await appModel.getConnectorRegistrationStatus(provider: provider),
           status.registered && status.clientIdPresent {
            state.registrationStatus = status
            state.step = .deviceFlow
        } else {
            state.step = .waitingRegistration
        }
    }

    private func startDeviceFlow() async {
        switch ConnectorWizardSetupRoute.resolve(provider: provider) {
        case .nativeOAuth(let connectorId):
            let result = await NativeOAuthFlow.startConnectorOAuthFlow(
                connectorId: connectorId)
            guard !Task.isCancelled else { return }
            if result.ok {
                state.step = .success
                await appModel.refreshForSidebarItem(.connectors)
            } else {
                state.errorMessage = result.error ?? "Sign-in failed."
                state.step = .error
            }
        case .manualToken:
            state.step = .manualToken
        case .notionToken:
            state.step = .notionToken
        case .unavailable:
            state.errorMessage = "\(displayName) does not have a verified in-app setup path. NativeAgent did not change its connection state."
            state.step = .error
        }
    }

    private func saveOAuthAppAndContinue() async {
        guard case .nativeOAuth(let connectorId) =
                ConnectorWizardSetupRoute.resolve(provider: provider) else {
            state.errorMessage = "This connector does not use OAuth app credentials."
            state.step = .error
            return
        }
        isSavingOAuthApp = true
        defer { isSavingOAuthApp = false }
        let result = await NativeOAuthFlow.saveConnectorOAuthApp(
            connectorId: connectorId,
            clientId: state.oauthClientId,
            clientSecret: state.oauthClientSecret
        )
        guard !Task.isCancelled else { return }
        if result.ok {
            state.step = .deviceFlow
        } else {
            state.errorMessage = result.error ?? "Could not save OAuth app configuration."
            state.step = .error
        }
    }

    private func saveNotionToken() async {
        isSavingNotionToken = true
        defer { isSavingNotionToken = false }
        let result = await NativeOAuthFlow.saveNotionToken(notionToken)
        guard !Task.isCancelled else { return }
        if result.ok {
            notionToken = ""
            state.step = .success
            await appModel.refreshForSidebarItem(.connectors)
        } else {
            state.errorMessage = result.error ?? "Notion token validation failed."
            state.step = .error
        }
    }

    private func saveSlackToken() async {
        isSavingSlackToken = true
        defer { isSavingSlackToken = false }

        let result = await NativeOAuthFlow.saveSlackToken(
            slackToken,
            appToken: slackAppToken,
            allowedChannelIds: parseSlackIDs(slackAllowedChannels),
            allowedUserIds: parseSlackIDs(slackAllowedUsers),
            requireMention: slackRequireMention
        )
        guard !Task.isCancelled else { return }
        if result.ok {
            slackToken = ""
            slackAppToken = ""
            state.step = .success
            _ = await BackgroundLoopsManager.shared.restartLoop(id: "slack_socket_mode")
            await appModel.refreshForSidebarItem(.connectors)
        } else {
            state.errorMessage = result.error ?? "Slack token save failed."
            state.step = .error
        }
    }

    private func loadSlackIngressPolicy() {
        let policy = SlackSocketModeConfig.loadIngressPolicy()
        slackAllowedChannels = policy.allowedChannelIds.sorted().joined(separator: ", ")
        slackAllowedUsers = policy.allowedUserIds.sorted().joined(separator: ", ")
        slackRequireMention = policy.requireMention
    }

    private func parseSlackIDs(_ raw: String) -> Set<String> {
        Set(raw.split { $0 == "," || $0 == ";" || $0.isWhitespace }
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }

    private func saveGitHubToken() async {
        isSavingGitHubToken = true
        defer { isSavingGitHubToken = false }

        let result = await NativeOAuthFlow.saveGitHubToken(githubToken)
        guard !Task.isCancelled else { return }
        if result.ok {
            githubToken = ""
            state.step = .success
            await appModel.refreshForSidebarItem(.connectors)
        } else {
            state.errorMessage = result.error ?? "GitHub token save failed."
            state.step = .error
        }
    }

}
