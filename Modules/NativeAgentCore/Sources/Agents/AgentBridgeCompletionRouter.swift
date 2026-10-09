import ChatOrchestration
import CryptoKit
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore

public struct AgentBridgeCompletionRoute: Sendable, Equatable {
  public let surface: String
  public let sessionId: String?
  public let destinationId: String?
  public let threadId: String?
  public let sourceKey: String?
  public let replyTo: String?
  public let correlationId: String?
  /// Where the turn that produced the answer ran, when that is not the chat
  /// it answers (a contact's own conversation): its result marker is there.
  public let turnSessionId: String?

  public init(
    surface: String,
    sessionId: String? = nil,
    destinationId: String? = nil,
    threadId: String? = nil,
    sourceKey: String? = nil,
    replyTo: String? = nil,
    correlationId: String? = nil,
    turnSessionId: String? = nil
  ) {
    self.surface = surface
    self.sessionId = sessionId
    self.destinationId = destinationId
    self.threadId = threadId
    self.sourceKey = sourceKey
    self.replyTo = replyTo
    self.correlationId = correlationId
    self.turnSessionId = turnSessionId
  }

  /// The door a contact's send was asked from, for an answer from a turn
  /// that ran in `turnSessionId`.
  public init(asking row: AgentConversationRecord, turnSessionId: String) {
    let saved = row.replyRoute ?? [:]
    self.init(surface: saved["surface"] ?? row.sourceSurface, sessionId: row.scopeSessionID,
              destinationId: saved["destinationId"], threadId: saved["threadId"], sourceKey: saved["sourceKey"],
              replyTo: saved["replyTo"], correlationId: saved["correlationId"],
              turnSessionId: turnSessionId == row.scopeSessionID ? nil : turnSessionId)
  }

