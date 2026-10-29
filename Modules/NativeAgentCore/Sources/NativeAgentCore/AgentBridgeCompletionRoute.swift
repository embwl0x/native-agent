import Foundation
// Blueprint: | `Modules/NativeAgentCore/Sources/NativeAgentCore/AgentBridgeCompletionRoute.swift` | Shared completion route/requester identity and destination validation; `isValidIOSDeviceRouteKey` |

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
    /// Its destination says when it holds a reply (Telegram's and Slack's
    /// servers keep the conversation). The phone does not yet: CloudKit
    /// accepting a push is transport only.
    public var acceptsDurably: Bool { self == .telegram || self == .slack }
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
