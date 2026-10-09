import Agents
import AttentionRouting
import ChatOrchestration
import CognitiveSubstrate
import CryptoKit
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import SlackConnector
import TelegramBot
import DeviceSync
import Transcripts

struct LiveAgentBridgeCompletionSender: AgentBridgeCompletionSending {
  let authorizeTelegramReply: (@Sendable (TelegramConfig, Int) -> Bool)?

  enum DeliveryError: LocalizedError {
    case telegramNotConfigured
    case telegramReplyNotAuthorized
    case telegramTransport(String)
    case invalidTelegramDestination
    case invalidTelegramThread(String)
    case missingSlackDestination
    case missingIOSSourceKey
    case slackRejected(String)
    case emptyCompletion
    case notificationNotAccepted

    var errorDescription: String? {
      switch self {
      case .telegramNotConfigured: return "Telegram is not enabled or has no bot token."
      case .telegramReplyNotAuthorized: return "The originating Telegram reply is no longer authorized."
      case .telegramTransport(let detail): return detail
      case .invalidTelegramDestination:
        return "The originating Telegram chat id is missing or invalid."
      case .invalidTelegramThread(let raw):
        return "The originating Telegram topic id is not a number: \(raw)"
      case .missingSlackDestination: return "The originating Slack channel id is missing."
      case .missingIOSSourceKey: return "The originating iOS device route key is missing."
      case .slackRejected(let detail): return "Slack rejected the completion: \(detail)"
      case .emptyCompletion: return "The agent produced no completion text or attachment."
      case .notificationNotAccepted: return "The requested result has not been accepted for phone delivery."
      }
    }
  }

  let dataRoot: URL
  /// Telegram text lands without a sound or alert (context, not a ping).
  let silentTelegram: Bool

  init(dataRoot: URL = PersistenceCore.defaultDataRoot(),
       silentTelegram: Bool = false,
       authorizeTelegramReply: (@Sendable (TelegramConfig, Int) -> Bool)? = nil) {
    self.dataRoot = dataRoot
    self.silentTelegram = silentTelegram
    self.authorizeTelegramReply = authorizeTelegramReply
  }

  func refreshLocalChat(sessionId: String?) async {
    await MainActor.run {
      NotificationCenter.default.post(name: .chatTurnCompleted, object: sessionId)
    }
  }

  func preflight(
    surface: String,
    route: AgentBridgeCompletionRoute,
    artifacts: [AgentBridgeCompletionArtifact]
  ) async throws {
    guard !artifacts.isEmpty else { throw DeliveryError.emptyCompletion }
    for artifact in artifacts {
      try AgentBridgeCompletionRouter.validateAttachmentExpectations(
        artifact.attachmentExpectations
      )
      if case .iosBundle(_, let attachments, _) = artifact.payload {
        _ = try Self.mobileAttachments(attachments)
      }
    }
    if artifacts.allSatisfy({ if case .iosNotification = $0.payload { return true }; return false }) { return }
    switch surface {
    case "caller-result":
      _ = try await NativeAgentEngine.live.agents.tasks.callerResultTarget(route)
    case "telegram":
      guard let config = TelegramBot.TelegramConfig.loadFromDisk(dataRoot: dataRoot),
            config.enabled, !config.botToken.isEmpty else {
        throw DeliveryError.telegramNotConfigured
      }
      guard let rawChatId = route.destinationId, let chatId = Int(rawChatId) else {
        throw DeliveryError.invalidTelegramDestination
      }
      if let authorizeTelegramReply, !authorizeTelegramReply(config, chatId) {
        throw DeliveryError.telegramReplyNotAuthorized
      }
    case "slack":
      guard let channel = route.destinationId, !channel.isEmpty else {
        throw DeliveryError.missingSlackDestination
      }
      try SlackConnectorActions.requireConfiguredToken(dataRoot: dataRoot)
    case "ios", "iphone", "mobile", "icloud":
      guard let sourceKey = route.sourceKey,
            AgentBridgeCompletionRouter.isValidIOSDeviceRouteKey(sourceKey) else {
        throw DeliveryError.missingIOSSourceKey
      }
    default:
      break
    }
  }