  public init(origin: [String: Any]?, sessionId: String?) {
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
  public var chatToolReplyRoute: ChatToolSessionContext.ReplyRoute {
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

public struct AgentBridgeCompletionDelivery: Sendable, Equatable, Codable {
  public let status: String
  public let surface: String
  public let delivery: String
  public let artifactCount: Int
  public let attempts: Int
  public let reason: String?

  public var jsonObject: [String: Any] {
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

public struct AgentBridgeCompletionArtifact: Sendable, Equatable {
  public struct AttachmentExpectation: Sendable, Equatable {
    public let path: String
    public let byteSize: Int
    public let digest: String
  }

  public enum Payload: Sendable, Equatable {
    case text(String)
    case attachment(ChatOrchestration.MultimodalAttachment)
    case iosBundle(String, [ChatOrchestration.MultimodalAttachment], String)
    case iosNotification(String, String)
  }

  public let id: String
  public let kind: String
  public let retrySafe: Bool
  public let logicalCount: Int
  public let payload: Payload
  public let attachmentExpectations: [AttachmentExpectation]
}

public enum AgentBridgeTransportResult: Sendable, Equatable {
  case accepted
  /// The transport proved no effect occurred. `retryable` means another
  /// attempt with the same idempotency key is safe.
  case rejected(reason: String, retryable: Bool)
  /// The effect may have occurred. Never retry a non-idempotent artifact.
  case ambiguous(reason: String)
}

public protocol AgentBridgeCompletionSending: Sendable {
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

public enum AgentBridgeCompletionRouter {
  private enum ValidatedRoute: Equatable {
    case local
    case callerResult
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
    case "chat", "app", "mac", "github-command", "mission", "missions", "workshop":
      return .success(.local)
    case "caller-result":
      guard let owner = route.destinationId, !owner.isEmpty,
            let context = route.threadId, let request = route.correlationId,
            NativeAgentA2AWire.locator("na3.\(context).\(request)") != nil,
            route.sessionId?.hasPrefix(AgentBridgePrincipal.genericAgentSessionPrefix(owner: owner)) == true else {
        return .failure(RouteValidationFailure(reason: "invalid_caller_result_route"))
      }
      return .success(.callerResult)
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
  public static func isValidIOSDeviceRouteKey(_ raw: String) -> Bool {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf8.count <= 200,
          value.rangeOfCharacter(from: .controlCharacters) == nil else {
      return false
    }
    if value == "iphone" { return true }
    guard value.hasPrefix("iphone:") else { return false }
    return !String(value.dropFirst("iphone:".count))
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty
  }

  /// User 10-01: a contact's conversation runs her turn in its own session,
  /// but when User asked from a chat at any door her answer reaches THAT chat:
  /// a visible row in the Mac or phone chat that asked, then the route's own
  /// delivery (the push, or Telegram's text). No row, no delivery.
  public static func deliverAnswer(
    deliveryId: String,
    requestDigest: String,
    text: String,
    attachments: [ChatOrchestration.MultimodalAttachment],
    route: AgentBridgeCompletionRoute,
    client: any ChatOrchestrationClient,
    sender: any AgentBridgeCompletionSending,
    lifecycle: CodexCompletionLifecycle,
    notifyRequestedResult: Bool = true
  ) async -> AgentBridgeCompletionDelivery {
    let surface = route.surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if route.turnSessionId != nil, let asking = route.sessionId,
       ["chat", "app", "mac", "ios", "iphone", "mobile", "icloud"].contains(surface) {
      do {
        try await client.appendAnswerForAskingChat(sessionID: asking, text: text, attachments: attachments,
                                                   surface: surface, deliveryID: deliveryId)
      } catch {
        return AgentBridgeCompletionDelivery(status: "failed_pre_dispatch", surface: surface, delivery: "asking_chat_row",
          artifactCount: 0, attempts: 0, reason: "asking_chat_row_failed:\(error.localizedDescription)")
      }
    }
    return await deliver(deliveryId: deliveryId, requestDigest: requestDigest, text: text, attachments: attachments,
                         route: route, sender: sender, lifecycle: lifecycle, notifyRequestedResult: notifyRequestedResult)
  }

  public static func deliver(
    deliveryId: String,
    requestDigest: String,
    text: String,
    attachments: [ChatOrchestration.MultimodalAttachment],
    route: AgentBridgeCompletionRoute,
    sender: any AgentBridgeCompletionSending,
    lifecycle: CodexCompletionLifecycle,
    notifyRequestedResult: Bool = true
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
      delivery = notifyRequestedResult ? "requested_result_phone" : "local_session_refresh"
    case .success(.callerResult):
      delivery = "retained_caller_result"
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

    if validatedRoute != .success(.callerResult) {
      await sender.refreshLocalChat(sessionId: route.sessionId)
    }
    // A tool-authored reply to another human conversation is part of the
    // enclosing turn's work. That turn owns the single result notification.
    if validatedRoute == .success(.local), !notifyRequestedResult {
      let result = AgentBridgeCompletionDelivery(status: "completed", surface: surface, delivery: delivery,
        artifactCount: text.isEmpty ? attachments.count : attachments.count + 1, attempts: 0, reason: nil)
      do {
        try await lifecycle.recordDelivery(result, deliveryId: deliveryId, requestDigest: requestDigest)
        return result
      } catch {
        return lifecycleUnavailable(surface: surface, delivery: delivery,
          reason: "local_settlement_not_durable:\(error.localizedDescription)")
      }
    }
    let artifacts: [AgentBridgeCompletionArtifact]
    do {
      artifacts = try Self.artifacts(
        deliveryId: deliveryId,
        surface: surface,
        text: text,
        attachments: attachments,
        notifyRequestedResult: notifyRequestedResult
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
      let attemptID: String
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
      case .send(let id):
        attemptID = id
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
            attemptID: attemptID,
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
          artifactId: artifact.id,
          attemptID: attemptID
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
              artifactId: artifact.id,
              attemptID: attemptID
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
                attemptID: attemptID,
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
              attemptID: attemptID,
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

  public static func artifacts(
    deliveryId: String,
    surface: String,
    text: String,
    attachments: [ChatOrchestration.MultimodalAttachment],
    notifyRequestedResult: Bool = true
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
      let bundle = AgentBridgeCompletionArtifact(
          id: "\(deliveryId):ios_bundle", kind: "ios_message", retrySafe: true,
          logicalCount: (trimmed.isEmpty ? 0 : 1) + validated.count,
          payload: .iosBundle(trimmed, validated.map(\.0), correlationId),
          attachmentExpectations: validated.map(\.1)
      )
      guard notifyRequestedResult else { return [bundle] }
      return [
        bundle,
        AgentBridgeCompletionArtifact(
          id: "\(deliveryId):ios_notification",
          kind: "ios_notification",
          // Attention and phone publication share the saved result's stable
          // event identity; retry only delivery, never the resident turn.
          retrySafe: true,
          logicalCount: 0,
          payload: .iosNotification(trimmed, deliveryId),
          attachmentExpectations: []
        ),
      ]
    }
    let notification = AgentBridgeCompletionArtifact(
      id: "\(deliveryId):requested_result", kind: "requested_result", retrySafe: true,
      logicalCount: 0, payload: .iosNotification(trimmed, deliveryId), attachmentExpectations: []
    )
    if notifyRequestedResult, ["chat", "app", "mac", "github-command", "mission", "missions", "workshop"].contains(surface) {
      return [notification]
    }
    var result: [AgentBridgeCompletionArtifact] = []
    if !trimmed.isEmpty {
      result.append(AgentBridgeCompletionArtifact(
        id: "\(deliveryId):text",
        kind: "text",
        retrySafe: surface == "slack" || surface == "caller-result",
        logicalCount: 1,
        payload: .text(trimmed),
        attachmentExpectations: []
      ))
    }
    for (index, item) in validated.enumerated() {
      result.append(AgentBridgeCompletionArtifact(
        id: "\(deliveryId):attachment:\(index):\(item.0.id):\(item.1.digest)",
        kind: "attachment",
        retrySafe: surface == "caller-result",
        logicalCount: 1,
        payload: .attachment(item.0),
        attachmentExpectations: [item.1]
      ))
    }
    if notifyRequestedResult, surface != "caller-result" { result.append(notification) }
    return result
  }

  public static func validateAttachmentExpectations(
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

  public static func stableUUID(_ value: String) -> String {
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
