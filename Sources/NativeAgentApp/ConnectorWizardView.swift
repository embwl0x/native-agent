import Connectors
import ProviderRouting
// PATCH-2026-05-07: oauth-registration-2 Inline OAuth wizard — ConnectorWizardView
import SwiftUI
import AppKit
import TrustCenter
import ChatOrchestration
import GitHubConnector
import SlackBot

/// The GitHub token form must describe the registered capability set, never a
/// hand-maintained list that can call a write tool "read-only" after a catalog
/// change.
enum GitHubPermissionPresentation {
    static func lines(actions: [ConnectorActionDescriptor] = connectorActionDescriptors()) -> [String] {
        let github = actions.filter { $0.connectorId == "github" }
        let hasVisibilityWrite = github.contains {
            $0.id == "github.set_repo_visibility" && $0.risk == "external_write" && $0.requiresApproval
        }
        var result = [
            "Metadata: read, so I can list your repositories",
            "Issues: read, so I can list their issues",
        ]
        if hasVisibilityWrite {
            result.append("Administration: write only if you want me to make a repository public or private. Changes follow your Trust settings. Leave it off otherwise.")
        }
        return result
    }
}

// MARK: - Models

typealias ConnectorRegistrationStatus = Connectors.ConnectorRegistrationStatus
typealias ConnectorRegisterAppResponse = Connectors.ConnectorRegisterAppResponse
typealias ConnectorWizardSetupRoute = Connectors.ConnectorWizardSetupRoute


/// The Slack setup page is an external browser handoff, not a completed
/// connector setup. Keep the request outcome visible so a missing browser
/// handler cannot look like a successful navigation.
enum SlackSettingsPortal {
    enum OpenOutcome: Equatable {
        case requested
        case unavailable

        var message: String {
            switch self {
            case .requested:
                return "Asked your browser to open Slack apps."
            case .unavailable:
                return "Couldn't open your browser. Go to api.slack.com/apps to continue."
            }
        }
    }

    static let url = URL(string: "https://api.slack.com/apps")!

    static func open(using opener: (URL) -> Bool) -> OpenOutcome {
        opener(url) ? .requested : .unavailable
    }
}

// MARK: - Wizard State

enum GoogleOAuthSetupGuidance {
    static func connectorId(provider: String) -> String? {
        guard case .nativeOAuth(let id) = ConnectorWizardSetupRoute.resolve(provider: provider),
              id == "gmail" || id == "calendar" else { return nil }
        return id
    }

    static func clientIDIssue(_ value: String) -> String? {
        let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.count <= 512, id.hasSuffix(".apps.googleusercontent.com"),
              id.count > ".apps.googleusercontent.com".count,
              !id.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
              }) else {
            return "That isn't a Google Client ID. Copy the one ending in .apps.googleusercontent.com from Google Auth Platform › Clients."
        }
        return nil
    }
}

@Observable
@MainActor
final class ConnectorWizardState {
    var step: WizardStep = .loading
    var registerAppResponse: ConnectorRegisterAppResponse?
    /// The one error line: what happened and what to do. Never a service's
    /// own text, which goes to the log only.
    var errorMessage: String?
    var oauthClientId: String = ""
    var oauthClientSecret: String = ""
    // Tracks the running sign-in or save so a sheet dismissed mid-flow, or a
    // step left with Back, cannot mutate the wizard afterward.
    var flowTask: Task<Void, Never>?

    /// One page each. Which pages a connector walks is `ConnectorWizardView.trail`.
    enum WizardStep {
        case loading
        case googleIntro
        case googleCreateApp
        case appCredentials
        case signIn
        case githubToken
        case slackTokens
        case slackAccess
        case notionToken
        case success
        case error
    }
}

// MARK: - ConnectorWizardView

/// Connecting an account, one page at a time: a title and where you are, one
/// page of cards, and Back / Cancel / the next step along the bottom. A
/// resizable sheet in the shell's card style (the alive kit), not a stack of
/// panels in a fixed box.
struct ConnectorWizardView: View {
    let provider: String
    /// Opened from a chat card that already said "Connect with GitHub": start
    /// the sign-in straight away rather than asking twice.
    var startsSignIn = false
    let onDismiss: () -> Void

