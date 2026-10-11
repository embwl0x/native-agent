import Foundation

public struct AgentBridgeCompletionRoute: Sendable, Equatable {
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

    public var hasRedeliveryOwner: Bool { self != .local }
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

  public var kind: Kind? { Kind(surface: surface) }
}
