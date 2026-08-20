import Foundation
import NativeAgentCore
import BackgroundLoops
import ChatOrchestration
import DoctorChecks
import MemoryV2
import PersistenceCore
import ProviderRouting
import DreamREMCycle
import TelegramBot
import ApprovalInbox
import WorkshopExecution
import TrustCenter
import MacControl
import SelfImprovement
import NotificationInbox

// MARK: - Chat Surface Loops

extension BackgroundLoopsAssembly {
    private static func withChatTranscriptCompletionSignal<T>(
        sessionID: String,
        operation: () async throws -> T
    ) async rethrows -> T {
        do {
            let value = try await operation()
            await MainActor.run {
                NotificationCenter.default.post(name: .chatTurnCompleted, object: sessionID)
            }
            return value
        } catch {
            await MainActor.run {
                NotificationCenter.default.post(name: .chatTurnCompleted, object: sessionID)
            }
            throw error
        }
    }

    static func makeSlackSocketModeLoopIfConfigured(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> SlackSocketModeLoop? {
        guard let cfg = SlackSocketModeConfig.load(dataRoot: dataRoot), cfg.enabled else {
            return nil
        }
        let slackSessions = SlackSessionStore(dataRoot: dataRoot)
        let client = makeNativeAgentAppChatOrchestrationClient(
            profile: .slack,
            dataRoot: dataRoot
        )
        let handler: SlackSocketModeChatHandler = { inbound in
            let sessionId = try await slackSessions.activeSessionId(for: inbound)
            let prompt = """
            [from: slack, user: \(inbound.userId), channel: \(inbound.channelId)]
            \(inbound.text)
            """
            let replyRoute = ChatToolSessionContext.ReplyRoute(
                surface: "slack",
                destinationId: inbound.channelId,
                threadId: inbound.replyThreadTs
            )
            // 2026-07-21 audit fix: the forged commandSignatureVerified=true
            // binding is REMOVED. Socket mode carries no request signature;
            // slack origin trust now comes from the explicit slack allowlist
            // in SecurityCenter.assessOrigin (mirroring telegram).
            let response = try await withChatTranscriptCompletionSignal(sessionID: sessionId) {
                try await ChatToolSessionContext.$verifiedChatId.withValue(inbound.channelId) {
                    try await ChatToolSessionContext.$verifiedUserId.withValue(inbound.userId) {
                        try await ChatToolSessionContext.$replyRoute.withValue(replyRoute) {
                            try await client.chat(
                                message: prompt,
                                sessionId: sessionId,
                                // The chat facade admits the complete checked tuple
                                // once; surface shells provide no stale partial pick.
                                model: "",
                                reasoningEffort: "",
                                fileAccess: "auto",
                                attachments: inbound.attachments,
                                persona: NativeAgentNotificationDefaults.agentDisplayName(dataRoot: dataRoot),
                                surface: "slack",
                                suppressUserAppend: false
                            )
                        }
                    }
                }
            }
            return SlackSocketModeReply(
                text: response.output,
                attachments: response.attachments ?? []
            )
        }
        return SlackSocketModeLoop(
            config: cfg,
            dataRoot: dataRoot,
            chatHandler: handler
        )
    }

    // Swift Telegram long-poll loop wiring. Only enabled when
    // a real token + enabled=true sit on disk; otherwise we skip silently so
    // the assembly stays free of dead loops in cold-install / no-token setups.
    static func makeTelegramPollLoopIfConfigured(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> TelegramPollLoop? {
        guard let cfg = TelegramBot.TelegramConfig.loadFromDisk(dataRoot: dataRoot),
              cfg.enabled, !cfg.botToken.isEmpty
        else { return nil }
        // Build the Swift-native chat-orchestration client lazily so we don't
        // pay the LLM-client construction cost when no Telegram traffic flows.
        // The profiled app client factory is idempotent — each call builds a
        // fresh client over the same on-disk data root.
        // Brain state has one owner: providers/surfaces.json. Resolve it at
        // handler time so /model, /think, /fast, Mac settings, and iPhone
        // controls all affect the very next turn without restarting this loop.
        let providerDir = dataRoot.appendingPathComponent("providers", isDirectory: true)
        let providerRouting = SwiftNativeProviderRouting(
            dataRoot: dataRoot,
            surfacesPathOverride: providerDir.appendingPathComponent("surfaces.json"),
            activeProviderPathOverride: providerDir.appendingPathComponent("active.json")
        )
        let telegramSessions = TelegramSessionStore(dataRoot: dataRoot)
        let telegramBot = SwiftNativeTelegramBot(
            dataRoot: dataRoot,
            completenessDeps: TelegramBotCompletenessDeps(
                routing: TelegramProviderRoutingBridge(
                    routing: providerRouting,
                    dataRoot: dataRoot
                ),
                memory: TelegramMemoryWriterBridge(dataRoot: dataRoot),
                restart: TelegramRestartBridge(dataRoot: dataRoot)
            )
        )
        let approvalFiler = TelegramApprovalFiler(
            dataRoot: dataRoot,
            token: cfg.botToken
        )
        // Keep the exact Telegram profile and approval filer resident for the
        // loop lifetime. Routing/policy remain per-turn snapshots; only the
        // stateless orchestration graph and schema caches are reused.
        let client = makeNativeAgentAppChatOrchestrationClient(
            profile: .telegram,
            approvalFiler: approvalFiler,
            dataRoot: dataRoot
        )
        // chat-smoothness phase 5: lock-guarded incremental→accumulated text
        // bridge for the Telegram growing draft (the progress closure is
        // @Sendable; deltas arrive on the chat engine's executor).
        final class TelegramDeltaAccumulator: @unchecked Sendable {
            private let lock = NSLock()
            private var text = ""
            func append(_ chunk: String) -> String {
                lock.lock(); defer { lock.unlock() }
                text += chunk
                return text
            }
        }
        // telegram-vision-in: attachment-aware handler. `attachments` carry
        // already-downloaded inbound images (TelegramMediaAttachment.bytes set);
        // convert each to ChatOrchestration's MultimodalAttachment — the SAME
        // {type:"image", base64, mime, byteSize} shape the Mac UI builds in
        // ChatView.swift — so the vision pass works for whichever provider/model
        // the telegram surface resolves to.
        let handler: TelegramProgressChatHandlerWithAttachments = { chatId, text, mediaAttachments, progress, context in
            // chat-smoothness phase 5: chat deltas arrive INCREMENTAL; the
            // bot's growing draft wants accumulated text-so-far. One
            // accumulator per turn (this closure runs once per turn).
            let deltaAccumulator = TelegramDeltaAccumulator()
            // U4 Wave D (gpt-5.5 review BLOCKER): Telegram is a REMOTE surface —
            // the self-evolution tools must not be reachable from it.
            // includeEvolutionBridge:false → they return `bridge_not_wired`.
            let sessionId = try await telegramSessions.activeSessionId(chatId: chatId)
            let persona = (try? await telegramSessions.persona(chatId: chatId))
                ?? NativeAgentNotificationDefaults.agentDisplayName(dataRoot: dataRoot)
            let effectiveText = TelegramReplyPromptRenderer.messageWithReplyContext(
                text: text,
                replyTo: context.replyTo
            )
            let replyRoute = ChatToolSessionContext.ReplyRoute(
                surface: "telegram",
                destinationId: String(chatId)
            )
            // Convert downloaded Telegram images into the Mac-path attachment
            // shape. Mirrors ChatView.swift's MultimodalAttachment(type:"image",
            // base64:, mime:, byteSize:) exactly so the existing vision path
            // consumes them with no special-casing.
            // Qualify as ChatOrchestration.MultimodalAttachment: an unqualified
            // `MultimodalAttachment` resolves to NativeAgentShared's same-named
            // type, which `client.chat` does NOT accept (mirrors NativeClient's
            // explicit qualification at its chat call site).
            let chatAttachments: [ChatOrchestration.MultimodalAttachment] = mediaAttachments.compactMap { media in
                guard let bytes = media.bytes, !bytes.isEmpty else { return nil }
                return ChatOrchestration.MultimodalAttachment(
                    type: "image",
                    base64: bytes.base64EncodedString(),
                    mime: media.mimeType ?? "image/jpeg",
                    name: media.captureFilename,
                    byteSize: bytes.count
                )
            }
            // Bind the verified Telegram chatId so the security gates resolve
            // allowlist trust even when the active session is a bare UUID
            // (post-/new), not the legacy `telegram:<chatId>` form. See
            // ChatToolSessionContext.
            let response = try await withChatTranscriptCompletionSignal(sessionID: sessionId) {
                try await ChatToolSessionContext.$verifiedChatId.withValue(String(chatId)) {
                    try await ChatToolSessionContext.$verifiedUserId.withValue(
                        context.fromUserId.map(String.init)
                    ) {
                        try await ChatToolSessionContext.$verifiedSessionId.withValue(sessionId) {
                            try await ChatToolSessionContext.$replyRoute.withValue(replyRoute) {
                                try await client.chat(
                                    message: effectiveText,
                                    sessionId: sessionId,
                                    // The facade freezes provider/model/effort/tier
                                    // before branch selection and context assembly.
                                    model: "",
                                    reasoningEffort: "",
                                    fileAccess: "auto",
                                    attachments: chatAttachments,
                                    persona: persona,
                                    surface: "telegram",
                                    suppressUserAppend: context.suppressUserAppend,
                                    progress: { event in
                                        switch event {
                                        case .toolUse(let name, let input):
                                            await progress(.toolUse(name: name, input: input))
                                        case .toolResult(let name, let output):
                                            await progress(.toolResult(name: name, output: output))
                                        case .notice(let kind, let text):
                                            // invoke_claude start/heartbeat/timeout — surface on
                                            // Telegram so the user sees live progress instead of a silent
                                            // multi-minute hang. Carry `kind` so the bot throttles
                                            // heartbeats but always delivers the terminal timeout.
                                            // (2026-06-09 — completes notify-don't-hang on Telegram.)
                                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                                            if !trimmed.isEmpty {
                                                await progress(.notice(kind: kind, text: trimmed))
                                            }
                                        case .delta(let chunk):
                                            // chat-smoothness phase 5: forward text-so-far to
                                            // the bot's growing-draft streamer (it throttles
                                            // the actual Telegram edits to ~2s).
                                            await progress(.textDelta(accumulated: deltaAccumulator.append(chunk)))
                                        case .final, .error:
                                            break
                                        }
                                    }
                                )
                            }
                        }
                    }
                }
            }
            return response.output
        }
        return TelegramPollLoop(
            interval: 0.25,
            token: cfg.botToken,
            allowedChatIds: cfg.allowedChatIds,
            allowedUserIds: cfg.allowedUserIds,
            requireMention: cfg.requireMention,
            bot: telegramBot,
            dataRoot: dataRoot,
            offsetURL: dataRoot
                .appendingPathComponent("telegram", isDirectory: true)
                .appendingPathComponent("last_offset.json"),
            sendRichMessageDraft: TelegramPollLoop.defaultSendRichMessageDraft,
            sendRichMessage: TelegramPollLoop.defaultSendRichMessage,
            sendMessageWithReplyMarkupReturningId: TelegramPollLoop.defaultSendMessageWithReplyMarkupReturningId,
            editMessageTextWithReplyMarkup: TelegramPollLoop.defaultEditMessageTextWithReplyMarkup,
            syncCommandMenu: TelegramPollLoop.defaultSyncCommandMenu,
            approvalHandler: approvalFiler,
            attachmentChatHandler: handler,
            voiceTranscriber: makeTelegramVoiceTranscriber(cfg: cfg, dataRoot: dataRoot),
            onCapabilityDenied: { capability in
                await fileSystemPermissionNotice(capability: capability, dataRoot: dataRoot)
            },
            voiceMaxBytes: cfg.voiceMaxBytes
        )
    }

    /// Stable card id for the Speech Recognition permission notice. One id, so
    /// every subsequent denied voice note updates the SAME card instead of
    /// stacking a new row per message.
    static let systemPermissionsSpeechCardId = "system-permissions-speech"

    /// PATCH-2026-08-18: surface a headless TCC denial to the human at the Mac.
    ///
    /// The Telegram sender already gets a chat notice; this is the other half —
    /// the person who can actually flip the switch is not in the chat. Mirrors
    /// the established `fileDiskHygieneNotice` shape
    /// (BackgroundLoopsAssembly+Maintenance.swift:205): stable id, upsert,
    /// severity "actionable", then push only when the row is newly inserted.
    ///
    /// The card carries the real route rather than a bare Dismiss: the exact
    /// System Settings deep link in `related_paths`, and the in-app row
    /// (Mac Integration → System Permissions → Speech Recognition) named in the
    /// detail. See the report note about the one-click Act button.
    static func fileSystemPermissionNotice(
        capability: String,
        dataRoot: URL
    ) async {
        guard capability == SystemPermissionCapability.speechRecognition.rawValue else {
            // Only the speech capability has a card today. An unrecognised
            // capability is dropped LOUDLY rather than filed under the speech
            // card id, which would put the wrong pane in front of the user.
            FileHandle.standardError.write(Data(
                "SystemPermissionNotice: no card mapped for capability \(capability)\n".utf8))
            return
        }
        let cap = SystemPermissionCapability.speechRecognition
        // Read the LIVE status (non-prompting) so the card states what is
        // actually true now, not what the failing turn assumed.
        let liveStatus = SystemPermissionPreflight.status(cap)
        guard liveStatus != .granted else {
            // The grant landed between the failed turn and this write (e.g. the
            // launch preflight resolved it). Do not file a card that is already
            // false — and clear any card a previous denial left behind.
            await retireSystemPermissionCardIfGranted(dataRoot: dataRoot)
            return
        }
        let snapshot = SystemPermissionSnapshot(capability: cap, status: liveStatus)
        let summary = SystemPermissionPreflight.warningSummary(for: snapshot)
        let settingsLink = SystemPermissionPreflight.settingsURL(for: cap)?.absoluteString
        let now = ISO8601DateFormatter().string(from: Date())
        let detail = """
        A Telegram voice note could not be transcribed because macOS \
        Speech Recognition is not approved for NativeAgent (current state: \
        \(liveStatus.rawValue)).

        \(summary)

        Two ways to fix it:
        • In NativeAgent: Mac Integration → System Permissions → Speech Recognition → Grant.
        • In macOS: open System Settings → Privacy & Security → Speech Recognition \
        and switch NativeAgent on.\
        \(settingsLink.map { "\n\nDirect link: \($0)" } ?? "")

        Until then, inbound voice notes will keep replying with the permission notice \
        instead of a transcript.
        """
        let card: JSONValue = .object([
            "id": .string(systemPermissionsSpeechCardId),
            "created_at": .string(now),
            "source": .string("system_permissions"),
            "severity": .string("actionable"),
            "title": .string("Speech Recognition is not approved"),
            "summary": .string(String(summary.prefix(500))),
            "detail": .string(detail),
            "related_mission_id": .null,
            "related_approval_id": .null,
            "related_paths": .array(settingsLink.map { [.string($0)] } ?? []),
            "related_groups": .array([]),
            // No "act" entry on purpose: the inbox act-router has no
            // system_permissions case, so an Act button here would fall through
            // to the generic chat-draft path — a button that looks like a fix
            // and is not. The levers above are real; a fake one is worse than
            // none. (See report: wiring a true one-click Act needs a case in
            // NativeClient+ExportWorkshopInbox.resolveInboxPrimaryAction.)
            "actions": .array([
                .object(["id": .string("view"), "label": .string("View"),
                         "description": .string("See how to grant Speech Recognition")]),
                .object(["id": .string("archive"), "label": .string("Archive"),
                         "description": .string("Archive this card")]),
                .object(["id": .string("dismiss"), "label": .string("Dismiss"),
                         "description": .string("Dismiss this card")]),
            ]),
            "status": .string("unread"),
            "read_at": .null,
        ])
        // Sticky-status upsert, mirroring upsertDiskHygieneCard. A plain
        // LiveNotificationInbox.upsert replaces the whole row — including
        // status: "unread" — so a card the user already archived or dismissed
        // would be resurrected by the very next denied voice note. Since the
        // underlying condition persists until someone flips a System Settings
        // switch, that is a guaranteed nag loop. Preserve the user's disposition
        // whenever the detail text is unchanged; a CHANGED detail (the status
        // moved notDetermined -> denied) is genuinely new information and does
        // re-surface the card.
        let inboxPath = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        let persistence = SwiftNativePersistenceCore()
        do {
            let inserted = try await persistence.withFileLock(inboxPath) { () async throws -> Bool in
                let lines = try InboxRewriteGuard.readLines(inboxPath)
                guard InboxRewriteGuard.rewriteIsSafe(lines: lines, path: inboxPath) else {
                    InboxRewriteGuard.refuse("SystemPermissionNotice", path: inboxPath)
                    return false
                }
                var mutated: [Data] = []
                mutated.reserveCapacity(lines.count + 1)
                var found = false
                for line in lines {
                    guard case .object(let obj)? = line.row,
                          case .string(let id)? = obj["id"],
                          id == systemPermissionsSpeechCardId else {
                        // Other rows AND undecodable lines: verbatim.
                        mutated.append(line.raw)
                        continue
                    }
                    var replacement = card
                    if case .object(var newObj) = card,
                       case .string(let newDetail)? = newObj["detail"],
                       case .string(let oldDetail)? = obj["detail"],
                       newDetail == oldDetail {
                        newObj["status"] = obj["status"] ?? .string("unread")
                        newObj["read_at"] = obj["read_at"] ?? .null
                        replacement = .object(newObj)
                    }
                    mutated.append(Data(try replacement.serialize(pretty: false).utf8))
                    found = true
                }
                if !found { mutated.append(Data(try card.serialize(pretty: false).utf8)) }
                try InboxRewriteGuard.writeLines(mutated, to: inboxPath)
                return !found
            }
            if inserted {
                await InboxPushNotifier.notifyIfAttentionWorthy(
                    dataRoot: dataRoot,
                    itemId: systemPermissionsSpeechCardId,
                    title: "Speech Recognition is not approved",
                    summary: String(summary.prefix(500)),
                    source: "system_permissions",
                    severity: "actionable"
                )
            }
        } catch {
            FileHandle.standardError.write(Data(
                "SystemPermissionNotice: card upsert failed: \(error)\n".utf8))
        }
    }

    /// Archives the Speech Recognition card once the grant actually lands.
    ///
    /// Without this the card is immortal: filing skips when granted, but a card
    /// filed while denied has nothing that ever clears it, so a user who fixes
    /// the permission keeps an actionable "not approved" row forever — an alert
    /// that outlives its own condition. Safe to call on every launch; it is a
    /// no-op when the grant is missing, when there is no card, or when the user
    /// already archived/dismissed it.
    static func retireSystemPermissionCardIfGranted(dataRoot: URL) async {
        guard SystemPermissionPreflight.status(.speechRecognition) == .granted else { return }
        let inboxPath = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        let persistence = SwiftNativePersistenceCore()
        let now = ISO8601DateFormatter().string(from: Date())
        do {
            try await persistence.withFileLock(inboxPath) { () async throws -> Void in
                let lines = try InboxRewriteGuard.readLines(inboxPath)
                guard !lines.isEmpty else { return }
                guard InboxRewriteGuard.rewriteIsSafe(lines: lines, path: inboxPath) else {
                    InboxRewriteGuard.refuse("SystemPermissionNotice", path: inboxPath)
                    return
                }
                var changed = false
                var mutated: [Data] = []
                mutated.reserveCapacity(lines.count)
                for line in lines {
                    guard case .object(var obj)? = line.row,
                          case .string(let id)? = obj["id"],
                          id == systemPermissionsSpeechCardId else {
                        mutated.append(line.raw)
                        continue
                    }
                    let status: String
                    if case .string(let raw)? = obj["status"] {
                        status = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    } else {
                        status = "unread"
                    }
                    if status == "archived" || status == "dismissed" {
                        mutated.append(line.raw)
                        continue
                    }
                    obj["status"] = .string("archived")
                    obj["read_at"] = .string(now)
                    mutated.append(Data(try JSONValue.object(obj).serialize(pretty: false).utf8))
                    changed = true
                }
                if changed { try InboxRewriteGuard.writeLines(mutated, to: inboxPath) }
            }
        } catch {
            FileHandle.standardError.write(Data(
                "SystemPermissionNotice: card retire failed: \(error)\n".utf8))
        }
    }

    private static func makeTelegramVoiceTranscriber(
        cfg: TelegramBot.TelegramConfig,
        dataRoot: URL
    ) -> (any TelegramVoiceTranscribing)? {
        guard cfg.voiceTranscriptionEnabled else { return nil }
        let backend = TelegramVoiceTranscriptionBackends.canonical(cfg.voiceTranscriptionBackend)
        if TelegramVoiceTranscriptionBackends.isAppleSpeech(backend) {
            return SwiftAppleSpeechTranscriber()
        }
        if TelegramVoiceTranscriptionBackends.isOpenAI(backend) {
            return SwiftOpenAIWhisperTranscriber(
                model: cfg.voiceTranscriptionModel,
                dataRoot: dataRoot
            )
        }
        return nil
    }

}

struct TelegramProviderRoutingBridge: ProviderRoutingRef, Sendable {
    let routing: SwiftNativeProviderRouting
    let dataRoot: URL

    func modelForSurface(_ surface: String) async -> (model: String, provider: String)? {
        guard let snapshot = try? await routing.checkedRoutingSnapshot(),
              let pref = snapshot.preferences[surface] else {
            return nil
        }
        let provider = snapshot.activeProviders[surface]
            ?? routing.inferProviderForModel(pref.model)
            ?? "unknown"
        return (pref.model, provider)
    }

    func saveModelConfig(surface: String, key: String, value: String) async throws {
        var body: [String: JSONValue] = ["surface": .string(surface)]
        switch key {
        case "reasoning_effort", "reasoningEffort":
            body["reasoningEffort"] = .string(value)
        case "service_tier", "serviceTier":
            body["serviceTier"] = .string(value)
        case "model":
            body["model"] = .string(value)
            body["inferProvider"] = .bool(true)
        default:
            body[key] = .string(value)
        }
        _ = try await routing.saveModelConfig(.object(body))
    }

    func saveModelSelection(surface: String, provider: String?, model: String) async throws {
        let explicitProvider = provider?.trimmingCharacters(in: .whitespacesAndNewlines)
        let admittedProvider = explicitProvider?.isEmpty == false
            ? explicitProvider
            : routing.inferProviderForModel(model)
        try await routing.saveSurfaceConfiguration(
            surface: surface,
            model: model,
            reasoningEffort: nil,
            serviceTier: nil,
            providerId: admittedProvider
        )
    }

    func modelMenuForSurface(_ surface: String) async -> TelegramModelMenu? {
        guard let snapshot = try? await routing.checkedRoutingSnapshot(),
              let preference = snapshot.preferences[surface] else {
            return nil
        }
        let current = (
            model: preference.model,
            provider: snapshot.activeProviders[surface]
                ?? routing.inferProviderForModel(preference.model)
                ?? "unknown"
        )
        let currentProvider = current.provider
        guard let providers = try? await routing.listProviders() else {
            return nil
        }

        let choices = providers
            .filter { Self.isSelectableProvider($0, currentProvider: currentProvider) }
            .map { provider in
                let isCurrent = Self.providerIdsMatch(provider.id, currentProvider)
                var models = Self.modelChoices(
                    from: provider,
                    currentModel: current.model,
                    isCurrentProvider: isCurrent
                )
                if CodexSelectableModelCatalog.isAccountBackedProvider(provider.id) {
                    var seen = Set(models.map(\.id))
                    let isDirectOAuth = provider.id == "openai_oauth_direct"
                    let cacheURL = isDirectOAuth
                        ? CodexSelectableModelCatalog.chatGPTOAuthCacheCandidate(
                            dataRoot: dataRoot
                        )
                        : nil
                    let discovered = CodexSelectableModelCatalog.load(
                        providerID: provider.id,
                        cacheURL: cacheURL,
                        useDefaultCacheWhenNil: !isDirectOAuth
                    ).compactMap { model -> TelegramModelChoice? in
                        guard seen.insert(model.id).inserted else { return nil }
                        return TelegramModelChoice(
                            id: model.id,
                            name: model.displayName,
                            isCurrent: isCurrent && model.id == current.model,
                            supportedReasoningEfforts: model.supportedReasoningEfforts,
                            supportsFast: model.supportsFast
                        )
                    }
                    models = discovered + models
                }
                if isCurrent,
                   !models.contains(where: { $0.id == current.model }) {
                    let descriptor = FirstPartyModelCatalog.descriptor(
                        for: current.model,
                        providerID: provider.id
                    )
                    models.insert(
                        TelegramModelChoice(
                            id: current.model,
                            name: current.model,
                            isCurrent: true,
                            supportedReasoningEfforts: descriptor?.supportedReasoningEfforts ?? [],
                            supportsFast: descriptor?.supportsFast ?? false
                        ),
                        at: 0
                    )
                }
                return TelegramModelProviderChoice(
                    id: provider.id,
                    displayName: provider.displayName ?? Self.displayName(for: provider.id),
                    isCurrent: isCurrent,
                    models: models
                )
            }
            .filter { !$0.models.isEmpty }

        return TelegramModelMenu(
            surface: surface,
            currentModel: current.model,
            currentProvider: currentProvider,
            providers: choices
        )
    }

    static func providerIdsMatch(_ lhs: String, _ rhs: String) -> Bool {
        normalizeProviderId(lhs) == normalizeProviderId(rhs)
    }

    private static func normalizeProviderId(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "xai", "xai_oauth_direct", "xai-oauth", "grok-oauth", "x-ai-oauth", "xai-grok-oauth":
            return "xai_oauth_direct"
        case "moonshot", "kimi":
            return "moonshot"
        default:
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    private static func isSelectableProvider(_ provider: Provider, currentProvider: String) -> Bool {
        if provider.id == "codex" { return true }
        if providerIdsMatch(provider.id, currentProvider) { return true }
        if provider.configured == true || provider.active == true { return true }
        if case .object(let obj)? = provider.oauthStatus,
           case .string(let state)? = obj["state"],
           state == "ready" {
            return true
        }
        if case .object(let extras)? = provider.extras,
           case .object(let status)? = extras["auth_status"],
           case .string(let state)? = status["state"],
           state == "ready" {
            return true
        }
        return false
    }

    private static func modelChoices(
        from provider: Provider,
        currentModel: String,
        isCurrentProvider: Bool
    ) -> [TelegramModelChoice] {
        var out: [TelegramModelChoice] = []
        var seen: Set<String> = []
        for object in modelObjects(from: provider) {
            guard let id = firstString(object, keys: ["id", "model_id", "model"]),
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            let name = firstString(object, keys: ["name", "display_name", "displayName"]) ?? id
            if seen.insert(id).inserted {
                out.append(TelegramModelChoice(
                    id: id,
                    name: name,
                    isCurrent: isCurrentProvider && id == currentModel,
                    supportedReasoningEfforts: stringArray(
                        object,
                        keys: ["supported_reasoning_efforts", "supportedReasoningEfforts"]
                    ),
                    supportsFast: firstBool(
                        object,
                        keys: ["supports_fast", "supportsFast"]
                    ) ?? false
                ))
            }
        }
        return out
    }

    private static func modelObjects(from provider: Provider) -> [[String: JSONValue]] {
        if case .array(let items)? = provider.modelCatalog {
            let models = items.compactMap { item -> [String: JSONValue]? in
                guard case .object(let obj) = item else { return nil }
                return obj
            }
            if !models.isEmpty { return models }
        }
        if case .object(let extras)? = provider.extras,
           case .array(let items)? = extras["models"] {
            return items.compactMap { item in
                guard case .object(let obj) = item else { return nil }
                return obj
            }
        }
        return []
    }

    private static func firstString(
        _ object: [String: JSONValue],
        keys: [String]
    ) -> String? {
        for key in keys {
            guard let value = object[key] else { continue }
            switch value {
            case .string(let str):
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            case .int(let int):
                return String(int)
            case .double(let double):
                return String(double)
            case .bool(let bool):
                return bool ? "true" : "false"
            case .null, .array, .object:
                continue
            }
        }
        return nil
    }

    private static func stringArray(
        _ object: [String: JSONValue],
        keys: [String]
    ) -> [String] {
        for key in keys {
            guard case .array(let values)? = object[key] else { continue }
            return values.compactMap { value in
                guard case .string(let string) = value else { return nil }
                return string
            }
        }
        return []
    }

    private static func firstBool(
        _ object: [String: JSONValue],
        keys: [String]
    ) -> Bool? {
        for key in keys {
            guard case .bool(let value)? = object[key] else { continue }
            return value
        }
        return nil
    }

    private static func displayName(for providerId: String) -> String {
        switch normalizeProviderId(providerId) {
        case "anthropic": return "Anthropic"
        case "openai": return "ChatGPT / OpenAI"
        case "codex": return "Codex CLI"
        case "xai": return "xAI Grok"
        case "moonshot": return "Moonshot AI (Kimi)"
        case "openrouter": return "OpenRouter"
        default: return providerId.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

}

struct TelegramMemoryWriterBridge: TelegramMemoryWriteRef, Sendable {
    let dataRoot: URL
    let memory: SwiftNativeMemoryV2

    init(
        dataRoot: URL,
        memory: SwiftNativeMemoryV2? = nil
    ) {
        self.dataRoot = dataRoot
        if let memory {
            self.memory = memory
        } else {
            self.memory = SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
        }
    }

    func remember(text: String, source: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TelegramBotError.invalidRequest }
        let record = try await memory.store(
            content: trimmed,
            source: source,
            metadata: .object([
                "surface": .string("telegram"),
                "command": .string("/remember"),
            ])
        )
        return record.id
    }

    func note(text: String, kind: String, source: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TelegramBotError.invalidRequest }
        let resolvedKind = kind.isEmpty ? "telegram_note" : kind
        let record = try await memory.store(
            content: trimmed,
            source: source,
            metadata: .object([
                "note_kind": .string(resolvedKind),
                "tags": .array([.string("telegram")]),
                "confidence": .double(0.8),
                "importance": .double(0.5),
                "surface": .string("telegram"),
                "command": .string("/note"),
            ])
        )
        return record.id
    }
}

// MARK: - TelegramRestartBridge (2026-06-10)
//
// Routes the owner-gated /restart into AppRestartCoordinator — the SAME
// core routine the chat `restart_app` tool dispatches through, so cooldown
// stamp, audit trail, relauncher, and grace-period terminate exist exactly
// once. The TelegramBot module can't see AppKit; this bridge is the
// injection point, mirroring TelegramMemoryWriterBridge.
private struct TelegramRestartBridge: TelegramRestartRef, Sendable {
    let dataRoot: URL

    func ownerChatIds() async -> Set<Int64> {
        // Owner = the on-disk Telegram allowlist. Re-read per call (not
        // cached at assembly) so an allowlist edit takes effect without an
        // app restart. Empty/missing config fails the gate closed.
        TelegramBot.TelegramConfig.loadFromDisk(dataRoot: dataRoot)?.allowedChatIds ?? []
    }

    func requestRestart(reason: String) async -> TelegramRestartOutcome {
        // Deferred-terminate variant (blocker fix 2026-06-10): the
        // coordinator commits the restart (cooldown → audit → stamp →
        // relauncher) but does NOT arm termination here. The armTerminate
        // closure rides back to the poll loop, which invokes it AFTER the
        // reply send attempt instead of racing sendMessage against the app
        // termination timer.
        let (envelope, armTerminate) = await AppRestartCoordinator.shared
            .requestRestartDeferringTerminate(
                reason: reason,
                source: "telegram:/restart"
            )
        guard case .object(let obj) = envelope else {
            return TelegramRestartOutcome(
                reply: "Restart failed: unexpected coordinator response.",
                armTerminate: armTerminate
            )
        }
        func str(_ key: String) -> String? {
            if case .string(let s)? = obj[key] { return s }
            return nil
        }
        if str("status") == "restarting" {
            return TelegramRestartOutcome(
                reply: "Restarting NativeAgent — back in under a minute. \(str("note") ?? "")",
                armTerminate: armTerminate
            )
        }
        if str("reason") == "cooldown" {
            let retry: String = {
                if case .double(let n)? = obj["retryAfterSeconds"] { return String(Int(n)) }
                return "?"
            }()
            return TelegramRestartOutcome(
                reply: "Restart refused: a tool-initiated restart fired within the last 10 minutes. Retry in \(retry)s.",
                armTerminate: armTerminate
            )
        }
        return TelegramRestartOutcome(
            reply: "Restart failed: \(str("reason") ?? "unknown"). \(str("detail") ?? "")",
            armTerminate: armTerminate
        )
    }
}