    @Environment(AppModel.self) private var appModel
    @State private var state = ConnectorWizardState()
    @State private var githubToken: String = ""
    @State private var githubCode: GitHubOAuthDeviceFlow.DeviceCode?
    @State private var githubLogin: String?
    @State private var didCopyGitHubCode = false
    @State private var slackToken: String = ""
    @State private var slackAppToken: String = ""
    @State private var slackAllowedChannels: String = ""
    @State private var slackAllowedUsers: String = ""
    @State private var slackRequireMention = true
    @State private var slackSettingsOpenOutcome: SlackSettingsPortal.OpenOutcome?
    @State private var notionToken: String = ""
    @State private var isSaving = false
    @State private var isConnecting = false
    @State private var didCopyRedirect = false
    @State private var didSaveOAuthApp = false

    private var route: ConnectorWizardSetupRoute { ConnectorWizardSetupRoute.resolve(provider: provider) }
    private var connectorID: String { InlineInteractionRegistry.canonicalConnectorID(provider) }
    private var isGitHub: Bool { connectorID == "github" }

    private var googleConnectorId: String? {
        GoogleOAuthSetupGuidance.connectorId(provider: provider)
    }

    private var displayName: String {
        switch connectorID {
        case "github": "GitHub"
        case "slack": "Slack"
        case "notion": "Notion"
        case "gmail": "Gmail"
        case "gcal": "Google Calendar"
        case "x": "X"
        default: provider.capitalized
        }
    }

