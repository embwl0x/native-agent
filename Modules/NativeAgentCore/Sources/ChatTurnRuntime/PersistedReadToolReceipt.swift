import Foundation
import PersistenceCore

/// A historical receipt, not another copy of the source or an extension of a
/// turn-scoped output handle. Preserve small factual fields before the preview
/// so later exact history reads need not rely on the assistant's own summary.
enum PersistedReadToolReceipt {
    static func project(tool: String, json: String, maximumCharacters: Int) -> String? {
        guard ["read_page", "read_file", "list_dir"].contains(tool),
              json.count > maximumCharacters,
              json.utf8.count <= ProviderToolResultRecoveryStore.maxEntryBytes,
              case .object(let original)? = try? JSONValue.parse(Data(json.utf8)) else { return nil }

        let rootKeys = ["status", "reason", "ok", "id", "createdAt", "url", "path", "version", "snapshot",
                        "offset", "bytes", "returned_bytes", "count", "total_visible", "total_matching",
                        "has_more", "truncated", "name_contains", "case_sensitive"]
        let coverageKeys = ["complete", "extraction_status", "http_status", "response_complete",
                            "body_truncated", "text_truncated", "retained_body_bytes", "observed_body_bytes",
                            "body_byte_limit", "extracted_characters", "requested_url", "final_url", "content_type",
                            "declared_charset", "decoded_encoding", "encoding_source", "discarded_terminal_bytes", "encoding_error"]
        var omitted: [String] = []
        var evidence = selectScalars(original, keys: rootKeys, budget: 1_500, prefix: "", omitted: &omitted)
        if case .object(let coverage)? = original["coverage"] {
            evidence["coverage"] = .object(selectScalars(coverage, keys: coverageKeys, budget: 2_000,
                                                        prefix: "coverage.", omitted: &omitted))
        } else if let coverage = original["coverage"], let value = safeScalar(coverage) {
            evidence["coverage"] = value
        }
        if case .object(let source)? = original["source_receipt"] {
            evidence["source_receipt"] = .object(selectScalars(source,
                keys: ["path", "source_id", "contents", "retention", "read_tool", "access"],
                budget: 1_500, prefix: "source_receipt.", omitted: &omitted))
        }
        var fields: [String: JSONValue] = [
            "evidence": .object(evidence),
            "evidence_fields_omitted": .array(omitted.map(JSONValue.string)),
            "original_result_class": .string(ChatToolOutcome.exactResultClass(.object(original)).rawValue),
            "original_characters": .int(Int64(json.count)),
            "transcript_projection": .string("bounded_read_receipt"),
            "full_result_in_transcript": .bool(false),
            "verification_scope": .string("historical_tool_response_not_current_source_state"),
            "note": .string("Tool result truncated in transcript. Evidence fields describe the original read; the preview is incomplete. Temporary result handles only work in their originating turn. This receipt does not promise that the full source is still retained. Do not repeat an action merely to recover its output."),
        ]
        var previewLimit = max(0, maximumCharacters / 2)
        while true {
            let window = String(json.prefix(previewLimit + 512))
            fields["preview"] = .string(String(ChatSecretRedactor.redactText(window).prefix(previewLimit)))
            guard let serialized = try? JSONValue.object(fields).serialize(pretty: false) else { return nil }
            if serialized.count <= maximumCharacters { return serialized }
            if previewLimit == 0 { return nil }
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
