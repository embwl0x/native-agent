import ChatOrchestration
import CryptoKit
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import SlackConnector
import TelegramBot

struct AgentBridgeCompletionRoute: Sendable, Equatable {
  let surface: String
  let sessionId: String?
  let destinationId: String?
  let threadId: String?
  let sourceKey: String?
  let replyTo: String?
  let correlationId: String?

  init(
    surface: String,
    sessionId: String? = nil,
    destinationId: String? = nil,
    threadId: String? = nil,
    sourceKey: String? = nil,
    replyTo: String? = nil,
    correlationId: String? = nil
  ) {
    self.surface = surface
    self.sessionId = sessionId
    self.destinationId = destinationId
    self.threadId = threadId
    self.sourceKey = sourceKey
    self.replyTo = replyTo
    self.correlationId = correlationId
  }

  init(origin: [String: Any]?, sessionId: String?) {
    func value(_ key: String) -> String? {
      guard let raw = origin?[key] as? String else { return nil }
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    self.init(
      // A completion route is durable authority, not a hint. Missing origin
      // identity must remain missing so delivery fails before any side effect;
      // silently treating corrupt/legacy data as local chat loses the result.
      surface: value("surface") ?? "",
      sessionId: sessionId,
      destinationId: value("destinationId"),
      threadId: value("threadId"),
      sourceKey: value("sourceKey"),
      replyTo: value("replyTo"),
      correlationId: value("correlationId")
    )
  }

  /// Preserve the immutable return route while Agent handles an asynchronous
  /// builder completion. The completion itself still executes on the local
  /// bridge/chat trust surface; this value carries delivery identity only, so
  /// any follow-up `codex_message`/`claude_message` returns to the same
  /// Telegram, Slack, or iOS conversation instead of silently degrading to a
  /// Mac-only reply.
  var chatToolReplyRoute: ChatToolSessionContext.ReplyRoute {
    ChatToolSessionContext.ReplyRoute(
      surface: surface,
      destinationId: destinationId,
      threadId: threadId,
      sourceKey: sourceKey,
      replyTo: replyTo,
      correlationId: correlationId
    )
  }
}

struct AgentBridgeCompletionDelivery: Sendable, Equatable, Codable {
  let status: String
  let surface: String
  let delivery: String
  let artifactCount: Int
  let attempts: Int
  let reason: String?

  var jsonObject: [String: Any] {
    var object: [String: Any] = [
      "status": status,
      "surface": surface,
      "delivery": delivery,
      "artifactCount": artifactCount,
      "attempts": attempts,
    ]
    if let reason { object["reason"] = reason }
    return object
  }
}

struct AgentBridgeCompletionArtifact: Sendable, Equatable {
  struct AttachmentExpectation: Sendable, Equatable {
    let path: String
    let byteSize: Int
    let digest: String
  }

  enum Payload: Sendable, Equatable {
    case text(String)
    case attachment(ChatOrchestration.MultimodalAttachment)
    case iosBundle(String, [ChatOrchestration.MultimodalAttachment], String)
    case iosNotification(String, String)
  }

  let id: String
  let kind: String
  let retrySafe: Bool
  let logicalCount: Int
  let payload: Payload
  let attachmentExpectations: [AttachmentExpectation]
}

enum AgentBridgeTransportResult: Sendable, Equatable {
  case accepted
  /// The transport proved no effect occurred. `retryable` means another
  /// attempt with the same idempotency key is safe.
  case rejected(reason: String, retryable: Bool)
  /// The effect may have occurred. Never retry a non-idempotent artifact.
  case ambiguous(reason: String)
}

protocol AgentBridgeCompletionSending: Sendable {
  func refreshLocalChat(sessionId: String?) async
  func preflight(
    surface: String,
    route: AgentBridgeCompletionRoute,
    artifacts: [AgentBridgeCompletionArtifact]
  ) async throws
  func send(
    artifact: AgentBridgeCompletionArtifact,
    idempotencyKey: String,
    surface: String,
    route: AgentBridgeCompletionRoute
  ) async -> AgentBridgeTransportResult
}

enum AgentBridgeCompletionRouter {
  private enum ValidatedRoute: Equatable {
    case local
    case telegram
    case slack
    case ios
  }

  private struct RouteValidationFailure: Error, Equatable {
    let reason: String
  }

