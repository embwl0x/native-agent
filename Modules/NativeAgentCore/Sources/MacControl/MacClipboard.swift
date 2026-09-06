// MacClipboard.swift — THE CLIPBOARD ORGAN (fable51 sweep item 30).
//
// The Mac's clipboard is the one place where every app already agrees to hand
// its content to whoever asks. Agent could press ⌘C through `act` and then had
// nowhere to read the result: the pasteboard existed only in UI code
// (ChatPlatformAdapters, DeskView, RunsView), never as an organ. That made
// "copy this document and tell me what it says" impossible for a reason that
// was pure omission.
//
// TWO ACTIONS, TWO CONTRACTS:
//
//   • `clipboard_read` — perception. It emits nothing, changes nothing, and
//     goes through the SAME shape redactor every other perception organ uses
//     (`MacScreenViewTextRedaction`). This is not optional politeness: a
//     password manager's ⌘C puts a live credential on the pasteboard, and an
//     unredacted read would ship it to a provider, a turn trace and every sink
//     that syncs one. Redaction is applied LINE BY LINE, because a copied
//     document is prose with (at most) a secret in it, and blanking the whole
//     document because one line is a token would blind the organ this exists
//     to build.
//
//   • `clipboard_write` — a local write. It replaces the general pasteboard's
//     contents, which is a change to the world (the next ⌘V anywhere pastes
//     it), so it sits at the same tier as the other Mac verbs that move
//     things. It never echoes the text back: the caller already knows what it
//     wrote, and echoing would put it through the redactor's blind spot.
//
// NON-TEXT is REPORTED, never dumped. An image or a file promise on the
// pasteboard is named by its UTI and its size; the bytes never enter a result.
// "There is a PNG here" is the honest answer, and it is the useful one.

import Foundation
import NativeAgentCore
import PersistenceCore

#if canImport(AppKit) && os(macOS)
import AppKit
#endif

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

/// The pasteboard seam. Production reads `NSPasteboard.general`; tests inject a
/// scripted board so redaction, round-trip and the non-text path are pinned
/// without touching User's real clipboard.
public protocol MacPasteboardSource: Sendable {
    /// `nil` when no pasteboard exists on this platform at all — which the
    /// caller REPORTS rather than dressing up as an empty clipboard.
    func read() -> MacPasteboardContents?
    /// Replace the pasteboard's contents with `text`. Returns false when the
    /// write was refused by the system.
    func write(text: String) -> Bool
}

#if canImport(AppKit) && os(macOS)
public struct SystemMacPasteboardSource: MacPasteboardSource {
    public init() {}

    public func read() -> MacPasteboardContents? {
        let board = NSPasteboard.general
        let types = (board.types ?? []).map { type in
            MacPasteboardType(
                identifier: type.rawValue,
                bytes: board.data(forType: type)?.count
            )
        }
        return MacPasteboardContents(
            text: board.string(forType: .string),
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
    public static let minMaxChars = 200
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
    /// IN it: `MacScreenViewTextRedaction.standaloneSecretReason` answers "is
    /// this line ITSELF a secret", which is exactly the question a clipboard
    /// line poses. A line that is a secret is replaced by its reason — never
    /// dropped silently, because a caller who cannot tell redaction from a
    /// short clipboard will re-read forever.
    ///
    /// Deliberately NOT the whole-blob check: a 4,000-character document is
    /// never a "high entropy token", so testing the blob would redact nothing
    /// and testing only the blob would miss the password on line 9.
    public static func redacted(_ raw: String) -> Redaction {
        var lines: [String] = []
        var flagged: [RedactedLine] = []
        for (index, line) in raw.components(separatedBy: "\n").enumerated() {
            if let reason = MacScreenViewTextRedaction.standaloneSecretReason(line) {
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
