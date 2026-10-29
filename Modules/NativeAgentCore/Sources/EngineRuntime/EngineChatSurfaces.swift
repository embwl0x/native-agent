import Foundation
import NativeAgentCore
import AppToolRuntime
import ApprovalTransactions
import AttentionRouting
import AuthoredCapabilities
import BackgroundLoops
import BackgroundWork
import ChatSessionWork
import ChatTurnContracts
import ChatTurnRuntime
import ChatToolRuntime
import MacControl
import PersistenceCore
import ProviderRouting
import SlackBot
import StandingBots
import TelegramBot
import ToolExecution
// Blueprint: | `EngineChatSurfaces.swift` | NativeAgentEngine chat-surface composition: Slack Socket Mode, Telegram polling, approvals, provider choices, speech transcription and permission cards |

extension NativeAgentEngine {
    public static let telegramUnconfiguredReason =
        "telegram not configured (no enabled bot token in telegram/config.json)"

    /// The configured Socket Mode worker, or a visible disabled lane.
    public static func makeSlackSocketModeLane(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> LoopRegistration {
        do {
            return try SlackSocketModeLoop.ifConfigured(
                dataRoot: dataRoot,
                chatClient: { NativeAgentEngine.live.chatClient(profile: .slack) },
                // Reply delivery does not wait for the Mac UI to reload.
                turnCompleted: { sessionID in
                    Task { @MainActor in
                        NotificationCenter.default.post(name: .chatTurnCompleted, object: sessionID)
                    }
                },
                botEventIntake: { channelId, text, userId in
                    await BotEventIntake.slackMessage(channelId: channelId, text: text,
                                                     userId: userId, dataRoot: dataRoot,
                                                     isAutonomyEnabled: {
                        await WorkshopBackgroundWork.unattendedWorkAllowed(dataRoot: dataRoot)
                    })
                }
            ).map(LoopRegistration.enabled) ?? .disabled(
                loopId: "slack_socket_mode",
                reason: SlackSocketModeLoop.offReason(dataRoot: dataRoot)
            )
        } catch {
            return .unreadable(loopId: "slack_socket_mode",
                               error: "could not read the Slack tokens: \(error.localizedDescription)")
        }
    }

    /// Missing or disconnected settings are off; unreadable credentials are unavailable.
    public static func makeTelegramPollLane(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> LoopRegistration {
        do {
            guard let cfg = try TelegramBot.TelegramConfig.loadSavedConfiguration(
                dataRoot: dataRoot, includeDisconnected: false
            ), cfg.enabled, !cfg.botToken.isEmpty else {
                return .disabled(loopId: "telegram_poll", reason: telegramUnconfiguredReason)
            }
            return .enabled(makeTelegramPollLoop(cfg: cfg, dataRoot: dataRoot))
        } catch {
            return .unreadable(loopId: "telegram_poll",
                               error: "could not read the Telegram token: \(error.localizedDescription)")
        }
    }

    private static func makeTelegramPollLoop(
        cfg: TelegramBot.TelegramConfig, dataRoot: URL
    ) -> TelegramPollLoop {
        // Brain state has one owner: providers/surfaces.json. Resolve it at
        // handler time so /model, /think, /fast, Mac settings, and iPhone
        // controls all affect the very next turn without restarting this loop.
        let providerRouting = SwiftNativeProviderRouting(dataRoot: dataRoot)
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
                _ = try await NativeAgentEngine.live.ports.backgroundWork.approvals.resolveApproval(
                    id: id, decision: decision.rawValue, provenance: provenance
                )
            }
        )
        ApprovalChatCards.useTelegram(approvalFiler)
        // Keep the exact Telegram profile and approval filer resident for the
        // loop lifetime. Routing/policy remain per-turn snapshots; only the
        // stateless orchestration graph and schema caches are reused.
        let client = NativeAgentEngine.live.chatClient(
            profile: .telegram,
            approvalFiler: approvalFiler
        )
        let telegramFace: PartFaces.Call = { id, input, version in
            do {
                return try await NativeAgentEngine.forRoot(dataRoot).tools.withPartDoor(envelope: .native("telegram:projection:" + id)) {
                    await Parts(root: dataRoot).face(id: id, input: input, version: version)
                }
            } catch {
                return .failure(.init(code: "unavailable", message: error.localizedDescription))
            }
        }
        let telegramBot = SwiftNativeTelegramBot(
            dataRoot: dataRoot,
            completenessDeps: TelegramBotCompletenessDeps(
                routing: TelegramProviderRoutingBridge(routing: providerRouting),
                memory: TelegramMemoryWriterBridge(dataRoot: dataRoot),
                restart: TelegramRestartBridge(dataRoot: dataRoot, deferredRestart: { reason in
                    await AppRelaunch.shared.requestRestartDeferringTerminate(
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
            },
            partCall: { id, input in
                guard let envelope = ChatToolSessionContext.envelope, envelope.surface == "telegram", envelope.workIdentity != nil else {
                    return .failure(.init(code: "unavailable", message: "The Telegram command has no authenticated originating update."))
                }
                do {
                    return try await NativeAgentEngine.forRoot(dataRoot).tools.withPartDoor(envelope: envelope) {
                        await Parts(root: dataRoot).call(id: id, input: input, as: JSONValue.self)
                    }
                } catch {
                    return .failure(.init(code: "unavailable", message: error.localizedDescription))
                }
            },
            partFace: telegramFace
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
            partFace: telegramFace,
            offsetURL: dataRoot
                .appendingPathComponent("telegram", isDirectory: true)
                .appendingPathComponent("last_offset.json"),
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

    public static func fileSystemPermissionNotice(capability: String, dataRoot: URL) async {
        // Ask for undecided speech permission; only a refusal needs the pane.
        if capability == "speechRecognition",
           await NativeAgentEngine.live.ports.backgroundWork.requestSpeechPermissionIfNotDetermined().isGranted {
            await retireSystemPermissionCardIfGranted(dataRoot: dataRoot)
            return
        }
        await ChatSurfaceBackgroundWork.fileSystemPermissionNotice(
            capability: capability, dataRoot: dataRoot,
            permissionStatus: { NativeAgentEngine.live.ports.backgroundWork.speechPermission },
            assistanceCard: { try await EngineBackgroundWorkPort().assistanceCard(dataRoot: dataRoot, input: $0) },
            notify: { root, id, title, summary, source, severity in
                await NativeAgentEngine.live.ports.backgroundWork.attention.notifyIfAttentionWorthy(
                    dataRoot: root, itemId: id, title: title, summary: summary,
                    source: source, severity: severity)
            })
    }

    public static func retireSystemPermissionCardIfGranted(dataRoot: URL) async {
        await ChatSurfaceBackgroundWork.retireSystemPermissionCardIfGranted(
            dataRoot: dataRoot,
            permissionStatus: { NativeAgentEngine.live.ports.backgroundWork.speechPermission })
    }

    /// The Telegram surface's one transcriber factory. Keeping this at the
    /// assembly boundary means the config chooses a backend once, while each
    /// inbound voice note still executes through the shared poll-loop error and
    /// permission-card path.
    public static func makeTelegramVoiceTranscriber(
        cfg: TelegramBot.TelegramConfig,
        dataRoot: URL
    ) -> SwiftAppleSpeechTranscriber? {
        guard cfg.voiceTranscriptionEnabled else { return nil }
        return SwiftAppleSpeechTranscriber(contextualStrings: { [NativeAgentEngine.live.ports.backgroundWork.voiceName] })
    }

}
