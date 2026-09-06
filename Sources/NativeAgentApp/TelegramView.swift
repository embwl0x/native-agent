import SwiftUI
import AppKit
import CoreGraphics
import ScreenCaptureKit
import ScreenVision
import Speech
import AVFoundation
import UniformTypeIdentifiers
import NativeAgentShared
import MemoryV2
import PersistenceCore
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif

enum TelegramPanelPresentation {
    enum ReadState: Equatable {
        case loading
        case current
        case stale(detail: String)
        case unavailable(detail: String)
    }

    static func hiddenCount(total: Int, visibleLimit: Int) -> Int {
        max(0, total - visibleLimit)
    }

    static func readState(status: TelegramStatus?, refreshError: String?) -> ReadState {
        let detail = boundedDetail(refreshError)
        guard status != nil else {
            return detail.map { .unavailable(detail: $0) } ?? .loading
        }
        return detail.map { .stale(detail: $0) } ?? .current
    }

    private static func boundedDetail(_ detail: String?, limit: Int = 240) -> String? {
        guard let detail else { return nil }
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }
}

enum TelegramSettingsPresentation {
    static let statusPanelTitle = "Telegram Status"

    struct TokenStatus: Equatable, Sendable {
        let label: String
        let systemImage: String
        let isConfigured: Bool
    }

    static func tokenStatus(tokenConfigured: Bool) -> TokenStatus {
        tokenConfigured
            ? TokenStatus(
                label: "Bot token configured",
                systemImage: "checkmark.circle.fill",
                isConfigured: true
            )
            : TokenStatus(
                label: "Bot token missing",
                systemImage: "exclamationmark.triangle.fill",
                isConfigured: false
            )
    }

    static func tokenStatusLabel(tokenConfigured: Bool) -> String {
        tokenStatus(tokenConfigured: tokenConfigured).label
    }

    static func tokenStatusSymbol(tokenConfigured: Bool) -> String {
        tokenStatus(tokenConfigured: tokenConfigured).systemImage
    }
}

enum TelegramSettingsSaveOutcome: Equatable {
    case saved(tokenConfigured: Bool, enabled: Bool, allowlistCount: Int)
    case rejected(detail: String)
    case failed(detail: String)

    var message: String {
        switch self {
        case .saved(let tokenConfigured, let enabled, let allowlistCount):
            guard tokenConfigured else {
                return "Telegram settings saved, but no bot token is configured."
            }
            guard enabled else {
                return "Telegram settings saved. The bot remains disabled."
            }
            return "Telegram settings saved for \(allowlistCount) allowed \(allowlistCount == 1 ? "recipient" : "recipients")."
        case .rejected(let detail):
            return "Telegram settings were not saved: \(detail)"
        case .failed(let detail):
            return "Telegram settings could not be saved: \(detail)"
        }
    }

    var isAdverse: Bool {
        switch self {
        case .saved: return false
        case .rejected, .failed: return true
        }
    }
}

enum TelegramBotTokenPresentation {
    static let accessibilityIdentifier = "telegram.bot-token"

    /// A field projection is deliberately credential-free. The secure draft
    /// belongs to the input binding only; all text rendered around it reports
    /// configuration state without ever carrying the token back into another
    /// observable value.
    struct FieldState: Equatable {
        let accessibilityIdentifier: String
        let canSave: Bool
        let validationMessage: String?
        let helperText: String
        let tokenStatus: String
    }

