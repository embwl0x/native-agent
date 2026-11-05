import Foundation
import NativeAgentCore
import TrustCenter
// Blueprint: | `SecurityOriginContext+Turn.swift` | `SecurityOriginContext.currentTurn`: ingress-bound origin proof |

extension SecurityOriginContext {
    /// Read security provenance only from the ingress-bound turn envelope. A remote adapter can dispatch under the shared chat surface; trusting that spelling
    /// would grant local authority before the allowlist. Missing provenance stays unbound.
    public static func currentTurn(turn: Turn?,
        surface: String, source: String = "chat_runtime"
    ) -> SecurityOriginContext {
        let sessionId = turn?.verifiedSessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let usableSessionId = sessionId?.isEmpty == false ? sessionId : nil
        let envelope = TurnEnvelope.current(turn: turn, surface: surface)
        // Remoteness can only widen: declaredRemote adds to the surface profile's remote classification, never subtracts from it.
        let remote = ConversationSurfaceProfile(envelope.surface).isRemote
            || envelope.declaredRemote == true
        return SecurityOriginContext(
            surface: envelope.surface,
            sessionId: usableSessionId,
            userId: envelope.verifiedUserId,
            chatId: envelope.verifiedChatId,
            deviceId: nil,
            source: source,
            isRemote: remote,
            commandSignatureVerified: envelope.commandSignatureVerified
        )
    }
}
