import EngineRuntime
import Connectors
import ProviderRouting
import SwiftUI
import AppKit
import TrustCenter
import ChatToolRuntime
import SlackBot

// Blueprint: | `ConnectorWizardView.swift` | `ConnectorWizardView` and state: existing connector setup routes, cancellable sign-in/save steps and truthful external-browser handoff outcomes |

// MARK: - Models

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

@Observable
@MainActor
final class ConnectorWizardState {
    var step: WizardStep = .loading
    /// The one error line: what happened and what to do. Never a service's
    /// own text, which goes to the log only.
    var errorMessage: String?
    // Tracks the running sign-in or save so a sheet dismissed mid-flow, or a
    // step left with Back, cannot mutate the wizard afterward.
    var flowTask: Task<Void, Never>?

    /// One page each. Which pages a connector walks is `ConnectorWizardView.trail`.
    enum WizardStep {
        case loading
        case slackTokens
        case slackAccess
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
    let onDismiss: () -> Void

    @Environment(AppModel.self) private var appModel
    @State private var state = ConnectorWizardState()
    // Tokens and OAuth secrets deliberately stay view-local and die with the wizard.
    // The saved policy, or why it could not be read; saving waits until it reads.
    private var slackPolicyRead: Result<SlackIngressPolicy, Error>? { appModel.engine.connectors.slackPolicy }
    private var slackPolicy: SlackIngressPolicy? { try? slackPolicyRead?.get() }
    @State private var slackToken: String = ""
    @State private var slackAppToken: String = ""
    @State private var slackSettingsOpenOutcome: SlackSettingsPortal.OpenOutcome?
    @State private var isSaving = false

    private var slackAllowedChannels: String {
        get { appModel.editDraft("connector:\(connectorID):slackAllowedChannels", seed: (slackPolicy?.allowedChannelIds.sorted() ?? []).joined(separator: ", ")) }
        nonmutating set { appModel.setEditDraft(newValue, for: "connector:\(connectorID):slackAllowedChannels") }
    }
    private var slackAllowedUsers: String {
        get { appModel.editDraft("connector:\(connectorID):slackAllowedUsers", seed: (slackPolicy?.allowedUserIds.sorted() ?? []).joined(separator: ", ")) }
        nonmutating set { appModel.setEditDraft(newValue, for: "connector:\(connectorID):slackAllowedUsers") }
    }
    private var slackRequireMention: Bool {
        get { appModel.editDraft("connector:\(connectorID):slackRequireMention", seed: slackPolicy?.requireMention ?? true) }
        nonmutating set { appModel.setEditDraft(newValue, for: "connector:\(connectorID):slackRequireMention") }
    }

    private func clearDraft() {
        for field in ["slackAllowedChannels", "slackAllowedUsers", "slackRequireMention"] {
            appModel.clearEditDraft("connector:\(connectorID):" + field)
        }
    }

    private var route: ConnectorWizardSetupRoute { ConnectorWizardSetupRoute.resolve(provider: provider) }
    private var connectorID: String { InlineInteractionRegistry.canonicalConnectorID(provider) }

    private var displayName: String {
        switch connectorID {
        case "slack": "Slack"
        default: provider.capitalized
        }
    }

    private var slackAllowlistConfigured: Bool {
        !SlackSocketModeConfig.parseIDs(slackAllowedChannels).isEmpty || !SlackSocketModeConfig.parseIDs(slackAllowedUsers).isEmpty
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
        // drag it larger.
        .frame(minWidth: 480, idealWidth: 560, minHeight: 440, idealHeight: 600)
        .animation(NativeAgentMotion.standard, value: state.step)
        .animation(NativeAgentMotion.standard, value: state.errorMessage)
        .quietReadTask { await appModel.engine.connectors.refresh(quiet: true); showFirstStep() }
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
        case .manualToken:
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
        case .slackTokens: "Add your Slack tokens"
        case .slackAccess: "Choose who can message me"
        case .success: "All set"
        case .error: "Couldn't set this up"
        }
    }

