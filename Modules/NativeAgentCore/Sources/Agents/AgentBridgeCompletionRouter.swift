import ChatTurnRuntime
import ChatTurnContracts
import AgentWorkspace
import CryptoKit
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `AgentBridgeCompletionRouter.swift` | Completion-route adapters and destination validation; saved let-go delivery stops at admission before asking-chat rows or dispatch; retained tasks own caller-result artifact idempotence under delivery admission; cancellation fences the append; `AgentBridgeCompletionRouter`: `validatedRoute`, `deliverAnswer` |

extension AgentBridgeCompletionRoute {
  /// The door a contact's send was asked from, for an answer from a turn
  /// that ran in `turnSessionId`.
  public init(asking row: AgentConversationRecord, turnSessionId: String) {
    let saved = row.replyRoute ?? [:]
    self.init(surface: saved["surface"] ?? row.sourceSurface, sessionId: row.scopeSessionID,
              destinationId: saved["destinationId"], threadId: saved["threadId"], sourceKey: saved["sourceKey"],
              replyTo: saved["replyTo"], correlationId: saved["correlationId"],
              turnSessionId: turnSessionId == row.scopeSessionID ? nil : turnSessionId,
              requesterUserId: saved["requesterUserId"])
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
      correlationId: value("correlationId"),
      requesterUserId: value("requesterUserId")
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
      correlationId: correlationId,
      requesterUserId: requesterUserId
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

  public init(status: String, surface: String, delivery: String, artifactCount: Int, attempts: Int, reason: String?) {
    self.status = status; self.surface = surface; self.delivery = delivery
    self.artifactCount = artifactCount; self.attempts = attempts; self.reason = reason
  }

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
    case attachment(ChatTurnRuntime.MultimodalAttachment)
  }

  public let id: String
  public let kind: String
  public let logicalCount: Int
  public let payload: Payload
  public let attachmentExpectations: [AttachmentExpectation]
}

public enum AgentBridgeTransportResult: Sendable, Equatable {
  case accepted
  case alreadyAccepted
  case rejected(reason: String)
  case preDispatchFailed(reason: String)
  case outcomeUnknown(reason: String)
  case settled(AgentBridgeCompletionDelivery)
}

public protocol AgentBridgeCompletionSending: Sendable {
  func deliverReply(_ response: ChatResponse, deliveryId: String, route: AgentBridgeCompletionRoute,
                    priorVerdict: String?, notifyRequestedResult: Bool) async throws -> AgentBridgeCompletionDelivery
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
  public enum DeliveryError: LocalizedError {
    case invalidTelegramDestination
    case missingSlackDestination
    case missingIOSSourceKey
    case emptyCompletion
    case notificationNotAccepted

    public var errorDescription: String? {
      switch self {
      case .invalidTelegramDestination:
        return "The originating Telegram chat id is missing or invalid."
      case .missingSlackDestination: return "The originating Slack channel id is missing."
      case .missingIOSSourceKey: return "The originating iOS device route key is missing."
      case .emptyCompletion: return "The agent produced no completion text or attachment."
      case .notificationNotAccepted: return "The requested result has not been accepted for phone delivery."
      }
    }
  }

  public static func deliverReply(
    deliveryId: String, route: AgentBridgeCompletionRoute, notifyRequestedResult: Bool,
    recoverTelegram: @Sendable () async throws -> String,
    recoverSlack: @Sendable () async throws -> String,
    recoverIOS: @Sendable () async throws -> String,
    deliverRequestedResult: @Sendable () async throws -> Void
  ) async throws -> AgentBridgeCompletionDelivery {
    let verdict: String
    switch route.kind {
    case .telegram: verdict = try await recoverTelegram()
    case .slack: verdict = try await recoverSlack()
    case .ios: verdict = try await recoverIOS()
    default: throw DeliveryError.emptyCompletion
    }
    var notificationDiagnostic: String?
    if verdict != "owed", notifyRequestedResult {
      do { try await deliverRequestedResult() }
      catch {
        notificationDiagnostic = error.localizedDescription
        nativeLog("Requested result notification remains pending for %@: %@", deliveryId, error.localizedDescription)
      }
    }
    return AgentBridgeCompletionDelivery(status: verdict, surface: route.surface, delivery: "route_journal",
      artifactCount: verdict == "owed" ? 0 : 1, attempts: 0,
      reason: verdict == "sent_unconfirmed" ? "Route journal retained an unconfirmed dispatch; automatic resend is disabled." : notificationDiagnostic)
  }