  func send(
    artifact: AgentBridgeCompletionArtifact,
    idempotencyKey: String,
    surface: String,
    route: AgentBridgeCompletionRoute
  ) async -> AgentBridgeTransportResult {
    do {
      try AgentBridgeCompletionRouter.validateAttachmentExpectations(
        artifact.attachmentExpectations
      )
      try await sendThrowing(
        artifact: artifact,
        idempotencyKey: idempotencyKey,
        surface: surface,
        route: route
      )
      return .accepted
    } catch DeliveryError.slackRejected(let detail) {
      return .rejected(reason: "slack_rejected:\(detail)", retryable: false)
    } catch DeliveryError.telegramNotConfigured {
      return .rejected(reason: "telegram_not_configured", retryable: false)
    } catch DeliveryError.telegramReplyNotAuthorized {
      return .rejected(reason: "telegram_reply_not_authorized", retryable: false)
    } catch DeliveryError.telegramTransport(let detail) {
      return .ambiguous(reason: detail)
    } catch DeliveryError.invalidTelegramDestination {
      return .rejected(reason: "invalid_telegram_destination", retryable: false)
    } catch DeliveryError.invalidTelegramThread(let raw) {
      return .rejected(reason: "invalid_telegram_thread:\(raw)", retryable: false)
    } catch DeliveryError.missingSlackDestination {
      return .rejected(reason: "missing_slack_destination", retryable: false)
    } catch DeliveryError.missingIOSSourceKey {
      return .rejected(reason: "missing_ios_source_key", retryable: false)
    } catch DeliveryError.emptyCompletion {
      return .rejected(reason: "empty_completion", retryable: false)
    } catch DeliveryError.notificationNotAccepted {
      return .rejected(reason: "notification_not_accepted", retryable: true)
    } catch {
      return .ambiguous(reason: String(describing: error))
    }
  }