    private var backStep: ConnectorWizardState.WizardStep? {
        switch state.step {
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
        case .slackTokens:
            return PrimaryAction(title: "Next") { go(.slackAccess) }
        case .slackAccess:
            return PrimaryAction(
                title: isSaving ? "Checking…" : "Save",
                enabled: !isSaving && slackPolicyRead != nil && slackAllowlistConfigured
            ) { run { await saveSlackToken() } }
        case .success:
            return PrimaryAction(title: "Done") { onDismiss() }
        case .error:
            guard route != .unavailable else { return nil }
            return PrimaryAction(title: "Try again") { showFirstStep() }
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
                    Button(state.step == .error ? "Close" : "Cancel") {
                        if state.step != .error { clearDraft() }
                        onDismiss()
                    }
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

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch state.step {
        case .loading:
            AdvancedWaitingLine("One moment…")
        case .slackTokens:
            slackTokensView
        case .slackAccess:
            slackAccessView
        case .success:
            successView
        case .error:
            Text(state.errorMessage ?? "Something went wrong. Try again.")
                .font(ShellType.body)
                .foregroundStyle(NativeAgentShell.text)
                .fixedSize(horizontal: false, vertical: true)
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
                note("From Basic Information › App-Level Tokens, with connections:write. Turn on Socket Mode too.")
            }
            card("Scopes to add") {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
                    Text("app_mentions:read, channels:history, groups:history, im:history, mpim:history to chat with me")
                    Text("chat:write and files:write to reply")
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
            TextField("Channel IDs, like C0123", text: appModel.editBinding("connector:\(connectorID):slackAllowedChannels", seed: (slackPolicy?.allowedChannelIds.sorted() ?? []).joined(separator: ", ")))
                .textFieldStyle(.roundedBorder)
            TextField("User IDs, like U0123", text: appModel.editBinding("connector:\(connectorID):slackAllowedUsers", seed: (slackPolicy?.allowedUserIds.sorted() ?? []).joined(separator: ", ")))
                .textFieldStyle(.roundedBorder)
            Toggle("In channels and groups, only answer when @mentioned", isOn: appModel.editBinding("connector:\(connectorID):slackRequireMention", seed: slackPolicy?.requireMention ?? true))
            note("Add at least one channel or user. With both empty, I stay out of Slack chats. Direct messages never need an @mention.")
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
        }
    }

    // MARK: - Logic

    /// Moving between pages stops whatever the last page started.
    private func go(_ step: ConnectorWizardState.WizardStep) {
        state.flowTask?.cancel()
        state.flowTask = nil
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
    /// classes the inline chat card uses.
    private func failure(_ raw: String?, typed: [String] = [], fallback: String) -> String {
        let reason = NativeOAuthFlow.inlineSetupFailureReason(
            raw ?? "", service: displayName, typed: typed, otherwise: fallback)
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

    private func showFirstStep() {
        state.step = .loading
        state.errorMessage = nil
        switch route {
        case .manualToken:
            state.step = .slackTokens
        case .unavailable:
            state.errorMessage = "\(displayName) can't be set up from here yet. Nothing was changed."
            state.step = .error
        }
    }

    private func saveSlackToken() async {
        if case .failure(let error)? = slackPolicyRead {
            state.errorMessage = "Slack's saved policy could not be read (\(error.localizedDescription)). Nothing was changed."
            return
        }
        isSaving = true
        defer { isSaving = false }

        let submittedChannels = slackAllowedChannels
        let submittedUsers = slackAllowedUsers
        let submittedMention = slackRequireMention
        let result = await NativeOAuthFlow.saveSlackToken(
            slackToken,
            appToken: slackAppToken,
            allowedChannelIds: SlackSocketModeConfig.parseIDs(submittedChannels),
            allowedUserIds: SlackSocketModeConfig.parseIDs(submittedUsers),
            requireMention: submittedMention,
            dataRoot: appModel.engine.dataRoot
        )
        guard !Task.isCancelled else { return }
        if result.ok {
            await appModel.engine.connectors.refresh()
            if slackAllowedChannels == submittedChannels, slackAllowedUsers == submittedUsers,
               slackRequireMention == submittedMention { clearDraft() }
            slackToken = ""
            slackAppToken = ""
            state.step = .success
            _ = await NativeAgentEngine.restartBackgroundLoop(id: "slack_socket_mode")
            await appModel.refreshForSidebarItem(.connectors)
        } else {
            state.errorMessage = failure(
                result.error, typed: [slackToken, slackAppToken],
                fallback: "Couldn't save the Slack settings. Go Back to check the tokens, then try again.")
        }
    }
}
