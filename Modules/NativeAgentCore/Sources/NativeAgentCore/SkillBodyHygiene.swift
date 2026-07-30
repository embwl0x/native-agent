import Foundation

public enum SkillBodyHygiene {
    public struct Violation: Equatable, Sendable {
        public let line: Int
        public let label: String
        public let message: String

        public init(line: Int, label: String, message: String) {
            self.line = line
            self.label = label
            self.message = message
        }
    }

    private static let bannedPatterns: [(label: String, pattern: String)] = [
        ("python", #"\bpython\b"#),
        ("daemon", #"\bdaemons?\b"#),
        ("native_agentd", #"native_agentd"#),
        ("old local port", #"127\.0\.0\.1:8765|:8765\b|\b8766\b"#),
        ("old tool proposal route", #"/v1/tools/propose"#),
        ("python cache artifact", #"\.pyc\b|\.pyo\b|__pycache__"#),
        ("old introspection tool names", #"daemon_introspect|daemon_status|daemon_logs"#),
    ]

    public static func violations(in text: String, requireHeading: Bool = true) -> [Violation] {
        var result: [Violation] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [Violation(line: 1, label: "empty", message: "empty skill body")]
        }

        let lines = text.components(separatedBy: .newlines)
        let firstNonEmpty = lines.enumerated().first { _, line in
            !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if requireHeading, let firstNonEmpty {
            let line = firstNonEmpty.element.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.hasPrefix("#") {
                result.append(Violation(
                    line: firstNonEmpty.offset + 1,
                    label: "heading",
                    message: "first non-empty line must be a markdown heading"
                ))
            }
        }
        if firstUsefulLine(in: text) == nil {
            result.append(Violation(
                line: firstNonEmpty.map { $0.offset + 1 } ?? 1,
                label: "body",
                message: "skill body must include non-heading guidance"
            ))
        }

        for (index, line) in lines.enumerated() {
            for pattern in bannedPatterns {
                if line.range(
                    of: pattern.pattern,
                    options: [.regularExpression, .caseInsensitive]
                ) != nil {
                    result.append(Violation(
                        line: index + 1,
                        label: pattern.label,
                        message: "stale active-skill term: \(pattern.label)"
                    ))
                }
            }
        }
        return result
    }

    public static func isClean(_ text: String, requireHeading: Bool = true) -> Bool {
        violations(in: text, requireHeading: requireHeading).isEmpty
    }

    public static func firstUsefulLine(in text: String) -> String? {
        text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { line in !line.isEmpty && !line.hasPrefix("#") }
    }

    public static func failureMessage(for violations: [Violation]) -> String {
        let prefix = violations.prefix(5).map { violation in
            "line \(violation.line): \(violation.message)"
        }
        let suffix = violations.count > prefix.count ? "; ... \(violations.count - prefix.count) more" : ""
        return prefix.joined(separator: "; ") + suffix
    }
}
