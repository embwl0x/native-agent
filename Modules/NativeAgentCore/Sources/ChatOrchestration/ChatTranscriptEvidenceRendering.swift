import Foundation
import NativeAgentCore
import PersistenceCore

/// Pure presentation of evidence already recorded by transcript persistence.
/// Shared by history and compaction; no storage, semantic interpretation,
/// content fetch, permission decision, or additional model call lives here.
enum ChatTranscriptEvidenceRendering {
    /// A successful approval-filing transport is not successful tool execution.
    /// This reads the writer's exact receipt kind, not prose or result heuristics;
    /// it describes the recorded row and never decides current permission.
    static func recordedPendingToolStatus(_ metadata: [String: JSONValue]?) -> String? {
        guard case .string(let kind)? = metadata?["kind"],
              kind == ChatTranscriptToolMessageKind.approvalPending else { return nil }
        return "awaiting approval; not run"
    }

    /// Transport `ok` is not evidence that queued work finished. New receipts
    /// retain the canonical classifier's small tag before their body is clipped;
    /// legacy receipts can recover it only from a complete, bounded envelope.
    static func recordedToolStatus(_ metadata: [String: JSONValue]?) -> String? {
        if let pending = recordedPendingToolStatus(metadata) { return pending }
        guard case .string(ChatTranscriptToolMessageKind.toolUse)? = metadata?["kind"] else {
            return nil
        }
        let resultClass: ChatToolOutcome.ExactResultClass?
        if case .string(let rawClass)? = metadata?["resultClass"],
           let recorded = ChatToolOutcome.ExactResultClass(rawValue: rawClass) {
            resultClass = recorded
        } else if case .string(let raw)? = metadata?["resultSummary"] {
            // Match the persisted receipt-body bound without scanning arbitrary
            // legacy output. A clipped/oversized body is not parseable evidence.
            let bounded = String(raw.prefix(8_001))
            if bounded.count <= 8_000,
               let value = try? JSONValue.parse(Data(bounded.utf8)),
               case .object(let object) = value,
               case .string? = object["status"] {
                resultClass = ChatToolOutcome.exactResultClass(value)
            } else {
                resultClass = nil
            }
        } else {
            resultClass = nil
        }
        switch resultClass {
        case .unknown:
            // `.unknown` covers everything from "queued" to "running" to
            // "accepted". Collapsing them all into "completion unconfirmed"
            // told the model nothing was heard back when the receipt had in
            // fact said exactly where the work got to. Report the recorded
            // word when the writer kept one; "unconfirmed" now means only
            // what it says — no state was ever reported.
            if case .string(let recorded)? = metadata?["resultStatus"] {
                let word = recorded.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !word.isEmpty && word != "unknown" { return word }
            }
            return "completion unconfirmed"
        case .cancelled: return "cancelled"
        case .timeout: return "timed out"
        case .failed: return "failed"
        case .succeeded, nil: return nil
        }
    }

    static func displayContent(_ content: String, originLabel: String?, incompleteReplyLabel: String?) -> String {
        let markers = [
            originLabel.map { "[origin: \($0)]" },
            incompleteReplyLabel.map { "[incomplete reply: \($0)]" },
        ].compactMap { $0 }
        guard !markers.isEmpty else { return content }
        return markers.joined(separator: " ") + " " + content
    }

    static func contentIncludingAttachments(_ content: String, attachments: JSONValue?) -> String {
        guard let marker = attachmentMarker(attachments) else { return content }
        return content.isEmpty ? marker : "\(marker) \(content)"
    }

