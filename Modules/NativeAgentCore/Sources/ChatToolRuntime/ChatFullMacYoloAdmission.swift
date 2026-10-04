import Foundation
import NativeAgentCore
import TrustCenter

/// Assembles current-task provenance; TrustCenter alone evaluates authority.
public enum ChatFullMacYoloAdmission {
    public static func admitted(tool: String, surface: String, dataRoot: URL, source: String) async -> Bool {
        var origin = SecurityOriginContext.currentTurn(
            verifiedSessionId: ChatToolSessionContext.verifiedSessionId, surface: surface
        )
        origin.source = source
        let authority = await SwiftNativeSecurityCenter(dataRoot: dataRoot).fullMacYoloAuthority(
            tool: tool,
            origin: origin
        )
        return authority.admitted
    }
}

extension SecurityOriginContext {
    /// THE origin projection. Every security field here comes from the TURN
    /// ENVELOPE, not from the `surface` the caller happened to dispatch under.
    ///
    /// That distinction is the whole point. A remote adapter binds
    /// `TurnEnvelope(surface: "signal", declaredRemote: true, verifiedUserId: …)`
    /// while its `client.chat` call still runs with the shared tool surface
    /// `"chat"` (the bridges deliberately do exactly that). Reading `surface`
    /// here would then hand a genuinely remote turn a LOCAL, trusted origin —
    /// `assessOrigin` short-circuits to "local app surface" before any
    /// allowlist is consulted. The envelope is the one value that knows what
    /// the turn actually is, so it is the one value this reads.
    ///
    /// `TurnEnvelope.current(surface:)` is the ONLY path to the task-locals:
    /// when no envelope is bound it composes one from them, so a pre-envelope
    /// adapter keeps its exact behavior and there is no second place that can
    /// disagree about identity.
    public static func currentTurn(
        verifiedSessionId: String?,
        surface: String
    ) -> SecurityOriginContext {
        let sessionId = verifiedSessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let usableSessionId = sessionId?.isEmpty == false ? sessionId : nil
        let envelope = TurnEnvelope.current(surface: surface)
        // Remoteness only ever WIDENS: the surface profile owns the known
        // remote set, and `declaredRemote` can add remoteness to a surface the
        // profile has not heard of yet. Neither can subtract it — see the
        // same rule restated in `SecurityCenter.assessOrigin`.
        let remote = ConversationSurfaceProfile(envelope.surface).isRemote
            || envelope.declaredRemote == true
        return SecurityOriginContext(
            surface: envelope.surface,
            sessionId: usableSessionId,
            userId: envelope.verifiedUserId,
            chatId: envelope.verifiedChatId,
            deviceId: nil,
            source: "chat_runtime",
            isRemote: remote,
            commandSignatureVerified: envelope.commandSignatureVerified
        )
    }
}