  public static func sendCallerResult(
    artifact: AgentBridgeCompletionArtifact, idempotencyKey: String,
    route: AgentBridgeCompletionRoute, tasks: @Sendable () -> AgentContactTasks
  ) async -> AgentBridgeTransportResult {
    do {
      try validateAttachmentExpectations(artifact.attachmentExpectations)
      guard route.kind == .callerResult else { throw DeliveryError.emptyCompletion }
      let part: AgentContactPart
      switch artifact.payload {
      case .text(let text): part = .text(text)
      case .attachment(let attachment):
        part = try AgentContactPart.output(attachment, taskID: "na3.\(route.threadId ?? "").\(route.correlationId ?? "")")
      }
      return try await tasks().appendCallerResult(part, artifactID: idempotencyKey, route: route)
        ? .accepted : .alreadyAccepted
    } catch { return .rejected(reason: error.localizedDescription) }
  }

  private struct RouteValidationFailure: Error, Equatable {
    let reason: String
  }

  private static func validatedRoute(
    surface: String,
    route: AgentBridgeCompletionRoute
  ) -> Result<AgentBridgeCompletionRoute.Kind, RouteValidationFailure> {
    guard let kind = route.kind else {
      return .failure(RouteValidationFailure(reason: surface.isEmpty
        ? "missing_origin_surface" : "unknown_origin_surface:\(surface)"))
    }
    switch kind {
    case .local: break
    case .callerResult:
      guard let owner = route.destinationId, !owner.isEmpty,
            let context = route.threadId, let request = route.correlationId,
            NativeAgentA2AWire.locator("na3.\(context).\(request)") != nil,
            route.sessionId?.hasPrefix(AgentBridgePrincipal.genericAgentSessionPrefix(owner: owner)) == true else {
        return .failure(RouteValidationFailure(reason: "invalid_caller_result_route"))
      }
    case .telegram:
      guard let destination = route.destinationId, Int(destination) != nil else {
        return .failure(RouteValidationFailure(reason: "invalid_telegram_destination"))
      }
    case .slack:
      guard let destination = route.destinationId?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !destination.isEmpty else {
        return .failure(RouteValidationFailure(reason: "missing_slack_destination"))
      }
    case .ios:
      guard let sourceKey = route.sourceKey?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !sourceKey.isEmpty else {
          return .failure(RouteValidationFailure(reason: "missing_ios_source_key"))
      }
      guard AgentBridgeCompletionRoute.isValidIOSDeviceRouteKey(sourceKey) else {
        return .failure(RouteValidationFailure(reason: "invalid_ios_source_key"))
      }
    }
    return .success(kind)
  }


  /// A contact's conversation runs her turn in its own session,
  /// but when User asked from a chat at any door her answer reaches THAT chat:
  /// a visible row in the chat that asked and the route's own delivery. Phone
  /// rows wait for the native send verdict so a held answer stays unpublished.
  public static func deliverAnswer(
    deliveryId: String,
    requestDigest: String,
    text: String,
    attachments: [ChatTurnRuntime.MultimodalAttachment],
    route: AgentBridgeCompletionRoute,
    client: SwiftNativeChatOrchestrationClient,
    sender: any AgentBridgeCompletionSending,
    lifecycle: CodexCompletionLifecycle,
    notifyRequestedResult: Bool = true
  ) async -> AgentBridgeCompletionDelivery {
    return await deliver(deliveryId: deliveryId, requestDigest: requestDigest, text: text, attachments: attachments,
                         route: route, sender: sender, lifecycle: lifecycle, notifyRequestedResult: notifyRequestedResult,
                         askingChatClient: client)
  }

