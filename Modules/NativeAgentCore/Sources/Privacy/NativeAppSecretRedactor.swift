import PersistenceCore
import NativeAgentShared
import Foundation
import NativeAgentCore
// Blueprint: | `NativeAppSecretRedactor.swift` | App privacy extends canonical credential redaction. |

public enum NativeAppSecretRedactor {
    /// App-only boundaries redact Telegram credentials and home paths more strictly than the shared activity-feed contract.
    private static let appOnlyPatterns: [(String, NSRegularExpression)] = {
        let specs: [(String, String, NSRegularExpression.Options)] = [
            ("TELEGRAM_TOKEN", "\\b(?:bot)?[0-9]{6,12}:[A-Za-z0-9_-]{30,}\\b", [.caseInsensitive]),
            ("LOCAL_HOME", "(?:/Users|/home)/[^/\\s]+", []),
        ]
        return specs.map { kind, pattern, options in
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else {
                preconditionFailure("NativeAppSecretRedactor pattern failed: \(kind)")
            }
            return (kind, re)
        }
    }()

    public static func redactText(_ value: String) -> String {
        TurnSecretRedactor.redactText(
            NativeAgentSecretRedactor.redactText(value), patterns: appOnlyPatterns,
            replacement: NativeAgentSecretRedactor.digestReplacement
        )
    }

    public static func isSecretArgName(_ name: String) -> Bool {
        NativeAgentSecretRedactor.isSecretName(name, use: .approval)
    }

    /// Withhold secret-named values at every depth and scrub credentials from remaining strings.
    public static func redactArguments(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let fields):
            return .object(Dictionary(uniqueKeysWithValues: fields.map { key, raw in
                (key, isSecretArgName(key) ? .string("[REDACTED]") : redactArguments(raw))
            }))
        case .array(let items): return .array(items.map(redactArguments))
        case .string(let text): return .string(redactText(text))
        default: return value
        }
    }

    /// Pattern-redact strings only; secret-named fields require redactArguments.
    public static func redactValue(_ value: JSONValue) -> JSONValue {
        value.mapStrings(redactText)
    }

    /// Remote errors keep only absolute-path leaves; relative paths and URL schemes remain readable.
    public static func redactedRemoteErrorDetail(_ value: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "(?<![A-Za-z0-9_.~%/-])(?:/[^\\s\"'<>)\\]},;/]+){2,}", options: []
        ) else { return value }
        var text = value
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        for match in matches.reversed() {
            let path = (text as NSString).substring(with: match.range)
            let leaf = (path as NSString).lastPathComponent
            text = (text as NSString).replacingCharacters(in: match.range,
                with: leaf.isEmpty ? "[redacted path]" : ".../\(leaf)")
        }
        return text
    }
}
