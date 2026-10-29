import Foundation

// Blueprint: | `TurnSecretRedactor.swift` | `TurnSecretRedactor`: credential-name/token recognition and shared presentation/trace scrubbing; callers own size bounds |

/// Credential scrubbing shared by presentation and trace boundaries; callers own bounding.
public enum TurnSecretRedactor {
    // Pagination cursors are inputs, not credentials.
    private static let credentialName = #"(?!(?:next|pagination)_token(?![\w-]))(?:[\w-]*(?:password|passwd|token|secret)|(?:[\w-]*[_-])?(?:api[_-]?key|private[_-]?key)|authorization)"#

    public static func isCredentialName(_ name: String) -> Bool {
        name.range(of: "^" + credentialName + "$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let secretPatterns: [(String, NSRegularExpression)] = {
        let specs: [(String, String, NSRegularExpression.Options)] = [
            // Scrub embedded JSON too, including JSON escaped inside another string.
            ("NAMED_SECRET", #"\\+""# + credentialName + #"\\+"\s*:\s*\\+".*?(?:\\+"(?=\s*[,}\]]|$)|$)"#, [.caseInsensitive, .dotMatchesLineSeparators]),
            ("NAMED_SECRET", #"["']"# + credentialName + #"["']\s*[:=]\s*(?:"(?:\\.|[^"\\])*(?:"|$)|'(?:\\.|[^'\\])*(?:'|$)|[^\s,}\]]+)"#, [.caseInsensitive]),
            ("TELEGRAM_TOKEN", #"(?:bot\d+|\b\d{6,})(?::|%3[Aa])[A-Za-z0-9_-]+"#, [.caseInsensitive]),
            // Assignments and credential fields are secrets; provider-label prose needs a shaped value.
            (
                "NAMED_SECRET",
                // URLs are prose; credential-shaped query values still match.
                #"(?<![A-Za-z0-9])(?:[A-Za-z0-9]+[_-]){0,3}(?:api[_-]?key|key|token|secret|password|passwd|openai|anthropic|github)(?![A-Za-z0-9])\s*[=:]\s*(?!(?:https?|ftp)://)[^\s"']{8,}"#,
                [.caseInsensitive]
            ),
            ("BEARER_TOKEN", #"\bBearer\s+[A-Za-z0-9._~+/=-]+"#, [.caseInsensitive]),
        ]
        let patterns = specs.map { kind, pattern, options in
            guard let expression = try? NSRegularExpression(pattern: pattern, options: options.union(.caseInsensitive)) else {
                preconditionFailure("Turn presentation redaction pattern failed: \(kind)")
            }
            return (kind, expression)
        }
        return Array(patterns.prefix(2)) + credentialPatterns.filter { $0.0 != "BEARER_TOKEN" } + Array(patterns.suffix(3))
    }()

    /// Receipt and display boundaries share token recognition; callers own replacements.
    public static let credentialPatterns: [(String, NSRegularExpression)] = {
        let specs: [(String, String, NSRegularExpression.Options)] = [
            (
                "PRIVATE_KEY",
                "-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----",
                [.dotMatchesLineSeparators]
            ),
            ("GITHUB_TOKEN", "\\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{30,})\\b", []),
            ("JWT", "\\beyJ[A-Za-z0-9_-]{8,}\\.eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}", []),
            ("OPENAI_KEY", "\\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\\b", []),
            ("ANTHROPIC_KEY", "\\bsk-ant-[A-Za-z0-9_-]{20,}\\b", []),
            ("STRIPE_KEY", "\\b(?:sk|rk)_live_[A-Za-z0-9]{16,}\\b", []),
            ("SLACK_TOKEN", "\\bxox[baprs]-[A-Za-z0-9-]{20,}|\\bxapp-[A-Za-z0-9-]{20,}\\b", []),
            ("GOOGLE_API_KEY", "\\bAIza[0-9A-Za-z_-]{25,}\\b", []),
            ("BEARER_TOKEN", "\\bBearer\\s+[A-Za-z0-9._~+/=-]{20,}\\b", [.caseInsensitive]),
        ]
        return specs.map { kind, pattern, options in
            guard let expression = try? NSRegularExpression(pattern: pattern, options: options.union(.caseInsensitive)) else {
                preconditionFailure("Credential redaction pattern failed: \(kind)")
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
        var text = redactText(value, patterns: credentialPatterns) { kind, _ in "[REDACTED_\(kind)]" }
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
        redactText(value, patterns: secretPatterns) { kind, _ in "[REDACTED_\(kind)]" }
    }

    public static func redactText(_ value: String, replacement: (String, String) -> String) -> String {
        redactText(value, patterns: secretPatterns, replacement: replacement)
    }

    /// Boundaries supply additional patterns and their replacement format.
    public static func redactText(_ value: String, patterns: [(String, NSRegularExpression)],
                                  replacement: (String, String) -> String) -> String {
        var text = value
        for (kind, expression) in patterns {
            let nsText = text as NSString
            let matches = expression.matches(
                in: text,
                options: [],
                range: NSRange(location: 0, length: nsText.length)
            )
            // Each policy still sees the entire preceding policy's result.
            // Assemble its edits once instead of copying the full document
            // once per credential match.
            if !matches.isEmpty {
                var safe = "", start = 0
                safe.reserveCapacity(text.utf8.count)
                for match in matches {
                    var range = match.range
                    // Bare pairs keep their labels. Cursors remain usable;
                    // assignments and explicit credential names need no shape proof.
                    if kind == "NAMED_SECRET", !#""'\"#.utf16.contains(nsText.character(at: range.location)) {
                        let whole = nsText.substring(with: range)
                        guard let colon = whole.firstIndex(where: { $0 == "=" || $0 == ":" }) else { continue }
                        let value = whole[whole.index(after: colon)...].drop(while: \.isWhitespace)
                        let name = String(whole[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !["next_token", "pagination_token"].contains(name.lowercased()),
                              whole[colon] == "=" || isCredentialName(name) || isTokenShaped(String(value))
                        else { continue }
                        let offset = (String(whole[..<value.startIndex]) as NSString).length
                        range = NSRange(location: range.location + offset, length: range.length - offset)
                    }
                    safe += nsText.substring(with: NSRange(location: start, length: range.location - start))
                    safe += replacement(kind, nsText.substring(with: range))
                    start = range.location + range.length
                }
                safe += nsText.substring(from: start)
                text = safe
            }
        }
        return text
    }
}
