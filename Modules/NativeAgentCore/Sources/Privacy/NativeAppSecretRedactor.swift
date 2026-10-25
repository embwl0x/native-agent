import PersistenceCore
import Foundation
import NativeAgentCore
// Blueprint: | `NativeAppSecretRedactor.swift` | NativeAppSecretRedactor: redactText and string-only redactValue; redactArguments withholds secret-named fields; redactedRemoteErrorDetail owns phone error path projection |

public enum NativeAppSecretRedactor {
    /// App-only privacy extensions layered after the canonical credential
    /// redactor. Telegram credentials and local home paths intentionally remain
    /// stricter than the cross-module activity-feed contract.
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
        NativeAgentSecretRedactor.redactText(
            NativeAgentSecretRedactor.redactText(value), patterns: appOnlyPatterns
        )
    }

    public static func isSecretArgName(_ name: String) -> Bool {
        NativeAgentSecretRedactor.isSecretName(name, use: .approval)
    }

    /// An approval card's arguments as shown to a person: a secret-named
    /// argument's value is withheld at any depth, and every string is
    /// scrubbed for token and key patterns.
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

    /// Remote error details reduce absolute paths of two or more segments to
    /// their leaf. Relative paths and URL schemes are excluded; `path:/…` is not.
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
