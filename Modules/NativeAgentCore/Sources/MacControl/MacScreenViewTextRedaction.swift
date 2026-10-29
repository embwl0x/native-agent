import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Senses
import TrustCenter
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(CoreText)
import CoreText
#endif
#if canImport(ScreenCaptureKit) && os(macOS)
import ScreenCaptureKit
#endif
#if canImport(AppKit)
import AppKit
import ApplicationServices
import UserNotifications
import Experiences
import CryptoKit
import os
#endif
// Blueprint: | `MacScreenViewTextRedaction.swift` | One secret-decision owner for text, pixels and enclosing captions |
/// Keeps a secret that is merely DISPLAYED out of the fused view's text channel.
///
/// Displayed secrets include static text; redact secret shapes while keeping prose legible:
///
///   • a lone 6–8 digit code (an OTP and nothing else in the line);
///   • a long high-entropy single token, or one carrying a known key prefix;
///   • a run of bullets/asterisks (a masked field, drawn as text);
///   • `label: value` on one line where the label names a secret and the value
///     is a single token — "API key: sk-live-…";
///   • a code-shaped token sitting immediately right of / below a SHORT label
///     that names a secret — the same proximity heuristic the legend uses to
///     name an unlabeled control, because a form reads the same way either way.
///
/// Each detector below guards against matching ordinary prose.
public enum MacScreenViewTextRedaction {
    /// Field names use these hints without the prose caption-length or code-disqualifier rules.
    public static let secretFieldLabelTokens: [String] = [
        "password", "passcode", "passphrase", "secret", "api key", "api-key",
        "token", "pin code", "security code", "2fa", "one-time code",
    ]
    /// Words that make a SHORT nearby line a secret LABEL. Matched only against
    /// labels (≤ `maxLabelChars`), never against the body of a sentence.
    public static let secretLabelTokens = secretFieldLabelTokens.filter {
        $0 != "pin code" && $0 != "one-time code"
    } + [
        "two-factor", "two factor", "one-time", "one time", "otp", "apikey",
        "recovery", "verification code",
        "auth code", "authentication code", "access key", "private key",
        "pin", "code",
        "cvv", "cvc", "csc", "card verification", "card security",
        "seed phrase", "recovery phrase", "seed words", "recovery words",
        "mnemonic", "backup phrase", "secret phrase", "card number",
    ]
    /// A label naming the 3–4 digit code on the back of a card. Split out from
    /// `secretLabelTokens` because its VALUE is shorter than any other secret
    /// we redact — three digits — and only a label this specific earns the
    /// right to darken something that short. "Security code" lives here AND in
    /// the generic list; the disqualifier pass never applies to these.
    public static let cardVerificationLabelTokens: [String] = [
        "cvv", "cvc", "csc", "cvv2", "cid",
        "security code", "card verification", "card security",
    ]
    /// A label naming a wallet's recovery words. Under one of these, a run of
    /// lowercase words far SHORTER than the unlabeled bar is still the secret.
    public static let seedPhraseLabelTokens: [String] = [
        "seed phrase", "recovery phrase", "seed words", "recovery words",
        "mnemonic", "backup phrase", "secret phrase", "secret recovery phrase",
    ]
    /// Function words that are common in English prose. Used ONLY as a
    /// false-positive guard on the unlabeled seed-phrase shape: a run of
    /// lowercase words containing any of these is a sentence, not a wallet
    /// backup. Deliberately conservative — a wordlist phrase that happens to
    /// contain one of these is MISSED rather than prose being darkened, and an
    /// explicitly labeled phrase is caught regardless of this list.
    public static let proseFunctionWords: Set<String> = [
        "the", "and", "that", "this", "with", "for", "are", "was", "not",
        "but", "have", "from", "they", "his", "her", "has", "had", "were",
        "been", "will", "can", "out", "how", "why", "when", "what", "who",
        "which", "there", "here", "then", "than", "into", "just", "like",
        "some", "more", "most", "only", "very", "after", "before", "because",
        "them", "him", "your", "our", "their", "its", "would", "could",
        "should", "said", "says", "our", "you",
    ]
    /// "Code" is the most useful indicator and the most dangerous one: a screen
    /// is full of zip codes, area codes, promo codes and error codes. A label
    /// whose "code" is qualified by any of these is not naming a secret.
    public static let codeDisqualifiers: [String] = [
        "zip", "postal", "post code", "area", "country", "dial", "promo",
        "coupon", "discount", "error", "status", "color", "colour", "qr",
        "barcode", "bar code", "source", "product", "language", "currency",
        "airport", "region", "state", "sort code", "swift code", "referral",
        "invite", "tracking",
    ]
    /// Known secret prefixes: short but unambiguous, so they bypass the length
    /// bar an unlabeled random token has to clear.
    public static let knownSecretPrefixes: [String] = [
        "sk-", "sk_", "pk_", "rk_", "ghp_", "gho_", "ghu_", "ghs_",
        "github_pat_", "xoxb-", "xoxp-", "xoxa-", "akia", "asia", "aiza",
        "ya29.", "eyj", "npm_", "glpat-", "shpat_",
    ]
    /// A label longer than this is a sentence, not a caption.
    public static let maxLabelChars = 40
    /// A redactable VALUE is a token, not a paragraph.
    public static let maxValueChars = 128
    /// Same reach the legend's label inference uses, for the same reason.
    public static let proximityPoints: Double = 240
    /// The replacement: never the characters, always enough to audit them.
    /// Same digest shape as `MacInjectionResultRedaction.redactedSecret`, plus
    /// the reason — a caller deserves to know WHY a line went dark, otherwise
    /// redaction is indistinguishable from the organ failing to see.
    public static func redactedText(_ secret: String, reason: String) -> JSONValue {
        guard case .object(var object) =
            MacInjectionResultRedaction.redactedSecret(secret) else {
            return .object(["redacted": .bool(true), "reason": .string(reason)])
        }
        object["reason"] = .string(reason)
        return .object(object)
    }
    /// Is this line, ON ITS OWN, a secret? Independent of neighbours, so it
    /// also guards the legend's labels and values.
    public static func standaloneSecretReason(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if isMaskedRun(text) { return "masked_secret" }
        if isOneTimeCode(text) { return "otp_shape" }
        if let inline = inlineLabeledSecretReason(text) { return inline }
        // Check shapes cheapest-first, each with its own false-positive guard.
        if isPaymentCardNumber(text) { return "card_number_shape" }
        if isRecoveryPhrase(text) { return "recovery_phrase_shape" }
        if isHighEntropyToken(text) { return "high_entropy_token" }
        if isBase64Token(text) { return "high_entropy_token" }
        return nil
    }
    /// Does this SHORT line name the 3–4 digit card verification code?
    public static func isCardVerificationLabel(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, text.count <= maxLabelChars else { return false }
        return cardVerificationLabelTokens.contains { token in
            // "cid"/"cvc" are short enough to appear inside another word, so a
            // 3-letter token has to sit on a word boundary.
            guard token.count <= 3 else { return text.contains(token) }
            return text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .contains { $0.lowercased() == token }
        }
    }
    /// Does this SHORT line name a wallet recovery phrase?
    public static func isSeedPhraseLabel(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, text.count <= maxLabelChars else { return false }
        return seedPhraseLabelTokens.contains { text.contains($0) }
    }
    /// Exactly 3–4 digits and nothing else. Only ever redacted UNDER a card
    /// verification label — on its own, three digits is a quantity.
    static func isShortCodeValue(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3, text.count <= 4 else { return false }
        return text.allSatisfy { $0.isNumber }
    }
    /// Does this SHORT line name a secret — i.e. is it the caption of a secret
    /// field/value? Never true for a sentence.
    public static func looksLikeSecretLabel(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, text.count <= maxLabelChars else { return false }
        guard secretLabelTokens.contains(where: { text.contains($0) }) else { return false }
        // Qualified "code" labels (zip/area/promo/…) are not secrets. Only the
        // bare-"code" match needs the guard: every other token in the list is
        // unambiguous on its own.
        let matchedOnlyCode = !secretLabelTokens.contains {
            $0 != "code" && $0 != "pin" && text.contains($0)
        }
        if matchedOnlyCode, codeDisqualifiers.contains(where: { text.contains($0) }) {
            return false
        }
        return true
    }
    /// Transfer the shared node verdict to visible text without truncating it.
    /// Paths align with items; context includes captions from the whole snapshot.
    public static func applied(
        to items: [MacScreenViewBuilder.VisibleText],
        paths: [[Int]] = [],
        context: NodeSecretContext
    ) -> [MacScreenViewBuilder.VisibleText] {
        return items.enumerated().map { index, item in
            let enclosing = index < paths.count
                ? enclosingKinds(forNodeAt: item.frame, path: paths[index], among: context.enclosingCaptions) : .none
            let verdict = redactedNodeString(item.text, valueChars: .max, frame: item.frame,
                under: nil, enclosing: enclosing, context: context)
            guard case .object(let object) = verdict, case .string(let reason)? = object["reason"] else { return item }
            return MacScreenViewBuilder.VisibleText(text: item.text, frame: item.frame, redactionReason: reason)
        }
    }
    /// The legend's mirror of `applied`: a name or a value that is itself a
    /// secret never rides out as a label row either.
    /// - Parameter under: the control's own label, when this string is that
    ///   control's VALUE. A legend row carries its own caption, so the CVV box
    ///   labeled "CVV" showing `123` is the positional shape the prose channel
    ///   already redacts — without this the same three digits ride out in the
    ///   legend. Nil for a label (a label has no label).
    /// - Parameter enclosing: secret-naming ancestor groups, including captions absent from `under`.
    public static func redactedLegendString(
        _ text: String,
        valueChars: Int,
        under label: String? = nil,
        enclosing: EnclosingCaptionKinds = .none
    ) -> JSONValue {
        if let reason = standaloneSecretReason(text) {
            return redactedText(text, reason: reason)
        }
        if let reason = enclosingSecretReason(text, kinds: enclosing) {
            return redactedText(text, reason: reason)
        }
        if let label {
            if isCardVerificationLabel(label), isShortCodeValue(text) {
                return redactedText(text, reason: "labeled_cvv")
            }
            if isSeedPhraseLabel(label), isRecoveryPhrase(text, labeled: true) {
                return redactedText(text, reason: "labeled_recovery_phrase")
            }
            if looksLikeSecretLabel(label), isLabeledSecretValue(text) {
                return redactedText(text, reason: "labeled_secret_nearby")
            }
        }
        return .string(MacAccessibilityReader.truncate(text, to: valueChars))
    }
    /// Redact action-result name/value echoes too; existing redaction objects pass through unchanged.
    public static func redactedElementJSON(
        _ value: JSONValue,
        valueChars: Int = MacAXLimits.hardValueChars,
        under caption: String? = nil,
        enclosing: EnclosingCaptionKinds = .none
    ) -> JSONValue {
        guard case .object(var object) = value else { return value }
        let nameKeys = ["label", "title"]
        var label = caption
        for key in nameKeys {
            guard case .string(let raw)? = object[key] else { continue }
            label = label ?? raw
            object[key] = redactedLegendString(raw, valueChars: valueChars, enclosing: enclosing)
        }
        if case .string(let raw)? = object["value"] {
            object["value"] = redactedLegendString(raw, valueChars: valueChars, under: label, enclosing: enclosing)
        }
        return .object(object)
    }
    /// Redact text at serialization with the view's detectors; the shared AX reader stays read-only.
    /// Preserve role, subrole, enabled, frame, actions, path and score so redacted nodes stay addressable.
    public struct NodeSecretContext: Sendable {
        public let secretLabelFrames: [MacAXFrame]
        public let cvvLabelFrames: [MacAXFrame]
        public let seedLabelFrames: [MacAXFrame]
        /// An ancestor GROUP whose
        /// title names a secret and whose frame contains the value.
        public let enclosingCaptions: [EnclosingCaption]
        public init(
            secretLabelFrames: [MacAXFrame],
            cvvLabelFrames: [MacAXFrame],
            seedLabelFrames: [MacAXFrame],
            enclosingCaptions: [EnclosingCaption] = []
        ) {
            self.secretLabelFrames = secretLabelFrames
            self.cvvLabelFrames = cvvLabelFrames
            self.seedLabelFrames = seedLabelFrames
            self.enclosingCaptions = enclosingCaptions
        }
        public static let empty = NodeSecretContext(
            secretLabelFrames: [], cvvLabelFrames: [], seedLabelFrames: []
        )
    }
    /// Which frames on this screen are CAPTIONS naming a secret. Built from the
    /// WHOLE snapshot — including nodes a `find` query did not match — because a
    /// caption two rows away still names the value beside it.
    public static func nodeSecretContext(_ nodes: [MacAXNode]) -> NodeSecretContext {
        var secret: [MacAXFrame] = []
        var cvv: [MacAXFrame] = []
        var seed: [MacAXFrame] = []
        for node in nodes {
            guard let frame = node.attributes.frame else { continue }
            for candidate in [node.attributes.title, node.attributes.value].compactMap({ $0 }) {
                if looksLikeSecretLabel(candidate) { secret.append(frame) }
                if isCardVerificationLabel(candidate) { cvv.append(frame) }
                if isSeedPhraseLabel(candidate) { seed.append(frame) }
            }
        }
        return NodeSecretContext(
            secretLabelFrames: secret,
            cvvLabelFrames: cvv,
            seedLabelFrames: seed,
            enclosingCaptions: enclosingCaptions(nodes)
        )
    }
    /// One node's text field, judged by shape on its own, then by the caption it
    /// carries (`under`), then by the caption sitting beside/above it.
    static func redactedNodeString(
        _ text: String,
        valueChars: Int,
        frame: MacAXFrame?,
        under label: String?,
        enclosing: EnclosingCaptionKinds = .none,
        context: NodeSecretContext
    ) -> JSONValue {
        let redacted = redactedLegendString(text, valueChars: valueChars, under: label, enclosing: enclosing)
        guard case .string = redacted else { return redacted }
        if let frame {
            func near(_ frames: [MacAXFrame]) -> Bool {
                frames.contains { $0 != frame && labelDistance($0, forValueAt: frame, proximity: proximityPoints) != nil }
            }
            if isShortCodeValue(text), near(context.cvvLabelFrames) {
                return redactedText(text, reason: "labeled_cvv")
            }
            if isRecoveryPhrase(text, labeled: true), near(context.seedLabelFrames) {
                return redactedText(text, reason: "labeled_recovery_phrase")
            }
            if isLabeledSecretValue(text), near(context.secretLabelFrames) {
                return redactedText(text, reason: "labeled_secret_nearby")
            }
        }
        return redacted
    }
    /// Serialize one AX node with its text channels redacted and every
    /// addressing channel intact.
    public static func redactedNodeFields(
        _ node: MacAXNode,
        valueChars: Int = MacAXLimits.hardValueChars,
        context: NodeSecretContext = .empty
    ) -> [String: JSONValue] {
        let attributes = node.attributes
        var object: [String: JSONValue] = [
            "role": .string(attributes.role),
            "enabled": .bool(attributes.enabled),
            "actions": .array(attributes.actions.map { .string($0) }),
            "path": .array(node.path.map { .int(Int64($0)) }),
        ]
        if let subrole = attributes.subrole { object["subrole"] = .string(subrole) }
        if let selected = attributes.selected { object["selected"] = .bool(selected) }
        if let state = attributes.state { object["state"] = .string(state) }
        if let frame = attributes.frame { object["frame"] = frame.toJSON() }
        if let summary = attributes.listSummary { object["list_summary"] = .string(summary) }
        let frame = node.attributes.frame
        // Include secret-naming groups enclosing this node.
        let enclosing = enclosingKinds(
            forNodeAt: frame,
            path: node.path,
            among: context.enclosingCaptions
        )
        if let title = node.attributes.title {
            object["title"] = redactedNodeString(
                title,
                valueChars: valueChars,
                frame: frame,
                under: nil,
                enclosing: enclosing,
                context: context
            )
        }
        if let value = node.attributes.value {
            object["value"] = MacScreenViewBuilder.isSecretField(
                role: node.attributes.role,
                subrole: node.attributes.subrole,
                label: node.attributes.title
            ) ? MacInjectionResultRedaction.redactedSecret(value) : redactedNodeString(
                value,
                valueChars: valueChars,
                frame: frame,
                // A control's own title IS its caption — the "CVV" box showing
                // `123`, the "API key" field showing the key.
                under: node.attributes.title,
                enclosing: enclosing,
                context: context
            )
        }
        return object
    }
    /// `mac_ax_tree`'s node array.
    public static func redactedNodesJSON(
        _ nodes: [MacAXNode],
        valueChars: Int = MacAXLimits.hardValueChars
    ) -> [JSONValue] {
        let context = nodeSecretContext(nodes)
        return nodes.map { .object(redactedNodeFields($0, valueChars: valueChars, context: context)) }
    }
    /// `mac_ax_find`'s match array. Same redaction, `score` preserved — a match
    /// on a redacted node is still a usable handle.
    public static func redactedMatchesJSON(
        _ matches: [MacAXMatch],
        valueChars: Int = MacAXLimits.hardValueChars,
        context: NodeSecretContext
    ) -> [JSONValue] {
        matches.map { match in
            var object = redactedNodeFields(match.node, valueChars: valueChars, context: context)
            object["score"] = .double(match.score)
            return .object(object)
        }
    }
    /// A secret-naming ancestor can caption an untitled field by containment:
    ///
    ///     AXGroup  title="CVV"          ← encloses
    ///       AXTextField  value="451"    ← no title of its own
    ///
    /// Containment uses the shared caption vocabulary and shape detectors, with stricter matching:
    ///
    ///   • the caption must NAME a secret — a group titled "Payment", "Form",
    ///     "Account" or "Toolbar" is ordinary structure and its children stay
    ///     fully legible;
    ///   • the secret word must be a WORD, not a substring — "Shipping"
    ///     contains "pin" and a shipping section is not a secret. Nearby captions use substrings.
    ///   • the ROOT window is never an enclosing caption. It encloses
    ///     everything, so a window titled "Recovery Code" would blank the whole
    ///     screen; the window title is redacted on its own, standalone.
    ///   • the value still has to have a secret SHAPE. A toolbar group named
    ///     "Password" enclosing a "New Tab" button keeps its button.
    public struct EnclosingCaptionKinds: Sendable, Equatable {
        public let secret: Bool
        public let cvv: Bool
        public let seed: Bool
        public init(secret: Bool = false, cvv: Bool = false, seed: Bool = false) {
            self.secret = secret
            self.cvv = cvv
            self.seed = seed
        }
        public var any: Bool { secret || cvv || seed }
        public static let none = EnclosingCaptionKinds()
        public func merged(with other: EnclosingCaptionKinds) -> EnclosingCaptionKinds {
            EnclosingCaptionKinds(
                secret: secret || other.secret,
                cvv: cvv || other.cvv,
                seed: seed || other.seed
            )
        }
    }
    /// One node that both NAMES a secret and ENCLOSES things: a candidate
    /// ancestor. `path` is what makes it an ancestor rather than merely a
    /// bigger overlapping rectangle — frame containment alone would let a
    /// full-window backdrop caption a control it has no relationship to.
    public struct EnclosingCaption: Sendable, Equatable {
        public let frame: MacAXFrame
        public let path: [Int]
        public let kinds: EnclosingCaptionKinds
        public init(frame: MacAXFrame, path: [Int], kinds: EnclosingCaptionKinds) {
            self.frame = frame
            self.path = path
            self.kinds = kinds
        }
    }
    /// Words, not substrings: `"Shipping"` must not match `"pin"`.
    /// Normalizes both sides (lowercase, every non-alphanumeric run becomes a
    /// single space) so a multi-word token like `"api key"` or `"one-time"`
    /// matches `"API Key:"` and `"One-Time Code"` on the same rule.
    static func captionWords(_ raw: String) -> String {
        let words = raw.lowercased().split { !$0.isLetter && !$0.isNumber }
        return " " + words.joined(separator: " ") + " "
    }
    static func captionContainsWord(_ normalized: String, anyOf tokens: [String]) -> Bool {
        tokens.contains { token in
            let needle = captionWords(token)
            guard needle.count > 2 else { return false }
            return normalized.contains(needle)
        }
    }
    /// Which secret-caption vocabularies does this title belong to, judged at
    /// the stricter word-boundary bar an enclosing caption has to clear?
    public static func enclosingCaptionKinds(forCaption raw: String) -> EnclosingCaptionKinds {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxLabelChars else { return .none }
        let normalized = captionWords(text)
        let cvv = captionContainsWord(normalized, anyOf: cardVerificationLabelTokens)
        let seed = captionContainsWord(normalized, anyOf: seedPhraseLabelTokens)
        var secret = captionContainsWord(normalized, anyOf: secretLabelTokens)
        if secret {
            // Same disqualifier pass the beside-geometry runs: a group titled
            // "Zip Code" or "Promo Code" names neither a secret nor a PIN.
            let matchedOnlyCode = !secretLabelTokens.contains {
                $0 != "code" && $0 != "pin"
                    && captionContainsWord(normalized, anyOf: [$0])
            }
            if matchedOnlyCode,
               codeDisqualifiers.contains(where: { text.lowercased().contains($0) }) {
                secret = false
            }
        }
        return EnclosingCaptionKinds(secret: secret, cvv: cvv, seed: seed)
    }
    /// Every node on this screen that could caption its own subtree. Built from
    /// the WHOLE snapshot for the same reason the beside-caption map is: a
    /// `find` query matches the field, never the group around it.
    public static func enclosingCaptions(_ nodes: [MacAXNode]) -> [EnclosingCaption] {
        var captions: [EnclosingCaption] = []
        for node in nodes {
            // The root (empty path) encloses the entire window — excluded on
            // purpose, see the guard list above.
            guard !node.path.isEmpty else { continue }
            guard let frame = node.attributes.frame, frame.w > 0, frame.h > 0 else { continue }
            guard let title = node.attributes.title else { continue }
            let kinds = enclosingCaptionKinds(forCaption: title)
            guard kinds.any else { continue }
            captions.append(EnclosingCaption(frame: frame, path: node.path, kinds: kinds))
        }
        return captions
    }
    /// Which enclosing captions apply to the node at `path`/`frame`: a strict
    /// path ancestor whose frame also contains the node. Both are required —
    /// the path proves the relationship, the frame proves the group is really
    /// drawn around it (an AX subtree can outlive its visual box).
    public static func enclosingKinds(
        forNodeAt frame: MacAXFrame?,
        path: [Int],
        among captions: [EnclosingCaption]
    ) -> EnclosingCaptionKinds {
        guard let frame, frame.w > 0, frame.h > 0, !captions.isEmpty else { return .none }
        var kinds = EnclosingCaptionKinds.none
        for caption in captions where isStrictAncestor(caption.path, of: path) {
            guard frameContains(caption.frame, frame) else { continue }
            kinds = kinds.merged(with: caption.kinds)
        }
        return kinds
    }
    static func isStrictAncestor(_ ancestor: [Int], of path: [Int]) -> Bool {
        guard !ancestor.isEmpty, ancestor.count < path.count else { return false }
        for (index, component) in ancestor.enumerated() where path[index] != component {
            return false
        }
        return true
    }
    static func frameContains(_ outer: MacAXFrame, _ inner: MacAXFrame) -> Bool {
        let slack = 1.0
        return outer.x <= inner.x + slack
            && outer.y <= inner.y + slack
            && outer.x + outer.w >= inner.x + inner.w - slack
            && outer.y + outer.h >= inner.y + inner.h - slack
    }
    /// The enclosing rule, applied to one string. Shape still decides: the
    /// caption only says WHICH shapes are in play here.
    static func enclosingSecretReason(_ text: String, kinds: EnclosingCaptionKinds) -> String? {
        guard kinds.any else { return nil }
        if kinds.cvv, isShortCodeValue(text) { return "enclosing_cvv" }
        if kinds.seed, isRecoveryPhrase(text, labeled: true) {
            return "enclosing_recovery_phrase"
        }
        if kinds.secret, looksLikeRedactableValue(text) { return "enclosing_secret_caption" }
        return nil
    }
    /// Complete masking coverage; callers choose timing and frame-size requirements.
    public static func inspectSecretFields(source: any MacAXElementSource, root: MacAXElementRef,
        deadline: Date, nonnegativeFrames: Bool = true) throws -> [MacAXNode] {
        try MacAXLimits.$readDeadline.withValue(deadline) {
            let snapshot = MacAccessibilityReader.walk(source: source, root: root, limits: .whole,
                read: source.maskingAttributes, deadline: deadline, stopAtCut: true)
            guard !snapshot.truncated else { throw SenseFailure(code: "redaction_coverage_unavailable", message: "AX inspection was cut: \(snapshot.truncationReasons.joined(separator: ", ")).") }
            guard !snapshot.nodes.isEmpty else { throw SenseFailure(code: "redaction_coverage_unavailable", message: "AX inspection returned no nodes.") }
            guard snapshot.nodes.allSatisfy({ node in
                guard MacScreenViewBuilder.isMarkable(node.attributes) else { return true }
                guard let frame = node.attributes.frame else { return false }
                return (!nonnegativeFrames || frame.w >= 0 && frame.h >= 0)
                    && [frame.x, frame.y, frame.w, frame.h].allSatisfy(\.isFinite)
            }) else { throw SenseFailure(code: "redaction_coverage_unavailable", message: "An AX control has no finite frame for secret masking.") }
            return snapshot.nodes
        }
    }
    /// Masks withheld words and secret controls in one pass over indexed
    /// captions and names. Nil past the deadline withholds the window's pixels.
    public static func secretFrames(
        nodes: [MacAXNode],
        geometry: MacScreenViewGeometry,
        deadline: Date
    ) -> [MacAXFrame]? {
        let context = nodeSecretContext(nodes)
        let names = MacScreenViewBuilder.LabelIndex(nodes)
        // The indexes are built from a walk the share already bounded; past the deadline the window is masked whole.
        guard Date() < deadline else { return nil }
        var frames: [MacAXFrame] = []
        for node in nodes {
            guard Date() < deadline else { return nil }
            let attributes = node.attributes
            guard let frame = attributes.frame, frame.w > 0, frame.h > 0, geometry.intersects(frame) else { continue }
            let enclosing = enclosingKinds(forNodeAt: frame, path: node.path, among: context.enclosingCaptions)
            func withheld(_ text: String?, under label: String?) -> Bool {
                guard let text else { return false }
                if case .object = redactedNodeString(text, valueChars: MacAXLimits.hardValueChars, frame: frame,
                    under: label, enclosing: enclosing, context: context) { return true }
                return false
            }
            let control = MacScreenViewBuilder.isMarkable(attributes)
            let name = control ? MacScreenViewBuilder.inferLabel(for: node, frame: frame, in: names).label : attributes.title
            if withheld(name, under: nil) || withheld(attributes.value, under: name)
                || (control && MacScreenViewBuilder.isSecretField(role: attributes.role, subrole: attributes.subrole,
                        label: name, value: attributes.value)) {
                frames.append(frame)
            }
        }
        return frames
    }
    /// Shared AX/OCR caption geometry: coordinates and proximity share units,
    /// with a top-left origin and y increasing downward.
    static func labelDistance(_ label: MacAXFrame, forValueAt value: MacAXFrame, proximity: Double) -> Double? {
        guard label.w > 0, label.h > 0, value.w > 0, value.h > 0 else { return nil }
        let sameRow = label.y < value.y + value.h && label.y + label.h > value.y
        let toTheLeft = label.x + label.w <= value.x + 1
        if sameRow, toTheLeft {
            let distance = value.x - (label.x + label.w)
            return distance >= 0 && distance <= proximity ? distance : nil
        }
        let above = label.y + label.h <= value.y + 1
        let horizontallyOverlapping = label.x < value.x + value.w && label.x + label.w > value.x
        if above, horizontallyOverlapping {
            let distance = value.y - (label.y + label.h)
            return distance >= 0 && distance <= proximity ? distance : nil
        }
        return nil
    }
    /// A value worth redacting BY POSITION is a token, not prose: one word,
    /// long enough to be a secret, and either carrying a digit, long, or an
    /// all-caps/alnum run. "Cancel" beside a password label stays visible;
    /// "8F2K-91QT" does not.
    static func looksLikeRedactableValue(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 4, text.count <= maxValueChars else { return false }
        guard !text.contains(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) else { return false }
        let hasDigit = text.contains { $0.isNumber }
        let allCaps = text.allSatisfy { !$0.isLowercase } && text.contains { $0.isLetter }
        return hasDigit || allCaps || text.count >= 12
    }
    /// Dot filenames are excluded only from positional `labeled_secret_nearby` value matching.
    /// Standalone secrets, captioned CVVs/recovery phrases and inline secrets retain their checks.
    static func isFilenameShapedToken(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, text.count <= maxValueChars else { return false }
        guard text.hasPrefix(".") else { return false }
        guard !text.contains(where: { $0.isWhitespace }) else { return false }
        return text.dropFirst().allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_"
        }
    }
    /// `looksLikeRedactableValue`, minus the shapes that are not values at all.
    /// The ONE gate every `labeled_secret_nearby` decision goes through, so the
    /// prose channel, the legend and the perception compiler cannot disagree
    /// about the same filename.
    static func isLabeledSecretValue(_ text: String) -> Bool {
        looksLikeRedactableValue(text) && !isFilenameShapedToken(text)
    }
    static func isMaskedRun(_ text: String) -> Bool {
        let masks: Set<Character> = ["•", "●", "*", "·", "∙", "◦", "⁕", "✱", "◍", "＊"]
        let stripped = text.filter { !$0.isWhitespace }
        guard stripped.count >= 4 else { return false }
        return stripped.allSatisfy { masks.contains($0) }
    }
    /// A LONE 6–8 digit code. The whole line has to be the code: "123456" is an
    /// OTP, "Order 123456 shipped" is not.
    static func isOneTimeCode(_ text: String) -> Bool {
        guard text.count <= 12 else { return false }
        guard !text.contains(where: { $0.isLetter }) else { return false }
        let digits = text.filter { $0.isNumber }
        guard digits.count >= 6, digits.count <= 8 else { return false }
        let separators: Set<Character> = [" ", "-", "–", "—", "\u{00A0}"]
        return text.allSatisfy { $0.isNumber || separators.contains($0) }
    }
    /// `label: value` on one line, where the label names a secret and the value
    /// is a single token. The single-token bar is the false-positive guard:
    /// "Choose a strong password: it must be at least 8 characters" has a
    /// secret-naming label and a SENTENCE after the colon, so it stays visible.
    static func inlineLabeledSecretReason(_ text: String) -> String? {
        guard text.count <= 200 else { return nil }
        for separator in [":", "=", "："] {
            guard let range = text.range(of: separator) else { continue }
            let label = String(text[text.startIndex..<range.lowerBound])
            let value = String(text[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            // Captioned CVVs and recovery phrases bypass the generic token length/whitespace limits.
            if isCardVerificationLabel(label), isShortCodeValue(value) {
                return "labeled_cvv"
            }
            if isSeedPhraseLabel(label), isRecoveryPhrase(value, labeled: true) {
                return "labeled_recovery_phrase"
            }
            guard looksLikeSecretLabel(label) else { continue }
            // The generic token test rejects whitespace, so a spaced card
            // number or a word run after a secret caption needs its own shape.
            guard looksLikeRedactableValue(value)
                || isPaymentCardNumber(value)
                || isRecoveryPhrase(value, labeled: true) else { continue }
            return "labeled_inline_secret"
        }
        return nil
    }
    /// Under an explicit seed/recovery caption the wordlist run does not have to
    /// reach the unlabeled 12-word bar — the caption already said what it is.
    public static let labeledSeedMinWords = 6
    /// A payment card number, INCLUDING the spaced/dashed form a human reads.
    ///
    /// FALSE-POSITIVE GUARD: **Luhn**. 13–19 digits is a wide net (an order id,
    /// an account number, a serial all live in there), so the line only goes
    /// dark if it also satisfies the card checksum. An order number, a tracking
    /// number and a phone number are shorter, carry letters, or fail Luhn.
    static func isPaymentCardNumber(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 32 else { return false }
        let separators: Set<Character> = [" ", "-", "–", "—", "\u{00A0}"]
        guard text.allSatisfy({ $0.isNumber || separators.contains($0) }) else { return false }
        let digits = text.filter { $0.isNumber }
        guard digits.count >= 13, digits.count <= 19 else { return false }
        return luhnValid(digits)
    }
    /// The Luhn mod-10 checksum every issuer's numbering satisfies.
    static func luhnValid(_ digits: String) -> Bool {
        var sum = 0
        var double = false
        for character in digits.reversed() {
            guard let value = character.wholeNumberValue else { return false }
            if double {
                let doubled = value * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += value
            }
            double.toggle()
        }
        return sum % 10 == 0
    }
    /// A wallet seed / recovery phrase: a run of lowercase space-separated
    /// words, checked separately from single-token secrets.
    ///
    /// FALSE-POSITIVE GUARD, three layers, because "lowercase words" is what
    /// prose is made of: (1) every word must be 3–8 letters, pure alphabetic —
    /// wordlist shape, and prose is full of 1–2 letter function words; (2) the
    /// WHOLE line must be the run, so any capital or punctuation mark — which
    /// real prose lines carry — disqualifies it; (3) no common English function
    /// word may appear. A phrase that happens to contain one of those words is
    /// MISSED rather than a sentence being darkened; that direction of error is
    /// the deliberate one, and a LABELED phrase is caught regardless (see
    /// `labeled`, which also drops the minimum to 6 under that caption).
    static func isRecoveryPhrase(_ raw: String, labeled: Bool = false) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 400 else { return false }
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count >= (labeled ? labeledSeedMinWords : 12) else { return false }
        for word in words {
            guard word.count >= 3, word.count <= 8 else { return false }
            guard word.allSatisfy({ $0.isLetter && $0.isLowercase }) else { return false }
            if !labeled, proseFunctionWords.contains(word) { return false }
        }
        return true
    }
    /// A base64 / base64url blob, including `+`, `/` and `=` markers.
    ///
    /// FALSE-POSITIVE GUARD, four gates, because `/` also means "path":
    /// (1) at least one true base64 marker (`+`, `/`, `=`) — those never occur
    /// in an identifier or an English word; (2) no `.` or `:`, which kills URLs,
    /// hostnames and filenames outright; (3) mixed case AND a digit, the
    /// signature random bytes always produce; (4) no same-case alphabetic run
    /// longer than 5, which is what separates `Reports/2024/Summary` (run of 6
    /// in "eports") from an encoded blob; then a Shannon entropy floor.
    /// base64url tokens made only of `[A-Za-z0-9-_]` carry no marker char and
    /// are already caught by `isHighEntropyToken` above.
    static func isBase64Token(_ text: String) -> Bool {
        guard text.count >= 20, text.count <= maxValueChars else { return false }
        guard !text.contains(where: { $0.isWhitespace }) else { return false }
        guard !text.contains("."), !text.contains(":") else { return false }
        let markers: Set<Character> = ["+", "/", "="]
        let allowed = text.allSatisfy {
            $0.isLetter || $0.isNumber || markers.contains($0) || $0 == "-" || $0 == "_"
        }
        guard allowed else { return false }
        guard text.contains(where: { markers.contains($0) }) else { return false }
        guard text.contains(where: { $0.isUppercase }),
              text.contains(where: { $0.isLowercase }),
              text.contains(where: { $0.isNumber }) else { return false }
        guard longestSameCaseRun(text) <= 5 else { return false }
        return shannonEntropyBitsPerCharacter(text) >= 3.5
    }
    /// Longest run of consecutive letters sharing a case. Words have long ones;
    /// encoded bytes do not.
    static func longestSameCaseRun(_ text: String) -> Int {
        var best = 0
        var current = 0
        var previous: Bool?
        for character in text {
            guard character.isLetter else {
                current = 0
                previous = nil
                continue
            }
            let upper = character.isUppercase
            if upper == previous { current += 1 } else { current = 1; previous = upper }
            best = max(best, current)
        }
        return best
    }
    /// Shannon entropy over the characters, in bits per character.
    static func shannonEntropyBitsPerCharacter(_ text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for character in text { counts[character, default: 0] += 1 }
        let total = Double(text.count)
        return counts.values.reduce(0.0) { partial, count in
            let probability = Double(count) / total
            return partial - probability * log2(probability)
        }
    }
    /// A single opaque token: long, mixed, and made only of token characters
    /// (so a URL, a path, an email or a sentence cannot qualify) — or short but
    /// carrying a known key prefix.
    static func isHighEntropyToken(_ text: String) -> Bool {
        guard !text.contains(where: { $0.isWhitespace }) else { return false }
        let allowed = text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        guard allowed else { return false }
        let lowered = text.lowercased()
        if knownSecretPrefixes.contains(where: { lowered.hasPrefix($0) }), text.count >= 12 {
            return true
        }
        guard text.count <= maxValueChars else { return false }
        guard text.count >= 20 else { return false }
        // A dotted word run (a hostname, a filename, a version) is not a token.
        guard !text.contains(".") else { return false }
        let hasDigit = text.contains { $0.isNumber }
        let hasLetter = text.contains { $0.isLetter }
        guard hasDigit, hasLetter else { return false }
        // Keep ordinary CamelCase identifiers legible even when they meet the entropy thresholds.
        guard !looksLikeCamelCaseIdentifier(text) else { return false }
        return Set(text).count >= 10
    }
    /// Does this split at its capitals into three or more real words? A random
    /// token does not — its "words" are two characters long and full of digits.
    static func looksLikeCamelCaseIdentifier(_ text: String) -> Bool {
        var segments: [String] = []
        var current = ""
        for character in text {
            if character.isUppercase, !current.isEmpty {
                segments.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { segments.append(current) }
        guard segments.count >= 3 else { return false }
        return segments.allSatisfy { segment in
            let letters = segment.prefix { $0.isLetter }
            guard letters.count >= 3 else { return false }
            return segment.dropFirst(letters.count).allSatisfy { $0.isNumber }
        }
    }
}
