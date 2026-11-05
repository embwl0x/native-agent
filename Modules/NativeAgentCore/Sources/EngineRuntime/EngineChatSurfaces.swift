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
// Blueprint: | `EngineChatSurfaces.swift` | Slack and Telegram ingress; speech permission episodes use the body attention port |

extension NativeAgentEngine {
    public static let telegramUnconfiguredReason =
        "telegram not configured (no enabled bot token in telegram/config.json)"

    public static func makeSlackSocketModeLane(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> LoopRegistration {
        do {
            return try SlackSocketModeLoop.ifConfigured(
                dataRoot: dataRoot,
                chatClient: { _ in NativeAgentEngine.live.chatClient(profile: .slack) },
                // Reply delivery does not wait for the Mac UI to reload.
                turnCompleted: { sessionID in
                    Task { @MainActor in
                        NotificationCenter.default.post(name: .chatTurnCompleted, object: sessionID)
                    }
                },
                botEventIntake: { channelId, text, userId, eventId in
                    try await BotEventIntake.slackMessage(channelId: channelId, text: text,
                                                     userId: userId, eventId: eventId, dataRoot: dataRoot,
                                                     isAutonomyEnabled: {
                        await UnattendedWork.allowed(dataRoot: dataRoot)
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

    /// Unreadable credentials are unavailable; missing or disconnected settings are off.
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
        // Resolve `providers/surfaces.json` at handler time so every surface’s setting affects the next turn without a restart.
        let providerRouting = SwiftNativeProviderRouting(dataRoot: dataRoot)
        let telegramSessions = TelegramSessionStore(dataRoot: dataRoot)
        let approvalFiler = TelegramApprovalFiler(
            dataRoot: dataRoot,
            token: cfg.botToken,
            promptSender: { token, chatId, approval, toolName, payload in
                try await TelegramApprovalFiler.sendTelegramApprovalPrompt(
                    token: token, chatId: chatId, approval: approval,
                    toolName: toolName, payload: payload,
                    send: TelegramPollLoop.defaultSendMessageWithReplyMarkupReturningId
                )
            },
            approvalResolver: { id, decision, provenance in
                _ = try await NativeAgentEngine.live.ports.backgroundWork.approvals.resolveApproval(
                    id: id, decision: decision.rawValue, provenance: provenance, turn: provenance.resolvingTurn
                )
            }
        )
        ApprovalChatCards.useTelegram(approvalFiler)
        // Retain the profile, filer and stateless graph for the loop lifetime; resolve routing and policy for each turn.
        let client = NativeAgentEngine.live.chatClient(
            profile: .telegram,
            approvalFiler: approvalFiler
        )
        let telegramFace: PartFaces.Call = { id, input, version in
            do {
                return try await NativeAgentEngine.forRoot(dataRoot).tools.withPartDoor(envelope: .native("telegram:projection:" + id)) { door in
                    await Parts(root: dataRoot).face(id: id, input: input, version: version, invocation: door.invocation)
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
                        turn: nil, reason: reason,
                        source: "telegram:/restart"
                    )
                })
            ),
            partCall: { id, input, turn in
                guard let envelope = turn.envelope, envelope.surface == "telegram", envelope.workIdentity != nil else {
                    return .failure(.init(code: "unavailable", message: "The Telegram command has no authenticated originating update."))
                }
                do {
                    return try await NativeAgentEngine.forRoot(dataRoot).tools.withPartDoor(envelope: envelope, turn: turn) { door in
                        await Parts(root: dataRoot).call(id: id, input: input, invocation: door.invocation, as: JSONValue.self)
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
            // Turn ownership handles memory promotion; Telegram completion must not wait for optional background work.
            voiceTranscriber: makeTelegramVoiceTranscriber(cfg: cfg, dataRoot: dataRoot),
            onCapabilityDenied: { capability in
                await fileSystemPermissionNotice(capability: capability, dataRoot: dataRoot)
            },
            voiceMaxBytes: cfg.voiceMaxBytes
        )
    }

    public static func fileSystemPermissionNotice(capability: String, dataRoot: URL) async {
        // Request undecided speech access directly; only refusal needs Settings.
        if capability == "speechRecognition",
           await NativeAgentEngine.live.ports.backgroundWork.requestSpeechPermissionIfNotDetermined().isGranted {
            await retireSystemPermissionCardIfGranted(dataRoot: dataRoot)
            return
        }
        await ChatSurfaceBackgroundWork.fileSystemPermissionNotice(
            capability: capability, dataRoot: dataRoot,
            permissionStatus: { NativeAgentEngine.live.ports.backgroundWork.speechPermission },
            assistanceCard: { try await EngineBackgroundWorkPort().assistanceCard(dataRoot: dataRoot, input: $0) },
            notifications: EngineBackgroundWorkPort())
    }

    public static func retireSystemPermissionCardIfGranted(dataRoot: URL) async {
        await ChatSurfaceBackgroundWork.retireSystemPermissionCardIfGranted(
            dataRoot: dataRoot,
            permissionStatus: { NativeAgentEngine.live.ports.backgroundWork.speechPermission })
    }

    /// Choose the transcription backend once at assembly, preserving shared error and permission-card handling for every voice note.
    public static func makeTelegramVoiceTranscriber(
        cfg: TelegramBot.TelegramConfig,
        dataRoot: URL
    ) -> SwiftAppleSpeechTranscriber? {
        guard cfg.voiceTranscriptionEnabled else { return nil }
        return SwiftAppleSpeechTranscriber(contextualStrings: { [NativeAgentEngine.live.ports.backgroundWork.voiceName] })
    }

}
