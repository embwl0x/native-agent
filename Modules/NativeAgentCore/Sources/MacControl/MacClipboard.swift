// Redact clipboard text by line so one secret cannot hide an entire document. Writes never echo input; nontext types expose only UTIs, never bytes or guessed
// sizes.

import Foundation
import NativeAgentCore
import PersistenceCore

#if canImport(AppKit) && os(macOS)
import AppKit
#endif

// Blueprint: | `MacClipboard.swift` | `MacClipboardRead`: Permission-bound pasteboard reads/writes; bounded redacted text and type metadata |

// MARK: - What one look at the pasteboard found

public struct MacPasteboardType: Sendable, Equatable {
    public let identifier: String
    /// Byte count of the data behind this type, when the pasteboard reports one. `nil` means "present but the size is not knowable" — never zero, which would
    /// be a claim.
    public let bytes: Int?

    public init(identifier: String, bytes: Int? = nil) {
        self.identifier = identifier
        self.bytes = bytes
    }
}

public struct MacPasteboardContents: Sendable, Equatable {
    /// Keep raw text within the seam; every serialization must apply redaction before text leaves the process.
    public let text: String?
    public let types: [MacPasteboardType]
    /// Use NSPasteboard.changeCount to distinguish fresh reads without comparing or exposing content.
    public let changeCount: Int

    public init(text: String?, types: [MacPasteboardType], changeCount: Int) {
        self.text = text
        self.types = types
        self.changeCount = changeCount
    }
}

public protocol MacPasteboardSource: Sendable {
    /// A missing pasteboard is unavailable, never evidence of an empty clipboard.
    func read() -> MacPasteboardContents?
    /// A failed replacement may already have cleared the previous contents; false cannot promise preservation.
    func write(text: String) -> Bool
}

#if canImport(AppKit) && os(macOS)
public struct SystemMacPasteboardSource: MacPasteboardSource {
    public init() {}

    public func read() -> MacPasteboardContents? {
        let board = NSPasteboard.general
        let text = board.string(forType: .string)
        let types = (board.types ?? []).map { type in
            MacPasteboardType(
                identifier: type.rawValue,
                bytes: type == .string ? text?.utf8.count : nil
            )
        }
        return MacPasteboardContents(
            text: text,
            types: types,
            changeCount: board.changeCount
        )
    }

    public func write(text: String) -> Bool {
        let board = NSPasteboard.general
        board.clearContents()
        return board.setString(text, forType: .string)
    }
}
#endif

/// Platforms without a window server report unavailability rather than an empty clipboard.
public struct UnavailableMacPasteboardSource: MacPasteboardSource {
    public init() {}
    public func read() -> MacPasteboardContents? { nil }
    public func write(text: String) -> Bool { false }
}

public func defaultMacPasteboardSource() -> any MacPasteboardSource {
    #if canImport(AppKit) && os(macOS)
    return SystemMacPasteboardSource()
    #else
    return UnavailableMacPasteboardSource()
    #endif
}

// MARK: - The redaction boundary

public enum MacClipboardRead {
    /// Allow more than a window look's text cap because copied documents can be dense prose the AX tree cannot express.
    public static let defaultMaxChars = 8_000
    public static let hardMaxChars = 32_000
    public static let minMaxChars = 0
    /// Bound writes to prevent an unbounded pasteboard payload from exhausting memory.
    public static let maxWriteChars = 100_000

    public static func clampedMaxChars(_ requested: Int?) -> Int {
        guard let requested else { return defaultMaxChars }
        return min(max(requested, minMaxChars), hardMaxChars)
    }

    public struct RedactedLine: Sendable, Equatable {
        public let line: Int
        public let reason: String
    }

    public struct Redaction: Sendable, Equatable {
        public let text: String
        public let redactedLines: [RedactedLine]
        public var didRedact: Bool { !redactedLines.isEmpty }
    }

    /// Redact each line with its preceding label context before text leaves this boundary. Whole-blob entropy misses embedded secrets; retain redaction reasons
    /// so callers cannot mistake withheld text for a short clipboard and reread forever.
    public static func redacted(_ raw: String) -> Redaction {
        var lines: [String] = []
        var flagged: [RedactedLine] = []
        var previousLine: String?
        for (index, line) in raw.components(separatedBy: "\n").enumerated() {
            let redacted = MacScreenViewTextRedaction.redactedLegendString(
                line, valueChars: line.count, under: previousLine
            )
            var reason: String?
            if case .object(let details) = redacted,
               case .string(let sharedReason)? = details["reason"] {
                reason = sharedReason
            } else if let label = previousLine?.trimmingCharacters(in: .whitespacesAndNewlines),
                      label.hasSuffix(":"),
                      MacScreenViewTextRedaction.looksLikeSecretLabel(label),
                      !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reason = "labeled_secret_nearby"
            }
            previousLine = line
            if let reason {
                flagged.append(RedactedLine(line: index + 1, reason: reason))
                lines.append("[redacted: \(reason)]")
            } else {
                lines.append(line)
            }
        }
        return Redaction(text: lines.joined(separator: "\n"), redactedLines: flagged)
    }

    /// Cut only on character boundaries and report truncation so partial text stays explicit.
    public static func truncated(_ text: String, maxChars: Int) -> (text: String, truncated: Bool) {
        guard text.count > maxChars else { return (text, false) }
        return (String(text.prefix(maxChars)), true)
    }

    /// Types expose names and sizes only; reading bytes would disclose nontext content.
    public static func typesJSON(_ types: [MacPasteboardType]) -> JSONValue {
        .array(types.map { type in
            var row: [String: JSONValue] = ["type": .string(type.identifier)]
            if let bytes = type.bytes { row["bytes"] = .int(Int64(bytes)) }
            return .object(row)
        })
    }

    /// Use unsupported-type evidence only to explain unrenderable contents; never read those bytes.
    public static func hasNonTextTypes(_ types: [MacPasteboardType]) -> Bool {
        types.contains { !isTextType($0.identifier) }
    }

    static func isTextType(_ identifier: String) -> Bool {
        let lower = identifier.lowercased()
        return lower.hasPrefix("public.utf")
            || lower.hasPrefix("public.plain-text")
            || lower.hasPrefix("public.text")
            || lower == "public.rtf"
            || lower == "public.html"
            || lower.hasPrefix("com.apple.traditional-mac-plain-text")
            || lower.hasPrefix("nsstringpboardtype")
    }
}
