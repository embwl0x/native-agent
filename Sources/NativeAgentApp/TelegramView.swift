import MacIntegration
import EngineRuntime
import NativeAgentCore
import SwiftUI
import AppKit
import TelegramBot
import NativeAgentShared
import PersistenceCore

// Blueprint: | `TelegramView.swift` | `TelegramView`: credential-free settings/status projections, access confirmation and save/test/log controls; outbound success never proves inbound poller health |

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

    static func readState(status: TelegramPresentationSnapshot?, refreshError: String?) -> ReadState {
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
    }

    static func canSave(draft: String, tokenConfigured: Bool) -> Bool {
        TelegramFacade.tokenValidationMessage(for: draft) == nil && (tokenConfigured || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    static func fieldState(draft: String, tokenConfigured: Bool) -> FieldState {
        FieldState(
            accessibilityIdentifier: accessibilityIdentifier,
            canSave: canSave(draft: draft, tokenConfigured: tokenConfigured),
            validationMessage: TelegramFacade.tokenValidationMessage(for: draft),
            helperText: tokenConfigured
                ? "Paste a new token only when replacing the saved bot token. The field clears after saving."
                : "Paste a BotFather token here. The field clears after saving."
        )
    }
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
import CloudKit
#endif

struct TelegramView: View {
    @Environment(AppModel.self) private var appModel
    @State private var showDisconnectConfirm = false
    @State private var showAccessConfirm = false
    @State private var showClearLogsConfirm = false
    @State private var requestingVoicePermission = false
    @State private var voicePermissionMessage: String?
    @State private var settingsLoaded = false
    @State private var settingsLoading = true
    @State private var checkingSender = false
    @State private var senderCheckMessage: String?

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
            savedEnabled: appModel.engine.telegram.status?.enabled,
            savedRequireMention: appModel.engine.telegram.status?.requireMention,
            savedChatIDs: appModel.engine.telegram.status?.allowedChatIds,
            savedUserIDs: appModel.engine.telegram.status?.allowedUserIds
        )
    }

    private var telegramModelOptions: [ModelCatalogItem] {
        ProvidersFacade.modelOptions(from: appModel.engine.providers.catalog, current: appModel.telegramModel, limit: 40)
    }

    private var tokenConfigured: Bool { appModel.engine.telegram.status?.tokenConfigured == true }

    private var botTokenFieldState: TelegramBotTokenPresentation.FieldState {
        TelegramBotTokenPresentation.fieldState(
            draft: appModel.telegramToken,
            tokenConfigured: tokenConfigured
        )
    }

    private var canSaveTelegram: Bool {
        botTokenFieldState.canSave
    }

    private var tokenStatusPresentation: TelegramSettingsPresentation.TokenStatus {
        TelegramSettingsPresentation.tokenStatus(tokenConfigured: tokenConfigured)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if settingsLoaded {
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
                } else if settingsLoading {
                    ProgressView("Reading Telegram settings…")
                } else {
                    ProviderNote(text: "Telegram settings are unavailable. \(appModel.telegramStatusRefreshError ?? "Try refreshing again.")", color: NativeAgentShell.trouble)
                    Button("Retry") { Task { await loadSettings() } }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 32)
        }
        .navigationTitle("Telegram")
        .quietReadTask { await loadSettings() }
        .confirmationDialog(
            "Allow more Telegram replies?" as String,
            isPresented: $showAccessConfirm,
            titleVisibility: .visible
        ) {
            Button("Allow replies" as String) {
                Task { await appModel.saveTelegram() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: "Telegram can reply to allowed chats and users when enabled. If group mentions are not required, it can reply in allowed groups without being mentioned.")
        }
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
                Task { _ = await appModel.clearTelegramToken() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved bot token and disables Telegram until new credentials are saved.")
        }
    }

    // MARK: - Connection

    private func loadSettings() async {
        settingsLoading = true
        let loaded = await appModel.refreshTelegram()
        guard !Task.isCancelled else { return }
        settingsLoaded = loaded
        settingsLoading = false
    }

    @ViewBuilder
    private var connectionSection: some View {
        let savedAllowlist = appModel.engine.telegram.status.map { telegramAllowlistPresentation(
            chats: $0.configuration.allowedChatIds.joined(separator: ","),
            users: $0.configuration.allowedUserIds.joined(separator: ",")) }
        let configured = savedAllowlist?.isValidAndConfigured == true
        AdvancedSection(title: "Connection", card: .bare) {
            ProviderCard {
                VStack(alignment: .leading, spacing: 12) {
                    TelegramStatusLine(
                        text: tokenStatusPresentation.label,
                        systemImage: tokenStatusPresentation.systemImage,
                        tone: tokenStatusPresentation.isConfigured ? .calm : .trouble
                    )
                    TelegramStatusLine(
                        text: savedAllowlist?.statusLabel ?? "Allowlist unavailable",
                        systemImage: configured
                            ? "person.crop.circle.badge.checkmark"
                            : "person.crop.circle.badge.exclamationmark",
                        tone: configured ? .calm : .trouble
                    )

                    if let status = appModel.engine.telegram.status {
                        TelegramMetaRow(label: "Poller", value: status.pollerEnabled ? "Running" : "Disabled")
                        TelegramMetaRow(label: "Last successful poll", value: status.lastPollAt.map(UserDisplayFormatters.humanizeISOTimestamp) ?? "None")
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
                            if voice.enabled {
                                Text("Allow speech recognition on this Mac to transcribe Telegram voice messages. Microphone access is not needed.")
                                    .font(ShellType.caption)
                                Button("Set up Telegram voice") {
                                    Task { @MainActor in
                                        requestingVoicePermission = true
                                        defer { requestingVoicePermission = false }
                                        NSApp.activate(ignoringOtherApps: true)
                                        let permission = await SystemPermissionPreflight.requestSpeechRecognitionIfNotDetermined()
                                        switch permission {
                                        case .granted:
                                            voicePermissionMessage = "Speech recognition is ready for Telegram voice messages."
                                            await NativeAgentEngine.retireSystemPermissionCardIfGranted(dataRoot: appModel.engine.dataRoot)
                                        case .denied:
                                            voicePermissionMessage = "Enable NativeAgent in System Settings → Privacy & Security → Speech Recognition."
                                        case .restricted:
                                            voicePermissionMessage = "Speech recognition is restricted on this Mac."
                                        case .notDetermined, .unknown:
                                            voicePermissionMessage = "Speech recognition permission was not resolved. Try setup again."
                                        }
                                    }
                                }
                                .disabled(requestingVoicePermission)
                                if let voicePermissionMessage {
                                    Text(voicePermissionMessage).font(ShellType.caption)
                                }
                            }
                        }
                        if let message = status.pollStatusMessage {
                            ProviderNote(text: message, color: status.isTransientPollInterruption ? NativeAgentShell.secondary : NativeAgentShell.trouble)
                        }
                    } else {
                        ProviderNote(
                            text: "Telegram has not reported yet. Refresh to read the bot's current state.",
                            color: NativeAgentShell.secondary
                        )
                    }
                }
            }
        }
    }

    // MARK: - Bot token

    @ViewBuilder
    private var botTokenSection: some View {
        AdvancedSection(title: "Bot token", card: .bare) {
            ProviderCard {
                VStack(alignment: .leading, spacing: 12) {
                    SecureField("Bot token", text: Bindable(appModel).telegramToken)
                        .textFieldStyle(.roundedBorder)
                        .font(ShellType.label)
                        .accessibilityIdentifier(botTokenFieldState.accessibilityIdentifier)
                    ProviderNote(text: botTokenFieldState.helperText, color: NativeAgentShell.secondary)
                    if let validationMessage = botTokenFieldState.validationMessage {
                        ProviderNote(text: validationMessage, color: NativeAgentShell.trouble)
                    } else if !tokenConfigured
                                && appModel.telegramToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ProviderNote(text: "A bot token is needed before Telegram settings can be saved.", color: NativeAgentShell.trouble)
                    }
                    if tokenConfigured {
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
        AdvancedSection(title: "Who can reach me", card: .bare) {
            ProviderCard {
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
                    ProviderNote(text: "To find your ID, leave Telegram off, save the bot token, then send the bot a message in Telegram. Check sender shows its numeric chat ID below. Admit only a sender you recognize, then save with Telegram on.", color: NativeAgentShell.secondary)
                    Button(checkingSender ? "Checking…" : "Check sender") {
                        checkingSender = true
                        Task {
                            defer { checkingSender = false }
                            do {
                                let count = try await appModel.engine.telegram.discoverTelegramSenders(token: appModel.telegramToken)
                                await appModel.refreshTelegram()
                                senderCheckMessage = count == 0 ? "No messages found. Send your bot a message, then check again." : "Sender IDs are in Blocked and ignored below. Choose your chat ID and save to admit it."
                            } catch {
                                senderCheckMessage = "Could not check senders: "
                                    + TurnSecretRedactor.redactText(error.localizedDescription)
                            }
                        }
                    }
                    .disabled(checkingSender || appModel.isSavingTelegram || appModel.engine.telegram.status?.enabled == true)
                    if let senderCheckMessage { ProviderNote(text: senderCheckMessage, color: NativeAgentShell.secondary) }
                    if !invalidAllowlistTokens.isEmpty {
                        ProviderNote(
                            text: "These are not usable IDs: \(invalidAllowlistTokens.joined(separator: ", ")). Use the numeric chat or user ID.",
                            color: NativeAgentShell.trouble
                        )
                    }
                    Toggle("Only answer when mentioned in a group", isOn: Bindable(appModel).telegramRequireMention)
                        .font(ShellType.label)
                    if hasUnsavedAuthorizationChanges {
                        ProviderNote(text: "These changes are not saved yet. Save before Telegram uses them.", color: NativeAgentShell.trouble)
                    }
                }
            }
        }
    }

    // MARK: - Model

    @ViewBuilder
    private var modelSection: some View {
        AdvancedSection(title: "Model", card: .bare) {
            ProviderCard {
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
                    ProviderNote(
                        text: "The list stays short so it opens fast. Paste any provider's model ID here if it is not listed.",
                        color: NativeAgentShell.secondary
                    )
                    TelegramField(title: "How hard it thinks") {
                        Picker("Think level", selection: Bindable(appModel).telegramReasoningEffort) {
                            ForEach(ProvidersFacade.reasoningOptions(from: appModel.engine.providers.catalog, model: appModel.telegramModel)) { effort in
                                Text(effort.label).tag(effort.id)
                            }
                        }
                        .pickerStyle(.segmented)
                        .hazeTinted(.segments)
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: appModel.telegramModel) { _, model in
                            appModel.telegramReasoningEffort = ProvidersFacade.normalizedReasoningEffort(
                                from: appModel.engine.providers.catalog,
                                model: model,
                                selected: appModel.telegramReasoningEffort
                            )
                        }
                    }
                    if let mismatch = telegramReasoningEffortMismatch(
                        from: appModel.engine.providers.catalog,
                        model: appModel.telegramModel,
                        selected: appModel.telegramReasoningEffort
                    ) {
                        ProviderNote(text: mismatch, color: NativeAgentShell.trouble)
                    }
                    TelegramMetaRow(label: "Commands in the chat", value: "/model, /think, /fast, /brain")
                }
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionsSection: some View {
        AdvancedSection(title: "Actions", card: .bare) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Button(appModel.isSavingTelegram ? "Saving…" : "Save") {
                        let saved = appModel.engine.telegram.status
                        if (appModel.telegramEnabled && saved?.enabled != true)
                            || (!appModel.telegramRequireMention && saved?.requireMention != false) {
                            showAccessConfirm = true
                        } else {
                            Task { await appModel.saveTelegram() }
                        }
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
                        Task { _ = await appModel.testTelegram() }
                    }
                    .disabled(
                        appModel.isTestingTelegram
                            || !tokenConfigured
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
        if let status = appModel.engine.telegram.status {
            if case .stale(let detail) = TelegramPanelPresentation.readState(
                status: status,
                refreshError: appModel.telegramStatusRefreshError
            ) {
                AdvancedSection(title: "These readings may be old", card: .bare) {
                    ProviderCard {
                        ProviderNote(
                            text: "Showing the last readable snapshot. The newest refresh failed: \(detail)",
                            color: NativeAgentShell.trouble
                        )
                    }
                }
            }

            AdvancedSection(title: "Recent replies", card: .bare) {
                AliveGroupCard {
                    Group {
                        if let issue = status.receiptsIssue {
                            ProviderNote(text: issue, color: NativeAgentShell.trouble)
                        }
                        if status.receipts.isEmpty {
                            ProviderNote(
                                text: status.receiptsIssue == nil
                                    ? "Replies I send over Telegram will be listed here."
                                    : "No readable reply records are available.",
                                color: NativeAgentShell.secondary
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
                                ProviderNote(text: "\(hidden) older replies are not shown.", color: NativeAgentShell.secondary)
                            }
                        }
                    }
                }
            }

            AdvancedSection(title: "Blocked and ignored", card: .bare) {
                AliveGroupCard {
                    Group {
                        if let issue = status.blockedIssue {
                            ProviderNote(text: issue, color: NativeAgentShell.trouble)
                        }
                        if status.blocked.isEmpty {
                            ProviderNote(
                                text: status.blockedIssue == nil
                                    ? "Messages turned away by the allowlist will be listed here."
                                    : "No readable blocked-message records are available.",
                                color: NativeAgentShell.secondary
                            )
                        } else {
                            ForEach(status.blocked.prefix(6)) { event in
                                TelegramEventRow(
                                    title: "\(event.reason ?? "blocked") · chat \(event.chatId ?? "unknown")",
                                    detail: event.textPreview ?? "",
                                    metadata: event.at
                                )
                                if let chatID = event.chatId, Int64(chatID) != nil {
                                    Button("Use chat ID \(chatID)") {
                                        var ids = appModel.telegramAllowedChats.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
                                        if !ids.contains(chatID) { ids.append(chatID) }
                                        appModel.telegramAllowedChats = ids.joined(separator: ", ")
                                    }
                                }
                            }
                            let hidden = TelegramPanelPresentation.hiddenCount(total: status.blocked.count, visibleLimit: 6)
                            if hidden > 0 {
                                ProviderNote(text: "\(hidden) older blocked messages are not shown.", color: NativeAgentShell.secondary)
                            }
                        }
                    }
                }
            }

            if status.errorsIssue != nil || !status.errors.isEmpty {
                AdvancedSection(title: "Recent errors", card: .bare) {
                    AliveGroupCard {
                        Group {
                            if let issue = status.errorsIssue {
                                ProviderNote(text: issue, color: NativeAgentShell.trouble)
                            }
                            if status.errors.isEmpty {
                                ProviderNote(text: "No readable Telegram errors are available.", color: NativeAgentShell.secondary)
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
                                    ProviderNote(text: "\(hidden) older errors are not shown.", color: NativeAgentShell.secondary)
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
            AdvancedSection(title: "What Telegram has been doing", card: .bare) {
                ProviderCard {
                    switch readState {
                    case .loading:
                        ProviderNote(text: "Reading what Telegram has been doing…", color: NativeAgentShell.secondary)
                    case .unavailable(let detail):
                        ProviderNote(text: "Telegram's records could not be read: \(detail)", color: NativeAgentShell.trouble)
                    case .current, .stale:
                        ProviderNote(
                            text: "Replies, blocked messages and errors will be listed here.",
                            color: NativeAgentShell.secondary
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

private struct TelegramStatusLine: View {
    let text: String
    let systemImage: String
    let tone: TrustTone

    var body: some View {
        // The mark carries the tone; the words stay in text colour, since
        // light calm and trouble fail 4.5:1 on the card fill.
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(ShellType.labelSemibold)
                .foregroundStyle(tone.color)
            Text(text)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
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
                .foregroundStyle(NativeAgentShell.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}
