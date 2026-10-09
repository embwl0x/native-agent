import Foundation
import os

private let nativeModuleLogger = Logger(
    subsystem: "com.example.nativeagent",
    category: "NativeAgentShared"
)

// Shared cannot import the core redactor. CloudKit errors can include record
// fields, so scrub credential text before making the diagnostic public.
private let nativeLogSecretPatterns: [NSRegularExpression] = [
    #"\\+"(?!(?:next|pagination)_token(?![\w-]))(?:[\w-]*(?:password|passwd|token|secret)|(?:[\w-]*[_-])?(?:api[_-]?key|private[_-]?key)|authorization)\\+"\s*:\s*\\+".*?(?:\\+"(?=\s*[,}\]]|$)|$)"#,
    #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#,
    #"\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{30,})\b"#,
    #"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#,
    #"\bsk-(?:proj-|ant-)?[A-Za-z0-9_-]{20,}\b"#,
    #"\b(?:sk|rk)_live_[A-Za-z0-9]{16,}\b"#,
    #"\bxox[baprs]-[A-Za-z0-9-]{20,}\b"#,
    #"\bAIza[0-9A-Za-z_-]{25,}\b"#,
    #"\bBearer\s+[A-Za-z0-9._~+/=-]+"#,
    #"(?:\bbot\d+|\b\d{6,})(?::|%3[Aa])[A-Za-z0-9_-]+"#,
    #"["'](?!(?:next|pagination)_token(?![\w-]))(?:[\w-]*(?:password|passwd|token|secret)|(?:[\w-]*[_-])?(?:api[_-]?key|private[_-]?key)|authorization)["']\s*[:=]\s*(?:"(?:\\.|[^"\\])*(?:"|$)|'(?:\\.|[^'\\])*(?:'|$)|[^\s,}\]]+)"#,
    #"(?<![A-Za-z0-9])(?:[A-Za-z0-9]+[_-]){0,3}(?:api[_-]?key|key|token|secret|password|passwd|openai|anthropic|github)(?![A-Za-z0-9])\s*[=:]\s*(?!(?:https?|ftp)://)[^\s"']{8,}"#,
].map { pattern in
    do {
        return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    } catch {
        preconditionFailure("Invalid logging redaction pattern")
    }
}

/// Module diagnostics. Callers must keep credential values out of messages.
func nativeLog(_ format: String, _ arguments: CVarArg...) {
    let message = arguments.isEmpty ? format : String(format: format, arguments: arguments)
    var safeMessage = message
    for pattern in nativeLogSecretPatterns {
        safeMessage = pattern.stringByReplacingMatches(
            in: safeMessage,
            range: NSRange(safeMessage.startIndex..., in: safeMessage),
            withTemplate: "[REDACTED]"
        )
    }
    nativeModuleLogger.log("\(safeMessage, privacy: .public)")
}