    /// A Telegram token is a numeric bot identifier followed by an opaque,
    /// URL-safe secret.  This is intentionally local syntax validation only:
    /// Telegram remains the authority that can prove a credential works.
    static func validationMessage(for draft: String) -> String? {
        let token = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        let pieces = token.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              !pieces[0].isEmpty,
              !pieces[1].isEmpty,
              pieces[0].allSatisfy(\.isNumber),
              pieces[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        else {
            return "Enter a BotFather token in numeric-bot-ID:secret form. The token was not saved."
        }
        return nil
    }

    static func canSave(draft: String, tokenConfigured: Bool) -> Bool {
        validationMessage(for: draft) == nil && (tokenConfigured || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    static func fieldState(draft: String, tokenConfigured: Bool) -> FieldState {
        FieldState(
            accessibilityIdentifier: accessibilityIdentifier,
            canSave: canSave(draft: draft, tokenConfigured: tokenConfigured),
            validationMessage: validationMessage(for: draft),
            helperText: tokenConfigured
                ? "Paste a new token only when replacing the saved bot token. The field clears after saving."
                : "Paste a BotFather token here. The field clears after saving.",
            tokenStatus: TelegramSettingsPresentation.tokenStatusLabel(tokenConfigured: tokenConfigured)
        )
    }
}

struct TelegramDiagnosticsClearReceipt: Hashable {
    let clearedAt: String
    let removedFileCount: Int
    let removedRowCount: Int
    let status: TelegramStatus
}

enum TelegramClearLogsPresentation {
    enum Outcome: Equatable {
        case completed(TelegramDiagnosticsClearReceipt)
        case failed(detail: String)
    }

    static func summary(for receipt: TelegramDiagnosticsClearReceipt) -> String {
        let files = "\(receipt.removedFileCount) diagnostic \(receipt.removedFileCount == 1 ? "file" : "files")"
        let rows = "\(receipt.removedRowCount) \(receipt.removedRowCount == 1 ? "row" : "rows")"
        return "Cleared \(files) containing \(rows)."
    }
}

/// The test-reply button reports outbound credential validation and inbound
/// poller liveness separately.  A green send alone must never look like a
/// healthy Telegram surface when the long-poll loop is absent or stalled.
enum TelegramTestReplyPresentation {
    static func summary(for response: TelegramTestResponse) -> String {
        let delivery = "Telegram test sent to \(response.chatId). Bot token verified."
        guard response.pollerRegistered == true else {
            return "\(delivery) Telegram polling is not registered."
        }
        guard response.pollerTicking == true else {
            return "\(delivery) Telegram polling is registered but has not ticked yet."
        }
        return "\(delivery) Telegram polling is registered and ticking."
    }
}
#if canImport(CloudKit)
import CloudKit
#endif

struct TelegramView: View {
    @Environment(AppModel.self) private var appModel
    @State private var showDisconnectConfirm = false
    @State private var showClearLogsConfirm = false

    private var allowlistPresentation: TelegramAllowlistPresentation {
        telegramAllowlistPresentation(
            chats: appModel.telegramAllowedChats,
            users: appModel.telegramAllowedUsers
        )
    }

    private var allowlistConfigured: Bool { allowlistPresentation.isValidAndConfigured }

    private var invalidAllowlistTokens: [String] {
        allowlistPresentation.invalidTokens
    }

    private var hasUnsavedAuthorizationChanges: Bool {
        telegramAuthorizationHasUnsavedChanges(
            enabled: appModel.telegramEnabled,
            requireMention: appModel.telegramRequireMention,
            allowlist: allowlistPresentation,
            savedEnabled: appModel.telegramStatus?.enabled,
            savedRequireMention: appModel.telegramStatus?.requireMention,
            savedAcceptedCount: appModel.telegramStatus.map {
                Set($0.allowedChatIds + $0.allowedUserIds).count
            }
        )
    }

    private var telegramModelOptions: [ModelCatalogItem] {
        modelOptions(from: appModel.modelCatalog, current: appModel.telegramModel, limit: 40)
    }

    private var botTokenFieldState: TelegramBotTokenPresentation.FieldState {
        TelegramBotTokenPresentation.fieldState(
            draft: appModel.telegramToken,
            tokenConfigured: appModel.telegramTokenConfigured
        )
    }

    private var canSaveTelegram: Bool {
        botTokenFieldState.canSave
    }

    private var tokenStatusPresentation: TelegramSettingsPresentation.TokenStatus {
        TelegramSettingsPresentation.tokenStatus(tokenConfigured: appModel.telegramTokenConfigured)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                connectionSection
                botTokenSection
                authorizationSection
                modelSection
                actionsSection
                diagnosticsSections

                Text(appModel.statusText)
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 32)
        }
        .navigationTitle("Telegram")
        .confirmationDialog(
            "Clear Telegram diagnostics?",
            isPresented: $showClearLogsConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear logs", role: .destructive) {
                Task { await appModel.clearTelegramLogs() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes recent replies, blocked-message records, errors, and diagnostic logs from this Mac.")
        }
        .confirmationDialog(
            "Disconnect Telegram?",
            isPresented: $showDisconnectConfirm,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                Task { await appModel.clearTelegramToken() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved bot token and disables Telegram until new credentials are saved.")
        }
    }

    // MARK: - Connection

    @ViewBuilder
    private var connectionSection: some View {
        TelegramSection(label: "Connection") {
            TelegramCard {
                VStack(alignment: .leading, spacing: 12) {
                    TelegramStatusLine(
                        text: tokenStatusPresentation.label,
                        systemImage: tokenStatusPresentation.systemImage,
                        tone: tokenStatusPresentation.isConfigured ? .calm : .trouble
                    )
                    TelegramStatusLine(
                        text: allowlistPresentation.statusLabel,
                        systemImage: allowlistConfigured
                            ? "person.crop.circle.badge.checkmark"
                            : "person.crop.circle.badge.exclamationmark",
                        tone: allowlistConfigured ? .calm : .trouble
                    )

                    if let status = appModel.telegramStatus {
                        TelegramMetaRow(label: "Poller", value: status.pollerEnabled ? "Running" : "Disabled")
                        TelegramMetaRow(label: "Last update", value: status.lastSeenUpdateId.map(String.init) ?? "None")
                        TelegramMetaRow(
                            label: "Last reply",
                            value: status.lastReplyAt.map(UserDisplayFormatters.humanizeISOTimestamp) ?? "None"
                        )
                        if let clearedAt = status.lastDiagnosticsClearedAt {
                            TelegramMetaRow(
                                label: "Diagnostics cleared",
                                value: UserDisplayFormatters.humanizeISOTimestamp(clearedAt)
                            )
                        }
                        if let voice = status.voiceTranscription {
                            TelegramMetaRow(
                                label: "Voice",
                                value: voice.enabled ? "\(voice.model) via \(voice.backend)" : "Disabled"
                            )
                            if voice.enabled && !voice.backendSupported {
                                TelegramNote(
                                    text: "Voice backend \(voice.backend) is not supported by the Swift Telegram runtime.",
                                    tone: .trouble
                                )
                            } else if voice.enabled && voice.requiresAPIKey == true && !voice.keyConfigured {
                                TelegramNote(text: "Voice transcription needs an OpenAI platform key.", tone: .trouble)
                            }
                        }
                        if status.isTransientPollInterruption {
                            TelegramNote(
                                text: "The poller is active and retrying after a transient interruption.",
                                tone: .quiet
                            )
                        } else if let error = status.actionableError {
                            TelegramNote(text: error, tone: .trouble)
                        }
                    } else {
                        TelegramNote(
                            text: "Telegram has not reported yet. Refresh to read the bot's current state.",
                            tone: .quiet
                        )
                    }
                }
            }
        }
    }

    // MARK: - Bot token

    @ViewBuilder
    private var botTokenSection: some View {
        TelegramSection(label: "Bot token") {
            TelegramCard {
                VStack(alignment: .leading, spacing: 12) {
                    SecureField("Bot token", text: Bindable(appModel).telegramToken)
                        .textFieldStyle(.roundedBorder)
                        .font(ShellType.label)
                        .accessibilityIdentifier(botTokenFieldState.accessibilityIdentifier)
                    TelegramNote(text: botTokenFieldState.helperText, tone: .quiet)
                    if let validationMessage = botTokenFieldState.validationMessage {
                        TelegramNote(text: validationMessage, tone: .trouble)
                    } else if !appModel.telegramTokenConfigured
                                && appModel.telegramToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        TelegramNote(text: "A bot token is needed before Telegram settings can be saved.", tone: .trouble)
                    }
                    if appModel.telegramTokenConfigured {
                        Button("Disconnect Telegram") {
                            showDisconnectConfirm = true
                        }
                        .buttonStyle(.bordered)
                        .font(ShellType.labelMedium)
                        .disabled(appModel.isSavingTelegram)
                    }
                }
            }
        }
    }

    // MARK: - Who can reach the agent

    @ViewBuilder
    private var authorizationSection: some View {
        TelegramSection(label: "Who can reach \(AgentVoice.live.object)") {
            TelegramCard {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Telegram is on", isOn: Bindable(appModel).telegramEnabled)
                        .font(ShellType.label)
                    TelegramField(title: "Allowed chat IDs") {
                        TextField("", text: Bindable(appModel).telegramAllowedChats)
                            .textFieldStyle(.roundedBorder)
                            .font(ShellType.label)
                    }
                    TelegramField(title: "Allowed user IDs") {
                        TextField("", text: Bindable(appModel).telegramAllowedUsers)
                            .textFieldStyle(.roundedBorder)
                            .font(ShellType.label)
                    }
                    if !invalidAllowlistTokens.isEmpty {
                        TelegramNote(
                            text: "These are not usable IDs: \(invalidAllowlistTokens.joined(separator: ", ")). Use the numeric chat or user ID.",
                            tone: .trouble
                        )
                    }
                    Toggle("Only answer when mentioned in a group", isOn: Bindable(appModel).telegramRequireMention)
                        .font(ShellType.label)
                    if hasUnsavedAuthorizationChanges {
                        TelegramNote(text: "These changes are not saved yet. Save before Telegram uses them.", tone: .trouble)
                    }
                }
            }
        }
    }

    // MARK: - Model

    @ViewBuilder
    private var modelSection: some View {
        TelegramSection(label: "Model") {
            TelegramCard {
                VStack(alignment: .leading, spacing: 12) {
                    TelegramField(title: "Model") {
                        Picker("Model", selection: Bindable(appModel).telegramModel) {
                            ForEach(telegramModelOptions) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .font(ShellType.label)
                    }
                    TelegramField(title: "Or paste a model ID") {
                        TextField("", text: Bindable(appModel).telegramModel)
                            .textFieldStyle(.roundedBorder)
                            .font(ShellType.label)
                    }
                    TelegramNote(
                        text: "The list stays short so it opens fast. Paste any provider's model ID here if it is not listed.",
                        tone: .quiet
                    )
                    TelegramField(title: "How hard it thinks") {
                        Picker("Think level", selection: Bindable(appModel).telegramReasoningEffort) {
                            ForEach(reasoningOptions(from: appModel.modelCatalog, model: appModel.telegramModel)) { effort in
                                Text(effort.label).tag(effort.id)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: appModel.telegramModel) { _, model in
                            appModel.telegramReasoningEffort = normalizedReasoningEffort(
                                from: appModel.modelCatalog,
                                model: model,
                                selected: appModel.telegramReasoningEffort
                            )
                        }
                    }
                    if let mismatch = telegramReasoningEffortMismatch(
                        from: appModel.modelCatalog,
                        model: appModel.telegramModel,
                        selected: appModel.telegramReasoningEffort
                    ) {
                        TelegramNote(text: mismatch, tone: .trouble)
                    }
                    TelegramMetaRow(label: "Commands in the chat", value: "/model, /think, /fast, /brain")
                }
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionsSection: some View {
        TelegramSection(label: "Actions") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Button(appModel.isSavingTelegram ? "Saving…" : "Save") {
                        Task { await appModel.saveTelegram() }
                    }
                    .disabled(appModel.isSavingTelegram || !invalidAllowlistTokens.isEmpty || !canSaveTelegram)

                    Button("Refresh") {
                        Task { await appModel.refreshTelegram() }
                    }

                    Button(appModel.isClearingTelegramLogs ? "Clearing…" : "Clear logs") {
                        showClearLogsConfirm = true
                    }
                    .disabled(appModel.isClearingTelegramLogs)

                    Button(appModel.isTestingTelegram ? "Sending…" : "Send a test reply") {
                        Task { await appModel.testTelegram() }
                    }
                    .disabled(
                        appModel.isTestingTelegram
                            || !appModel.telegramTokenConfigured
                            || !allowlistConfigured
                            || !invalidAllowlistTokens.isEmpty
                    )
                }
                .buttonStyle(.bordered)
                .font(ShellType.labelMedium)

                if let outcome = appModel.telegramSettingsSaveOutcome {
                    TelegramStatusLine(
                        text: outcome.message,
                        systemImage: outcome.isAdverse ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                        tone: outcome.isAdverse ? .trouble : .calm
                    )
                    .accessibilityIdentifier("telegram.settings.save-outcome")
                }

                if let outcome = appModel.telegramClearLogsOutcome {
                    switch outcome {
                    case .completed(let receipt):
                        TelegramStatusLine(
                            text: TelegramClearLogsPresentation.summary(for: receipt),
                            systemImage: "checkmark.circle.fill",
                            tone: .calm
                        )
                    case .failed(let detail):
                        TelegramStatusLine(
                            text: "The Telegram diagnostics could not be cleared: \(detail)",
                            systemImage: "exclamationmark.triangle.fill",
                            tone: .trouble
                        )
                    }
                }
            }
        }
    }

    // MARK: - What Telegram has been doing

    @ViewBuilder
    private var diagnosticsSections: some View {
        if let status = appModel.telegramStatus {
            if case .stale(let detail) = TelegramPanelPresentation.readState(
                status: status,
                refreshError: appModel.telegramStatusRefreshError
            ) {
                TelegramSection(label: "These readings may be old") {
                    TelegramCard {
                        TelegramNote(
                            text: "Showing the last readable snapshot. The newest refresh failed: \(detail)",
                            tone: .trouble
                        )
                    }
                }
            }

            TelegramSection(label: "Recent replies") {
                TelegramCard {
                    VStack(alignment: .leading, spacing: 12) {
                        if let issue = status.receiptsIssue {
                            TelegramNote(text: issue, tone: .trouble)
                        }
                        if status.receipts.isEmpty {
                            TelegramNote(
                                text: status.receiptsIssue == nil
                                    ? "Replies \(AgentVoice.live.subject) \(AgentVoice.live.verb("send")) over Telegram will be listed here."
                                    : "No readable reply records are available.",
                                tone: .quiet
                            )
                        } else {
                            ForEach(status.receipts.prefix(6)) { receipt in
                                TelegramEventRow(
                                    title: "\(receipt.kind ?? "reply") · chat \(receipt.chatId ?? "unknown")",
                                    detail: [receipt.replyPreview ?? receipt.textPreview ?? "", receipt.model.map { "\($0) / \(receipt.reasoningEffort ?? "default")" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"),
                                    metadata: receipt.at
                                )
                            }
                            let hidden = TelegramPanelPresentation.hiddenCount(total: status.receipts.count, visibleLimit: 6)
                            if hidden > 0 {
                                TelegramNote(text: "\(hidden) older replies are not shown.", tone: .quiet)
                            }
                        }
                    }
                }
            }

            TelegramSection(label: "Blocked and ignored") {
                TelegramCard {
                    VStack(alignment: .leading, spacing: 12) {
                        if let issue = status.blockedIssue {
                            TelegramNote(text: issue, tone: .trouble)
                        }
                        if status.blocked.isEmpty {
                            TelegramNote(
                                text: status.blockedIssue == nil
                                    ? "Messages turned away by the allowlist will be listed here."
                                    : "No readable blocked-message records are available.",
                                tone: .quiet
                            )
                        } else {
                            ForEach(status.blocked.prefix(6)) { event in
                                TelegramEventRow(
                                    title: "\(event.reason ?? "blocked") · chat \(event.chatId ?? "unknown")",
                                    detail: event.textPreview ?? "",
                                    metadata: event.at
                                )
                            }
                            let hidden = TelegramPanelPresentation.hiddenCount(total: status.blocked.count, visibleLimit: 6)
                            if hidden > 0 {
                                TelegramNote(text: "\(hidden) older blocked messages are not shown.", tone: .quiet)
                            }
                        }
                    }
                }
            }

            if status.errorsIssue != nil || !status.errors.isEmpty {
                TelegramSection(label: "Recent errors") {
                    TelegramCard {
                        VStack(alignment: .leading, spacing: 12) {
                            if let issue = status.errorsIssue {
                                TelegramNote(text: issue, tone: .trouble)
                            }
                            if status.errors.isEmpty {
                                TelegramNote(text: "No readable Telegram errors are available.", tone: .quiet)
                            } else {
                                ForEach(status.errors.prefix(4)) { event in
                                    TelegramEventRow(
                                        title: event.context ?? "telegram",
                                        detail: event.error,
                                        metadata: event.at
                                    )
                                }
                                let hidden = TelegramPanelPresentation.hiddenCount(total: status.errors.count, visibleLimit: 4)
                                if hidden > 0 {
                                    TelegramNote(text: "\(hidden) older errors are not shown.", tone: .quiet)
                                }
                            }
                        }
                    }
                }
            }
        } else {
            let readState = TelegramPanelPresentation.readState(
                status: nil,
                refreshError: appModel.telegramStatusRefreshError
            )
            TelegramSection(label: "What Telegram has been doing") {
                TelegramCard {
                    switch readState {
                    case .loading:
                        TelegramNote(text: "Reading what Telegram has been doing…", tone: .quiet)
                    case .unavailable(let detail):
                        TelegramNote(text: "Telegram's records could not be read: \(detail)", tone: .trouble)
                    case .current, .stale:
                        TelegramNote(
                            text: "Replies, blocked messages and errors will be listed here.",
                            tone: .quiet
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Page kit
//
// The page's own small vocabulary: an eyebrow over a run, the card the
// controls sit in, and the three shapes of line inside one.

private struct TelegramSection<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label)
                .font(ShellType.labelSemibold)
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(NativeAgentShell.secondary)
            content
        }
    }
}

private struct TelegramCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                    .fill(TodayPalette.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                    .strokeBorder(TodayPalette.cardStroke, lineWidth: 1)
            )
    }
}

/// The three tones a line on this page can carry. Nothing else is tinted.
private enum TelegramTone {
    case calm
    case trouble
    case quiet

    var color: Color {
        switch self {
        case .calm: NativeAgentShell.calm
        case .trouble: NativeAgentShell.trouble
        case .quiet: NativeAgentShell.secondary
        }
    }
}

private struct TelegramStatusLine: View {
    let text: String
    let systemImage: String
    let tone: TelegramTone

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(ShellType.labelSemibold)
            Text(text)
                .font(ShellType.label)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .foregroundStyle(tone.color)
    }
}

private struct TelegramNote: View {
    let text: String
    let tone: TelegramTone

    var body: some View {
        Text(text)
            .font(ShellType.caption)
            .foregroundStyle(tone.color)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

private struct TelegramMetaRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.text)
                .textSelection(.enabled)
        }
    }
}

private struct TelegramField<Control: View>: View {
    let title: String
    @ViewBuilder var control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(ShellType.labelMedium)
                .foregroundStyle(NativeAgentShell.secondary)
            control
        }
    }
}

struct TelegramEventRow: View {
    var title: String
    var detail: String
    var metadata: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(ShellType.labelSemibold)
                .foregroundStyle(NativeAgentShell.text)
            if !detail.isEmpty {
                Text(detail)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(2)
            }
            Text(metadata)
                .font(ShellType.caption)
                .foregroundStyle(NativeAgentShell.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}
