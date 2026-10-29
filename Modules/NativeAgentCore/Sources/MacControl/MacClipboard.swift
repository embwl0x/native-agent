// MacClipboard.swift — clipboard contracts.
// Reads apply line-by-line perception redaction so one secret does not hide an entire document.
// Writes replace the general pasteboard without echoing input.
// Non-text content is named by UTI without reading its bytes or claiming a size.

import Foundation
import NativeAgentCore
import PersistenceCore

#if canImport(AppKit) && os(macOS)
import AppKit
#endif

// Blueprint: | `MacClipboard.swift` | `MacClipboardRead` and pasteboard ports: permission-bound clipboard reads/writes, source redaction and bounded text/type projection |

// MARK: - What one look at the pasteboard found

/// A single pasteboard type present on the general pasteboard.
public struct MacPasteboardType: Sendable, Equatable {
    /// The raw UTI (`public.utf8-plain-text`, `public.png`, …).
    public let identifier: String
    /// Byte count of the data behind this type, when the pasteboard reports
    /// one. `nil` means "present but the size is not knowable" — never zero,
    /// which would be a claim.
    public let bytes: Int?

    public init(identifier: String, bytes: Int? = nil) {
        self.identifier = identifier
        self.bytes = bytes
    }
}

/// Everything a read of the general pasteboard can honestly report.
public struct MacPasteboardContents: Sendable, Equatable {
    /// The plain-text flavor, RAW. Redaction happens at the serialization
    /// boundary, never in the seam, so a synthetic source can carry a secret
    /// and the test still proves the redactor ran.
    public let text: String?
    public let types: [MacPasteboardType]
    /// `NSPasteboard.changeCount` — the only stable "did this change" signal
    /// the system publishes. Reported so a caller can tell a re-read apart
    /// from a stale one without diffing content.
    public let changeCount: Int

    public init(text: String?, types: [MacPasteboardType], changeCount: Int) {
        self.text = text
        self.types = types
        self.changeCount = changeCount
    }
}

/// Pasteboard access; production uses `NSPasteboard.general`.
public protocol MacPasteboardSource: Sendable {
    /// `nil` when no pasteboard exists on this platform at all — which the
    /// caller REPORTS rather than dressing up as an empty clipboard.
    func read() -> MacPasteboardContents?
    /// Replace the pasteboard's contents with `text`. Returns false when the
    /// write failed; the previous contents may already have been cleared.
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

/// Non-macOS builds and any environment with no window server. It says so
/// instead of pretending the clipboard is empty.
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
    /// Default characters returned by one read. Larger than the look cap
    /// (6,144 bytes) on purpose: the whole point of the ⌘A ⌘C route is a dense
    /// document the AX walk cannot express, and a cap tuned for a window's
    /// controls would make this organ useless for the job it exists for.
    public static let defaultMaxChars = 8_000
    public static let hardMaxChars = 32_000
    public static let minMaxChars = 0
    /// A single `clipboard_write` payload cap. Generous — she is writing text
    /// she composed — but bounded, because an unbounded pasteboard write is a
    /// memory shape, not a feature.
    public static let maxWriteChars = 100_000

    public static func clampedMaxChars(_ requested: Int?) -> Int {
        guard let requested else { return defaultMaxChars }
        return min(max(requested, minMaxChars), hardMaxChars)
    }

    /// One redacted line and, when it went dark, WHY.
    public struct RedactedLine: Sendable, Equatable {
        public let line: Int
        public let reason: String
    }

    public struct Redaction: Sendable, Equatable {
        public let text: String
        public let redactedLines: [RedactedLine]
        public var didRedact: Bool { !redactedLines.isEmpty }
    }

    /// THE BOUNDARY. Every character that leaves this organ passes through
    /// here.
    ///
    /// Line by line, because a copied document is prose with at most a secret
    /// IN it. The shared redactor checks each line on its own and under the
    /// preceding line's label. A secret is replaced by its reason — never
    /// dropped silently, because a caller who cannot tell redaction from a
    /// short clipboard will re-read forever.
    ///
    /// Deliberately NOT the whole-blob check: a 4,000-character document is
    /// never a "high entropy token", so testing the blob would redact nothing
    /// and testing only the blob would miss the password on line 9.
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

    /// Cut to `maxChars` on a character boundary, reporting whether it cut.
    public static func truncated(_ text: String, maxChars: Int) -> (text: String, truncated: Bool) {
        guard text.count > maxChars else { return (text, false) }
        return (String(text.prefix(maxChars)), true)
    }

    /// The `types` channel: names and sizes, never bytes.
    public static func typesJSON(_ types: [MacPasteboardType]) -> JSONValue {
        .array(types.map { type in
            var row: [String: JSONValue] = ["type": .string(type.identifier)]
            if let bytes = type.bytes { row["bytes"] = .int(Int64(bytes)) }
            return .object(row)
        })
    }

    /// True when the pasteboard carries something this organ cannot put into
    /// words — an image, a file promise, an app's private flavor. Used only to
    /// phrase the answer honestly; the bytes are never read.
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
