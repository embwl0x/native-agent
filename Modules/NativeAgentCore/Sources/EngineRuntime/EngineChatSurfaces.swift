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
import ChatToolParsing
import MacControl
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import SlackBot
import StandingBots
import TelegramBot
import ToolExecution
// Blueprint: | `EngineChatSurfaces.swift` | Slack and Telegram ingress; speech permission episodes use the body attention port |

extension NativeAgentEngine {
    /// A matter's row as the Inbox draws it now, read again first: nil when the face drew without it; thrown with the face's own cause
    /// when it did not draw.
    @MainActor func inboxRow(_ matter: String) async throws -> PartFace.Row? {
        let snapshot = await pages.refresh(page: "inbox")
        guard let face = snapshot?.drawnFace else {
            throw snapshot?.error ?? PartCallError(code: "inbox_unread", message: "The Inbox has not been read yet.")
        }
        return face.sections.flatMap(\.allRows).first { $0.id == matter }
    }

    public static let telegramUnconfiguredReason =
        "telegram not configured (no enabled bot token in telegram/config.json)"

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
            promptSender: { token, chatId, approval, buttons in
                try await TelegramApprovalFiler.sendTelegramApprovalPrompt(
                    token: token, chatId: chatId, approval: approval, buttons: buttons,
                    send: TelegramPollLoop.defaultSendConsentWithReplyMarkupReturningId
                )
            },
            // A Telegram card is its matter's Inbox row: drawn from the Inbox as it reads now, answered by the row's own call.
            inbox: TelegramInboxDoor(row: { matter in try await NativeAgentEngine.live.inboxRow(matter) },
                act: { matter, action, chat, sender in
                    try await NativeAgentEngine.live.pages.act(page: "inbox", row: matter, action: action, door: TelegramApprovalFiler.door,
                                                               device: sender, chat: chat)
                })
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
                routing: TelegramProviderRoutingBridge(routing: providerRouting, dataRoot: dataRoot, choose: { setting, value, turn in
                    // The verified command is the person's exact Providers call, under its original update/callback identity.
                    let sender = try TelegramCommandSender(turn: turn, dataRoot: dataRoot)
                    try sender.requireOwner()
                    guard let envelope = sender.turn.envelope else { throw TelegramBotError.invalidRequest }
                    let input: [String: JSONValue] = ["action": .string("provider.choose"),
                        "args": .object(["group": .string("chat"), "setting": .string(setting), "value": value])]
                    let act = PersonAct(by: .tap(door: "telegram", device: envelope.verifiedUserId,
                        chat: envelope.verifiedChatId, page: "providers", row: "providers.chat_" + setting), tool: "app", input: input)
                    let decided = sender.turn.with(\.personAct, act)
                    let reply = try await NativeAgentEngine.forRoot(dataRoot).tools.withPartDoor(envelope: envelope,
                        fileAccess: sender.turn.fileAccess ?? "auto",
                        turn: decided, traced: true) { door in try await door.perform("app", input) }
                    let result = ToolResult(reply)
                    if result.outcome != .succeeded || result.carriesFailureEvidence {
                        throw TelegramBotError.underlying(ChatToolOutcome.explanation(reply)
                            ?? "The Providers choice did not complete. Read Providers before another change.")
                    }
                }),
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
