import CryptoKit
import Foundation
import NativeAgentShared

/// The seam that lets a card raised by a SIGNED turn resume as one, without
/// ever writing "this was signed" into the transcript as a fact.
///
/// A signed iOS turn carries `commandSignatureVerified` from cryptographic
/// evidence the inbound path checked against the live pairing secret. The
/// persisted envelope deliberately does NOT carry that flag — a persisted
/// trust verdict is exactly the "authority from history" `TurnEnvelope`
/// forbids — so a card raised on the phone used to replay with no signature at
/// all and the iOS trust gate refused it.
///
/// The fix is not to persist the boolean. It is to persist a RECEIPT: a MAC
/// over this continuation's own identity, minted from the same pairing secret
/// at the moment the signed turn raised the card, and RE-VERIFIED against the
/// live secret at replay. A transcript nobody signed cannot produce one, and a
/// receipt minted under a secret that has since been rotated — the phone was
/// unpaired — stops verifying, which is the honest answer: sign in again.
///
/// What the MAC covers is the whole `Witness` below, not just the resume id.
/// A MAC over the resume id alone is a receipt for "some card", so a valid one
/// lifted off any signed card could be pasted onto an edited row — a different
/// tool, different arguments, another session — and that row would replay with
/// signed authority. The witness binds the receipt to the exact row being
/// replayed: which session, which interaction, which origin, which tool, and a
/// digest of the exact argument text. Change any of it and the MAC no longer
/// verifies.
///
/// The key material lives in the app (`PairingSecretManager`), so the two
/// halves are installed at launch. Uninstalled, minting returns nil and
/// verification refuses: a build with no pairing owner grants nothing.
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
