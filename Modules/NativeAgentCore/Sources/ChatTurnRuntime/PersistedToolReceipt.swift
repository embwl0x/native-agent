import Foundation
import PersistenceCore

// Blueprint: | `PersistedToolReceipt.swift` | `PersistedToolReceipt.project`: bounded, redacted historical tool facts and exact continuations; oversized locators are omitted rather than clipped; `SwiftNativeTurnEngine.landedEffect` reads declared landed effects from execution receipts |

extension SwiftNativeTurnEngine {
    /// Read landed effects from execution receipts, including batches and scripts.
    /// A part answers for itself. Ignore previews and unsettled outcomes; return
    /// "part" only for parts alone, otherwise the strongest landed effect.
    nonisolated static func landedEffect(_ receipt: JSONValue) -> String? {
        var landed: Set<String> = []
        func walk(_ value: JSONValue) {
            guard case .object(let fields) = value else { return }
            // A saved receipt too big to keep whole carries it, kept before it was bounded.
            if case .string(let kept)? = fields["landedEffect"] { landed.insert(kept); return }
            // A script's primitive rows declare their class as read_only alone.
            let own = if case .string(let effect)? = fields["effect"] { effect }
                else if case .bool(let read)? = fields["read_only"] { read ? "read" : "write" } else { String?.none }
            // Explicit effects win ("none" did not land, even executed); execution answers only without them.
            let did = fields["effects"].map { [.string("occurred"), .string("partial")].contains($0) } ?? (fields["execution"] == .string("executed"))
            if let own, did {
                landed.insert(own)
            }
            for key in own == nil ? ["receipts", "calls"] : ["receipts"] {
                if case .array(let rows)? = fields[key] { rows.forEach(walk) }
            }
        }
        walk(receipt)
        return landed == ["part"] ? "part" : ["irreversible", "write", "read"].first(where: landed.contains)
    }
}

