import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore

enum NativeAppSecretRedactor {
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

    static func redactText(_ value: String) -> String {
        var text = NativeAgentSecretRedactor.redactText(value)
        for (kind, re) in appOnlyPatterns {
            let ns = text as NSString
            let matches = re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                let matched = ns.substring(with: match.range)
                let digest = SHA256.hash(data: Data(matched.utf8))
                    .map { String(format: "%02x", $0) }
                    .joined()
                    .prefix(12)
                text = (text as NSString).replacingCharacters(
                    in: match.range,
                    with: "[REDACTED_\(kind):\(digest)]"
                )
            }
        }
        return text
    }

    static func redactValue(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let s):
            return .string(redactText(s))
        case .array(let items):
            return .array(items.map { redactValue($0) })
        case .object(let obj):
            var out: [String: JSONValue] = [:]
            for (key, raw) in obj {
                out[key] = redactValue(raw)
            }
            return .object(out)
        default:
            return value
        }
    }
}