  private static func validatedRoute(
    surface: String,
    route: AgentBridgeCompletionRoute
  ) -> Result<ValidatedRoute, RouteValidationFailure> {
    switch surface {
    case "chat", "mac", "codex", "codex-bridge", "codex_bridge", "claude-bridge",
         "github-command", "mission", "missions", "workshop":
      return .success(.local)
    case "telegram":
      guard let destination = route.destinationId, Int(destination) != nil else {
        return .failure(RouteValidationFailure(reason: "invalid_telegram_destination"))
      }
      return .success(.telegram)
    case "slack":
      guard let destination = route.destinationId?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !destination.isEmpty else {
        return .failure(RouteValidationFailure(reason: "missing_slack_destination"))
      }
      return .success(.slack)
    case "ios", "iphone", "mobile", "icloud":
      guard let sourceKey = route.sourceKey?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !sourceKey.isEmpty else {
          return .failure(RouteValidationFailure(reason: "missing_ios_source_key"))
      }
      guard isValidIOSDeviceRouteKey(sourceKey) else {
        return .failure(RouteValidationFailure(reason: "invalid_ios_source_key"))
      }
      return .success(.ios)
    case "":
      return .failure(RouteValidationFailure(reason: "missing_origin_surface"))
    default:
      return .failure(RouteValidationFailure(reason: "unknown_origin_surface:\(surface)"))
    }
  }

  /// Current iOS clients mint an exact per-device route as `iphone` or
  /// `iphone:<device name>`. The generic `mobile_app` source key is a session
  /// identity shared by every mobile client, not a reply destination. Accepting
  /// arbitrary non-empty strings (notably the old `app` fallback) can make an
  /// iCloud write look successful while every device correctly filters it out.
  static func isValidIOSDeviceRouteKey(_ raw: String) -> Bool {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf8.count <= 200,
          !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
      return false
    }
    if value == "iphone" { return true }
    guard value.hasPrefix("iphone:") else { return false }
    return !String(value.dropFirst("iphone:".count))
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty
  }