    /// Preserve attachment identity without claiming that document inputs were
    /// images. Bound metadata independently so filenames cannot consume the
    /// ordinary row before the user's caption. Never read bytes or paths.
    private static func attachmentMarker(_ value: JSONValue?) -> String? {
        guard case .array(let attachments)? = value, !attachments.isEmpty else { return nil }
        let entries = attachments.prefix(3).compactMap { entry -> (kind: String, reference: String)? in
            guard case .object(let item) = entry else { return nil }
            let type = string(item["type"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let mime = string(item["mime"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let kind: String
            if type == "image" || (type.isEmpty && mime.lowercased().hasPrefix("image/")) {
                kind = "image"
            } else if type == "file" {
                kind = "file"
            } else {
                kind = "attachment"
            }
            let rawName = string(item["name"]) ?? mime
            let normalizedName = ChatSecretRedactor.redactText(String(rawName.prefix(320)))
                .replacingOccurrences(of: "\r", with: "\n")
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = normalizedName.isEmpty ? "attachment"
                : normalizedName.count > 80 ? String(normalizedName.prefix(80)) + "..." : normalizedName
            let reference: String
            if let bytes = int(item["byteSize"]), bytes > 0 {
                reference = "\(name), \(bytes / 1024)kB"
            } else {
                reference = name
            }
            return (kind, reference)
        }
        guard !entries.isEmpty else { return nil }
        let omitted = attachments.count > 3
        let kinds = Set(entries.map(\.kind))
        let label = !omitted && kinds.count == 1 ? entries[0].kind : "attachments"
        var references = entries.map(\.reference).joined(separator: "; ")
        if omitted { references += "; additional attachments omitted" }
        return "[sent \(label): \(references)]"
    }

    /// Origin records a route, not permission or an attested worker identity.
    /// Coordinator instructions and returns share it; roles stay unchanged.
    static func recordedOriginLabel(_ value: JSONValue?) -> String? {
        guard case .object(let origin)? = value else { return nil }
        switch (string(origin["surface"]), string(origin["agent"])) {
        case ("codex-bridge", "codex"): return "Codex bridge"
        case ("claude-bridge", "claude"): return "Claude bridge"
        case ("omp-bridge", "omp"): return "OMP bridge"
        default: return "unattributed route"
        }
    }

    /// Fragments remain useful evidence, but not completed replies. Only the
    /// persistence owner's explicit Boolean fields establish their status.
    static func recordedIncompleteReplyLabel(
        extras: [String: JSONValue]?, metadata: [String: JSONValue]?
    ) -> String? {
        if case .bool(true)? = extras?["cancelled"] { return "cancelled" }
        if case .bool(true)? = metadata?["cancelled"] { return "cancelled" }
        if case .bool(true)? = metadata?["partial"] { return "interrupted" }
        return nil
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let value)? = value else { return nil }
        return value
    }

    private static func int(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let number)?: return Int(exactly: number)
        case .double(let number)?: return Int(exactly: number)
        default: return nil
        }
    }
}

/// The plumbing a stored transcript row carries around its actual words: the
/// bridge's `[from: <agent>, via bridge]` routing prefix, and the wake-helper
/// receipt slip a delegated worker's reply arrives inside.
///
/// Agent, 2026-09-06: `search_chat_history` matched inside all of it, so
/// "Telegram missing duplicate notification" returned hundreds of hits made of
/// routing prefixes, "Automated completion event. Do NOT auto-fire…" headers
/// and the slip's Topic/Status lines. The chat SHELL already folds this
/// material away (`ChatShellConversationRow.stripBridgePrefix`,
/// `ChatShellEnvelope.reply`); search had no equivalent. This is the core's
/// copy of that same knowledge, applied to the searchable text only — the
/// stored row is never rewritten.
enum ChatTranscriptBoilerplate {
    static let replyMarker = "--- Claude's reply ---"
    static let endReplyMarker = "--- end reply ---"

    static func stripBridgePrefix(_ text: String) -> String {
        BridgeRoutingPrefix.stripping(text)
    }

    /// The routing-slip header lines a wake receipt opens with. Recognised by
    /// their exact `Key: value` spellings so ordinary prose that begins with a
    /// capitalised word is never eaten.
    private static let receiptHeaderKeys = [
        "originating message id:", "topic:", "priority:", "status:", "duration:",
    ]

    /// Whether the STORED row says it arrived through the agent bridge. Only
    /// those rows carry a routing prefix or a wake-helper receipt slip: the
    /// bridge stamps `metadata.origin.surface` (`claude-bridge`,
    /// `codex-bridge`, `omp-bridge`) on every message it delivers, wake
    /// receipts included, and the turn envelope carries the same surface for
    /// rows written before origin was persisted. A row the person typed in the
    /// app has neither.
    ///
    /// Agent, 2026-09-06: stripping used to be decided by SYNTAX alone, so
    /// anyone who quoted `[from: claude, via bridge]` or
    /// `--- Claude's reply ---` in their own message had their own words
    /// deleted from search. Persisted provenance decides now; a plain user row
    /// is never stripped.
    static func isBridgeRouted(rowMetadata: JSONValue?) -> Bool {
        guard case .object(let metadata)? = rowMetadata else { return false }
        for key in ["origin", "envelope"] {
            guard case .object(let object)? = metadata[key],
                  case .string(let surface)? = object["surface"] else { continue }
            let normalized = surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "bridge" || normalized.hasSuffix("-bridge") { return true }
        }
        return false
    }

    /// The words a transcript row actually SAID, with routing plumbing removed.
    ///
    /// Only a `bridgeRouted` row is touched (see `isBridgeRouted`). A wake
    /// receipt keeps only what is between the reply markers — that is the
    /// worker's real answer. A receipt with no reply marker keeps whatever
    /// follows its slip header. Everything else is returned unchanged apart
    /// from the bridge prefix.
    static func substantiveText(_ content: String, bridgeRouted: Bool) -> String {
        guard bridgeRouted else { return content }
        var text = stripBridgePrefix(content)
        if let start = text.range(of: replyMarker) {
            text = String(text[start.upperBound...])
            if let end = text.range(of: endReplyMarker) {
                text = String(text[..<end.lowerBound])
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // No reply marker: drop the receipt header itself (the "Automated
        // completion event … Do NOT auto-fire …" line and the slip's key rows)
        // and keep the body under it.
        let head = text.prefix(400).lowercased()
        guard head.contains("automated completion event")
                || head.hasPrefix("originating message id:")
                || head.hasPrefix("[claude-wake]")
                || head.hasPrefix("[omp-wake]")
        else { return text }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).drop { line in
            let lowered = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lowered.isEmpty { return true }
            if lowered.contains("automated completion event") { return true }
            // The reply-free notice variant of that same header line.
            if lowered.hasPrefix("[claude-wake] [notice]") { return true }
            return receiptHeaderKeys.contains { lowered.hasPrefix($0) }
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
