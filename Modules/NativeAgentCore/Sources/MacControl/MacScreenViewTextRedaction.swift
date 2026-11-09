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
/// Displayed secrets include static text: apply shape and caption checks while preserving ordinary prose. Cover lone OTPs, opaque tokens, masks, inline labeled
/// tokens and nearby secret values; caption evidence never assigns action identity.
public enum MacScreenViewTextRedaction {
    /// Field names bypass prose caption-length and code-disqualifier limits.
    public static let secretFieldLabelTokens: [String] = [
        "password", "passcode", "passphrase", "secret", "api key", "api-key",
        "token", "pin code", "security code", "2fa", "one-time code",
    ]
    /// Only short labels may caption secrets; sentence bodies cannot.
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
    /// Only specific card-verification labels justify masking short three- or four-digit values; code disqualifiers do not apply.
    public static let cardVerificationLabelTokens: [String] = [
        "cvv", "cvc", "csc", "cvv2", "cid",
        "security code", "card verification", "card security",
    ]
    /// Explicit recovery labels justify masking shorter word runs than the unlabeled threshold.
    public static let seedPhraseLabelTokens: [String] = [
        "seed phrase", "recovery phrase", "seed words", "recovery words",
        "mnemonic", "backup phrase", "secret phrase", "secret recovery phrase",
    ]
    /// Function words guard unlabeled prose from seed-phrase masking; labeled phrases still qualify regardless of this list.
    public static let proseFunctionWords: Set<String> = [
        "the", "and", "that", "this", "with", "for", "are", "was", "not",
        "but", "have", "from", "they", "his", "her", "has", "had", "were",
        "been", "will", "can", "out", "how", "why", "when", "what", "who",
        "which", "there", "here", "then", "than", "into", "just", "like",
        "some", "more", "most", "only", "very", "after", "before", "because",
        "them", "him", "your", "our", "their", "its", "would", "could",
        "should", "said", "says", "our", "you",
    ]
    /// Qualified zip, area, promo and error codes are not secrets; bare code needs this disqualifier guard.
    public static let codeDisqualifiers: [String] = [
        "zip", "postal", "post code", "area", "country", "dial", "promo",
        "coupon", "discount", "error", "status", "color", "colour", "qr",
        "barcode", "bar code", "source", "product", "language", "currency",
        "airport", "region", "state", "sort code", "swift code", "referral",
        "invite", "tracking",
    ]
    /// Known key prefixes are unambiguous enough to bypass the opaque-token length floor.
    public static let knownSecretPrefixes: [String] = [
        "sk-", "sk_", "pk_", "rk_", "ghp_", "gho_", "ghu_", "ghs_",
        "github_pat_", "xoxb-", "xoxp-", "xoxa-", "akia", "asia", "aiza",
        "ya29.", "eyj", "npm_", "glpat-", "shpat_",
    ]
    /// Long captions are sentences rather than secret labels.
    public static let maxLabelChars = 40
    /// Token bounds prevent a secret caption from masking an entire paragraph.
    public static let maxValueChars = 128
    /// Match the legend’s label-inference reach so both channels judge nearby captions consistently.
    public static let proximityPoints: Double = 240
    /// Replace secret characters with the shared digest shape and a reason so callers can audit withholding without mistaking it for failed sight.
    public static func redactedText(_ secret: String, reason: String) -> JSONValue {
        guard case .object(var object) =
            MacInjectionResultRedaction.redactedSecret(secret) else {
            return .object(["redacted": .bool(true), "reason": .string(reason)])
        }
        object["reason"] = .string(reason)
        return .object(object)
    }
    /// Standalone checks protect labels and values even without caption context.
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
    public static func isCardVerificationLabel(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, text.count <= maxLabelChars else { return false }
        return cardVerificationLabelTokens.contains { token in
            // Short tokens such as cid and cvc need word boundaries to avoid matching inside unrelated words.
            guard token.count <= 3 else { return text.contains(token) }
            return text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .contains { $0.lowercased() == token }
        }
    }
    public static func isSeedPhraseLabel(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, text.count <= maxLabelChars else { return false }
        return seedPhraseLabelTokens.contains { text.contains($0) }
    }
    /// Three- or four-digit values require a card-verification caption; unlabeled digits may be ordinary quantities.
    static func isShortCodeValue(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3, text.count <= 4 else { return false }
        return text.allSatisfy { $0.isNumber }
    }
    /// Only short secret-naming captions qualify, never sentences.
    public static func looksLikeSecretLabel(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, text.count <= maxLabelChars else { return false }
        guard secretLabelTokens.contains(where: { text.contains($0) }) else { return false }
        // Disqualify only bare code matches; other secret-label tokens remain unambiguous independently.
        let matchedOnlyCode = !secretLabelTokens.contains {
            $0 != "code" && $0 != "pin" && text.contains($0)
        }
        if matchedOnlyCode, codeDisqualifiers.contains(where: { text.contains($0) }) {
            return false
        }
        return true
    }
    /// Transfer complete-snapshot caption verdicts without truncation; paths must stay aligned with text items.
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
    /// Legend labels need the same standalone secret checks as prose. Values additionally use their own label and enclosing groups, so short captioned CVVs
    /// cannot escape through the legend.
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
    /// Redact at serialization while the shared reader remains read-only; preserve all addressing and action evidence.
    public struct NodeSecretContext: Sendable {
        public let secretLabelFrames: [MacAXFrame]
        public let cvvLabelFrames: [MacAXFrame]
        public let seedLabelFrames: [MacAXFrame]
        /// Enclosing secret groups need both a naming title and a frame around the value.
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
    /// Build captions from the whole snapshot; a find query may omit the label that protects its matched value.
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
    /// Combine standalone shape, the value’s own caption and nearby-caption evidence.
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
    /// Redact every text channel without removing node addressing.
    public static func redactedNodeFields(
        _ node: MacAXNode,
        valueChars: Int = MacAXLimits.hardValueChars,
        context: NodeSecretContext
    ) -> [String: JSONValue] {
        let attributes = node.attributes
        var object: [String: JSONValue] = [
            "role": .string(attributes.role),
            "enabled": attributes.enabled.map(JSONValue.bool) ?? .null,
            "path": .array(node.path.map { .int(Int64($0)) }),
        ]
        if !attributes.attributeGaps.isEmpty {
            object["attribute_gaps"] = .array(attributes.attributeGaps.map(JSONValue.string))
        }
        if attributes.labelUnreadable { object["label_source"] = .string("unreadable") }
        if let reason = attributes.actionsUnreadable {
            object["actions_unreadable"] = .string(reason)
        } else {
            object["actions"] = .array(attributes.actions.map { .string($0) })
        }
        if let subrole = attributes.subrole { object["subrole"] = .string(subrole) }
        if let selected = attributes.selected { object["selected"] = .bool(selected) }
        if let state = attributes.state { object["state"] = .string(state) }
        if let frame = attributes.frame { object["frame"] = frame.toJSON() }
        if let summary = attributes.listSummary { object["list_summary"] = .string(summary) }
        let frame = node.attributes.frame
        // Enclosing secret captions protect untitled descendants too.
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
            // Unreadable secrecy evidence cannot establish a non-secret value; withhold it.
            let editable = ["AXTextField", "AXTextArea", "AXComboBox"].contains(node.attributes.role)
            let secrecyUnread = node.attributes.attributeGaps.contains { gap in
                [kAXTitleAttribute, kAXDescriptionAttribute, "caption read"].contains { gap.hasPrefix($0 + ":") }
                    || (editable && gap.hasPrefix(kAXSubroleAttribute + ":"))
            }
            object["value"] = secrecyUnread || MacScreenViewBuilder.isSecretField(
                role: node.attributes.role,
                subrole: node.attributes.subrole,
                label: node.attributes.title
            ) ? MacInjectionResultRedaction.redactedSecret(value) : redactedNodeString(
                value,
                valueChars: valueChars,
                frame: frame,
                // A control’s own title captions its value, protecting short CVVs and displayed keys.
                under: node.attributes.title,
                enclosing: enclosing,
                context: context
            )
        }
        return object
    }
    public static func redactedNodesJSON(
        _ nodes: [MacAXNode],
        valueChars: Int = MacAXLimits.hardValueChars
    ) -> [JSONValue] {
        let context = nodeSecretContext(nodes)
        return nodes.map { .object(redactedNodeFields($0, valueChars: valueChars, context: context)) }
    }
    /// Find matches retain score and addressing even when their text is redacted.
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
    /// Enclosing captions require secret words, not substrings, and a secret-shaped value; ordinary groups and buttons remain legible. Exclude the root window
    /// because it encloses everything; its title receives standalone redaction instead.
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
    /// Require a path ancestor as well as frame containment so unrelated overlapping backdrops cannot caption controls.
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
    /// Normalize word boundaries on both sides so multiword secret names match punctuation without matching pin inside Shipping.
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
    /// Enclosing captions use stricter word-boundary matching than nearby captions.
    public static func enclosingCaptionKinds(forCaption raw: String) -> EnclosingCaptionKinds {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxLabelChars else { return .none }
        let normalized = captionWords(text)
        let cvv = captionContainsWord(normalized, anyOf: cardVerificationLabelTokens)
        let seed = captionContainsWord(normalized, anyOf: seedPhraseLabelTokens)
        var secret = captionContainsWord(normalized, anyOf: secretLabelTokens)
        if secret {
            // Use the same qualified-code disqualifiers as nearby-caption geometry.
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
    /// Build enclosing captions from the whole snapshot because find may match a field without its protecting group.
    public static func enclosingCaptions(_ nodes: [MacAXNode]) -> [EnclosingCaption] {
        var captions: [EnclosingCaption] = []
        for node in nodes {
            // Exclude the root because it encloses the entire window.
            guard !node.path.isEmpty else { continue }
            guard let frame = node.attributes.frame, frame.w > 0, frame.h > 0 else { continue }
            guard let title = node.attributes.title else { continue }
            let kinds = enclosingCaptionKinds(forCaption: title)
            guard kinds.any else { continue }
            captions.append(EnclosingCaption(frame: frame, path: node.path, kinds: kinds))
        }
        return captions
    }
    /// Require both strict path ancestry and frame containment: AX subtrees can outlive their visible boxes.
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
    /// Captions select applicable secret shapes; shape checks still decide withholding.
    static func enclosingSecretReason(_ text: String, kinds: EnclosingCaptionKinds) -> String? {
        guard kinds.any else { return nil }
        if kinds.cvv, isShortCodeValue(text) { return "enclosing_cvv" }
        if kinds.seed, isRecoveryPhrase(text, labeled: true) {
            return "enclosing_recovery_phrase"
        }
        if kinds.secret, looksLikeRedactableValue(text) { return "enclosing_secret_caption" }
        return nil
    }
    /// Coverage must be complete; callers own timing and minimum frame size.
    public static func inspectSecretFields(source: any MacAXElementSource, root: MacAXElementRef,
        deadline: Date, nonnegativeFrames: Bool = true, context: MacOperationContext) throws -> [MacAXNode] {
        try context.holding(\.readDeadline, deadline) { context in
            // A list can publish every row and cell as visible with frames far off the window (Music's library): they cannot appear in the window's pixels.
            let bounds = source.attributes(of: root, context: context)?.frame
            let snapshot = MacAccessibilityReader.walk(source: source, root: root, limits: .whole,
                read: { ref, context in try source.checkedMaskingAttributes(of: ref, context: context) }, deadline: deadline, stopAtCut: true,
                skipping: { ref, context in bounds.map { source.liesWhollyOutside(ref, bounds: $0, context: context) } ?? false }, context: context)
            guard !snapshot.truncated else {
                throw SenseFailure(code: "redaction_coverage_unavailable",
                    message: "AX inspection was cut: \(snapshot.truncationReasons.joined(separator: ", ")). "
                    + snapshot.readFailures.joined(separator: "; "))
            }
            guard !snapshot.nodes.isEmpty else { throw SenseFailure(code: "redaction_coverage_unavailable", message: "AX inspection returned no nodes.") }
            for node in snapshot.nodes {
                let attributes = node.attributes
                // Static prose and container captions can reveal secrets too.
                guard MacScreenViewBuilder.isMarkable(attributes)
                    || MacScreenViewBuilder.textRoles.contains(attributes.role)
                    || attributes.title != nil || attributes.value != nil || !attributes.attributeGaps.isEmpty else { continue }
                guard let frame = attributes.frame,
                      (!nonnegativeFrames || frame.w >= 0 && frame.h >= 0),
                      [frame.x, frame.y, frame.w, frame.h].allSatisfy(\.isFinite) else {
                    throw SenseFailure(code: "redaction_coverage_unavailable",
                        message: "Secret masking element at path \(node.path) (\(attributes.role)) has unreadable AXPosition/AXSize: no finite frame.")
                }
            }
            return snapshot.nodes
        }
    }
    /// Mask withheld words and secret controls together; incomplete deadline coverage withholds the window pixels.
    public static func secretFrames(
        nodes: [MacAXNode],
        geometry: MacScreenViewGeometry,
        deadline: Date
    , context: MacOperationContext) -> [MacAXFrame]? {
        let context = nodeSecretContext(nodes)
        let names = MacScreenViewBuilder.LabelIndex(nodes)
        // If indexing exceeds the share’s deadline, mask the whole window rather than disclose unchecked pixels.
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
            let name = control ? MacScreenViewBuilder.inferLabel(for: node, in: names).label : attributes.title
            if !attributes.attributeGaps.isEmpty || withheld(name, under: nil) || withheld(attributes.value, under: name)
                || (control && MacScreenViewBuilder.isSecretField(role: attributes.role, subrole: attributes.subrole,
                        label: name, value: attributes.value)) {
                frames.append(frame)
            }
        }
        return frames
    }
    /// AX and OCR caption geometry must share units and a top-left origin.
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
    /// Nearby captions mask only code-shaped tokens, not ordinary prose such as a Cancel button.
    static func looksLikeRedactableValue(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 4, text.count <= maxValueChars else { return false }
        guard !text.contains(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) else { return false }
        let hasDigit = text.contains { $0.isNumber }
        let allCaps = text.allSatisfy { !$0.isLowercase } && text.contains { $0.isLetter }
        return hasDigit || allCaps || text.count >= 12
    }
    /// Dot filenames bypass only generic positional matching; standalone and explicitly captioned secret shapes still apply.
    static func isFilenameShapedToken(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, text.count <= maxValueChars else { return false }
        guard text.hasPrefix(".") else { return false }
        guard !text.contains(where: { $0.isWhitespace }) else { return false }
        return text.dropFirst().allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_"
        }
    }
    /// One positional-value predicate keeps prose, legends and perception compilation consistent about filenames.
    static func isLabeledSecretValue(_ text: String) -> Bool {
        looksLikeRedactableValue(text) && !isFilenameShapedToken(text)
    }
    static func isMaskedRun(_ text: String) -> Bool {
        let masks: Set<Character> = ["•", "●", "*", "·", "∙", "◦", "⁕", "✱", "◍", "＊"]
        let stripped = text.filter { !$0.isWhitespace }
        guard stripped.count >= 4 else { return false }
        return stripped.allSatisfy { masks.contains($0) }
    }
    /// Only a whole-line six- to eight-digit code qualifies as an unlabeled OTP; surrounding prose disqualifies it.
    static func isOneTimeCode(_ text: String) -> Bool {
        guard text.count <= 12 else { return false }
        guard !text.contains(where: { $0.isLetter }) else { return false }
        let digits = text.filter { $0.isNumber }
        guard digits.count >= 6, digits.count <= 8 else { return false }
        let separators: Set<Character> = [" ", "-", "–", "—", "\u{00A0}"]
        return text.allSatisfy { $0.isNumber || separators.contains($0) }
    }
    /// Inline secret captions require a single-token value so password instructions remain readable prose.
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
            // Spaced cards and recovery words need dedicated shapes because generic tokens reject whitespace.
            guard looksLikeRedactableValue(value)
                || isPaymentCardNumber(value)
                || isRecoveryPhrase(value, labeled: true) else { continue }
            return "labeled_inline_secret"
        }
        return nil
    }
    /// Explicit recovery captions justify shorter word runs than the unlabeled twelve-word floor.
    public static let labeledSeedMinWords = 6
    /// Require a Luhn checksum for 13–19 digit card shapes so ordinary numeric identifiers are less likely to be masked.
    static func isPaymentCardNumber(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 32 else { return false }
        let separators: Set<Character> = [" ", "-", "–", "—", "\u{00A0}"]
        guard text.allSatisfy({ $0.isNumber || separators.contains($0) }) else { return false }
        let digits = text.filter { $0.isNumber }
        guard digits.count >= 13, digits.count <= 19 else { return false }
        return luhnValid(digits)
    }
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
    /// Unlabeled recovery phrases need whole-line lowercase words of three to eight letters and no common function words. Favor missed unlabeled phrases over
    /// masked prose; explicit captions bypass that guard and lower the floor to six words.
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
    /// Base64 needs a marker, no dot or colon, mixed case, digits, short same-case letter runs and sufficient entropy to exclude paths. Markerless base64url
    /// tokens use the opaque-token detector.
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
    /// Long same-case letter runs suggest words rather than encoded bytes.
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
    /// Opaque tokens must exclude URL, path, email and prose syntax; known key prefixes may bypass the length floor.
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
        // Dotted runs are names or versions rather than opaque tokens.
        guard !text.contains(".") else { return false }
        let hasDigit = text.contains { $0.isNumber }
        let hasLetter = text.contains { $0.isLetter }
        guard hasDigit, hasLetter else { return false }
        // Keep ordinary CamelCase identifiers legible even when they meet the entropy thresholds.
        guard !looksLikeCamelCaseIdentifier(text) else { return false }
        return Set(text).count >= 10
    }
    /// CamelCase word segmentation distinguishes ordinary identifiers from short random fragments.
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