    private var slackAllowlistConfigured: Bool {
        !parseSlackIDs(slackAllowedChannels).isEmpty || !parseSlackIDs(slackAllowedUsers).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                stepContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(NativeAgentSpacing.xl)
                    .id(state.step)
                    .transition(NativeAgentMotion.dissolve)
            }
            Divider()
            footer
        }
        // Resizable: the sheet opens at the ideal size and the person can
        // drag it larger for the long Google steps.
        .frame(minWidth: 480, idealWidth: 560, minHeight: 440, idealHeight: 600)
        .animation(NativeAgentMotion.standard, value: state.step)
        .animation(NativeAgentMotion.standard, value: state.errorMessage)
        .task {
            if connectorID == "slack" {
                loadSlackIngressPolicy()
            }
            await loadRegistrationStatus()
        }
        .onDisappear {
            state.flowTask?.cancel()
            state.flowTask = nil
        }
    }

    // MARK: - Frame

    private var header: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
            Text("Connect \(displayName)")
                .font(ShellType.title)
                .foregroundStyle(NativeAgentShell.text)
                .accessibilityAddTraits(.isHeader)
            Text(stepLine)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, NativeAgentSpacing.xl)
        .padding(.vertical, NativeAgentSpacing.lg)
    }

    /// The pages this connector walks, in order, for "Step 2 of 4".
    private var trail: [ConnectorWizardState.WizardStep] {
        switch route {
        case .nativeOAuth:
            googleConnectorId != nil
                ? [.googleIntro, .googleCreateApp, .appCredentials, .signIn]
                : [.appCredentials, .signIn]
        case .manualToken where !isGitHub:
            [.slackTokens, .slackAccess]
        default:
            []
        }
    }

    private var stepLine: String {
        if let index = trail.firstIndex(of: state.step), trail.count > 1 {
            return "Step \(index + 1) of \(trail.count) · \(stepTitle)"
        }
        return stepTitle
    }

    private var stepTitle: String {
        switch state.step {
        case .loading: "Checking what's already set up…"
        case .googleIntro: "Before you start"
        case .googleCreateApp: "Make a Google app"
        case .appCredentials: "Add your app's details"
        case .signIn: "Sign in"
        case .githubToken: "Use a token instead"
        case .slackTokens: "Add your Slack tokens"
        case .slackAccess: "Choose who can message me"
        case .notionToken: "Add your Notion token"
        case .success: "All set"
        case .error: "Couldn't set this up"
        }
    }

    private var backStep: ConnectorWizardState.WizardStep? {
        switch state.step {
        case .googleCreateApp: .googleIntro
        case .appCredentials: googleConnectorId != nil ? .googleCreateApp : nil
        case .signIn: isGitHub ? nil : .appCredentials
        case .githubToken: .signIn
        case .slackAccess: .slackTokens
        default: nil
        }
    }

    private struct PrimaryAction {
        let title: String
        var enabled = true
        let run: () -> Void
    }

    private var primary: PrimaryAction? {
        switch state.step {
        case .loading:
            return nil
        case .googleIntro:
            return PrimaryAction(title: "Set up my own app") { go(.googleCreateApp) }
        case .googleCreateApp:
            return PrimaryAction(title: "Next") { go(.appCredentials) }
        case .appCredentials:
            return PrimaryAction(
                title: isSaving ? "Saving…" : "Save and continue",
                enabled: !isSaving && !trimmed(state.oauthClientId).isEmpty
            ) { saveAppCredentials() }
        case .signIn where isGitHub:
            if let code = githubCode {
                return PrimaryAction(title: "Open GitHub") { NSWorkspace.shared.open(code.verificationURI) }
            }
            return PrimaryAction(title: "Connect with GitHub") { startGitHubSignIn() }
        case .signIn:
            return PrimaryAction(title: "Connect") { startOAuthSignIn() }
        case .githubToken:
            return PrimaryAction(
                title: isSaving ? "Checking…" : "Save token",
                enabled: !isSaving && !trimmed(githubToken).isEmpty
            ) { run { await saveGitHubToken() } }
        case .slackTokens:
            return PrimaryAction(title: "Next") { go(.slackAccess) }
        case .slackAccess:
            return PrimaryAction(
                title: isSaving ? "Checking…" : "Save",
                enabled: !isSaving && slackAllowlistConfigured
            ) { run { await saveSlackToken() } }
        case .notionToken:
            return PrimaryAction(
                title: isSaving ? "Checking…" : "Connect",
                enabled: !isSaving && !trimmed(notionToken).isEmpty
            ) { run { await saveNotionToken() } }
        case .success:
            return PrimaryAction(title: "Done") { onDismiss() }
        case .error:
            guard route != .unavailable else { return nil }
            return PrimaryAction(title: "Try again") { Task { await loadRegistrationStatus() } }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
            if let message = state.errorMessage, state.step != .error {
                Text(message)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(NativeAgentMotion.fade)
            }
            HStack(spacing: NativeAgentSpacing.sm) {
                if let back = backStep {
                    Button("Back") { go(back) }
                        .disabled(isSaving)
                }
                Spacer(minLength: 0)
                if state.step != .success {
                    Button(state.step == .error ? "Close" : "Cancel") { onDismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                if let primary {
                    Button(primary.title, action: primary.run)
                        .buttonStyle(.borderedProminent)
                        .hazeTinted(.button)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!primary.enabled)
                }
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, NativeAgentSpacing.xl)
        .padding(.vertical, NativeAgentSpacing.lg)
    }

    // MARK: - Pieces

    /// An eyebrow over one card: the alive kit's card, on the sheet.
    private func card<Content: View>(_ title: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
            if let title { AliveEyebrow(title) }
            VStack(alignment: .leading, spacing: NativeAgentSpacing.md) { content() }
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AliveMetrics.rowInsetH)
                .padding(.vertical, AliveMetrics.rowInsetV)
                .aliveCard()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(ShellType.label)
            .foregroundStyle(NativeAgentShell.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func numbered(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NativeAgentSpacing.sm) {
            Text("\(number).")
                .monospacedDigit()
                .foregroundStyle(NativeAgentShell.secondary)
                .frame(width: 18, alignment: .leading)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func code(_ text: String) -> some View {
        Text(text)
            .font(ShellType.code)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func copyButton(_ value: String) -> some View {
        Button(didCopyRedirect ? "Copied" : "Copy") {
            NSPasteboard.general.clearContents()
            didCopyRedirect = NSPasteboard.general.setString(value, forType: .string)
        }
        .controlSize(.small)
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch state.step {
        case .loading:
            AdvancedWaitingLine("One moment…")
        case .googleIntro:
            if let connectorId = googleConnectorId { googleIntroView(connectorId: connectorId) }
        case .googleCreateApp:
            if let connectorId = googleConnectorId { googleCreateAppView(connectorId: connectorId) }
        case .appCredentials:
            appCredentialsView
        case .signIn:
            if isGitHub { githubSignInView } else { oauthSignInView }
        case .githubToken:
            githubTokenView
        case .slackTokens:
            slackTokensView
        case .slackAccess:
            slackAccessView
        case .notionToken:
            notionTokenView
        case .success:
            successView
        case .error:
            Text(state.errorMessage ?? "Something went wrong. Try again.")
                .font(ShellType.body)
                .foregroundStyle(NativeAgentShell.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Google

    private func googleIntroView(connectorId: String) -> some View {
        let calendar = connectorId == "calendar"
        return VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
            card(calendar ? "Only need your calendars?" : "Only need your mail?") {
                Text(calendar
                     ? "Add your Google account in System Settings › Internet Accounts and turn on Calendars. Then give me Calendar access in Mac integration. No Google app needed."
                     : "Add your Google account in System Settings › Internet Accounts and turn on Mail. Then give me Mail access in Mac integration. That reads Apple Mail on this Mac, not the Gmail API.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Mac integration") {
                    onDismiss()
                    _ = NativeAgentAppCoordinator.shared.request(.sidebar(.macIntegration))
                }
            }
            card("Want direct access to \(displayName)?") {
                Text(calendar
                     ? "You'll make a small Google app of your own. NativeAgent doesn't come with one. I ask to read your calendars and manage events, and Google handles the sign-in in your browser."
                     : "You'll make a small Google app of your own. NativeAgent doesn't come with one. I only ask for read access, and Google handles the sign-in in your browser.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func googleCreateAppView(connectorId: String) -> some View {
        let config = NativeOAuthFlow.connectorOAuthConfig(connectorId: connectorId)
        return VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
            card("In Google Cloud") {
                Link("Open Google Cloud Console", destination: URL(string: "https://console.cloud.google.com/apis/library")!)
                numbered(1, "Pick a project, or make a new one.")
                numbered(2, "In APIs & Services › Library, find the \(connectorId == "gmail" ? "Gmail API" : "Google Calendar API") and turn it on.")
                numbered(3, "In Google Auth Platform › Branding, give the app a name and your email. Under Audience choose External, leave it in Testing, and add your own Google address as a test user.")
                numbered(4, connectorId == "calendar"
                         ? "In Data Access, add these scopes to read calendars and manage events:"
                         : "In Data Access, add this read-only scope:")
                code(config?.scopes ?? "")
                numbered(5, "In Clients › Create client, choose Desktop app. Copy the Client ID, and the client secret if Google shows one. Not an API key or a service account.")
            }
            if let redirect = config?.redirectURI {
                card("Redirect address") {
                    Text("Desktop apps don't ask for one. If Google does, this is the exact address I use:")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .firstTextBaseline) {
                        code(redirect)
                        Spacer(minLength: 0)
                        copyButton(redirect)
                    }
                }
            }
            VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                note("Apps left in Testing ask you to sign in again after seven days. A work or school account may need an administrator's OK.")
                Link("Google's guide for desktop apps", destination: URL(string: "https://developers.google.com/identity/protocols/oauth2/native-app")!)
                    .font(ShellType.label)
            }
        }
    }

    // MARK: - OAuth app details

    private var appCredentialsView: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
            card(googleConnectorId != nil ? "Your Google app" : "Your \(displayName) app") {
                if googleConnectorId == nil {
                    Text("Make an app in \(displayName)'s developer portal, then paste its details here.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextField(googleConnectorId != nil ? "Client ID" : "OAuth client ID", text: $state.oauthClientId)
                    .textFieldStyle(.roundedBorder)
                SecureField("Client secret, if you were given one", text: $state.oauthClientSecret)
                    .textFieldStyle(.roundedBorder)
                note(googleConnectorId != nil
                     ? "They stay on this Mac. I check the format now; Google checks the app when you sign in."
                     : "They stay on this Mac.")
            }
            if googleConnectorId == nil, case .nativeOAuth(let connectorId) = route {
                card("Redirect address") {
                    let redirect = NativeOAuthFlow.connectorOAuthConfig(connectorId: connectorId)?.redirectURI ?? "http://127.0.0.1"
                    HStack(alignment: .firstTextBaseline) {
                        code(redirect)
                        Spacer(minLength: 0)
                        copyButton(redirect)
                    }
                    if let steps = state.registerAppResponse?.nextSteps, !steps.isEmpty {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            numbered(index + 1, step)
                        }
                    }
                }
                if let portalUrl = state.registerAppResponse?.portalUrl, let url = URL(string: portalUrl) {
                    Link("Open \(displayName)'s developer portal", destination: url)
                        .font(ShellType.label)
                }
            }
        }
    }

    // MARK: - Sign in

    private var oauthSignInView: some View {
        card("Sign in to \(displayName)") {
            if googleConnectorId != nil {
                Text(didSaveOAuthApp
                     ? "Your app's details are saved. Google checks them when you sign in."
                     : "Your Google app is already set up. To change it, go Back.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Connect opens your browser. Approve there, then come back here.")
                .fixedSize(horizontal: false, vertical: true)
            if isConnecting {
                AdvancedWaitingLine("Waiting for you in the browser…")
            }
        }
    }

    private var githubSignInView: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
            if let code = githubCode {
                card("Enter this code on GitHub") {
                    HStack(spacing: NativeAgentSpacing.md) {
                        Text(code.userCode)
                            .font(.system(size: ShellType.displaySize, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                            // macOS 27: selectable text + a custom accessibility label loops SwiftUI AX and crashes the app.
                        Spacer(minLength: 0)
                        Button(didCopyGitHubCode ? "Copied" : "Copy") {
                            copyGitHubCode(code.userCode)
                        }
                    }
                    AdvancedWaitingLine("Waiting for you to approve on GitHub. The code is already copied.")
                }
            } else {
                card("Sign in with your GitHub account") {
                    Text("GitHub opens in your browser and shows what I'm asking for: your repositories, pull requests, issues, organizations and notifications. Approve it and you're done. The sign-in is kept in your Mac's Keychain.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // A sign-in may already be asking GitHub for a code; `go` stops
            // it, or the code lands on the clipboard and the browser opens
            // after the person chose to paste a token.
            Button("Use a token instead") { go(.githubToken) }
                .buttonStyle(.link)
                .font(ShellType.label)
        }
    }

    private func copyGitHubCode(_ code: String) {
        NSPasteboard.general.clearContents()
        didCopyGitHubCode = NSPasteboard.general.setString(code, forType: .string)
    }

    // MARK: - Tokens

    private var githubTokenView: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
            card("Personal access token") {
                SecureField("ghp_… or github_pat_…", text: $githubToken)
                    .textFieldStyle(.roundedBorder)
                note("It's kept in your Mac's Keychain, and I check it with GitHub before using it.")
                Link("Make a token on GitHub", destination: URL(string: "https://github.com/settings/tokens")!)
            }
            card("What the token needs") {
                ForEach(GitHubPermissionPresentation.lines(), id: \.self) { line in
                    Text(line).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var slackTokensView: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
            card("Bot token") {
                SecureField("xoxb-…", text: $slackToken)
                    .textFieldStyle(.roundedBorder)
                note("From your Slack app's OAuth & Permissions page. Leave it empty if it's already saved. It stays on this Mac, and I check it with Slack before saving.")
            }
            card("App token, to chat with me in Slack") {
                SecureField("xapp-…", text: $slackAppToken)
                    .textFieldStyle(.roundedBorder)
                note("From Basic Information › App-Level Tokens, with connections:write. Turn on Socket Mode too. Only needed if you want to message me from Slack.")
            }
            card("Scopes to add") {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
                    Text("channels:read, groups:read, im:read, mpim:read")
                    Text("app_mentions:read, channels:history, groups:history, im:history, mpim:history to chat with me")
                    Text("chat:write to post")
                    Text("search:read needs a user token")
                }
                .font(ShellType.code)
                .foregroundStyle(NativeAgentShell.secondary)
                .textSelection(.enabled)
                note("Changed scopes or event subscriptions? Reinstall the Slack app before you try chatting.")
            }
            VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                Button("Open Slack apps") {
                    slackSettingsOpenOutcome = SlackSettingsPortal.open {
                        NSWorkspace.shared.open($0)
                    }
                }
                if let slackSettingsOpenOutcome {
                    Text(slackSettingsOpenOutcome.message)
                        .font(ShellType.label)
                        .foregroundStyle(slackSettingsOpenOutcome == .requested
                                         ? NativeAgentShell.secondary : NativeAgentShell.trouble)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var slackAccessView: some View {
        card("Who can message me") {
            TextField("Channel IDs, like C0123", text: $slackAllowedChannels)
                .textFieldStyle(.roundedBorder)
            TextField("User IDs, like U0123", text: $slackAllowedUsers)
                .textFieldStyle(.roundedBorder)
            Toggle("In channels and groups, only answer when @mentioned", isOn: $slackRequireMention)
            note("Add at least one channel or user. With both empty, I stay out of Slack chats. Direct messages never need an @mention.")
        }
    }

    private var notionTokenView: some View {
        card("Integration token") {
            Text("Make an internal integration in Notion, share the pages or databases I should see with it, then paste its token here.")
                .fixedSize(horizontal: false, vertical: true)
            SecureField("ntn_… or secret_…", text: $notionToken)
                .textFieldStyle(.roundedBorder)
            note("I check it with Notion first. Pages you don't share stay private.")
            Link("Open Notion integrations", destination: URL(string: "https://www.notion.so/profile/integrations")!)
        }
    }

    // MARK: - Success

    private var successView: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
            HStack(spacing: NativeAgentSpacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .font(ShellType.title)
                    .foregroundStyle(NativeAgentShell.calm)
                    .accessibilityHidden(true)
                Text("\(displayName) is connected.")
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
            }
            if let githubLogin {
                note("Signed in as @\(githubLogin).")
            }
            note("Try asking me: \u{201C}List my \(isGitHub ? "repos" : "recent items").\u{201D}")
        }
    }

    // MARK: - Logic

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Moving between pages stops whatever the last page started: a GitHub
    /// code request, a browser sign-in.
    private func go(_ step: ConnectorWizardState.WizardStep) {
        state.flowTask?.cancel()
        state.flowTask = nil
        githubCode = nil
        isConnecting = false
        state.errorMessage = nil
        state.step = step
    }

    private func run(_ work: @escaping @MainActor () async -> Void) {
        state.flowTask?.cancel()
        state.errorMessage = nil
        state.flowTask = Task { await work() }
    }

    /// One line: what happened, and what to do. The service's own text can
    /// echo a token, so it goes to the log only — through the same reason
    /// classes the inline chat card uses. A browser sign-in is never
    /// classified: "rejected the token" would misdescribe someone who simply
    /// didn't finish.
    private func failure(
        _ raw: String?, typed: [String] = [], fallback: String, classify: Bool = true
    ) -> String {
        let reason = InlineConnectorSetup.failureReason(
            raw ?? "", service: displayName, typed: typed, otherwise: fallback)
        guard classify else { return fallback }
        if reason.hasPrefix("Couldn't reach") {
            return "\(reason) Check your internet connection, then try again."
        }
        if reason.hasSuffix("rejected the token.") {
            return "\(reason) Check it's pasted in full, then try again."
        }
        if reason.contains("missing a permission") {
            return "\(reason) Add it in \(displayName), then try again."
        }
        if reason.contains("needs a valid allowed") {
            return "\(reason) Check the IDs, then try again."
        }
        return reason
    }

    private func loadRegistrationStatus() async {
        state.step = .loading
        state.errorMessage = nil
        switch route {
        case .manualToken where isGitHub:
            // Sign-in first; the token paste stays one tap away.
            state.step = .signIn
            if startsSignIn && githubCode == nil { startGitHubSignIn() }
        case .manualToken:
            state.step = .slackTokens
        case .notionToken:
            state.step = .notionToken
        case .unavailable:
            state.errorMessage = "\(displayName) can't be set up from here yet. Nothing was changed."
            state.step = .error
        case .nativeOAuth(let connectorId):
            if let credentials = NativeOAuthFlow.connectorOAuthAppCredentials(connectorId: connectorId) {
                state.oauthClientId = credentials.clientId
                state.oauthClientSecret = credentials.clientSecret ?? ""
            }
            do {
                let status = try await appModel.getConnectorRegistrationStatus(provider: provider)
                if status.registered && status.clientIdPresent {
                    state.step = .signIn
                } else {
                    // The portal link and its steps, for the details page.
                    state.registerAppResponse = try? await appModel.registerConnectorApp(provider: provider)
                    state.step = googleConnectorId != nil ? .googleIntro : .appCredentials
                }
            } catch {
                state.errorMessage = failure(
                    error.localizedDescription,
                    fallback: "Couldn't read what's already set up for \(displayName). Try again.",
                    classify: false)
                state.step = .error
            }
        }
    }

    private func startGitHubSignIn() {
        run {
            let code: GitHubOAuthDeviceFlow.DeviceCode
            do {
                code = try await GitHubOAuthDeviceFlow.requestDeviceCode()
            } catch {
                guard !Task.isCancelled else { return }
                state.errorMessage = failure(
                    error.localizedDescription,
                    fallback: "GitHub didn't start the sign-in. Try again, or use a token instead.",
                    classify: false)
                return
            }
            guard !Task.isCancelled else { return }
            githubCode = code
            copyGitHubCode(code.userCode)
            NSWorkspace.shared.open(code.verificationURI)
            let outcome = await NativeOAuthFlow.completeGitHubDeviceFlow(code, credentialStore: AppGitHubOAuthCredentials())
            guard !Task.isCancelled else { return }
            githubCode = nil
            if outcome.result.ok {
                githubLogin = outcome.login
                state.step = .success
                await appModel.refreshForSidebarItem(.connectors)
            } else {
                state.errorMessage = failure(
                    outcome.result.error,
                    fallback: "GitHub sign-in didn't finish. Try again, or use a token instead.",
                    classify: false)
            }
        }
    }

    private func startOAuthSignIn() {
        guard case .nativeOAuth(let connectorId) = route else { return }
        isConnecting = true
        run {
            let result = await NativeOAuthFlow.startConnectorOAuthFlow(
                platform: NativeOAuthPlatform.self,
                connectorId: connectorId)
            guard !Task.isCancelled else { return }
            isConnecting = false
            if result.ok {
                state.step = .success
                await appModel.refreshForSidebarItem(.connectors)
            } else {
                state.errorMessage = failure(
                    result.error,
                    fallback: "Sign-in didn't finish. Press Connect to try again, or go Back to check your app's details.",
                    classify: false)
            }
        }
    }

    private func saveAppCredentials() {
        if googleConnectorId != nil,
           let issue = GoogleOAuthSetupGuidance.clientIDIssue(state.oauthClientId) {
            state.errorMessage = issue
            return
        }
        run { await saveOAuthAppAndContinue() }
    }

    private func saveOAuthAppAndContinue() async {
        guard case .nativeOAuth(let connectorId) = route else { return }
        isSaving = true
        defer { isSaving = false }
        let result = await NativeOAuthFlow.saveConnectorOAuthApp(
            connectorId: connectorId,
            clientId: state.oauthClientId,
            clientSecret: state.oauthClientSecret
        )
        guard !Task.isCancelled else { return }
        if result.ok {
            didSaveOAuthApp = true
            state.step = .signIn
        } else {
            state.errorMessage = failure(
                result.error,
                typed: [state.oauthClientSecret],
                fallback: "Couldn't save your app's details. Check the client ID and secret, then try again.",
                classify: false)
        }
    }

    private func saveNotionToken() async {
        isSaving = true
        defer { isSaving = false }
        let result = await NativeOAuthFlow.saveNotionToken(notionToken)
        guard !Task.isCancelled else { return }
        if result.ok {
            notionToken = ""
            state.step = .success
            await appModel.refreshForSidebarItem(.connectors)
        } else {
            state.errorMessage = failure(
                result.error, typed: [notionToken],
                fallback: "Couldn't connect Notion. Check the token, then try again.")
        }
    }

    private func saveSlackToken() async {
        isSaving = true
        defer { isSaving = false }

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
            state.errorMessage = failure(
                result.error, typed: [slackToken, slackAppToken],
                fallback: "Couldn't save the Slack settings. Go Back to check the tokens, then try again.")
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
        isSaving = true
        defer { isSaving = false }

        let result = await NativeOAuthFlow.saveGitHubToken(githubToken, credentialStore: AppGitHubOAuthCredentials())
        guard !Task.isCancelled else { return }
        if result.ok {
            githubToken = ""
            state.step = .success
            await appModel.refreshForSidebarItem(.connectors)
        } else {
            state.errorMessage = failure(
                result.error, typed: [githubToken],
                fallback: "Couldn't save the GitHub token. Try again.")
        }
    }

}
