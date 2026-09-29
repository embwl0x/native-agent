import Agents
import ChatOrchestration
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import SlackConnector
import TelegramBot
import DeviceSync

struct LiveAgentBridgeCompletionSender: AgentBridgeCompletionSending {
  let authorizeTelegramReply: (@Sendable (TelegramConfig, Int) -> Bool)?

  enum DeliveryError: LocalizedError {
    case telegramNotConfigured
    case telegramReplyNotAuthorized
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
      case .invalidTelegramDestination:
        return "The originating Telegram chat id is missing or invalid."
      case .invalidTelegramThread(let raw):
        return "The originating Telegram topic id is not a number: \(raw)"
      case .missingSlackDestination: return "The originating Slack channel id is missing."
      case .missingIOSSourceKey: return "The originating iOS device route key is missing."
      case .slackRejected(let detail): return "Slack rejected the completion: \(detail)"
      case .emptyCompletion: return "The agent produced no completion text or attachment."
      case .notificationNotAccepted: return "APNS did not return an acceptance receipt."
      }
    }
  }

  let dataRoot: URL

  init(dataRoot: URL = PersistenceCore.defaultDataRoot(),
       authorizeTelegramReply: (@Sendable (TelegramConfig, Int) -> Bool)? = nil) {
    self.dataRoot = dataRoot
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
    switch surface {
    case "telegram":
      guard let config = TelegramBot.TelegramConfig.loadFromDisk(dataRoot: dataRoot),
            config.enabled, !config.botToken.isEmpty else {
        throw DeliveryError.telegramNotConfigured
      }
      guard let rawChatId = route.destinationId, Int(rawChatId) != nil else {
        throw DeliveryError.invalidTelegramDestination
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
    switch surface {
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
      switch artifact.payload {
      case .text(let text):
        try await TelegramPollLoop.defaultSendMessage(
          config.botToken, destination, TelegramPollLoop.cleanedPlainText(text))
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
      case .iosNotification(let text, let fallbackCorrelationId):
        let correlationId = route.correlationId ?? fallbackCorrelationId
        let accepted = await NativeAgentEngine.liveDeviceSync.relay.sendICloudReplyPushNotification(
          text: text,
          sessionID: route.sessionId,
          correlationID: correlationId,
          kind: "codex_completion"
        )
        if !accepted { throw DeliveryError.notificationNotAccepted }
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
