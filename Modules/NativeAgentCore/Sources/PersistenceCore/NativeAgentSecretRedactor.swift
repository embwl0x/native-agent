import CryptoKit
import Foundation

/// Canonical redaction contract for durable local receipts and activity feeds.
///
/// The pattern order and replacement format mirror the retired runtime's
/// `redact_secret_text` / `redact_secret_value` behavior. Subsystems that need
/// this exact eight-pattern, digest-bearing contract must reuse this owner
/// instead of carrying private copies. More aggressive privacy boundaries
/// (for example chat traces or public/app projections) may layer additional
/// patterns without weakening this baseline.
public enum NativeAgentSecretRedactor {
    private static let patterns: [(String, NSRegularExpression)] = {
        let specs: [(String, String, NSRegularExpression.Options)] = [
            (
                "PRIVATE_KEY",
                "-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----",
                [.dotMatchesLineSeparators]
            ),
            (
                "GITHUB_TOKEN",
                "\\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{30,})\\b",
                []
            ),
            ("OPENAI_KEY", "\\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\\b", []),
            ("ANTHROPIC_KEY", "\\bsk-ant-[A-Za-z0-9_-]{20,}\\b", []),
            ("STRIPE_KEY", "\\b(?:sk|rk)_live_[A-Za-z0-9]{16,}\\b", []),
            ("SLACK_TOKEN", "\\bxox[baprs]-[A-Za-z0-9-]{20,}\\b", []),
            ("GOOGLE_API_KEY", "\\bAIza[0-9A-Za-z_-]{25,}\\b", []),
            (
                "BEARER_TOKEN",
                "\\bBearer\\s+[A-Za-z0-9._~+/=-]{24,}\\b",
                [.caseInsensitive]
            ),
        ]
        return specs.map { kind, pattern, options in
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: options
            ) else {
                preconditionFailure("NativeAgentSecretRedactor pattern failed: \(kind)")
            }
            return (kind, expression)
        }
    }()

    public static func redactText(_ value: String) -> String {
        var text = value
        for (kind, expression) in patterns {
            let current = text as NSString
            let matches = expression.matches(
                in: text,
                options: [],
                range: NSRange(location: 0, length: current.length)
            )
            for match in matches.reversed() {
                let matched = current.substring(with: match.range)
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

    public static func redactValue(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let string):
            return .string(redactText(string))
        case .array(let items):
            return .array(items.map { redactValue($0) })
        case .object(let object):
            return .object(object.mapValues { redactValue($0) })
        default:
            return value
        }
    }
}
