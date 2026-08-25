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
            VStack(alignment: .leading, spacing: 16) {
            NativePanel(title: TelegramSettingsPresentation.statusPanelTitle, systemImage: "paperplane", tint: tokenStatusPresentation.isConfigured ? .green : .orange) {
                Label(
                    tokenStatusPresentation.label,
                    systemImage: tokenStatusPresentation.systemImage
                )
                .foregroundStyle(tokenStatusPresentation.isConfigured ? .green : .orange)

                Label(
                    allowlistPresentation.statusLabel,
                    systemImage: allowlistConfigured ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.exclamationmark"
                )
                .foregroundStyle(allowlistConfigured ? .green : .orange)

                if let status = appModel.telegramStatus {
                    LabeledContent("Poller", value: status.pollerEnabled ? "Running" : "Disabled")
                    LabeledContent("Last update", value: status.lastSeenUpdateId.map(String.init) ?? "None")
                    LabeledContent("Last reply", value: status.lastReplyAt.map(UserDisplayFormatters.humanizeISOTimestamp) ?? "None")
                    if let clearedAt = status.lastDiagnosticsClearedAt {
                        LabeledContent("Diagnostics cleared", value: UserDisplayFormatters.humanizeISOTimestamp(clearedAt))
                    }
                    if let voice = status.voiceTranscription {
                        LabeledContent("Voice", value: voice.enabled ? "\(voice.model) via \(voice.backend)" : "Disabled")
                        if voice.enabled && !voice.backendSupported {
                            Text("Voice backend \(voice.backend) is not supported by the Swift Telegram runtime.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        } else if voice.enabled && voice.requiresAPIKey == true && !voice.keyConfigured {
                            Text("Voice transcription needs an OpenAI platform key.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }
                    }
                    if status.isTransientPollInterruption {
                        Text("The poller is active and retrying after a transient interruption.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else if let error = status.actionableError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }

            NativePanel(title: "Bot", systemImage: "key", tint: appModel.telegramTokenConfigured ? .green : .secondary) {
                SecureField("Bot token", text: Bindable(appModel).telegramToken)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier(botTokenFieldState.accessibilityIdentifier)
                Text(botTokenFieldState.helperText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let validationMessage = botTokenFieldState.validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if !appModel.telegramTokenConfigured && appModel.telegramToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("A bot token is required before Telegram settings can be saved.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if appModel.telegramTokenConfigured {
                    Button("Disconnect Telegram", systemImage: "xmark.circle") {
                        showDisconnectConfirm = true
                    }
                    .disabled(appModel.isSavingTelegram)
                }
            }

            NativePanel(title: "Authorization", systemImage: "person.crop.circle.badge.checkmark") {
                Toggle("Telegram enabled", isOn: Bindable(appModel).telegramEnabled)
                TextField("Allowed chat IDs", text: Bindable(appModel).telegramAllowedChats)
                    .textFieldStyle(.roundedBorder)
                TextField("Allowed user IDs", text: Bindable(appModel).telegramAllowedUsers)
                    .textFieldStyle(.roundedBorder)
                if !invalidAllowlistTokens.isEmpty {
                    Text("Invalid Telegram IDs: \(invalidAllowlistTokens.joined(separator: ", ")). Use numeric chat or user IDs.")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                Toggle("Require mention in groups", isOn: Bindable(appModel).telegramRequireMention)
                if hasUnsavedAuthorizationChanges {
                    Text("Unsaved authorization changes — save before Telegram uses them.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            NativePanel(title: "Brain", systemImage: "brain") {
                Picker("Model", selection: Bindable(appModel).telegramModel) {
                    ForEach(telegramModelOptions) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                TextField("Custom model ID", text: Bindable(appModel).telegramModel)
                    .textFieldStyle(.roundedBorder)
                Text("The picker stays compact for responsiveness; paste any provider model ID here if it is not listed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Think level", selection: Bindable(appModel).telegramReasoningEffort) {
                    ForEach(reasoningOptions(from: appModel.modelCatalog, model: appModel.telegramModel)) { effort in
                        Text(effort.label).tag(effort.id)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: appModel.telegramModel) { _, model in
                    appModel.telegramReasoningEffort = normalizedReasoningEffort(
                        from: appModel.modelCatalog,
                        model: model,
                        selected: appModel.telegramReasoningEffort
                    )
                }
                if let mismatch = telegramReasoningEffortMismatch(
                    from: appModel.modelCatalog,
                    model: appModel.telegramModel,
                    selected: appModel.telegramReasoningEffort
                ) {
                    Text(mismatch)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                LabeledContent("Telegram commands", value: "/model, /think, /fast, /brain")
            }

            NativePanel(title: "Actions", systemImage: "slider.horizontal.3") {
                HStack {
                    Button {
                        Task { await appModel.saveTelegram() }
                    } label: {
                        if appModel.isSavingTelegram {
                            Label("Saving Telegram Settings", systemImage: "hourglass")
                        } else {
                            Label("Save Telegram Settings", systemImage: "paperplane")
                        }
                    }
                    .disabled(appModel.isSavingTelegram || !invalidAllowlistTokens.isEmpty || !canSaveTelegram)

                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await appModel.refreshTelegram() }
                    }
                    Button {
                        showClearLogsConfirm = true
                    } label: {
                        if appModel.isClearingTelegramLogs {
                            Label("Clearing Logs", systemImage: "hourglass")
                        } else {
                            Label("Clear Logs", systemImage: "trash")
                        }
                    }
                    .disabled(appModel.isClearingTelegramLogs)
                    Button {
                        Task { await appModel.testTelegram() }
                    } label: {
                        if appModel.isTestingTelegram {
                            Label("Sending Test", systemImage: "hourglass")
                        } else {
                            Label("Test Reply", systemImage: "paperplane.circle")
                        }
                    }
                    .disabled(
                        appModel.isTestingTelegram
                            || !appModel.telegramTokenConfigured
                            || !allowlistConfigured
                            || !invalidAllowlistTokens.isEmpty
                    )
                }
                .buttonStyle(.bordered)

                if let outcome = appModel.telegramSettingsSaveOutcome {
                    Label(
                        outcome.message,
                        systemImage: outcome.isAdverse
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(outcome.isAdverse ? .orange : .green)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("telegram.settings.save-outcome")
                }

                if let outcome = appModel.telegramClearLogsOutcome {
                    switch outcome {
                    case .completed(let receipt):
                        Label(TelegramClearLogsPresentation.summary(for: receipt), systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .textSelection(.enabled)
                    case .failed(let detail):
                        Label("Could not clear Telegram diagnostics: \(detail)", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }

            if let status = appModel.telegramStatus {
                if case .stale(let detail) = TelegramPanelPresentation.readState(
                    status: status,
                    refreshError: appModel.telegramStatusRefreshError
                ) {
                    NativePanel(title: "Telegram Diagnostics May Be Stale", systemImage: "clock.arrow.circlepath", tint: .orange) {
                        Text("Showing the last readable receipt snapshot. The latest refresh failed: \(detail)")
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }

                NativePanel(title: "Recent Replies", systemImage: "bubble.left.and.bubble.right") {
                    if let issue = status.receiptsIssue {
                        Label(issue, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                    if status.receipts.isEmpty {
                        Text(status.receiptsIssue == nil ? "No reply receipts yet" : "No readable reply receipts are available.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(status.receipts.prefix(6)) { receipt in
                            TelegramEventRow(
                                title: "\(receipt.kind ?? "reply") · chat \(receipt.chatId ?? "?")",
                                detail: [receipt.replyPreview ?? receipt.textPreview ?? "", receipt.model.map { "\($0) / \(receipt.reasoningEffort ?? "?")" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"),
                                metadata: receipt.at
                            )
                        }
                        let hidden = TelegramPanelPresentation.hiddenCount(total: status.receipts.count, visibleLimit: 6)
                        if hidden > 0 {
                            Text("\(hidden) older reply receipts are hidden.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                NativePanel(title: "Blocked / Ignored", systemImage: "hand.raised") {
                    if let issue = status.blockedIssue {
                        Label(issue, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                    if status.blocked.isEmpty {
                        Text(status.blockedIssue == nil ? "No blocked messages" : "No readable blocked-message records are available.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(status.blocked.prefix(6)) { event in
                            TelegramEventRow(
                                title: "\(event.reason ?? "blocked") · chat \(event.chatId ?? "?")",
                                detail: event.textPreview ?? "",
                                metadata: event.at
                            )
                        }
                        let hidden = TelegramPanelPresentation.hiddenCount(total: status.blocked.count, visibleLimit: 6)
                        if hidden > 0 {
                            Text("\(hidden) older blocked messages are hidden.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if status.errorsIssue != nil || !status.errors.isEmpty {
                    NativePanel(
                        title: "Recent Errors",
                        systemImage: "exclamationmark.triangle",
                        tint: status.errorsIssue == nil ? .red : .orange
                    ) {
                        if let issue = status.errorsIssue {
                            Label(issue, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }
                        if status.errors.isEmpty {
                            Text("No readable Telegram errors are available.")
                                .foregroundStyle(.secondary)
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
                                Text("\(hidden) older errors are hidden.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                let readState = TelegramPanelPresentation.readState(
                    status: nil,
                    refreshError: appModel.telegramStatusRefreshError
                )
                NativePanel(title: "Telegram Diagnostics", systemImage: "bubble.left.and.bubble.right", tint: readState == .loading ? .secondary : .orange) {
                    switch readState {
                    case .loading:
                        Label("Loading receipt panels…", systemImage: "hourglass")
                            .foregroundStyle(.secondary)
                    case .unavailable(let detail):
                        Text("Telegram receipt panels are unavailable: \(detail)")
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    case .current, .stale:
                        EmptyView()
                    }
                }
            }

            Text(appModel.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            .padding()
        }
        .navigationTitle("Telegram")
        .confirmationDialog(
            "Clear Telegram diagnostics?",
            isPresented: $showClearLogsConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear Logs", role: .destructive) {
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
}

struct TelegramEventRow: View {
    var title: String
    var detail: String
    var metadata: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            if !detail.isEmpty {
                Text(detail)
                    .lineLimit(2)
            }
            Text(metadata)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
    }
}