/// A historical receipt, not another copy of the source or an extension of a
/// turn-scoped output handle. Preserve small factual fields before the preview
/// so later exact history reads need not rely on the assistant's own summary.
enum PersistedToolReceipt {
    static func project(tool: String, value: JSONValue, json: String, maximumCharacters: Int) -> String? {
        guard json.count > maximumCharacters else { return nil }
        let read = ["read_page", "read_file", "list_dir"].contains(tool) && value.objectValue != nil
        var fields: [String: JSONValue] = [
            "original_result_class": .string(ChatToolOutcome.exactResultClass(value).rawValue),
            "original_characters": .int(Int64(json.count)),
            "transcript_projection": .string(read ? "bounded_read_receipt" : "bounded_tool_receipt"),
            "full_result_in_transcript": .bool(false),
        ]
        let original = value.objectValue ?? [:]
        var omitted: [String] = []
        var evidence: [String: JSONValue] = [:]
        if read {
            let rootKeys = ["status", "reason", "ok", "id", "createdAt", "url", "path", "version", "snapshot",
                            "offset", "bytes", "returned_bytes", "count", "total_visible", "total_matching",
                            "has_more", "truncated", "name_contains", "case_sensitive"]
            let coverageKeys = ["complete", "extraction_status", "http_status", "response_complete",
                                "body_truncated", "text_truncated", "retained_body_bytes", "observed_body_bytes",
                                "body_byte_limit", "extracted_characters", "requested_url", "final_url", "content_type",
                                "declared_charset", "decoded_encoding", "encoding_source", "discarded_terminal_bytes", "encoding_error"]
            evidence = selectScalars(original, keys: rootKeys, budget: 1_500, prefix: "", omitted: &omitted)
            if case .object(let coverage)? = original["coverage"] {
                evidence["coverage"] = .object(selectScalars(coverage, keys: coverageKeys, budget: 2_000,
                                                            prefix: "coverage.", omitted: &omitted))
            } else if let coverage = original["coverage"], let value = safeScalar(coverage) {
                evidence["coverage"] = value
            }
            if case .object(let source)? = original["source_receipt"] {
                evidence["source_receipt"] = .object(selectScalars(source,
                    keys: ["path", "purpose", "source_id", "contents", "retention", "read_tool", "access"],
                    budget: 1_500, prefix: "source_receipt.", omitted: &omitted))
            }
            if case .object(let selection)? = original["selection"] {
                evidence["selection"] = .object(selectScalars(selection,
                    keys: ["mode", "find", "around", "matching_paragraphs", "returned_match_paragraphs",
                           "has_more_matches", "whole_text_returned", "returned_characters", "note"],
                    budget: 1_000, prefix: "selection.", omitted: &omitted))
            }
            if let next = original["next"], next != .null {
                if ChatTranscriptEvidenceRendering.historicalContinuationIsExact(next) {
                    evidence["next"] = next
                    evidence["continuation_note"] = .string("Historical read continuation. Access and source-version checks depend on the reader; changed source content may require a fresh read.")
                } else {
                    omitted.append("next")
                    evidence["continuation_note"] = .string("Historical continuation unavailable: oversized, redacted or invalid. Read the source afresh; do not reconstruct this continuation.")
                }
            }
            fields.merge([
                "evidence": .object(evidence),
                "evidence_fields_omitted": .array(omitted.map(JSONValue.string)),
                "verification_scope": .string("historical_tool_response_not_current_source_state"),
                "note": .string("Tool result truncated in transcript. Evidence fields describe the original read; the preview is incomplete. Temporary result handles only work in their originating turn. This receipt does not promise that the full source is still retained. Do not repeat an action merely to recover its output."),
            ]) { _, selected in selected }
        } else {
            for key in ["status", "ok", "success", "isError", "is_error", "failed", "refused", "timed_out", "timeout",
                        "partial", "streamClosed", "exit_code", "operationState", "verification",
                        "detail", "message", "reason", "error", "remedy", "next_step", "summary", "effects"] {
                guard let value = original[key] else { continue }
                let safe: JSONValue
                if case .string(let text) = value {
                    safe = .string(String(ChatSecretRedactor.redactText(text).prefix(600)))
                    if text.count > 600 { omitted.append(key) }
                } else {
                    guard let encoded = try? value.serialize(pretty: false), encoded.count <= 1_000,
                          let redacted = try? JSONValue.parse(Data(ChatSecretRedactor.redactText(encoded).utf8)) else {
                        omitted.append(key)
                        continue
                    }
                    safe = redacted
                }
                var candidate = fields
                candidate[key] = safe
                guard let encoded = try? JSONValue.object(candidate).serialize(pretty: false),
                      encoded.count <= maximumCharacters - 1_000 else { omitted.append(key); continue }
                fields = candidate
            }
            fields["bounded_fields"] = .array(omitted.map(JSONValue.string))
        }
        var previewLimit = max(0, maximumCharacters / 2)
        while true {
            fields["preview"] = .string(String(ChatSecretRedactor.redactText(String(json.prefix(previewLimit + 512))).prefix(previewLimit)))
            guard let serialized = try? JSONValue.object(fields).serialize(pretty: false) else { return nil }
            if serialized.count <= maximumCharacters { return serialized }
            if previewLimit == 0 {
                // Keep exact continuations before optional descriptive groups.
                guard read, let key = ["coverage", "source_receipt", "selection"].first(where: { evidence[$0] != nil }) else { return nil }
                evidence.removeValue(forKey: key)
                omitted.append(key)
                fields["evidence"] = .object(evidence)
                fields["evidence_fields_omitted"] = .array(omitted.map(JSONValue.string))
                continue
            }
            previewLimit /= 2
        }
    }

    private static func selectScalars(
        _ object: [String: JSONValue], keys: [String], budget: Int, prefix: String, omitted: inout [String]
    ) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for key in keys {
            guard let raw = object[key] else { continue }
            guard let value = safeScalar(raw) else { omitted.append(prefix + key); continue }
            var candidate = result
            candidate[key] = value
            guard let encoded = try? JSONValue.object(candidate).serialize(pretty: false), encoded.count <= budget else {
                omitted.append(prefix + key)
                continue
            }
            result = candidate
        }
        return result
    }

    private static func safeScalar(_ value: JSONValue) -> JSONValue? {
        switch value {
        case .string(let text):
            // Omit oversized locators instead of turning a clipped value into
            // an apparently exact path, URL or version. Redact before storing.
            guard text.count <= 512 else { return nil }
            return .string(ChatSecretRedactor.redactText(text))
        case .int, .double, .bool, .null: return value
        case .object, .array: return nil
        }
    }
}