  static func deliver(
    deliveryId: String,
    requestDigest: String,
    text: String,
    attachments: [ChatOrchestration.MultimodalAttachment],
    route: AgentBridgeCompletionRoute,
    sender: any AgentBridgeCompletionSending,
    lifecycle: CodexCompletionLifecycle
  ) async -> AgentBridgeCompletionDelivery {
    let surface = route.surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let validatedRoute = Self.validatedRoute(surface: surface, route: route)
    let delivery: String
    switch validatedRoute {
    case .success(.telegram):
      delivery = "telegram"
    case .success(.slack):
      delivery = "slack"
    case .success(.ios):
      delivery = "icloud_and_apns"
    case .success(.local):
      delivery = "local_session_refresh"
    case .failure:
      delivery = "none"
    }

    if case .failure(let failure) = validatedRoute {
      let result = AgentBridgeCompletionDelivery(
        status: "failed_pre_dispatch",
        surface: surface.isEmpty ? "unknown" : surface,
        delivery: delivery,
        artifactCount: 0,
        attempts: 0,
        reason: failure.reason
      )
      do {
        try await lifecycle.recordDelivery(
          result, deliveryId: deliveryId, requestDigest: requestDigest
        )
        return result
      } catch {
        return lifecycleUnavailable(
          surface: result.surface,
          delivery: delivery,
          reason: "invalid_route_receipt_unavailable:\(error.localizedDescription)"
        )
      }
    }

    await sender.refreshLocalChat(sessionId: route.sessionId)
    guard validatedRoute != .success(.local) else {
      let result = AgentBridgeCompletionDelivery(
        status: "completed",
        surface: surface,
        delivery: delivery,
        artifactCount: text.isEmpty ? attachments.count : attachments.count + 1,
        attempts: 0,
        reason: nil
      )
      do {
        try await lifecycle.recordDelivery(
          result, deliveryId: deliveryId, requestDigest: requestDigest
        )
        return result
      } catch {
        return lifecycleUnavailable(
          surface: surface, delivery: delivery,
          reason: "local_settlement_not_durable:\(error.localizedDescription)"
        )
      }
    }

    let artifacts: [AgentBridgeCompletionArtifact]
    do {
      artifacts = try Self.artifacts(
        deliveryId: deliveryId,
        surface: surface,
        text: text,
        attachments: attachments
      )
    } catch {
      let result = AgentBridgeCompletionDelivery(
        status: "failed_pre_dispatch",
        surface: surface,
        delivery: delivery,
        artifactCount: 0,
        attempts: 0,
        reason: "attachment_validation_failed:\(error.localizedDescription)"
      )
      do {
        try await lifecycle.recordDelivery(
          result, deliveryId: deliveryId, requestDigest: requestDigest
        )
        return result
      } catch {
        return lifecycleUnavailable(
          surface: surface, delivery: delivery,
          reason: "attachment_failure_receipt_unavailable:\(error.localizedDescription)"
        )
      }
    }
    guard !artifacts.isEmpty else {
      let result = AgentBridgeCompletionDelivery(
        status: "failed_pre_dispatch",
        surface: surface,
        delivery: delivery,
        artifactCount: 0,
        attempts: 0,
        reason: "completion_has_no_deliverable_artifacts"
      )
      do {
        try await lifecycle.recordDelivery(
          result, deliveryId: deliveryId, requestDigest: requestDigest
        )
        return result
      } catch {
        return lifecycleUnavailable(
          surface: surface, delivery: delivery,
          reason: "empty_delivery_receipt_unavailable:\(error.localizedDescription)"
        )
      }
    }

    var acceptedCount = 0
    var attempts = 0
    var pendingCount = 0
    var rejectedReasons: [String] = []
    var unknownReasons: [String] = []
    var preDispatchReasons: [String] = []
    var lifecycleFailureReason: String?
    artifactLoop: for artifact in artifacts {
      let decision: CodexCompletionLifecycle.ArtifactDecision
      do {
        decision = try await lifecycle.beginArtifact(
          deliveryId: deliveryId,
          requestDigest: requestDigest,
          artifactId: artifact.id,
          artifactKind: artifact.kind,
          retrySafe: artifact.retrySafe
        )
      } catch {
        lifecycleFailureReason = "\(artifact.kind):settlement_begin_failed:\(error)"
        break artifactLoop
      }

      switch decision {
      case .alreadyAccepted:
        acceptedCount += artifact.logicalCount
        continue artifactLoop
      case .rejected:
        rejectedReasons.append("\(artifact.kind):transport_rejected")
        break artifactLoop
      case .inProgress:
        pendingCount += artifact.logicalCount
        break artifactLoop
      case .outcomeUnknown, .conflict:
        unknownReasons.append("\(artifact.kind):\(decision)")
        break artifactLoop
      case .send:
        break
      }

      do {
        try await sender.preflight(surface: surface, route: route, artifacts: [artifact])
      } catch {
        let detail = String(describing: error)
        do {
          try await lifecycle.markArtifactPreDispatchFailed(
            deliveryId: deliveryId,
            requestDigest: requestDigest,
            artifactId: artifact.id,
            detail: detail
          )
        } catch {
          lifecycleFailureReason = "\(artifact.kind):preflight_receipt_failed:\(error)"
          break artifactLoop
        }
        preDispatchReasons.append("\(artifact.kind):\(detail)")
        break artifactLoop
      }

      do {
        try await lifecycle.markArtifactDispatchStarted(
          deliveryId: deliveryId,
          requestDigest: requestDigest,
          artifactId: artifact.id
        )
      } catch {
        lifecycleFailureReason = "\(artifact.kind):dispatch_start_receipt_failed:\(error)"
        break artifactLoop
      }

      let maximumAttempts = 3
      var accepted = false
      var terminalRejected = false
      var lastError = "unknown_completion_delivery_error"
      for attempt in 1...maximumAttempts {
        attempts += 1
        var retryAfterDefiniteOrIdempotentFailure = false
        let transport = await sender.send(
            artifact: artifact,
            idempotencyKey: stableUUID("\(deliveryId):\(artifact.id)"),
            surface: surface,
            route: route
        )
        switch transport {
        case .accepted:
          do {
            try await lifecycle.markArtifactAccepted(
              deliveryId: deliveryId,
              requestDigest: requestDigest,
              artifactId: artifact.id
            )
            accepted = true
            acceptedCount += artifact.logicalCount
          } catch {
            lastError = "accepted_but_receipt_failed:\(error)"
          }
        case .rejected(let reason, let retryable):
          lastError = reason
          if retryable && attempt < maximumAttempts {
            retryAfterDefiniteOrIdempotentFailure = true
          } else {
            do {
              try await lifecycle.markArtifactRejected(
                deliveryId: deliveryId,
                requestDigest: requestDigest,
                artifactId: artifact.id,
                detail: reason
              )
              terminalRejected = true
            } catch {
              lastError = "rejection_receipt_failed:\(error)"
            }
          }
        case .ambiguous(let reason):
          lastError = reason
          if artifact.retrySafe && attempt < maximumAttempts {
            retryAfterDefiniteOrIdempotentFailure = true
          }
        }
        if retryAfterDefiniteOrIdempotentFailure {
          try? await Task.sleep(nanoseconds: UInt64(attempt) * 250_000_000)
          continue
        }
        break
      }
      if !accepted {
        if terminalRejected {
          rejectedReasons.append("\(artifact.kind):\(lastError)")
        } else {
          do {
            try await lifecycle.markArtifactOutcomeUnknown(
              deliveryId: deliveryId,
              requestDigest: requestDigest,
              artifactId: artifact.id,
              detail: lastError
            )
          } catch {
            lastError += ":outcome_unknown_receipt_failed:\(error)"
          }
          unknownReasons.append("\(artifact.kind):\(lastError)")
        }
        break artifactLoop
      }
    }

    if let lifecycleFailureReason {
      return lifecycleUnavailable(
        surface: surface,
        delivery: delivery,
        acceptedCount: acceptedCount,
        attempts: attempts,
        reason: lifecycleFailureReason
      )
    }

    let status: String
    if !unknownReasons.isEmpty {
      status = "outcome_unknown"
    } else if pendingCount > 0 {
      status = "in_progress"
    } else if !preDispatchReasons.isEmpty {
      status = "failed_pre_dispatch"
    } else if !rejectedReasons.isEmpty {
      status = "rejected"
    } else {
      status = "completed"
    }
    let result = AgentBridgeCompletionDelivery(
      status: status,
      surface: surface,
      delivery: delivery,
      artifactCount: acceptedCount,
      attempts: attempts,
      reason: (unknownReasons + preDispatchReasons + rejectedReasons).isEmpty
        ? nil
        : (unknownReasons + preDispatchReasons + rejectedReasons).joined(separator: " | ")
    )
    do {
      try await lifecycle.recordDelivery(
        result, deliveryId: deliveryId, requestDigest: requestDigest
      )
      return result
    } catch {
      return lifecycleUnavailable(
        surface: surface,
        delivery: delivery,
        acceptedCount: acceptedCount,
        attempts: attempts,
        reason: "delivery_settlement_not_durable:\(error.localizedDescription)"
      )
    }
  }

