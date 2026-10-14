import PersistenceCore
import Foundation
import NativeAgentCore

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

    /// Argument names whose value an approval card never shows (the Mac
    /// chat card and the copies sent to the phone and Telegram).
    public static let secretArgMarkers = [
        "token", "secret", "password", "passwd", "api_key", "apikey",
        "authorization", "auth", "credential", "private_key", "cookie",
    ]

    public static func isSecretArgName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return secretArgMarkers.contains { lowered.contains($0) }
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

    public static func redactValue(_ value: JSONValue) -> JSONValue {
        value.mapStrings(redactText)
    }
}
