import Foundation
// Blueprint: | `Modules/NativeAgentCore/Sources/NativeAgentCore/AgentBridgeCompletionRoute.swift` | `isValidIOSDeviceRouteKey` |

public struct AgentBridgeCompletionRoute: Sendable, Equatable, Codable {
  /// Only iphone or iphone:<device name> names a device reply route; mobile_app is shared session identity. A generic route can accept an iCloud write that
  /// every device filters out.
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
      case "chat", "github-command", "workshop": self = .local
      case "caller-result": self = .callerResult
      case "telegram": self = .telegram
      case "slack": self = .slack
      case "ios": self = .ios
      default: return nil
      }
    }

    public var hasRedeliveryOwner: Bool { self == .telegram || self == .slack || self == .ios }
    /// Its destination says when it holds a reply (Telegram's and Slack's servers keep the conversation). The phone has redelivery, but no authenticated
    /// per-reply receipt from durable phone storage back to this owner. CloudKit acceptance alone cannot settle that obligation.
    public var acceptsDurably: Bool { self == .telegram || self == .slack }
  }

  public let surface: String
  public let sessionId: String?
  public let destinationId: String?
  public let threadId: String?
  public let sourceKey: String?
  public let replyTo: String?
  public let correlationId: String?
  /// Where the turn that produced the answer ran, when that is not the chat it answers (a contact's own conversation): its result marker is there.
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
