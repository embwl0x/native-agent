import Foundation
import NativeAgentCore
// Blueprint: | `Turn+Bots.swift` | `Turn` part standing bots own: the authenticated event a helper run answers |

private enum BotEventProvenancePart: TurnPart { static let unset: BotEventProvenance? = nil }

extension Turn {
    /// The authenticated event source, chat and user this helper run answers.
    public var botEventProvenance: BotEventProvenance? {
        get { self[BotEventProvenancePart.self] }
        set { self[BotEventProvenancePart.self] = newValue }
    }
}