  private enum ArtifactBuildError: LocalizedError {
    case unsupportedAttachment
    case missingAttachment
    case attachmentSizeMismatch
    case attachmentDigestMismatch

    var errorDescription: String? {
      switch self {
      case .unsupportedAttachment: return "Completion attachment is not an image artifact."
      case .missingAttachment: return "Completion attachment file is missing or unreadable."
      case .attachmentSizeMismatch: return "Completion attachment byte count changed."
      case .attachmentDigestMismatch: return "Completion attachment content changed."
      }
    }
  }

  private static func artifacts(
    deliveryId: String,
    surface: String,
    text: String,
    attachments: [ChatOrchestration.MultimodalAttachment]
  ) throws -> [AgentBridgeCompletionArtifact] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let validated = try attachments.map { attachment -> (
      ChatOrchestration.MultimodalAttachment,
      AgentBridgeCompletionArtifact.AttachmentExpectation
    ) in
      guard attachment.type.lowercased() == "image",
            attachment.mime.lowercased().hasPrefix("image/") else {
        throw ArtifactBuildError.unsupportedAttachment
      }
      guard let rawPath = attachment.path, !rawPath.isEmpty,
            let data = try? Data(contentsOf: URL(fileURLWithPath: rawPath)),
            !data.isEmpty else {
        throw ArtifactBuildError.missingAttachment
      }
      guard attachment.byteSize == data.count else {
        throw ArtifactBuildError.attachmentSizeMismatch
      }
      return (attachment, .init(
        path: rawPath,
        byteSize: data.count,
        digest: dataDigest(data)
      ))
    }
    if ["ios", "iphone", "mobile", "icloud"].contains(surface) {
      guard !trimmed.isEmpty || !validated.isEmpty else { return [] }
      let correlationId = stableUUID("\(deliveryId):ios_correlation")
      let notificationText = trimmed.isEmpty
        ? "Codex work finished with an attachment."
        : trimmed
      return [
        AgentBridgeCompletionArtifact(
          id: "\(deliveryId):ios_bundle",
          kind: "ios_message",
          // The stable BridgeMessage record/file id makes a relaunch replay an
          // overwrite/server conflict, never a second visible chat message.
          retrySafe: true,
          logicalCount: (trimmed.isEmpty ? 0 : 1) + validated.count,
          payload: .iosBundle(trimmed, validated.map(\.0), correlationId),
          attachmentExpectations: validated.map(\.1)
        ),
        AgentBridgeCompletionArtifact(
          id: "\(deliveryId):ios_notification",
          kind: "ios_notification",
          // APNS collapse ids reduce duplicates but are not an exactly-once
          // receipt once a notification has reached a device. Never replay an
          // ambiguous push across an error or process boundary.
          retrySafe: false,
          logicalCount: 0,
          payload: .iosNotification(notificationText, correlationId),
          attachmentExpectations: []
        ),
      ]
    }
    var result: [AgentBridgeCompletionArtifact] = []
    if !trimmed.isEmpty {
      result.append(AgentBridgeCompletionArtifact(
        id: "\(deliveryId):text",
        kind: "text",
        retrySafe: surface == "slack",
        logicalCount: 1,
        payload: .text(trimmed),
        attachmentExpectations: []
      ))
    }
    for (index, item) in validated.enumerated() {
      result.append(AgentBridgeCompletionArtifact(
        id: "\(deliveryId):attachment:\(index):\(item.0.id):\(item.1.digest)",
        kind: "attachment",
        retrySafe: false,
        logicalCount: 1,
        payload: .attachment(item.0),
        attachmentExpectations: [item.1]
      ))
    }
    return result
  }

  static func validateAttachmentExpectations(
    _ expectations: [AgentBridgeCompletionArtifact.AttachmentExpectation]
  ) throws {
    for expectation in expectations {
      guard let data = try? Data(contentsOf: URL(fileURLWithPath: expectation.path)),
            !data.isEmpty else { throw ArtifactBuildError.missingAttachment }
      guard data.count == expectation.byteSize else {
        throw ArtifactBuildError.attachmentSizeMismatch
      }
      guard dataDigest(data) == expectation.digest else {
        throw ArtifactBuildError.attachmentDigestMismatch
      }
    }
  }

  private static func dataDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func lifecycleUnavailable(
    surface: String,
    delivery: String,
    acceptedCount: Int = 0,
    attempts: Int = 0,
    reason: String
  ) -> AgentBridgeCompletionDelivery {
    AgentBridgeCompletionDelivery(
      status: "lifecycle_unavailable",
      surface: surface,
      delivery: delivery,
      artifactCount: acceptedCount,
      attempts: attempts,
      reason: reason
    )
  }

  static func stableUUID(_ value: String) -> String {
    var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3],
      bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11],
      bytes[12], bytes[13], bytes[14], bytes[15]
    )).uuidString.lowercased()
  }
}

