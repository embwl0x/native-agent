import BackgroundWork
import StandingBots
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
import SlackBot
import ApprovalInbox
import ApprovalTransactions
import Cognition
import WorkshopExecution
import TrustCenter
import MacControl
import SelfImprovement
import NotificationInbox
import DeviceSync

// MARK: - Chat Surface Loops

extension BackgroundLoopsAssembly {
    static func makeSlackSocketModeLoopIfConfigured(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> SlackSocketModeLoop? {
        SlackSocketModeLoop.ifConfigured(
            dataRoot: dataRoot,
            chatClient: { NativeAgentEngine.live.chatClient(profile: .slack) },
            // 2026-09-22: fire-and-forget — the reply must not wait on a busy
            // main thread just to tell the Mac UI to reload.
            turnCompleted: { sessionID in
                Task { @MainActor in
                    NotificationCenter.default.post(name: .chatTurnCompleted, object: sessionID)
                }
            },
            botEventIntake: { channelId, text, userId in
                await BotEventIntake.slackMessage(channelId: channelId, text: text,
                                                 userId: userId, dataRoot: dataRoot,
                                                 isAutonomyEnabled: {
                    await BackgroundLoopsAssembly.unattendedWorkAllowed(dataRoot: dataRoot)
                })
            }
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
        let approvalFiler = TelegramApprovalFiler(
            dataRoot: dataRoot,
            token: cfg.botToken,
            promptSender: { token, chatId, approval, toolName, payload in
                try await TelegramApprovalFiler.sendTelegramApprovalPrompt(
                    token: token, chatId: chatId, approval: approval,
                    toolName: toolName, payload: payload,
                    send: TelegramPollLoop.defaultSendMessageWithReplyMarkup
                )
            },
            approvalResolver: { id, decision, provenance in
                _ = try await NativeClient().resolveApproval(
                    id: id, decision: decision.rawValue, provenance: provenance
                )
            }
        )
        TelegramApprovalFilerRef.shared.configure(approvalFiler)
        Task { await ApprovalChatCards.promptPending(dataRoot: dataRoot, telegram: approvalFiler) }
        // Keep the exact Telegram profile and approval filer resident for the
        // loop lifetime. Routing/policy remain per-turn snapshots; only the
        // stateless orchestration graph and schema caches are reused.
        let client = NativeAgentEngine.live.chatClient(
            profile: .telegram,
            approvalFiler: approvalFiler
        )
        let telegramBot = SwiftNativeTelegramBot(
            dataRoot: dataRoot,
            completenessDeps: TelegramBotCompletenessDeps(
                routing: TelegramProviderRoutingBridge(
                    routing: providerRouting,
                    dataRoot: dataRoot,
                    accountCatalog: TelegramAccountModelCatalogPort(
                        isAccountBackedProvider: { CodexSelectableModelCatalog.isAccountBackedProvider($0) },
                        chatGPTOAuthCacheCandidate: { CodexSelectableModelCatalog.chatGPTOAuthCacheCandidate(dataRoot: $0) },
                        load: { provider, cacheURL, useDefaultCacheWhenNil in
                            CodexSelectableModelCatalog.load(
                                providerID: provider,
                                cacheURL: cacheURL,
                                useDefaultCacheWhenNil: useDefaultCacheWhenNil
                            ).map { model in
                                TelegramModelChoice(
                                    id: model.id,
                                    name: model.displayName,
                                    isCurrent: false,
                                    supportedReasoningEfforts: model.supportedReasoningEfforts,
                                    supportsFast: model.supportsFast
                                )
                            }
                        }
                    )
                ),
                memory: TelegramMemoryWriterBridge(dataRoot: dataRoot),
                restart: TelegramRestartBridge(dataRoot: dataRoot, deferredRestart: { reason in
                    await AppRestartCoordinator.shared.requestRestartDeferringTerminate(
                        reason: reason,
                        source: "telegram:/restart"
                    )
                })
            ),
            compactionHandler: { sessionId in
                let model = await providerRouting.modelStringForSurface("compaction") ?? ""
                let outcome = try await client.compactSession(
                    sessionId: sessionId,
                    model: model,
                    surface: "telegram",
                    force: true
                )
                if outcome.compacted {
                    Task { @MainActor in
                        NotificationCenter.default.post(name: .chatTurnCompleted, object: sessionId)
                    }
                }
                return outcome
            }
        )
        let handler = ChatSurfaceBackgroundWork.makeTelegramChatHandler(
            dataRoot: dataRoot,
            telegramSessions: telegramSessions,
            client: client,
            turnCompleted: { sessionID in
                Task { @MainActor in
                    NotificationCenter.default.post(name: .chatTurnCompleted, object: sessionID)
                }
            }
        )
        return TelegramPollLoop(
            interval: 0.25,
            token: cfg.botToken,
            revokeDriverControl: { await MacAttentionSessionStore.shared.revokeDriverControl() },
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
            deleteMessage: TelegramPollLoop.defaultDeleteMessage,
            syncCommandMenu: TelegramPollLoop.defaultSyncCommandMenu,
            approvalHandler: approvalFiler,
            attachmentChatHandler: handler,
            // Memory promotion already runs under the turn engine's ownership.
            // Telegram completion must not wait for this optional background work.
            voiceTranscriber: makeTelegramVoiceTranscriber(cfg: cfg, dataRoot: dataRoot),
            onCapabilityDenied: { capability in
                await fileSystemPermissionNotice(capability: capability, dataRoot: dataRoot)
            },
            voiceMaxBytes: cfg.voiceMaxBytes
        )
    }

    static func fileSystemPermissionNotice(
        capability: String,
        dataRoot: URL,
        permissionStatus: @escaping @Sendable () -> SystemPermissionStatus = {
            SystemPermissionPreflight.status(.speechRecognition)
        }
    ) async {
        await ChatSurfaceBackgroundWork.fileSystemPermissionNotice(
            capability: capability,
            dataRoot: dataRoot,
            permissionStatus: { speechPermissionSnapshot(permissionStatus()) },
            notify: { root, id, title, summary, source, severity in
                await InboxPushNotifier.notifyIfAttentionWorthy(
                    dataRoot: root, itemId: id, title: title, summary: summary,
                    source: source, severity: severity
                )
            }
        )
    }

    static func retireSystemPermissionCardIfGranted(
        dataRoot: URL,
        permissionStatus: @escaping @Sendable () -> SystemPermissionStatus = {
            SystemPermissionPreflight.status(.speechRecognition)
        }
    ) async {
        await ChatSurfaceBackgroundWork.retireSystemPermissionCardIfGranted(
            dataRoot: dataRoot,
            permissionStatus: { speechPermissionSnapshot(permissionStatus()) }
        )
    }

    private static func speechPermissionSnapshot(_ status: SystemPermissionStatus) -> SpeechPermissionSnapshot {
        SpeechPermissionSnapshot(
            rawValue: status.rawValue,
            isGranted: status == .granted,
            warningSummary: SystemPermissionPreflight.warningSummary(for:
                SystemPermissionSnapshot(capability: .speechRecognition, status: status)),
            settingsLink: SystemPermissionPreflight.settingsURL(for: .speechRecognition)?.absoluteString
        )
    }

    /// The Telegram surface's one transcriber factory. Keeping this at the
    /// assembly boundary means the config chooses a backend once, while each
    /// inbound voice note still executes through the shared poll-loop error and
    /// permission-card path.
    static func makeTelegramVoiceTranscriber(
        cfg: TelegramBot.TelegramConfig,
        dataRoot: URL
    ) -> (any TelegramVoiceTranscribing)? {
        guard cfg.voiceTranscriptionEnabled else { return nil }
        return SwiftAppleSpeechTranscriber(contextualStrings: { [AgentVoice.live.name] })
    }

}

/// The running Telegram loop's approval filer, so an approval follow-up on
/// Telegram files its cards with the same inline buttons (Wave 2 #8).
final class TelegramApprovalFilerRef: @unchecked Sendable {
    static let shared = TelegramApprovalFilerRef()
    private let lock = NSLock()
    private var filer: TelegramApprovalFiler?

    func configure(_ filer: TelegramApprovalFiler) {
        lock.withLock { self.filer = filer }
        ApprovalChatCards.useTelegram(filer)
    }
    func current() -> TelegramApprovalFiler? { lock.withLock { filer } }
}
