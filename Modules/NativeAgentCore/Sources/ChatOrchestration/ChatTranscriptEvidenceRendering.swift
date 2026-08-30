import Foundation
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
        case .unknown: return "completion unconfirmed"
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
