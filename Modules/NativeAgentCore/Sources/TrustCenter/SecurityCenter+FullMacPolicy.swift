import Foundation
import MacControl
import NativeAgentCore
import PersistenceCore

extension SwiftNativeSecurityCenter {
    static func fullMacActive(policy: [String: JSONValue], now: Date = Date()) -> Bool {
        guard let trust = MacControlPolicy.fromTrustPolicyObject(policy).trustPolicy else {
            return false
        }
        return MacControlGate.fullMacActive(trust, now: now)
    }

    static func fullMacExpiresAt(policy: [String: JSONValue]) -> String? {
        if Self.bool(policy["fullMacNeverExpires"], default: false) {
            return "never"
        }
        guard let expiresAt = Self.string(policy["fullMacExpiresAt"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !expiresAt.isEmpty else {
            return nil
        }
        return expiresAt
    }

    /// The public checked authority door for non-chat/raw consumers. A damaged
    /// saved policy is distinguishable from an inactive grant and always fails
    /// closed. Remote trust is resolved from the concrete origin here; a caller
    /// cannot obtain YOLO authority by supplying only a surface label.
    public func fullMacYoloAuthority(
        tool: String,
        origin: SecurityOriginContext
    ) async -> FullMacYoloAuthorityAssessment {
        do {
            let snapshot = try await trustCenter.loadAuthorizationSnapshotChecked()
            let originAssessment = await assessOrigin(origin, policy: snapshot.policy)
            return Self.fullMacYoloAuthority(
                tool: tool,
                surface: origin.surface,
                originAssessment: originAssessment,
                snapshot: snapshot,
                now: clock()
            )
        } catch {
            return FullMacYoloAuthorityAssessment(
                state: .unavailable,
                reason: "saved trust policy is unavailable: \(error.localizedDescription)"
            )
        }
    }

    /// Shared pure evaluator for owners that already hold one checked
    /// authorization generation. This is the single YOLO vocabulary: there is
    /// intentionally no tool exclusion list. Explicit `blocked` is the only
    /// per-tool posture that outranks an admitted grant; hard SecurityCenter
    /// and domain decisions remain blocks rather than ask/confirm policy.
    static func fullMacYoloAuthority(
        tool: String,
        surface: String,
        originAssessment: OriginAssessment,
        snapshot: TrustPolicyAuthorizationSnapshot,
        now: Date
    ) -> FullMacYoloAuthorityAssessment {
        guard Self.fullMacActive(policy: snapshot.policy, now: now) else {
            return FullMacYoloAuthorityAssessment(
                state: .inactive,
                reason: "Full Mac grant is inactive or expired"
            )
        }
        let canonicalTool = Self.canonicalToolName(tool)
        if SwiftNativeTrustCenter.hasExplicitBlockOverride(
            tool,
            overrides: snapshot.userConfiguredAutonomyOverrides
        ) || (canonicalTool != tool && SwiftNativeTrustCenter.hasExplicitBlockOverride(
            canonicalTool,
            overrides: snapshot.userConfiguredAutonomyOverrides
        )) {
            return FullMacYoloAuthorityAssessment(
                state: .explicitlyBlocked,
                reason: "tool is explicitly blocked by the user"
            )
        }

        let normalizedSurface = surface
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if originAssessment.isRemote {
            guard originAssessment.trusted,
                  fullMacYoloTrustedRemoteSurfaces.contains(normalizedSurface) else {
                return FullMacYoloAuthorityAssessment(
                    state: .untrustedOrigin,
                    reason: originAssessment.reason
                )
            }
        } else if !fullMacYoloLocalSurfaces.contains(normalizedSurface) {
            return FullMacYoloAuthorityAssessment(
                state: .untrustedOrigin,
                reason: "surface is not an admitted Full Mac operator surface"
            )
        }
        return FullMacYoloAuthorityAssessment(
            state: .admitted,
            reason: originAssessment.reason
        )
    }

    /// Checked-snapshot variant for TrustCenter consumers that already received
    /// the concrete origin proof from SecurityCenter.
    public nonisolated static func fullMacYoloAuthority(
        tool: String,
        surface: String,
        originTrusted: Bool,
        snapshot: TrustPolicyAuthorizationSnapshot,
        now: Date = Date()
    ) -> FullMacYoloAuthorityAssessment {
        let remote = ConversationSurfaceProfile(surface).isRemote
        return fullMacYoloAuthority(
            tool: tool,
            surface: surface,
            originAssessment: OriginAssessment(
                trusted: remote ? originTrusted : true,
                reason: remote
                    ? (originTrusted ? "origin authenticated by conversation surface" : "remote origin is not authenticated")
                    : "local app surface",
                isRemote: remote
            ),
            snapshot: snapshot,
            now: now
        )
    }

    /// P2-3: `workshop` is the canonical Workshop surface; `mission`/`missions`
    /// stay for turns that still arrive on the 0.3.x spelling. Dropping either
    /// makes full-mac yolo quietly stop elevating Workshop builder steps.
    ///
    /// Wave 5b: the Workshop spellings come from
    /// `WorkshopSurfaceVocabulary.gateSpellings` rather than being open-coded
    /// here, per this vocabulary's own rule (no caller may hand-write an
    /// `== "missions"` check). Same three strings, same membership.
    static let fullMacYoloLocalSurfaces: Set<String> = Set(
        [
            "chat", "desk", "codex-bridge", "claude-bridge",
            "connector_action", "nextgen_action", "native_actions", "mcp_ui",
        ]
            + WorkshopSurfaceVocabulary.gateSpellings
    )

    static let fullMacYoloTrustedRemoteSurfaces: Set<String> = [
        "telegram",
        "slack",
        "ios",
        "icloud",
        "iphone",
        "ipad",
        "mobile",
        "watch",
        "remote",
    ]

}
