import CryptoKit
import Foundation
import NativeAgentShared
import ChatTurnContracts
import PersistenceCore
import TrustCenter

// Blueprint: | `InlineInteractionSignatureWitness.swift` | Shared continuation stamping binds replay identity, peer steering, DataRootLife and the persisted origin to a cryptographic witness; persisted transcript claims confer no signing authority |

extension InlineInteraction.Continuation {
    /// Stamp replay input once; the witness covers the exact origin the writer persists.
    package static func stamped(
        for interaction: InlineInteraction, sessionID: String,
        originRunId: String? = nil, toolCallId: String? = nil,
        toolName: String?, toolArgumentsJSON: String?, mode: Mode,
        state: ResumeState = .waiting, resumeText: String? = nil,
        peerSurface: String, originEnvelope: TurnEnvelope?, dataRoot: URL
    ) throws -> Self {
        let steer = PeerDataTaint.carried(
            peerBridge: PeerTurnEffectPolicy.isPeerBridge(surface: peerSurface),
            peerID: ChatToolSessionContext.envelope?.verifiedUserId)
        var continuation = Self(
            originRunId: originRunId, toolCallId: toolCallId,
            toolName: toolName, toolArgumentsJSON: toolArgumentsJSON,
            mode: mode, state: state, resumeRunId: "interaction-\(interaction.id)",
            resumeText: resumeText, peerSources: steer.sources, elevatedPeerSources: steer.elevated)
        continuation.lifeID = try DataRootLife.current(in: dataRoot)
        continuation.signatureReceipt = InlineInteractionSignatureWitness.receipt(for: .init(
            sessionID: sessionID, interactionID: interaction.id, continuation: continuation,
            originEnvelope: originEnvelope, interaction: interaction))
        return continuation
    }
}

/// A signed card resumes only through a MAC over its full witness, verified
/// against live pairing material. Persisted envelopes carry no signing verdict.
/// The receipt binds the session, card, origin, replay arguments and text;
/// editing those fields or rotating the pairing secret invalidates it.
/// The app installs the pairing owner; without it minting grants nothing.
public enum InlineInteractionSignatureWitness {
    /// Everything the receipt is bound to. Assembled identically at mint time
    /// and at replay — the replay side rebuilds it from the persisted row, so
    /// a tampered row produces a different witness and fails.
    public struct Witness: Sendable {
        public let sessionID: String
        public let interactionID: String
        public let continuation: InlineInteraction.Continuation
        /// The provenance envelope that is (or will be) persisted on this
        /// card's row. Canonicalized through `persistedMetadata()` so both
        /// sides see the same cleaned values, and `commandSignatureVerified`
        /// is deliberately not part of it — it never survives the row.
        public let originEnvelope: TurnEnvelope?
        /// The card itself, read ONLY for the immutable fields that compose
        /// the text the resumed turn is told (see `canonical`). Its state,
        /// revision and outcome move after the receipt is minted and are
        /// deliberately not covered.
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

        /// Unambiguous byte string for the MAC. Every field is
        /// length-prefixed, so no value can be re-split into a different set
        /// of fields by spelling a separator inside itself.
        var canonical: String {
            let envelope = originEnvelope
                .map { TurnEnvelope.fromPersistedMetadata($0.persistedMetadata()) } ?? nil
            let route = envelope?.deliveryRoute
            var fields: [String] = [
                Self.version,
                sessionID,
                interactionID,
                continuation.resumeRunId,
                continuation.lifeID ?? "",
                envelope?.surface ?? "",
                envelope?.agent ?? "",
                envelope?.verifiedChatId ?? "",
                envelope?.verifiedUserId ?? "",
                // WHERE the reply goes is part of this card's identity too.
                // Without these, a receipt stayed valid over an edited route:
                // same signed authority, answer delivered somewhere else.
                route?.destinationId ?? "",
                route?.threadId ?? "",
                route?.sourceKey ?? "",
                route?.replyTo ?? "",
                route?.correlationId ?? "",
                // Persisted metadata carries no remoteness declaration, so the
                // canonicalized value is absent on BOTH sides today; covered
                // here so a row that ever does carry one is bound by the MAC.
                envelope?.declaredRemote.map(String.init) ?? "",
                continuation.mode.rawValue,
                continuation.toolName ?? "",
            ]
            // The arguments are replayed VERBATIM, so the digest of that exact
            // text is what the receipt has to cover: a receipt that did not
            // name these arguments cannot authorize this call.
            fields.append(Self.digest(continuation.toolArgumentsJSON))
            // The continuation TEXT is replayed just as verbatim. `resumeText`
            // IS the resumed prompt on the no-provider path, and the immutable
            // card fields below are quoted into `continuationPrompt`
            // everywhere else — so without them an edited row could put
            // different words into a turn that still verified as signed.
            // Mutable fields (outcome, claim, replay checkpoint) stay out:
            // they move on the row after the mint.
            fields.append(Self.digest(continuation.resumeText))
            if let sources = continuation.peerSources {
                fields.append("peer-sources")
                fields.append(String(sources.count))
                fields.append(contentsOf: sources)
                let elevated = continuation.elevatedPeerSources ?? []
                fields.append(String(elevated.count))
                fields.append(contentsOf: elevated)
            }
            fields.append(Self.digest(interaction.map {
                "\($0.kind.rawValue)\u{1F}\($0.declineConsequence)"
            }))
            return fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        }

        /// Hex SHA-256, empty for an absent value. The length prefix above
        /// keeps "absent" and "empty" distinguishable.
        private static func digest(_ value: String?) -> String {
            guard let value else { return "" }
            return SHA256.hash(data: Data(value.utf8))
                .map { String(format: "%02x", $0) }.joined()
        }

        static let version = "inline-interaction-witness/v3"
    }

    /// Mints a receipt over a canonical witness string, or nil when no pairing
    /// owner is installed.
    public typealias Minter = @Sendable (_ canonicalWitness: String) -> String?
    /// Re-checks a stored receipt against the LIVE key material.
    public typealias Verifier = @Sendable (_ canonicalWitness: String, _ receipt: String) -> Bool

    // Private on purpose: a caller holding the raw minter could mint a receipt
    // for any witness it liked, with no signed-context check in the way.
    nonisolated(unsafe) private static var minter: Minter?
    nonisolated(unsafe) private static var verifier: Verifier?

    /// Installs the pairing half. Called once at launch by the app.
    public static func install(mint: @escaping Minter, verify: @escaping Verifier) {
        minter = mint
        verifier = verify
    }

    /// Nil unless the current turn is signature-verified AND a minter is
    /// installed. Callers store the result verbatim on the continuation.
    public static func receipt(for witness: Witness) -> String? {
        // Either binding counts: the inbound paths bind the task-local, a
        // resumed turn binds the whole envelope. Neither is trusted further
        // than minting — the receipt is what survives to the replay.
        let signed = ChatToolSessionContext.commandSignatureVerified == true
            || ChatToolSessionContext.envelope?.commandSignatureVerified == true
        guard signed else { return nil }
        return minter?(witness.canonical)
    }

    /// Whether this continuation may replay as a signature-verified turn.
    /// The witness is rebuilt from the row being replayed, so a receipt
    /// transplanted from another card, session, or an edited row fails here.
    public static func isStillSigned(_ witness: Witness) -> Bool {
        guard let receipt = witness.continuation.signatureReceipt, !receipt.isEmpty
        else { return false }
        return verifier?(witness.canonical, receipt) ?? false
    }
}
