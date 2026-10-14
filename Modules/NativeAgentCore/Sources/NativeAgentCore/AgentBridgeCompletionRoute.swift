import Foundation

public struct AgentBridgeCompletionRoute: Sendable, Equatable, Codable {
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
  public enum Kind: Sendable, Equatable {
    case local, callerResult, telegram, slack, ios

    public init?(surface: String) {
      switch surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "chat", "app", "mac", "github-command", "mission", "missions", "workshop": self = .local
      case "caller-result": self = .callerResult
      case "telegram": self = .telegram
      case "slack": self = .slack
      case "ios", "iphone", "mobile", "icloud": self = .ios
      default: return nil
      }
    }

    public var hasRedeliveryOwner: Bool { self == .telegram || self == .slack || self == .ios }
  }

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
  public let requesterUserId: String?

  public init(
    surface: String,
    sessionId: String? = nil,
    destinationId: String? = nil,
    threadId: String? = nil,
    sourceKey: String? = nil,
    replyTo: String? = nil,
    correlationId: String? = nil,
    turnSessionId: String? = nil,
    requesterUserId: String? = nil
  ) {
    self.surface = surface
    self.sessionId = sessionId
    self.destinationId = destinationId
    self.threadId = threadId
    self.sourceKey = sourceKey
    self.replyTo = replyTo
    self.correlationId = correlationId
    self.turnSessionId = turnSessionId
    self.requesterUserId = requesterUserId
  }

  public var kind: Kind? { Kind(surface: surface) }
}

/// The lifecycle owner's read model, shared below the surface and reporting modules.
public struct CodexCompletionLifecycleProjection: Decodable, Sendable {
  private struct Answer: Decodable, Sendable {
    struct Attachment: Decodable, Sendable { let id: String }
    let runId: String
    let sessionId: String?
    let output: String
    let attachments: [Attachment]?
  }
  private struct Delivery: Decodable, Sendable { let status: String; let delivery: String }
  private struct Artifact: Decodable, Sendable { let phase: String }
  public let deliveryId: String
  public let principal: String?
  public let source: String?
  public let updatedAt: String
  private let phase: String
  private let response: Answer?
  private let responseRunId: String?
  private let sessionId: String?
  private let delivery: Delivery?
  private let artifacts: [String: Artifact]

  public init(deliveryId: String, principal: String?, source: String?, updatedAt: String,
              phase: String, response: (runId: String, sessionId: String?, output: String, attachmentIds: [String])?, responseRunId: String?,
              sessionId: String?, delivery: (status: String, delivery: String)?, artifacts: [String: String]) {
    self.deliveryId = deliveryId
    self.principal = principal
    self.source = source
    self.updatedAt = updatedAt
    self.phase = phase
    self.response = response.map { Answer(runId: $0.runId, sessionId: $0.sessionId, output: $0.output,
                                         attachments: $0.attachmentIds.map { Answer.Attachment(id: $0) }) }
    self.responseRunId = responseRunId
    self.sessionId = sessionId
    self.delivery = delivery.map { Delivery(status: $0.status, delivery: $0.delivery) }
    self.artifacts = artifacts.mapValues { Artifact(phase: $0) }
  }

  public var status: String? {
    if delivery?.status == "let_go" { return "let_go" }
    if phase == "failed_before_answer" { return "failed_before_answer" }
    if delivery?.status == "completed" { return "delivered" }
    if delivery?.status == "sent_unconfirmed" || artifacts.values.contains(where: {
      !["accepted", "reserved", "pre_dispatch_failed", "rejected"].contains($0.phase)
    }) { return "sent_unconfirmed" }
    if !artifacts.isEmpty && artifacts.values.allSatisfy({ $0.phase == "accepted" }), let response,
       (response.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || artifacts["\(deliveryId):text"] != nil),
       (response.attachments ?? []).enumerated().allSatisfy({ index, attachment in
         artifacts.keys.contains { $0.hasPrefix("\(deliveryId):attachment:\(index):\(attachment.id):") }
       }) { return "delivered" }
    if artifacts.values.contains(where: { $0.phase == "accepted" }) { return "sent_unconfirmed" }
    return response == nil ? nil : "owed"
  }

  public var routeSettled: Bool {
    delivery?.delivery == "route_journal" && ["completed", "sent_unconfirmed"].contains(delivery?.status ?? "")
  }

  public var permitsDelivery: Bool { delivery?.status != "let_go" }

  public static func permitsDelivery(sessionId: String?, runId: String?, configRoot: URL, dataRoot: URL) throws -> Bool {
    guard let sessionId, let runId else { return true }
    return try rows(configRoot: configRoot, dataRoot: dataRoot).allSatisfy {
      $0.permitsDelivery || ($0.response?.runId ?? $0.responseRunId) != runId
        || ($0.response?.sessionId ?? $0.sessionId) != sessionId
    }
  }

  public var unsettledRunId: String? {
    ["delivered", "failed_before_answer", "let_go"].contains(status ?? "") ? nil : response?.runId ?? responseRunId
  }

  public func knownPrincipal(dataRoot: URL) throws -> String? {
    if let principal { return principal }
    guard let session = response?.sessionId ?? sessionId,
          NativeAgentChatSessionID.normalizedPathComponent(session) == session,
          let run = response?.runId ?? responseRunId else { return nil }
    let path = dataRoot.appendingPathComponent("chat/messages/\(session).jsonl")
    guard FileManager.default.fileExists(atPath: path.path) else { return nil }
    for line in try String(contentsOf: path, encoding: .utf8).split(whereSeparator: \.isNewline).reversed() {
      guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
      if row["role"] as? String == "user", row["runId"] as? String == run,
         let metadata = row["metadata"] as? [String: Any], let origin = metadata["origin"] as? [String: Any] {
        return origin["agent"] as? String
      }
    }
    return nil
  }

  public static func directories(configRoot: URL, dataRoot: URL) -> [URL] {
    [configRoot.appendingPathComponent("claude-bridge/codex-completion-lifecycle")]
      + ["agent-conversations", "chat/human-reply-delivery", "chat/anchor-mirror"].map {
        dataRoot.appendingPathComponent($0 + "/codex-completion-lifecycle")
      }
  }

  public static func unsettledAnswerRuns(configRoot: URL, dataRoot: URL) throws -> Set<String> {
    Set(try rows(configRoot: configRoot, dataRoot: dataRoot).compactMap(\.unsettledRunId))
  }

  private static func rows(configRoot: URL, dataRoot: URL) throws -> [Self] {
    var rows: [Self] = []
    for directory in directories(configRoot: configRoot, dataRoot: dataRoot)
      where FileManager.default.fileExists(atPath: directory.path) {
      for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                            options: [.skipsHiddenFiles]) where url.pathExtension == "json" {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if object?["schema"] as? String == "codex-completion-lifecycle.corrupt.v1" { continue }
        rows.append(try JSONDecoder().decode(Self.self, from: data))
      }
    }
    return rows
  }
}
