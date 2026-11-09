import Foundation
import NativeAgentShared
import PersistenceCore
import Privacy

// Blueprint: | `ApprovalWords.swift` | `ApprovalWords.call`: a tool call in the person's words, the act and what it does, for the card that asks them |

/// A card says what will happen in words, never the call's envelope: the act is an `app` action's own label (or the tool's title), and what
/// it does is that act with its arguments read plainly, the ones that decide a yes (where, to whom, what runs) first. Every argument shows,
/// each bounded on its own so a long one never hides another. Internal (`__`) and secret-named fields stay out; every value is redacted
/// whole before it is bounded, so no cut secret survives.
public enum ApprovalWords {
    public static func call(tool: String, input: JSONValue?) -> (act: String, says: String) {
        let fields = input?.objectValue ?? [:]
        let act: String
        let args: [String: JSONValue]
        if tool == "app", let action = fields["action"]?.stringValue {
            act = ToolActivityPresentation.act(action)
            args = fields["args"]?.objectValue ?? [:]
        } else {
            act = ToolActivityPresentation.title(tool)
            args = fields
        }
        let named = bounded(act, actLimit)
        let shown = shownFields(args)
        let what = shown.count == 1 ? shown[0].value : shown.map { $0.key + " " + $0.value }.joined(separator: "; ")
        return (named, what.isEmpty ? named : named + ": " + what)
    }

    /// Fields that decide whether the person says yes are named first; order is the display preference, not an allowlist.
    private static let deciding = ["path", "file_path", "paths", "directory", "to", "recipient", "recipients", "chat_id", "channel",
                                   "command", "cmd", "script", "url", "endpoint", "value", "name", "title", "subject"]

    private static func shownFields(_ fields: [String: JSONValue]) -> [(key: String, value: String)] {
        fields.filter { !$0.key.hasPrefix("__") && !NativeAppSecretRedactor.isSecretArgName($0.key) }
            .sorted { (deciding.firstIndex(of: $0.key) ?? deciding.count, $0.key) < (deciding.firstIndex(of: $1.key) ?? deciding.count, $1.key) }
            .compactMap { key, value in plain(value).map { (key.replacingOccurrences(of: "_", with: " "), bounded($0, valueLimit)) } }
    }

    /// A value read plainly: a string carrying a JSON list reads as its items, a yes/no as yes or no, an object as its fields.
    private static func plain(_ value: JSONValue) -> String? {
        switch value {
        case .null: return nil
        case .bool(let on): return on ? "yes" : "no"
        case .int(let number): return String(number)
        case .double(let number): return String(number)
        case .string(let text):
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("["), let list = try? JSONValue.parse(Data(text.utf8)), case .array = list { return plain(list) }
            return text.isEmpty ? nil : text
        case .array(let items):
            let words = items.compactMap(plain)
            return words.isEmpty ? nil : words.joined(separator: " · ")
        case .object(let fields):
            let words = shownFields(fields).map { $0.key + " " + $0.value }
            return words.isEmpty ? nil : words.joined(separator: ", ")
        }
    }

    private static let actLimit = 80
    private static let valueLimit = 500

    /// Redacted whole, then flattened and bounded.
    private static func bounded(_ text: String, _ limit: Int) -> String {
        let flat = NativeAppSecretRedactor.redactText(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}