struct LiveAgentBridgeCompletionSender: AgentBridgeCompletionSending {
  enum DeliveryError: LocalizedError {
    case telegramNotConfigured
    case invalidTelegramDestination
    case missingSlackDestination
    case missingIOSSourceKey
    case slackRejected(String)
    case emptyCompletion
    case notificationNotAccepted

    var errorDescription: String? {
      switch self {
      case .telegramNotConfigured: return "Telegram is not enabled or has no bot token."
      case .invalidTelegramDestination:
        return "The originating Telegram chat id is missing or invalid."
      case .missingSlackDestination: return "The originating Slack channel id is missing."
      case .missingIOSSourceKey: return "The originating iOS device route key is missing."
      case .slackRejected(let detail): return "Slack rejected the completion: \(detail)"
      case .emptyCompletion: return "The agent produced no completion text or attachment."
      case .notificationNotAccepted: return "APNS did not return an acceptance receipt."
      }
    }
  }

  let dataRoot: URL

  init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
    self.dataRoot = dataRoot
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
    } catch DeliveryError.invalidTelegramDestination {
      return .rejected(reason: "invalid_telegram_destination", retryable: false)
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
      switch artifact.payload {
      case .text(let text):
        try await TelegramPollLoop.defaultSendMessage(config.botToken, chatId, text)
      case .attachment(let attachment):
        guard let path = attachment.path else { throw DeliveryError.emptyCompletion }
        try await TelegramPollLoop.defaultSendPhoto(
          config.botToken,
          chatId,
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
        let result = try await SlackConnectorActions.uploadFile(input: input)
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
          _ = try await iCloudBridge.shared.sendChatMessage(
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
        let accepted = await AppDelegate.sendICloudReplyPushNotification(
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