  public static func deliver(
    deliveryId: String,
    requestDigest: String,
    text: String,
    attachments: [ChatTurnRuntime.MultimodalAttachment],
    route: AgentBridgeCompletionRoute,
    sender: any AgentBridgeCompletionSending,
    lifecycle: CodexCompletionLifecycle,
    notifyRequestedResult: Bool = true,
    askingChatClient: (SwiftNativeChatOrchestrationClient)? = nil
  ) async -> AgentBridgeCompletionDelivery {
    let surface = route.surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let admission: (response: ChatResponse?, priorVerdict: String?, letGo: AgentBridgeCompletionDelivery?)
    do {
      admission = try await lifecycle.deliveryAdmission(deliveryId: deliveryId, requestDigest: requestDigest)
      if let letGo = admission.letGo { return letGo }
    } catch {
      return lifecycleUnavailable(surface: surface, delivery: "none", reason: error.localizedDescription)
    }
    if let askingChatClient, route.turnSessionId != nil, let asking = route.sessionId,
       ["chat", "app", "mac"].contains(surface) {
      do {
        try await askingChatClient.appendAnswerForAskingChat(sessionID: asking, text: text, attachments: attachments,
                                                   surface: surface, deliveryID: deliveryId)
      } catch {
        return AgentBridgeCompletionDelivery(status: "failed_pre_dispatch", surface: surface, delivery: "asking_chat_row",
          artifactCount: 0, attempts: 0, reason: "asking_chat_row_failed:\(error.localizedDescription)")
      }
    }
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

    if validatedRoute != .success(.callerResult), validatedRoute != .success(.ios) {
      await sender.refreshLocalChat(sessionId: route.sessionId)
    }
    // A tool-authored reply to another human conversation is part of the
    // enclosing turn's work. That turn owns the single result notification.
    if validatedRoute == .success(.local) {
      if notifyRequestedResult {
        do {
          guard let response = admission.response,
                let session = route.turnSessionId ?? response.sessionId else { throw CodexCompletionLifecycle.LifecycleError.responseMissing }
          try await SwiftNativeChatOrchestrationClient.retainRequestedResult(dataRoot: lifecycle.dataRoot,
            sessionId: session, runId: response.runId, deliveryId: "requested-result:" + deliveryId)
        } catch {
          return lifecycleUnavailable(surface: surface, delivery: delivery,
            reason: "requested_result_intent_not_durable:\(error.localizedDescription)")
        }
      }
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
    if [.success(.telegram), .success(.slack), .success(.ios)].contains(validatedRoute) {
      do {
        let admission = try await lifecycle.deliveryAdmission(deliveryId: deliveryId, requestDigest: requestDigest)
        if let letGo = admission.letGo { return letGo }
        guard var response = admission.response else {
          throw CodexCompletionLifecycle.LifecycleError.responseMissing
        }
        response.output = text
        response.attachments = attachments
        let result = try await sender.deliverReply(response, deliveryId: deliveryId, route: route,
          priorVerdict: admission.priorVerdict, notifyRequestedResult: notifyRequestedResult)
        if result.status != "owed" {
          if validatedRoute == .success(.ios) {
            if route.turnSessionId != nil, let asking = route.sessionId, let askingChatClient {
              try await askingChatClient.appendAnswerForAskingChat(sessionID: asking, text: text, attachments: attachments,
                                                                  surface: surface, deliveryID: deliveryId)
            }
            await sender.refreshLocalChat(sessionId: route.sessionId)
          }
          try await lifecycle.recordDelivery(result, deliveryId: deliveryId, requestDigest: requestDigest)
        }
        return result
      } catch {
        return AgentBridgeCompletionDelivery(status: "owed", surface: surface, delivery: "route_journal",
          artifactCount: 0, attempts: 0, reason: error.localizedDescription)
      }
    }
    let artifacts: [AgentBridgeCompletionArtifact]
    do {
      artifacts = try Self.artifacts(
        deliveryId: deliveryId,
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
    var rejectedReasons: [String] = []
    var unknownReasons: [String] = []
    var preDispatchReasons: [String] = []
    var lifecycleFailureReason: String?
    artifactLoop: for artifact in artifacts {
      let verdict: AgentBridgeTransportResult
      do {
        verdict = try await lifecycle.admitCallerResult(deliveryId: deliveryId,
          requestDigest: requestDigest, artifact: artifact) {
          do { try await sender.preflight(surface: surface, route: route, artifacts: [artifact]) }
          catch { return .preDispatchFailed(reason: String(describing: error)) }
          guard !Task.isCancelled else { return .outcomeUnknown(reason: "completion_delivery_cancelled") }
          return await sender.send(artifact: artifact,
            idempotencyKey: stableUUID("\(deliveryId):\(artifact.id)"), surface: surface, route: route)
        }
      } catch {
        lifecycleFailureReason = "\(artifact.kind):delivery_admission_failed:\(error)"
        break artifactLoop
      }
      switch verdict {
      case .settled(let delivery):
        return delivery
      case .accepted:
        attempts += 1
        acceptedCount += artifact.logicalCount
      case .alreadyAccepted:
        acceptedCount += artifact.logicalCount
      case .rejected(let reason):
        attempts += 1
        rejectedReasons.append("\(artifact.kind):\(reason)")
        break artifactLoop
      case .preDispatchFailed(let reason):
        preDispatchReasons.append("\(artifact.kind):\(reason)")
        break artifactLoop
      case .outcomeUnknown(let reason):
        unknownReasons.append("\(artifact.kind):\(reason)")
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
    text: String,
    attachments: [ChatTurnRuntime.MultimodalAttachment]
  ) throws -> [AgentBridgeCompletionArtifact] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let validated = try attachments.map { attachment -> (
      ChatTurnRuntime.MultimodalAttachment,
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
    var result: [AgentBridgeCompletionArtifact] = []
    if !trimmed.isEmpty {
      result.append(AgentBridgeCompletionArtifact(
        id: "\(deliveryId):text",
        kind: "text",
        logicalCount: 1,
        payload: .text(trimmed),
        attachmentExpectations: []
      ))
    }
    for (index, item) in validated.enumerated() {
      result.append(AgentBridgeCompletionArtifact(
        id: "\(deliveryId):attachment:\(index):\(item.0.id):\(item.1.digest)",
        kind: "attachment",
        logicalCount: 1,
        payload: .attachment(item.0),
        attachmentExpectations: [item.1]
      ))
    }
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
