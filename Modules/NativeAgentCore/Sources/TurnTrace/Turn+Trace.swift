import Foundation
import NativeAgentCore
// Blueprint: | `Turn+Trace.swift` | `Turn` parts TurnTrace owns: the reply row the surface already draws and a reader of the envelope's trace route |

private enum ReplyRowPart: TurnPart { static let unset: TurnTraceContext.ReplyRow? = nil }
private enum ReplyRouteReaderPart: TurnPart {
    static let unset: (@Sendable (Turn) -> (destinationId: String?, threadId: String?))? = nil
}

extension Turn {
    /// The envelope owner binds its reader whenever it sets the envelope.
    /// Read the supplied turn's current route; never retain a second route snapshot.
    public var traceReplyRoute: (@Sendable (Turn) -> (destinationId: String?, threadId: String?))? {
        get { self[ReplyRouteReaderPart.self] }
        set { self[ReplyRouteReaderPart.self] = newValue }
    }

    /// The row a surface is drawing this turn's reply in: the answer is saved under it.
    public var replyRow: TurnTraceContext.ReplyRow? {
        get { self[ReplyRowPart.self] }
        set { self[ReplyRowPart.self] = newValue }
    }
}