  private func sendThrowing(
    artifact: AgentBridgeCompletionArtifact,
    idempotencyKey: String,
    surface: String,
    route: AgentBridgeCompletionRoute
  ) async throws {
    if case .iosNotification(_, let deliveryID) = artifact.payload {
      guard try await AttentionRouter.shared.deliverRequestedResult(
        deliveryID: deliveryID, sessionID: route.turnSessionId ?? route.sessionId,
        opening: route.turnSessionId == nil ? nil : route.sessionId, dataRoot: dataRoot
      ) else { throw DeliveryError.notificationNotAccepted }
      return
    }
    switch surface {
    case "caller-result":
      let part: AgentContactPart
      switch artifact.payload {
      case .text(let text): part = .text(text)
      case .attachment(let attachment):
        part = try AgentContactPart.output(attachment, taskID: "na3.\(route.threadId ?? "").\(route.correlationId ?? "")")
      case .iosBundle, .iosNotification: throw DeliveryError.emptyCompletion
      }
      try await NativeAgentEngine.live.agents.tasks.appendCallerResult(part, artifactID: idempotencyKey, route: route)
    case "telegram":
      guard let config = TelegramBot.TelegramConfig.loadFromDisk(dataRoot: dataRoot),
            config.enabled, !config.botToken.isEmpty else {
        throw DeliveryError.telegramNotConfigured
      }
      guard let rawChatId = route.destinationId, let chatId = Int(rawChatId) else {
        throw DeliveryError.invalidTelegramDestination
      }
      // Check the configuration used for this send, including each attachment.
      if let authorizeTelegramReply, !authorizeTelegramReply(config, chatId) {
        throw DeliveryError.telegramReplyNotAuthorized
      }
      // 2026-09-06: a completion answers in the forum topic its turn came
      // from. The route already carries that thread (Slack uses the same field
      // for thread_ts); without it the reply landed in General.
      //
      // 2026-09-06: a thread id that is present but not a number is a broken
      // route, not an instruction to answer the whole chat. Converting it to
      // nil published the topic's reply — approvals and tool output included —
      // into the supergroup's General for everyone to read.
      let rawThreadId = route.threadId?.trimmingCharacters(in: .whitespacesAndNewlines)
      var threadId: Int?
      if let rawThreadId, !rawThreadId.isEmpty {
        guard let parsed = Int(rawThreadId) else {
          throw DeliveryError.invalidTelegramThread(rawThreadId)
        }
        threadId = parsed
      }
      let destination = TelegramDestination(chatId: chatId, threadId: threadId)
      do {
        switch artifact.payload {
        case .text(let text):
          let send = silentTelegram ? TelegramPollLoop.defaultSendSilentMessage : TelegramPollLoop.defaultSendMessage
          try await send(config.botToken, destination, TelegramPollLoop.cleanedPlainText(text))
        case .attachment(let attachment):
          guard let path = attachment.path else { throw DeliveryError.emptyCompletion }
          try await TelegramPollLoop.defaultSendPhoto(
            config.botToken,
            destination,
            path,
            attachment.name
          )
        case .iosBundle, .iosNotification:
          throw DeliveryError.emptyCompletion
        }
      } catch let error as DeliveryError {
        throw error
      } catch {
        // Scrub the exact credential used by this send, even if it is malformed.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encodedToken = config.botToken.addingPercentEncoding(withAllowedCharacters: allowed) else {
          throw DeliveryError.telegramTransport("Telegram delivery failed; bot token could not be encoded for redaction.")
        }
        let detail = String(describing: error)
          .replacingOccurrences(of: config.botToken, with: "[REDACTED_TELEGRAM_TOKEN]")
          .replacingOccurrences(of: encodedToken, with: "[REDACTED_TELEGRAM_TOKEN]")
        throw DeliveryError.telegramTransport(TurnSecretRedactor.redactText(detail))
      }
    case "slack":
      guard let channel = route.destinationId, !channel.isEmpty else {
        throw DeliveryError.missingSlackDestination
      }
      switch artifact.payload {
      case .text(let text):
        var input: [String: JSONValue] = [
          "channel": .string(channel),
          "text": .string(text),
        ]
        if let threadId = route.threadId { input["thread_ts"] = .string(threadId) }
        let result = try await SlackConnectorActions.postMessage(
          input: input,
          idempotencyKey: idempotencyKey,
          dataRoot: dataRoot
        )
        try Self.requireSlackAcceptance(result)
      case .attachment(let attachment):
        guard let path = attachment.path else { throw DeliveryError.emptyCompletion }
        var input: [String: JSONValue] = [
          "channel": .string(channel),
          "file_path": .string(path),
          "filename": .string(attachment.name ?? URL(fileURLWithPath: path).lastPathComponent),
        ]
        if let threadId = route.threadId { input["thread_ts"] = .string(threadId) }
        let result = try await SlackConnectorActions.uploadFile(
          input: input,
          dataRoot: dataRoot
        )
        try Self.requireSlackAcceptance(result)
      case .iosBundle, .iosNotification:
        throw DeliveryError.emptyCompletion
      }
    case "ios", "iphone", "mobile", "icloud":
      guard let sourceKey = route.sourceKey, !sourceKey.isEmpty else {
        throw DeliveryError.missingIOSSourceKey
      }
      switch artifact.payload {
      case .iosBundle(let text, let attachments, let fallbackCorrelationId):
        let mobileAttachments = try Self.mobileAttachments(attachments)
        guard !text.isEmpty || !mobileAttachments.isEmpty else {
          throw DeliveryError.emptyCompletion
        }
        let correlationId = route.correlationId ?? fallbackCorrelationId
        try await Task { @MainActor in
          _ = try await NativeAgentEngine.liveDeviceSync.bridge.sendChatMessage(
            text: text,
            sessionID: route.sessionId,
            correlationID: correlationId,
            metadata: [
              "kind": "codex_completion",
              "transport": "icloud",
              "source": "mac",
              "replyTo": route.replyTo ?? "iphone",
              "targetSourceKey": sourceKey,
            ],
            attachments: mobileAttachments,
            messageID: idempotencyKey
          )
        }.value
      case .iosNotification:
        throw DeliveryError.emptyCompletion
      case .text, .attachment:
        throw DeliveryError.emptyCompletion
      }
    default:
      return
    }
  }

  private static func mobileAttachments(
    _ attachments: [ChatOrchestration.MultimodalAttachment]
  ) throws -> [NativeAgentShared.MultimodalAttachment] {
    let converted: [NativeAgentShared.MultimodalAttachment] = attachments.compactMap { attachment in
      guard let withData = ChatGeneratedImageArtifacts.imageDataAttachment(from: attachment) else {
        return nil
      }
      return NativeAgentShared.MultimodalAttachment(
        id: withData.id,
        type: withData.type,
        base64: withData.base64,
        mime: withData.mime,
        name: withData.name,
        byteSize: withData.byteSize
      )
    }
    guard converted.count == attachments.count else {
      throw DeliveryError.emptyCompletion
    }
    return converted
  }

  /// Slack's Web API can return HTTP success with `{ "ok": false }`.
  /// Connector actions preserve that semantic failure in their envelope rather
  /// than throwing, so the completion lifecycle must inspect it before writing
  /// an accepted receipt.
  static func requireSlackAcceptance(_ result: JSONValue) throws {
    guard case .object(let object) = result,
          object["ok"] == .bool(true) else {
      let detail: String
      if case .object(let object) = result,
         case .string(let error)? = object["error"],
         !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        detail = error
      } else {
        detail = "api_response_not_ok"
      }
      throw DeliveryError.slackRejected(detail)
    }
  }
}

/// User, 2026-10-01: what is said in the conversation he is in reaches his other
/// doors — and only that conversation. After a turn User started there at the
/// Mac, the phone or Slack (never an agent's, judged by the turn's user row),
/// its reply goes to the Telegram chat bound to that session, and to the phone
/// as a push unless the phone asked. A Telegram turn travels nowhere: Telegram
/// already notifies his phone, and a second push doubled it. User, 2026-10-04:
/// a Mac turn means he is at the Mac, so its Telegram copy lands silently and
/// the phone gets no push, only the transcript snapshot every completion
/// already publishes. It runs off the completion signal, never inside a turn,
/// so no door's stream waits on another.
enum AnchorReplyMirror {
  private static let doors = ["app": "Mac", "chat": "Mac", "ios": "iPhone", "slack": "Slack"]

