import NativeAgentCore
import CryptoKit
import Foundation
import NativeAgentShared
import ChatTurnContracts
import PersistenceCore
import TrustCenter

// Blueprint: | `InlineInteractionSignatureWitness.swift` | MAC-bound immutable continuation witness; persisted claims grant no signing authority |

extension InlineInteraction.Continuation {
    /// Stamp replay input once; the witness covers the exact origin the writer persists.
    package static func stamped(
        for interaction: InlineInteraction, sessionID: String,
        originRunId: String? = nil, toolCallId: String? = nil,
        toolName: String?, toolArgumentsJSON: String?, mode: Mode,
        state: ResumeState = .waiting, resumeText: String? = nil,
        peerSurface: String, originEnvelope: TurnEnvelope?, dataRoot: URL,
        turn: Turn
    ) throws -> Self {
        let steer = PeerDataTaint.carried(turn: turn,
            peerBridge: PeerTurnEffectPolicy.isPeerBridge(surface: peerSurface),
            peerID: turn.envelope?.verifiedUserId)
        var continuation = Self(
            originRunId: originRunId, toolCallId: toolCallId,
            toolName: toolName, toolArgumentsJSON: toolArgumentsJSON,
            mode: mode, state: state, resumeRunId: "interaction-\(interaction.id)",
            resumeText: resumeText, peerSources: steer.sources, elevatedPeerSources: steer.elevated)
        continuation.originTurnId = turn.id
        continuation.lifeID = try DataRootLife.current(in: dataRoot)
        continuation.fileAccessCeiling = turn.fileAccessCeiling
        continuation.signatureReceipt = InlineInteractionSignatureWitness.receipt(for: .init(
            sessionID: sessionID, interactionID: interaction.id, continuation: continuation,
            originEnvelope: originEnvelope, interaction: interaction),turn: turn)
        return continuation
    }
}

/// A MAC binds session, card, origin, arguments, text and route to live pairing material.
/// Edits or key rotation invalidate it. Persisted envelopes grant no signing verdict; absent pairing grants no minting.
public enum InlineInteractionSignatureWitness {
    /// Rebuild the witness from persisted fields at replay so tampering changes its MAC input.
    public struct Witness: Sendable {
        public let sessionID: String
        public let interactionID: String
        public let continuation: InlineInteraction.Continuation
        /// Canonicalize persisted origin on both sides; never persist or restore `commandSignatureVerified` as authority.
        public let originEnvelope: TurnEnvelope?
        /// Cover only immutable card text fields; state, revision and outcome legitimately change after minting.
        public let interaction: InlineInteraction?

        public init(
            sessionID: String,
            interactionID: String,
            continuation: InlineInteraction.Continuation,
            originEnvelope: TurnEnvelope?,
            interaction: InlineInteraction? = nil
        ) {
            self.sessionID = sessionID
            self.interactionID = interactionID
            self.continuation = continuation
            self.originEnvelope = originEnvelope
            self.interaction = interaction
        }

        /// Length-prefix every field so embedded separators cannot change witness boundaries.
        var canonical: String {
            let envelope = originEnvelope
                .map { TurnEnvelope.fromPersistedMetadata($0.persistedMetadata()) } ?? nil
            let route = envelope?.deliveryRoute
            var fields: [String] = [
                Self.version,
                sessionID,
                interactionID,
                continuation.resumeRunId,
                continuation.originTurnId ?? "",
                continuation.lifeID ?? "",
                envelope?.surface ?? "",
                envelope?.agent ?? "",
                envelope?.verifiedChatId ?? "",
                envelope?.verifiedUserId ?? "",
                // Bind the reply route so editing a destination cannot redirect signed authority.
                route?.destinationId ?? "",
                route?.threadId ?? "",
                route?.sourceKey ?? "",
                route?.replyTo ?? "",
                route?.correlationId ?? "",
                // Canonicalize remoteness identically on both sides; if a persisted row supplies it, the MAC must cover it.
                envelope?.declaredRemote.map(String.init) ?? "",
                continuation.mode.rawValue,
                continuation.toolName ?? "",
            ]
            // Bind the digest of exact replay arguments because they execute verbatim.
            fields.append(Self.digest(continuation.toolArgumentsJSON))
            // Bind continuation text and immutable quoted card fields so row edits cannot change a signed prompt.
            // Exclude outcome, claim and replay checkpoint because they legitimately change after minting.
            fields.append(Self.digest(continuation.resumeText))
            if let sources = continuation.peerSources {
                fields.append("peer-sources")
                fields.append(String(sources.count))
                fields.append(contentsOf: sources)
                let elevated = continuation.elevatedPeerSources ?? []
                fields.append(String(elevated.count))
                fields.append(contentsOf: elevated)
            }
            if let ceiling = continuation.fileAccessCeiling {
                fields.append("file-access-ceiling")
                fields.append(ceiling.signatureMaterial)
            }
            fields.append(Self.digest(interaction.map {
                "\($0.kind.rawValue)\u{1F}\($0.declineConsequence)"
            }))
            return fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        }

        /// Length-prefix absence separately from an empty value before hashing.
        private static func digest(_ value: String?) -> String {
            guard let value else { return "" }
            return SHA256.hash(data: Data(value.utf8))
                .map { String(format: "%02x", $0) }.joined()
        }

        static let version = "inline-interaction-witness/v4"
    }

    public typealias Minter = @Sendable (_ canonicalWitness: String) -> String?
    /// Verify against live pairing keys so rotation invalidates old receipts.
    public typealias Verifier = @Sendable (_ canonicalWitness: String, _ receipt: String) -> Bool

    // Keep the raw minter private so callers cannot bypass the signed-context check.
    nonisolated(unsafe) private static var minter: Minter?
    nonisolated(unsafe) private static var verifier: Verifier?

    public static func install(mint: @escaping Minter, verify: @escaping Verifier) {
        minter = mint
        verifier = verify
    }

    /// Mint only with both a signature-verified current turn and installed pairing owner.
    public static func receipt(for witness: Witness,turn: Turn) -> String? {
        // Inbound task-local and resumed-envelope verification may permit minting; only the resulting receipt survives replay.
        let signed = turn.envelope?.commandSignatureVerified == true
            || turn.envelope?.commandSignatureVerified == true
        guard signed else { return nil }
        return minter?(witness.canonical)
    }

    /// Rebuild the full witness at replay so transplanted or edited receipts cannot grant signature-verified authority.
    public static func isStillSigned(_ witness: Witness) -> Bool {
        guard let receipt = witness.continuation.signatureReceipt, !receipt.isEmpty
        else { return false }
        return verifier?(witness.canonical, receipt) ?? false
    }
}
