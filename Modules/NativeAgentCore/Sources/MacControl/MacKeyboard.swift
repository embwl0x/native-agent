import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Carbon) && os(macOS)
import Carbon
#endif

// Blueprint: | `MacKeyboard.swift` | `MacKeyModifiers`, `MacKeyChord`, `MacKeySyntax`, `MacKeyEvent`, `MacSecureEventInput`: Layout and secure-input rules |

// MARK: - Key modifiers

public struct MacKeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command  = MacKeyModifiers(rawValue: 1 << 0)
    public static let shift    = MacKeyModifiers(rawValue: 1 << 1)
    public static let option   = MacKeyModifiers(rawValue: 1 << 2)
    public static let control  = MacKeyModifiers(rawValue: 1 << 3)
    public static let function = MacKeyModifiers(rawValue: 1 << 4)

    /// Stable sorted slugs keep payload ordering deterministic.
    public var slugs: [String] {
        var out: [String] = []
        if contains(.command) { out.append("cmd") }
        if contains(.control) { out.append("ctrl") }
        if contains(.function) { out.append("fn") }
        if contains(.option) { out.append("opt") }
        if contains(.shift) { out.append("shift") }
        return out
    }
}

// MARK: - Key syntax

public struct MacKeyChord: Sendable, Equatable {
    public let modifiers: MacKeyModifiers
    public let keyCode: UInt16
    /// Keep the written token so results echo the actual request.
    public let source: String

    public init(modifiers: MacKeyModifiers, keyCode: UInt16, source: String) {
        self.modifiers = modifiers
        self.keyCode = keyCode
        self.source = source
    }

    public func toJSON() -> JSONValue {
        .object([
            "source": .string(source),
            "key_code": .int(Int64(keyCode)),
            "modifiers": .array(modifiers.slugs.map { .string($0) }),
        ])
    }
}

public enum MacKeySyntaxError: Error, Equatable, LocalizedError {
    case empty
    case emptyChord(String)
    case danglingSeparator(String)
    case unknownModifier(String, chord: String)
    case unknownKey(String, chord: String)
    case keyCodeOutOfRange(String)
    case tooManyChords(Int, limit: Int)
    case textTooLong(Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "invalid_keystroke_syntax: empty key specification"
        case .emptyChord(let spec):
            return "invalid_keystroke_syntax: empty chord in \"\(spec)\""
        case .danglingSeparator(let chord):
            return "invalid_keystroke_syntax: dangling '+' in \"\(chord)\" (write the literal plus key as \"plus\")"
        case .unknownModifier(let mod, let chord):
            return "invalid_keystroke_syntax: unknown modifier \"\(mod)\" in \"\(chord)\" (use cmd/shift/opt/ctrl/fn)"
        case .unknownKey(let key, let chord):
            // Explain modifier-only input with the accepted chord/holding syntax.
            if MacKeySyntax.modifier(key.lowercased()) != nil {
                return """
                    invalid_keystroke_syntax: \"\(key)\" is a modifier, not a key; put it in `holding` with the key it modifies, or write a chord such as \
                    \(key.lowercased())+tab
                    """
            }
            return "invalid_keystroke_syntax: unknown key \"\(key)\" in \"\(chord)\""
        case .keyCodeOutOfRange(let raw):
            return "invalid_keystroke_syntax: key code \"\(raw)\" is outside 0…127"
        case .textTooLong(let count, let limit):
            return "invalid_text_length: \(count) characters exceeds the \(limit)-character literal text limit"
        case .tooManyChords(let count, let limit):
            return "invalid_keystroke_syntax: \(count) chords exceeds the \(limit)-chord cap"
        }
    }
}

/// Characters use the active layout; `key:` and `code:` explicitly address physical keys. Chords run sequentially; uppercase letters and shifted glyphs imply
/// Shift.
public enum MacKeySyntax {
    /// Hard cap: a single keystroke call cannot emit an unbounded chord storm.
    public static let maxChords = 64
    /// Hard cap on literal typing per call. Long text should be several calls.
    public static let maxTextCharacters = 4000

