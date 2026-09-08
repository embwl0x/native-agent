import Foundation

/// Credential scrubbing shared by presentation and trace boundaries; callers own bounding.
public enum TurnSecretRedactor {
    private static let credentialName = #"(?:[\w-]*(?:password|passwd|token|secret)|(?:[\w-]*[_-])?(?:api[_-]?key|private[_-]?key)|authorization)"#

    public static func isCredentialName(_ name: String) -> Bool {
        name.range(of: "^" + credentialName + "$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let secretPatterns: [(String, NSRegularExpression)] = {
        let specs: [(String, String, NSRegularExpression.Options)] = [
            // Scrub embedded JSON too, including JSON escaped inside another string.
            ("NAMED_SECRET", #"\\+""# + credentialName + #"\\+"\s*:\s*\\+".*?(?:\\+"(?=\s*[,}\]]|$)|$)"#, [.caseInsensitive, .dotMatchesLineSeparators]),
            ("NAMED_SECRET", #"["']"# + credentialName + #"["']\s*[:=]\s*(?:"(?:\\.|[^"\\])*(?:"|$)|'(?:\\.|[^'\\])*(?:'|$)|[^\s,}\]]+)"#, [.caseInsensitive]),
            (
                "PRIVATE_KEY",
                "-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----",
                [.dotMatchesLineSeparators]
            ),
            ("GITHUB_TOKEN", "\\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{30,})\\b", []),
            ("OPENAI_KEY", "\\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\\b", []),
            ("ANTHROPIC_KEY", "\\bsk-ant-[A-Za-z0-9_-]{20,}\\b", []),
            ("STRIPE_KEY", "\\b(?:sk|rk)_live_[A-Za-z0-9]{16,}\\b", []),
            ("SLACK_TOKEN", "\\bxox[baprs]-[A-Za-z0-9-]{20,}\\b", []),
            ("GOOGLE_API_KEY", "\\bAIza[0-9A-Za-z_-]{25,}\\b", []),
            ("BEARER_TOKEN", "\\bBearer\\s+[A-Za-z0-9._~+/=-]{20,}\\b", [.caseInsensitive]),
            (
                "NAMED_SECRET",
                "((?:OPENAI|ANTHROPIC|GH|GITHUB|API|TOKEN|SECRET|PASSWORD)[\\w]*[_\\s-]*(?:KEY|TOKEN|SECRET|PASSWORD)?\\s*[=:]\\s*)[^\\s\"']{8,}",
                [.caseInsensitive]
            ),
        ]
        return specs.map { kind, pattern, options in
            guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
                preconditionFailure("Turn presentation redaction pattern failed: \(kind)")
            }
            return (kind, expression)
        }
    }()

    public static func redactText(_ value: String) -> String {
        var text = value
        for (kind, expression) in secretPatterns {
            let nsText = text as NSString
            let matches = expression.matches(
                in: text,
                options: [],
                range: NSRange(location: 0, length: nsText.length)
            )
            for match in matches.reversed() {
                text = (text as NSString).replacingCharacters(
                    in: match.range,
                    with: "[REDACTED_\(kind)]"
                )
            }
        }
        return text
    }
}