  static func start(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
    // Replies written before this launch never travel.
    let startedAt = Date()
    NotificationCenter.default.addObserver(forName: .chatTurnCompleted, object: nil, queue: nil) { note in
      guard let sessionId = note.object as? String else { return }
      Task.detached { await mirror(sessionId: sessionId, since: startedAt, dataRoot: dataRoot) }
    }
  }

  private static func mirror(sessionId: String, since startedAt: Date, dataRoot: URL) async {
    guard sessionId == ConversationAnchor.currentSessionId(dataRoot: dataRoot),
          let safeId = NativeAgentChatSessionID.normalizedPathComponent(sessionId),
          let rows = try? await SwiftNativePersistenceCore().readJSONL(
            dataRoot.appendingPathComponent("chat/messages/\(safeId).jsonl")),
          case .object(let reply)? = rows.last(where: {
            if case .object(let row) = $0 { return row["role"] == .string("assistant") }
            return false
          }),
          case .string(let rowId)? = reply["id"],
          case .string(let text)? = reply["content"],
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          case .string(let created)? = reply["createdAt"],
          let createdAt = date(created),
          createdAt >= startedAt,
          case .string(let runId)? = reply["runId"], !runId.isEmpty,
          // Who started the turn is on its USER row: bridge lanes and peers
          // stamp `origin` there, and the reply row carries none of it. No
          // user row of this run (a continuation, a resumed card) is not User.
          case .object(let ask)? = rows.last(where: {
            if case .object(let row) = $0 { return row["role"] == .string("user") && row["runId"] == .string(runId) }
            return false
          }),
          case .object(let metadata)? = ask["metadata"],
          metadata["origin"] == nil,
          metadata[CognitiveMechanicalRowKind.metadataKey] == nil,
          case .object(let envelope)? = metadata["envelope"],
          envelope["agent"] == nil,
          case .string(let surface)? = envelope["surface"],
          let door = doors[surface] else { return }
    let lifecycle = CodexCompletionLifecycle(
      receiptURL: dataRoot.appendingPathComponent("chat/anchor-mirror/receipts.jsonl"),
      ownerInstanceId: CodexCompletionLifecycle.processOwnerInstanceId, dataRoot: dataRoot)
    let deliveryId = "anchor-mirror:\(rowId)"
    let digest = SHA256.hash(data: Data((rowId + "\u{1f}" + text).utf8))
      .map { String(format: "%02x", $0) }.joined()
    // One claim per reply: the many completion signals of one turn mirror once.
    guard (try? await lifecycle.claim(deliveryId: deliveryId, requestDigest: digest, sessionId: sessionId)) == .start
    else { return }
    if door == "Slack" {
      let relay = await MainActor.run { NativeAgentEngine.liveDeviceSync.relay }
      await relay.sendICloudReplyPushNotification(text: text, sessionID: sessionId, correlationID: rowId, kind: "reply")
    }
    let telegram: TelegramDestination
    do {
      guard let destination = try await TelegramSessionStore(dataRoot: dataRoot).outboundDestination(sessionId: sessionId) else { return }
      telegram = destination
    } catch {
      nativeLog("[anchor-mirror] could not resolve Telegram destination: %@", error.localizedDescription)
      return
    }
    do {
      try await lifecycle.cacheResponse(
        ChatOrchestration.ChatResponse(runId: deliveryId, model: "anchor-mirror", output: text, sessionId: sessionId),
        deliveryId: deliveryId, requestDigest: digest)
    } catch {
      nativeLog("[anchor-mirror] could not record reply %@: %@", rowId, error.localizedDescription)
      return
    }
    let delivery = await AgentBridgeCompletionRouter.deliver(
      deliveryId: deliveryId, requestDigest: digest, text: "[\(door)]\n\(text)", attachments: [],
      route: AgentBridgeCompletionRoute(surface: "telegram", sessionId: sessionId,
                                        destinationId: String(telegram.chatId), threadId: telegram.threadId.map(String.init)),
      sender: LiveAgentBridgeCompletionSender(dataRoot: dataRoot, silentTelegram: door == "Mac",
                                              authorizeTelegramReply: { config, chatID in
        TelegramPollLoop.inboundAuthorizationDecision(
          allowedChatIds: config.allowedChatIds, allowedUserIds: config.allowedUserIds,
          chatId: chatID, fromUserId: chatID > 0 ? chatID : nil
        ) == .allowed
      }), lifecycle: lifecycle,
      notifyRequestedResult: false)
    if delivery.status != "completed" {
      nativeLog("[anchor-mirror] Telegram copy of %@ %@: %@", rowId, delivery.status, delivery.reason ?? "")
    }
  }

  private static func date(_ raw: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
  }

}