    static let namedKeys: [String: UInt16] = [
        "return": 36, "enter": 36, "\\n": 36,
        "tab": 48, "\\t": 48,
        "space": 49, "spacebar": 49,
        "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53,
        "capslock": 57,
        "forward_delete": 117, "forwarddelete": 117, "del": 117,
        "help": 114,
        "home": 115, "end": 119,
        "pageup": 116, "page_up": 116,
        "pagedown": 121, "page_down": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "leftarrow": 123, "rightarrow": 124, "downarrow": 125, "uparrow": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79,
        "f19": 80, "f20": 90,
    ]

    /// Resolve a glyph in one stroke; dead-key sequences are not key chords.
    private static func characterKey(_ glyph: String, command: Bool) -> (UInt16, MacKeyModifiers)? {
        #if canImport(Carbon) && os(macOS)
        // The input-source manager requires the main queue; copy layout bytes there before translating off-queue.
        let read = { () -> (Data, UInt8)? in
            guard let retained = TISCopyCurrentKeyboardLayoutInputSource() else { return nil }
            let source = retained.takeRetainedValue()
            guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
            return (Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data, LMGetKbdType())
        }
        guard let (data, keyboardType) = Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read),
              data.count >= MemoryLayout<UCKeyboardLayout>.size else { return nil }
        return data.withUnsafeBytes { buffer -> (UInt16, MacKeyModifiers)? in
            guard let base = buffer.baseAddress else { return nil }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            let variants: [(UInt32, MacKeyModifiers)] = [(0, []), (UInt32(shiftKey), .shift),
                (UInt32(optionKey), .option), (UInt32(shiftKey | optionKey), [.shift, .option])]
            for (flags, implied) in variants {
                for code in UInt16(0)...UInt16(127) {
                    var dead: UInt32 = 0, length = 0
                    var text = [UniChar](repeating: 0, count: 8)
                    let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown),
                        (flags | (command ? UInt32(cmdKey) : 0)) >> 8, UInt32(keyboardType),
                        OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, text.count, &length, &text)
                    if status == noErr, length <= text.count,
                       String(decoding: text.prefix(Int(length)), as: UTF16.self) == glyph { return (code, implied) }
                }
            }
            return nil
        }
        #else
        return nil
        #endif
    }

    static func modifier(_ token: String) -> MacKeyModifiers? {
        switch token {
        case "cmd", "command", "meta", "super": return .command
        case "shift": return .shift
        case "opt", "option", "alt": return .option
        case "ctrl", "control": return .control
        case "fn", "function": return .function
        default: return nil
        }
    }

    static func key(_ token: String, chord: String, modifiers: MacKeyModifiers = []) throws -> (UInt16, MacKeyModifiers) {
        let lower = token.lowercased()
        if let code = namedKeys[lower] {
            return (code, [])
        }
        if lower == "plus" { return try key("+", chord: chord, modifiers: modifiers) }
        if lower.hasPrefix("key:") || lower.hasPrefix("code:") {
            let raw = String(lower.drop(while: { $0 != ":" }).dropFirst())
            guard let value = Int(raw), (0...127).contains(value) else {
                throw MacKeySyntaxError.keyCodeOutOfRange(token)
            }
            return (UInt16(value), [])
        }
        if token.count == 1, let resolved = characterKey(token, command: modifiers.contains(.command)) {
            return resolved
        }
        // A bare modifier can itself be a key, as for a screensaver nudge.
        let modifierKeys: [String: UInt16] = ["shift": 56, "cmd": 55, "command": 55, "opt": 58,
                                              "option": 58, "alt": 58, "ctrl": 59, "control": 59]
        if let code = modifierKeys[lower] { return (code, []) }
        throw MacKeySyntaxError.unknownKey(token, chord: chord)
    }

    /// Reject malformed sequences whole: executing a partially understood shortcut can be destructive.
    public static func parseChords(_ spec: String, modifiers heldModifiers: MacKeyModifiers = []) throws -> [MacKeyChord] {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MacKeySyntaxError.empty }
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { throw MacKeySyntaxError.empty }
        guard tokens.count <= maxChords else {
            throw MacKeySyntaxError.tooManyChords(tokens.count, limit: maxChords)
        }

        var chords: [MacKeyChord] = []
        for token in tokens {
            // A bare "+" is the plus KEY, not a separator with empty sides.
            if token == "+" {
                let (code, implied) = try key(token, chord: token, modifiers: heldModifiers)
                chords.append(MacKeyChord(modifiers: heldModifiers.union(implied), keyCode: code, source: token))
                continue
            }
            let parts = token.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            guard !parts.isEmpty else { throw MacKeySyntaxError.emptyChord(spec) }
            if parts.contains(where: { $0.isEmpty }) {
                throw MacKeySyntaxError.danglingSeparator(token)
            }
            var modifiers = heldModifiers
            for raw in parts.dropLast() {
                guard let mod = modifier(raw.lowercased()) else {
                    throw MacKeySyntaxError.unknownModifier(raw, chord: token)
                }
                modifiers.insert(mod)
            }
            guard let keyToken = parts.last else { throw MacKeySyntaxError.emptyChord(token) }
            let (code, implied) = try key(keyToken, chord: token, modifiers: modifiers)
            chords.append(MacKeyChord(
                modifiers: modifiers.union(implied),
                keyCode: code,
                source: token
            ))
        }
        return chords
    }

    /// Held keys are simultaneous; deduplicate physical keys so each press has exactly one release.
    public static func parseHeldKeys(_ spec: String) throws -> (modifiers: MacKeyModifiers, keys: [UInt16]) {
        let tokens = spec.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { throw MacKeySyntaxError.empty }
        guard tokens.count <= maxChords else {
            throw MacKeySyntaxError.tooManyChords(tokens.count, limit: maxChords)
        }
        var modifiers: MacKeyModifiers = []
        var keys: [UInt16] = []
        // Resolve characters against all held modifiers because some layouts change their Command mapping.
        for token in tokens {
            if let held = modifier(token.lowercased()) { modifiers.formUnion(held) }
        }
        for token in tokens {
            if let modifier = modifier(token.lowercased()) {
                modifiers.formUnion(modifier)
            } else {
                for chord in try parseChords(token, modifiers: modifiers) {
                    modifiers.formUnion(chord.modifiers)
                    if !keys.contains(chord.keyCode) { keys.append(chord.keyCode) }
                }
            }
        }
        return (modifiers, keys)
    }

    /// Unicode emission bypasses layout keycodes; only the per-call length bound applies.
    public static func validateText(_ text: String) throws -> String {
        guard !text.isEmpty else { throw MacKeySyntaxError.empty }
        guard text.count <= maxTextCharacters else {
            throw MacKeySyntaxError.textTooLong(text.count, limit: maxTextCharacters)
        }
        return text
    }
}

// MARK: - Physical event seam

public struct MacKeyEvent: Sendable, Equatable {
    public let keyCode: UInt16
    public let down: Bool
    public let modifiers: MacKeyModifiers
    /// Unicode text travels verbatim without depending on keyboard layout.
    public let unicodeText: String?

    public init(keyCode: UInt16, down: Bool, modifiers: MacKeyModifiers = [], unicodeText: String? = nil) {
        self.keyCode = keyCode
        self.down = down
        self.modifiers = modifiers
        self.unicodeText = unicodeText
    }
}

/// Carbon’s secure-input probe is global and cannot identify the process that enabled it.
public enum MacSecureEventInput {
    public static func isEnabled() -> Bool {
        #if canImport(Carbon) && os(macOS)
        return IsSecureEventInputEnabled()
        #else
        return false
        #endif
    }
}
