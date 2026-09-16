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
            // Agent on the glass, 2026-09-13: the unquoted form ate ordinary
            // prose — it had no leading boundary and `[\w]*` ran through the
            // rest of whatever word it landed inside, so "Apiary: beekeeping
            // notes" was redacted off the "api" buried in it. A credential
            // name is a WHOLE TOKEN: it starts at a token boundary, ends at
            // one, and the thing after the `=`/`:` still has to be
            // credential-shaped (eight or more unbroken characters).
            (
                "NAMED_SECRET",
                #"(?<![A-Za-z0-9])(?:[A-Za-z0-9]+[_-]){0,3}(?:api[_-]?key|key|token|secret|password|passwd|openai|anthropic|github)(?![A-Za-z0-9])\s*[=:]\s*[^\s"']{8,}"#,
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

    /// A DISPLAY field's redactor: the proven-shape secrets only, plus a
    /// named pair whose VALUE is itself credential-shaped — and then only the
    /// value is replaced, never the label.
    ///
    /// `redactText` is right for a tool result, where any `name: value` pair
    /// may be a leaked credential. It is wrong for a card's title, option
    /// label or prose, which are sentences written for a person: it ate
    /// "GitHub: Reconnect account" whole, because a label plus a colon plus
    /// words matches the general named-secret rule. A person reading a
    /// redacted card cannot tell what it is asking, which is worse than the
    /// hypothetical leak of two ordinary words.
    private static let displaySecretPatterns: [(String, NSRegularExpression)] = {
        let specs: [(String, String, NSRegularExpression.Options)] = [
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
        ]
        return specs.map { kind, pattern, options in
            guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
                preconditionFailure("Display redaction pattern failed: \(kind)")
            }
            return (kind, expression)
        }
    }()

    /// `<credential name> = <value>` with the name captured separately, so the
    /// label survives and only a value that PROVES itself a secret is cut.
    private static let displayNamedSecretPattern: NSRegularExpression = {
        let pattern = #"((?<![A-Za-z0-9])(?:[A-Za-z0-9]+[_-]){0,3}(?:api[_-]?key|access[_-]?key|private[_-]?key|token|secret|password|passwd)(?![A-Za-z0-9])["']?\s*[=:]\s*["']?)([^\s"']+)"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]
        ) else {
            preconditionFailure("Display named-secret pattern failed")
        }
        return expression
    }()

    /// Token-shaped: a long unbroken run that mixes character classes the way
    /// an issued credential does and an English word does not.
    private static func isTokenShaped(_ value: String) -> Bool {
        guard value.count >= 16 else { return false }
        let hasDigit = value.contains(where: \.isNumber)
        let hasLetter = value.contains(where: \.isLetter)
        let hasUpper = value.contains(where: { $0.isUppercase })
        let hasLower = value.contains(where: { $0.isLowercase })
        // Either digits mixed into letters, or mixed case in a long run — both
        // of which a sentence fragment that got this far will not have.
        return (hasDigit && hasLetter) || (hasUpper && hasLower && value.count >= 24)
    }

    /// Scrub a field a PERSON reads: keeps every label, replaces only what is
    /// demonstrably a secret.
    public static func redactDisplayText(_ value: String) -> String {
        var text = value
        for (kind, expression) in displaySecretPatterns {
            let nsText = text as NSString
            let matches = expression.matches(
                in: text, options: [], range: NSRange(location: 0, length: nsText.length)
            )
            for match in matches.reversed() {
                text = (text as NSString).replacingCharacters(
                    in: match.range, with: "[REDACTED_\(kind)]"
                )
            }
        }
        let nsText = text as NSString
        let named = displayNamedSecretPattern.matches(
            in: text, options: [], range: NSRange(location: 0, length: nsText.length)
        )
        for match in named.reversed() where match.numberOfRanges == 3 {
            let valueRange = match.range(at: 2)
            guard valueRange.location != NSNotFound else { continue }
            let candidate = (text as NSString).substring(with: valueRange)
            guard isTokenShaped(candidate) else { continue }
            text = (text as NSString).replacingCharacters(
                in: valueRange, with: "[REDACTED_NAMED_SECRET]"
            )
        }
        return text
    }

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
