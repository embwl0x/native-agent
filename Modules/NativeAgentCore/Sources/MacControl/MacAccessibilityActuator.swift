import Foundation
import NativeAgentCore
import PersistenceCore
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

// MARK: - The action organ (W2 + W3)
//
// This file is the ACT half of Mac computer control. It is deliberately a
// SEPARATE file and a SEPARATE set of protocols from `MacAccessibilityReader`,
// so the read organ's injection-free guarantee stays provable by structure:
// every `CGEvent`, `AXUIElementPerformAction` and `AXUIElementSetAttributeValue`
// call in the module lives here, and nothing here is reachable from the read
// path (`MacAXElementSource`).
//
// Two injectable seams, both so tests never touch the real keyboard/mouse:
//   • `MacEventSink`   — physical event emission (CGEvent). Production is
//     `CGEventSink`; tests record events and assert on them.
//   • `MacAXActSource` — semantic action on a live AXUIElement resolved from a
//     child-index `path` (the handle `ax_tree`/`ax_find` hand out). Production
//     is `SystemMacAXActSource`; tests inject a synthetic tree.
//
// The act source resolves paths through its OWN element handles rather than
// reusing a `MacAXElementRef` minted by the reader. That is not duplication for
// its own sake: it keeps the read seam free of any element the act path could
// mutate, and a path resolved fresh at act time cannot be a stale handle from
// a snapshot taken seconds earlier.

// MARK: - Key modifiers

public struct MacKeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command  = MacKeyModifiers(rawValue: 1 << 0)
    public static let shift    = MacKeyModifiers(rawValue: 1 << 1)
    public static let option   = MacKeyModifiers(rawValue: 1 << 2)
    public static let control  = MacKeyModifiers(rawValue: 1 << 3)
    public static let function = MacKeyModifiers(rawValue: 1 << 4)

    /// Stable, sorted slugs for payloads and test assertions.
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

/// One resolved chord: zero or more modifiers plus exactly one virtual keycode.
public struct MacKeyChord: Sendable, Equatable {
    public let modifiers: MacKeyModifiers
    public let keyCode: UInt16
    /// The token as written, kept for honest echo in the result payload.
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
            return "invalid_keystroke_syntax: unknown key \"\(key)\" in \"\(chord)\""
        case .keyCodeOutOfRange(let raw):
            return "invalid_keystroke_syntax: key code \"\(raw)\" is outside 0…127"
        case .tooManyChords(let count, let limit):
            return "invalid_keystroke_syntax: \(count) chords exceeds the \(limit)-chord cap"
        }
    }
}

/// Human key syntax → virtual keycodes.
///
/// GRAMMAR (US ANSI layout, which is what the virtual-keycode table below
/// encodes — a non-US layout maps the same codes to different glyphs, so
/// literal TEXT should go through `text:` rather than `keys:`):
///
///     spec   := chord ( WHITESPACE+ chord )*        ; a sequence, run in order
///     chord  := ( modifier "+" )* key
///     modifier := cmd | command | meta | super
///                | shift
///                | opt | option | alt
///                | ctrl | control
///                | fn | function
///     key    := named | character | raw
///     named  := return|enter|tab|escape|esc|space|delete|backspace
///             | forward_delete|del|home|end|pageup|pagedown|up|down|left|right
///             | capslock|help|plus|f1…f20
///     character := any single character on the US layout; an UPPERCASE letter
///                  or a shifted glyph ("!", "?", ":") implies `shift`
///     raw    := ("key:"|"code:") 0…127        ; escape hatch for exotic keys
///
/// Examples: `cmd+shift+4`, `return`, `cmd+a cmd+c`, `ctrl+opt+left`, `key:96`.
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

    /// Unshifted US-ANSI glyph → virtual keycode.
    static let unshiftedCharacters: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16,
        "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30,
        "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
        "m": 46, ".": 47, "`": 50, " ": 49,
    ]

    /// Shifted US-ANSI glyph → the unshifted glyph it lives on.
    static let shiftedCharacters: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6",
        "&": "7", "*": "8", "(": "9", ")": "0", "_": "-", "+": "=",
        "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",",
        ">": ".", "?": "/", "~": "`",
    ]

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

    /// Resolve a key token to `(keyCode, impliedModifiers)`.
    static func key(_ token: String, chord: String) throws -> (UInt16, MacKeyModifiers) {
        let lower = token.lowercased()
        if let code = namedKeys[lower] {
            // "plus" is the only named key that itself implies a modifier.
            return lower == "plus" ? (24, .shift) : (code, [])
        }
        if lower == "plus" { return (24, .shift) }
        if lower.hasPrefix("key:") || lower.hasPrefix("code:") {
            let raw = String(lower.drop(while: { $0 != ":" }).dropFirst())
            guard let value = Int(raw), (0...127).contains(value) else {
                throw MacKeySyntaxError.keyCodeOutOfRange(token)
            }
            return (UInt16(value), [])
        }
        if token.count == 1, let character = token.first {
            if let code = unshiftedCharacters[Character(String(character).lowercased())],
               character.isLetter {
                // An uppercase letter is shift + the letter's key.
                return (code, character.isUppercase ? .shift : [])
            }
            if let code = unshiftedCharacters[character] {
                return (code, [])
            }
            if let base = shiftedCharacters[character], let code = unshiftedCharacters[base] {
                return (code, .shift)
            }
        }
        throw MacKeySyntaxError.unknownKey(token, chord: chord)
    }

    /// Parse a whitespace-separated chord sequence. Throws on ANY malformed
    /// input — a partially understood keystroke spec must never be executed,
    /// because "the part I understood" can itself be a destructive shortcut.
    public static func parseChords(_ spec: String) throws -> [MacKeyChord] {
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
                chords.append(MacKeyChord(modifiers: .shift, keyCode: 24, source: token))
                continue
            }
            let parts = token.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            guard !parts.isEmpty else { throw MacKeySyntaxError.emptyChord(spec) }
            if parts.contains(where: { $0.isEmpty }) {
                throw MacKeySyntaxError.danglingSeparator(token)
            }
            var modifiers: MacKeyModifiers = []
            for raw in parts.dropLast() {
                guard let mod = modifier(raw.lowercased()) else {
                    throw MacKeySyntaxError.unknownModifier(raw, chord: token)
                }
                modifiers.insert(mod)
            }
            let (code, implied) = try key(parts[parts.count - 1], chord: token)
            chords.append(MacKeyChord(
                modifiers: modifiers.union(implied),
                keyCode: code,
                source: token
            ))
        }
        return chords
    }

    /// Validate literal text for the `text:` path. Unicode is emitted through
    /// `keyboardSetUnicodeString`, so no keycode table is involved and any
    /// layout works — the only limit is length.
    public static func validateText(_ text: String) throws -> String {
        guard !text.isEmpty else { throw MacKeySyntaxError.empty }
        guard text.count <= maxTextCharacters else {
            throw MacKeySyntaxError.tooManyChords(text.count, limit: maxTextCharacters)
        }
        return text
    }
}

// MARK: - Physical event seam

public struct MacKeyEvent: Sendable, Equatable {
    public let keyCode: UInt16
    public let down: Bool
    public let modifiers: MacKeyModifiers
    /// When non-nil the event carries this text verbatim via
    /// `CGEvent.keyboardSetUnicodeString` — the layout-independent typing path.
    public let unicodeText: String?

    public init(keyCode: UInt16, down: Bool, modifiers: MacKeyModifiers = [], unicodeText: String? = nil) {
        self.keyCode = keyCode
        self.down = down
        self.modifiers = modifiers
        self.unicodeText = unicodeText
    }
}

public enum MacMouseButton: String, Sendable, Equatable {
    case left
    case right
}

public enum MacMousePhase: String, Sendable, Equatable {
    case move
    case down
    case up
    case drag
}

public struct MacMouseEvent: Sendable, Equatable {
    public let phase: MacMousePhase
    public let button: MacMouseButton
    public let x: Double
    public let y: Double
    public let clickCount: Int

    public init(phase: MacMousePhase, button: MacMouseButton, x: Double, y: Double, clickCount: Int = 1) {
        self.phase = phase
        self.button = button
        self.x = x
        self.y = y
        self.clickCount = clickCount
    }
}

public enum MacScrollUnit: String, Sendable, Equatable {
    case line
    case pixel
}

public struct MacScrollEvent: Sendable, Equatable {
    public let deltaX: Int32
    public let deltaY: Int32
    public let unit: MacScrollUnit

    public init(deltaX: Int32, deltaY: Int32, unit: MacScrollUnit) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.unit = unit
    }
}

/// The ONLY route to synthesized input in this module. Tests inject a recorder
/// so the whole executor is exercised without moving the real cursor.
public protocol MacEventSink: Sendable {
    /// False when this build/platform cannot synthesize events at all. The
    /// handlers then refuse honestly instead of reporting a no-op as success.
    var isAvailable: Bool { get }
    func post(key: MacKeyEvent)
    func post(mouse: MacMouseEvent)
    func post(scroll: MacScrollEvent)
}

#if canImport(CoreGraphics) && os(macOS)

/// Live `CGEvent` emitter posted at `.cghidEventTap` (the same tap a physical
/// device posts to, so apps cannot tell the difference and no per-app AX
/// support is needed). Requires the macOS Accessibility TCC grant — which is
/// User's click in System Settings; this code never prompts or toggles it.
public struct CGEventSink: MacEventSink {
    public init() {}

    public var isAvailable: Bool { true }

    private func source() -> CGEventSource? {
        CGEventSource(stateID: .hidSystemState)
    }

    private func flags(_ modifiers: MacKeyModifiers) -> CGEventFlags {
        var out: CGEventFlags = []
        if modifiers.contains(.command) { out.insert(.maskCommand) }
        if modifiers.contains(.shift) { out.insert(.maskShift) }
        if modifiers.contains(.option) { out.insert(.maskAlternate) }
        if modifiers.contains(.control) { out.insert(.maskControl) }
        if modifiers.contains(.function) { out.insert(.maskSecondaryFn) }
        return out
    }

    public func post(key event: MacKeyEvent) {
        guard let cg = CGEvent(
            keyboardEventSource: source(),
            virtualKey: CGKeyCode(event.keyCode),
            keyDown: event.down
        ) else { return }
        cg.flags = flags(event.modifiers)
        if let text = event.unicodeText {
            let units = Array(text.utf16)
            units.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                cg.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            }
        }
        cg.post(tap: .cghidEventTap)
    }

    public func post(mouse event: MacMouseEvent) {
        let point = CGPoint(x: event.x, y: event.y)
        let type: CGEventType
        let button: CGMouseButton
        switch (event.phase, event.button) {
        case (.move, _):          type = .mouseMoved;        button = .left
        case (.down, .left):      type = .leftMouseDown;     button = .left
        case (.up, .left):        type = .leftMouseUp;       button = .left
        case (.drag, .left):      type = .leftMouseDragged;  button = .left
        case (.down, .right):     type = .rightMouseDown;    button = .right
        case (.up, .right):       type = .rightMouseUp;      button = .right
        case (.drag, .right):     type = .rightMouseDragged; button = .right
        }
        guard let cg = CGEvent(
            mouseEventSource: source(),
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else { return }
        if event.phase != .move {
            cg.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, event.clickCount)))
        }
        cg.post(tap: .cghidEventTap)
    }

    public func post(scroll event: MacScrollEvent) {
        let units: CGScrollEventUnit = event.unit == .pixel ? .pixel : .line
        guard let cg = CGEvent(
            scrollWheelEvent2Source: source(),
            units: units,
            wheelCount: 2,
            wheel1: event.deltaY,
            wheel2: event.deltaX,
            wheel3: 0
        ) else { return }
        cg.post(tap: .cghidEventTap)
    }
}

#endif

/// Platform fallback: honest unavailability, never a silent no-op success.
public struct UnavailableMacEventSink: MacEventSink {
    public init() {}
    public var isAvailable: Bool { false }
    public func post(key: MacKeyEvent) {}
    public func post(mouse: MacMouseEvent) {}
    public func post(scroll: MacScrollEvent) {}
}

/// Reports available (so reachability/gating logic behaves as in production —
/// a test that asserts "keystroke dispatches" must still see `status: typed`)
/// but swallows every event. Used ONLY under a test harness so `swift test`
/// cannot post real CGEvents into the host's frontmost app. Distinct from
/// `UnavailableMacEventSink`, which reports UNavailable and would flip the
/// dispatch decision.
public struct InertAvailableMacEventSink: MacEventSink {
    public init() {}
    public var isAvailable: Bool { true }
    public func post(key: MacKeyEvent) {}
    public func post(mouse: MacMouseEvent) {}
    public func post(scroll: MacScrollEvent) {}
}

/// True when the process is a test run. DELIBERATELY class-linkage-only:
/// `XCTestCase` is linked into every `swift test` runner process (XCTest and
/// swift-testing alike) and into NO shipped app build — while environment
/// probes (XCTestConfigurationFilePath / SWIFT_TESTING) can be injected into a
/// production launch via launchctl setenv or a wrapper, which would silently
/// make her Mac control inert-but-"successful" (gpt-5.5 review 2026-08-13
/// NEEDS-FIX #2/#3). A class-linkage probe cannot be spoofed by environment.
private func isRunningUnderTestHarness() -> Bool {
    NSClassFromString("XCTestCase") != nil
}

public func defaultMacEventSink() -> any MacEventSink {
    // Load-bearing safety gate: a bare `swift test` holds the host's
    // Accessibility grant, so the real CGEvent sink would type and click into
    // whatever app is frontmost. Route tests to an inert-but-available sink so
    // reachability assertions still pass while NO real input reaches the host.
    // Production (no test env) is byte-identical to before. (2026-08-13, from a
    // worker FLAG that observed `status: typed` during a test run.)
    if isRunningUnderTestHarness() {
        return InertAvailableMacEventSink()
    }
    #if canImport(CoreGraphics) && os(macOS)
    return CGEventSink()
    #else
    return UnavailableMacEventSink()
    #endif
}

// MARK: - Semantic act seam

/// A live element the act source resolved from a child-index path. `handle` is
/// opaque and source-owned — nothing outside the source may interpret it.
public struct MacAXActTarget: Sendable, Equatable {
    public let handle: Int
    public let role: String
    public let title: String?
    public let value: String?
    public let enabled: Bool
    public let frame: MacAXFrame?
    public let actions: [String]

    public init(
        handle: Int,
        role: String,
        title: String? = nil,
        value: String? = nil,
        enabled: Bool = true,
        frame: MacAXFrame? = nil,
        actions: [String] = []
    ) {
        self.handle = handle
        self.role = role
        self.title = title
        self.value = value
        self.enabled = enabled
        self.frame = frame
        self.actions = actions
    }

    /// Geometric centre — the CGEvent fallback's click point.
    public var centre: (x: Double, y: Double)? {
        guard let frame, frame.w > 0, frame.h > 0 else { return nil }
        return (frame.x + frame.w / 2.0, frame.y + frame.h / 2.0)
    }

    /// - Parameter redactingValue: W2/W3-FIX-R2 3. When an `ax_act` call
    ///   CARRIES a `value`, the string it wrote is the same class of secret as
    ///   `mac_keystroke.text` — it can be a password or a 2FA code typed into a
    ///   field. Echoing it back through `element.value` / `post_state.value`
    ///   put it into the tool result, the turn trace, the operation store and
    ///   the approval record's `resultPreview`, which syncs to iOS/Telegram.
    ///   With this flag the element's value becomes count + digest, exactly
    ///   like the redacted ARGUMENT, so a reviewer can still confirm after the
    ///   fact that what landed is what was approved.
    public func toJSON(redactingValue: Bool = false) -> JSONValue {
        var object: [String: JSONValue] = [
            "role": .string(role),
            "enabled": .bool(enabled),
            "actions": .array(actions.map { .string($0) }),
        ]
        object["title"] = title.map { .string(MacAccessibilityReader.truncate($0, to: MacAXLimits.hardValueChars)) } ?? .null
        if redactingValue {
            object["value"] = value.map { MacInjectionResultRedaction.redactedSecret($0) } ?? .null
        } else {
            object["value"] = value.map { .string(MacAccessibilityReader.truncate($0, to: MacAXLimits.hardValueChars)) } ?? .null
        }
        object["frame"] = frame?.toJSON() ?? .null
        return .object(object)
    }
}

public enum MacAXActOutcome: String, Sendable, Equatable {
    /// The AX call returned success. The APP ran its own handler.
    case performed
    /// The element does not advertise this action / attribute as settable.
    case unsupported
    /// The AX call was attempted and the API reported failure.
    case failed
    /// The handle no longer resolves (window closed, element released).
    case invalidTarget
}

/// Semantic action on a live element. Separate protocol from
/// `MacAXElementSource` on purpose: the read seam has no member that can
/// mutate anything, and this one is the only place that can.
public protocol MacAXActSource: Sendable {
    func isTrusted() -> Bool
    /// Resolve a child-index chain from the frontmost window root. `[]` is the
    /// window itself. Returns nil when any index is out of range.
    func resolve(path: [Int]) -> MacAXActTarget?
    func perform(_ target: MacAXActTarget, action: String) -> MacAXActOutcome
    func setValue(_ target: MacAXActTarget, value: String) -> MacAXActOutcome
    /// Re-read the element's attributes so the caller can see the POST-state.
    func reread(_ target: MacAXActTarget) -> MacAXActTarget?
}

#if canImport(ApplicationServices) && os(macOS)

/// Live `AXUIElement` actuator. This is the only type in the module that calls
/// `AXUIElementPerformAction` / `AXUIElementSetAttributeValue`.
///
/// Handles are minted per instance into a locked table (`@unchecked Sendable`
/// carried by that lock — `AXUIElement` is a CFType with no Sendable
/// conformance and every access is serialized here), exactly like the reader's
/// table but entirely separate from it.
public final class SystemMacAXActSource: MacAXActSource, @unchecked Sendable {
    private let lock = NSLock()
    private var table: [Int: AXUIElement] = [:]
    private var nextID = 0

    public init() {}

    private func mint(_ element: AXUIElement) -> Int {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        table[nextID] = element
        return nextID
    }

    private func element(_ handle: Int) -> AXUIElement? {
        lock.lock()
        defer { lock.unlock() }
        return table[handle]
    }

    public func isTrusted() -> Bool { AXIsProcessTrusted() }

    public func resolve(path: [Int]) -> MacAXActTarget? {
        #if canImport(AppKit)
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard var current = copyElement(appElement, kAXFocusedWindowAttribute)
            ?? copyElement(appElement, kAXMainWindowAttribute)
            ?? copyElementArray(appElement, kAXWindowsAttribute).first
        else { return nil }
        for index in path {
            let children = copyElementArray(current, kAXChildrenAttribute)
            guard index >= 0, index < children.count else { return nil }
            current = children[index]
        }
        return describe(current)
        #else
        return nil
        #endif
    }

    public func perform(_ target: MacAXActTarget, action: String) -> MacAXActOutcome {
        guard let element = element(target.handle) else { return .invalidTarget }
        guard target.actions.contains(action) else { return .unsupported }
        let status = AXUIElementPerformAction(element, action as CFString)
        switch status {
        case .success: return .performed
        case .actionUnsupported: return .unsupported
        default: return .failed
        }
    }

    public func setValue(_ target: MacAXActTarget, value: String) -> MacAXActOutcome {
        guard let element = element(target.handle) else { return .invalidTarget }
        var settable: DarwinBoolean = false
        let probe = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        guard probe == .success, settable.boolValue else { return .unsupported }
        let status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        switch status {
        case .success: return .performed
        case .attributeUnsupported, .actionUnsupported: return .unsupported
        default: return .failed
        }
    }

    public func reread(_ target: MacAXActTarget) -> MacAXActTarget? {
        guard let element = element(target.handle) else { return nil }
        return describe(element, reusing: target.handle)
    }

    // MARK: raw AX reads used to describe the target (nil-tolerant)

    private func describe(_ element: AXUIElement, reusing handle: Int? = nil) -> MacAXActTarget? {
        guard let role = copyString(element, kAXRoleAttribute) else { return nil }
        return MacAXActTarget(
            handle: handle ?? mint(element),
            role: role,
            title: copyString(element, kAXTitleAttribute) ?? copyString(element, kAXDescriptionAttribute),
            value: copyString(element, kAXValueAttribute),
            enabled: copyBool(element, kAXEnabledAttribute) ?? true,
            frame: copyFrame(element),
            actions: copyActions(element)
        )
    }

    private func copyRaw(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw
    }

    private func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let raw = copyRaw(element, attribute), CFGetTypeID(raw) == CFStringGetTypeID() else { return nil }
        let string = raw as! CFString as String
        return string.isEmpty ? nil : string
    }

    private func copyBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let raw = copyRaw(element, attribute), CFGetTypeID(raw) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((raw as! CFBoolean))
    }

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let raw = copyRaw(element, attribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private func copyElementArray(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        guard let raw = copyRaw(element, attribute), CFGetTypeID(raw) == CFArrayGetTypeID() else { return [] }
        return (raw as! CFArray as [AnyObject]).compactMap { candidate in
            guard CFGetTypeID(candidate) == AXUIElementGetTypeID() else { return nil }
            return (candidate as! AXUIElement)
        }
    }

    private func copyActions(_ element: AXUIElement) -> [String] {
        var raw: CFArray?
        guard AXUIElementCopyActionNames(element, &raw) == .success, let raw else { return [] }
        return (raw as [AnyObject]).compactMap { $0 as? String }
    }

    /// Both halves required — a fabricated `0,0` half would send the CGEvent
    /// fallback clicking the screen corner (same rule as the reader's frame).
    private func copyFrame(_ element: AXUIElement) -> MacAXFrame? {
        var point = CGPoint.zero
        var size = CGSize.zero
        var hasPoint = false
        var hasSize = false
        if let raw = copyRaw(element, kAXPositionAttribute), CFGetTypeID(raw) == AXValueGetTypeID() {
            hasPoint = AXValueGetValue((raw as! AXValue), .cgPoint, &point)
        }
        if let raw = copyRaw(element, kAXSizeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() {
            hasSize = AXValueGetValue((raw as! AXValue), .cgSize, &size)
        }
        guard hasPoint && hasSize else { return nil }
        return MacAXFrame(x: Double(point.x), y: Double(point.y), w: Double(size.width), h: Double(size.height))
    }
}

#endif

public struct UnavailableMacAXActSource: MacAXActSource {
    public init() {}
    public func isTrusted() -> Bool { false }
    public func resolve(path: [Int]) -> MacAXActTarget? { nil }
    public func perform(_ target: MacAXActTarget, action: String) -> MacAXActOutcome { .invalidTarget }
    public func setValue(_ target: MacAXActTarget, value: String) -> MacAXActOutcome { .invalidTarget }
    public func reread(_ target: MacAXActTarget) -> MacAXActTarget? { nil }
}

public func defaultMacAXActSource() -> any MacAXActSource {
    #if canImport(ApplicationServices) && os(macOS)
    return SystemMacAXActSource()
    #else
    return UnavailableMacAXActSource()
    #endif
}

// MARK: - Pure executor

/// Event PLANS. The planners are pure functions of the request so a test can
/// assert the exact event sequence without a sink at all; `MacAccessibilityActuator`
/// then just pushes a plan into a sink.
public enum MacEventPlanner {
    /// Literal text: one keyDown/keyUp pair per character carrying the
    /// character as a unicode string. Per-character (rather than one event for
    /// the whole string) because apps that inspect keyDown individually — text
    /// editors with autocomplete, terminal emulators — behave as they do for a
    /// human typist.
    public static func typeText(_ text: String) -> [MacKeyEvent] {
        var events: [MacKeyEvent] = []
        for character in text {
            let unit = String(character)
            events.append(MacKeyEvent(keyCode: 0, down: true, modifiers: [], unicodeText: unit))
            events.append(MacKeyEvent(keyCode: 0, down: false, modifiers: [], unicodeText: unit))
        }
        return events
    }

    /// Chords: keyDown then keyUp with the modifier flags set on BOTH events.
    /// Flags-on-the-event (rather than separate modifier keyDown/keyUp events)
    /// is what CGEvent expects; a missing flag on keyUp leaves apps that track
    /// modifier state believing the modifier is still held.
    public static func chord(_ chord: MacKeyChord) -> [MacKeyEvent] {
        [
            MacKeyEvent(keyCode: chord.keyCode, down: true, modifiers: chord.modifiers),
            MacKeyEvent(keyCode: chord.keyCode, down: false, modifiers: chord.modifiers),
        ]
    }

    /// Click: move → (down → up) × count. The move first so hover-sensitive
    /// UI is in the state a human's click would find it in.
    public static func click(
        x: Double,
        y: Double,
        button: MacMouseButton,
        count: Int
    ) -> [MacMouseEvent] {
        let clicks = max(1, min(count, 3))
        var events: [MacMouseEvent] = [
            MacMouseEvent(phase: .move, button: button, x: x, y: y, clickCount: 1)
        ]
        for index in 1...clicks {
            events.append(MacMouseEvent(phase: .down, button: button, x: x, y: y, clickCount: index))
            events.append(MacMouseEvent(phase: .up, button: button, x: x, y: y, clickCount: index))
        }
        return events
    }

    /// Drag: move to origin → press → dragged to destination → release.
    public static func drag(
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        button: MacMouseButton
    ) -> [MacMouseEvent] {
        [
            MacMouseEvent(phase: .move, button: button, x: fromX, y: fromY),
            MacMouseEvent(phase: .down, button: button, x: fromX, y: fromY),
            MacMouseEvent(phase: .drag, button: button, x: toX, y: toY),
            MacMouseEvent(phase: .up, button: button, x: toX, y: toY),
        ]
    }
}

/// The semantic act (`ax_act`), as pure logic over the two seams.
///
/// ORDER — AX first, CGEvent second, and never silently:
///   1. `value` given → try `AXSetValue`. That is how you fill a text field
///      without simulating 40 keystrokes.
///   2. otherwise → the requested AX action (default `AXPress`) if the element
///      advertises it. The APP runs its real handler; works occluded/off-screen.
///   3. neither available → synthesize a click at the element's frame centre,
///      and SAY SO in `method` + `fallback_reason`. A caller must always be
///      able to tell which of the two mechanisms actually fired.
public enum MacAccessibilityActuator {
    /// The one non-result failure: the `path` no longer addresses an element.
    /// Typed rather than a bare string so callers cannot mistake it for a
    /// merely-unsuccessful act.
    public enum Failure: String, Error, Equatable, Sendable {
        case pathNotFound = "ax_path_not_found"
    }

    public static let defaultAction = "AXPress"

    public struct ActResult: Sendable, Equatable {
        public let ok: Bool
        /// `ax_set_value` | `ax_action` | `cgevent_click_fallback` | `none`
        public let method: String
        public let requestedAction: String
        public let outcome: MacAXActOutcome
        public let fallbackReason: String?
        public let target: MacAXActTarget
        public let postState: MacAXActTarget?
        public let error: String?
    }

    public static func act(
        source: any MacAXActSource,
        sink: any MacEventSink,
        path: [Int],
        action requestedAction: String?,
        value: String?
    ) -> Result<ActResult, Failure> {
        let action = (requestedAction?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? defaultAction
        guard let target = source.resolve(path: path) else {
            return .failure(.pathNotFound)
        }

        if let value {
            let outcome = source.setValue(target, value: value)
            if outcome == .performed {
                return .success(ActResult(
                    ok: true,
                    method: "ax_set_value",
                    requestedAction: "AXSetValue",
                    outcome: outcome,
                    fallbackReason: nil,
                    target: target,
                    postState: source.reread(target),
                    error: nil
                ))
            }
            // A settable-value request that the element refuses is NOT a click:
            // clicking a field that would not take the text is a different
            // effect than the caller asked for, so it fails honestly instead.
            return .success(ActResult(
                ok: false,
                method: "none",
                requestedAction: "AXSetValue",
                outcome: outcome,
                fallbackReason: nil,
                target: target,
                postState: source.reread(target),
                error: "ax_set_value_\(outcome.rawValue)"
            ))
        }

        if target.actions.contains(action) {
            let outcome = source.perform(target, action: action)
            if outcome == .performed {
                return .success(ActResult(
                    ok: true,
                    method: "ax_action",
                    requestedAction: action,
                    outcome: outcome,
                    fallbackReason: nil,
                    target: target,
                    postState: source.reread(target),
                    error: nil
                ))
            }
            // Advertised but refused: fall through to the physical fallback,
            // which is exactly the case the fallback exists for.
            return fallbackClick(
                source: source,
                sink: sink,
                target: target,
                action: action,
                reason: "ax_action_\(outcome.rawValue)"
            )
        }

        return fallbackClick(
            source: source,
            sink: sink,
            target: target,
            action: action,
            reason: "element_does_not_advertise_\(action)"
        )
    }

    private static func fallbackClick(
        source: any MacAXActSource,
        sink: any MacEventSink,
        target: MacAXActTarget,
        action: String,
        reason: String
    ) -> Result<ActResult, Failure> {
        guard sink.isAvailable else {
            return .success(ActResult(
                ok: false,
                method: "none",
                requestedAction: action,
                outcome: .unsupported,
                fallbackReason: reason,
                target: target,
                postState: source.reread(target),
                error: "event_injection_unavailable"
            ))
        }
        guard let centre = target.centre else {
            return .success(ActResult(
                ok: false,
                method: "none",
                requestedAction: action,
                outcome: .unsupported,
                fallbackReason: reason,
                target: target,
                postState: source.reread(target),
                error: "no_ax_action_and_no_frame"
            ))
        }
        for event in MacEventPlanner.click(x: centre.x, y: centre.y, button: .left, count: 1) {
            sink.post(mouse: event)
        }
        return .success(ActResult(
            ok: true,
            method: "cgevent_click_fallback",
            requestedAction: action,
            outcome: .performed,
            fallbackReason: reason,
            target: target,
            postState: source.reread(target),
            error: nil
        ))
    }
}

// MARK: - Injection TOOL vocabulary (the model-facing names)

/// `macControlAccessibilityInjectionActions` names the MacControl ACTIONS.
/// This names the model-facing TOOLS that map onto them, in every spelling the
/// catalog has ever used. Single source of truth for the autonomy floor, the
/// YOLO exclusion, and the redaction sinks — three places that were previously
/// keeping their own copies of the same four strings, which is how one of them
/// (the autonomy override path) ended up out of step.
public enum MacInjectionToolNames {
    public static let canonical: [String: String] = [
        "mac_keystroke": "keystroke",
        "mac_click": "click",
        "mac_scroll": "scroll",
        "mac_ax_act": "ax_act",
        // W6 — mac_wake posts a HID nudge, so it belongs to the SAME
        // vocabulary: one entry here is what gives it the approval floor, the
        // Full-Mac-YOLO exclusion, the replay verification and the capability
        // mint, with no wake-shaped special case anywhere in the gate.
        "mac_wake": "wake",
        "mac.keystroke": "keystroke",
        "mac.click": "click",
        "mac.scroll": "scroll",
        "mac.ax_act": "ax_act",
        "mac.wake": "wake",
    ]

    public static var all: Set<String> { Set(canonical.keys) }

    public static func isInjectionTool(_ toolName: String) -> Bool {
        canonical[toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] != nil
    }

    /// The MacControl action a tool name maps to, or nil if it is not an
    /// injection tool.
    public static func action(forTool toolName: String) -> String? {
        canonical[toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

    /// The autonomy level injection tools can never resolve below. Any policy
    /// resolution that comes back more permissive than this is clamped to it.
    public static let minimumAutonomyLevel = "send_approval"

    /// Levels that would let a tool fire with no human in the loop. Anything in
    /// here is what the floor exists to override.
    public static let unattendedAutonomyLevels: Set<String> = [
        "auto", "app_data_autonomous", "workspace_autonomous",
    ]

    /// THE FLOOR (W2/W3-FIX 3). Apply to the FINAL resolved autonomy level of
    /// any tool, after defaults, exact overrides, glob overrides, Full Mac YOLO
    /// and every other policy input have had their say.
    ///
    /// The first cut only excluded these tools from the broad Full-Mac YOLO
    /// branch, which left the ordinary override table wide open: a saved
    /// `toolAutonomy` entry of `"mac_keystroke": "auto"` (or a glob like
    /// `"mac_*": "auto"`) resolved to auto and fired with no approval. Autonomy
    /// policy is user-editable data, and a model with a policy-writing tool is
    /// a model that can promote itself. A floor applied AFTER resolution is not
    /// bypassable by any policy content: the most an override can do now is
    /// make an injection tool MORE restrictive.
    /// USER 2026-08-12 — YOLO: "Nothing should be approval gated for her.
    /// Nothing." The floor is DISABLED at his explicit direction. His machine,
    /// his agent: the Full-Mac grant + accessibility category + the macOS TCC
    /// grant are the gates, and per-call approval made every motor tool dead on
    /// non-interactive surfaces (the bridge, while he is away) — precisely when
    /// he needs her to act. Restore by returning the clamp below.
    public static func clampedAutonomyLevel(toolName: String, resolved: String) -> String {
        return resolved
    }
}

// MARK: - Approval capability (W2/W3-FIX 1+2, replaces the forgeable marker)

/// A per-call, non-forgeable authorization to synthesize input.
///
/// WHY IT IS A TYPE AND NOT A JSON KEY. The first cut of this wave carried the
/// approval as `body["__mac_injection_approved"] = true`. That is in-band with
/// model-supplied arguments, so anything that could put a key in a dictionary —
/// the model's own tool arguments, an HTTP body, a raw dispatcher call — could
/// mint the authority itself. Stripping-then-stamping made forgery from the
/// MODEL hard but left every in-process caller of the public API able to type
/// the key. The boundary was a convention, not a boundary.
///
/// What replaces it:
///   • `MacInjectionCapability` has a PRIVATE memberwise init. It cannot be
///     constructed by writing a literal; the only constructor is `mint`.
///   • It is not `Codable` and carries no wire form, so it cannot arrive from
///     off-process. The HTTP / iOS bridge calls `dispatch`, which has no
///     parameter that can carry one — remote injection is refused by SIGNATURE,
///     not by a runtime check that could be forgotten.
///   • It is BOUND: to one action, to a SHA-256 digest of the exact body, to an
///     approval id, and to a short TTL. A capability minted for
///     `keystroke "hello"` does not authorize `keystroke "rm -rf /"`, a
///     different action, or the same call ten minutes later.
///   • It is SINGLE USE: `MacInjectionCapabilityLedger` consumes the id on
///     first successful authorization, so a captured capability cannot be
///     replayed even inside its TTL.
///   • `mint` has exactly ONE non-test call site in the repo — the
///     post-approval branch of `AutonomyGatedDispatcher`. That is pinned by a
///     source-conformance test (`macInjectionCapability_hasExactlyOneMintSite`)
///     which fails the build's test suite if a second site appears.
///
/// The honest limit: Swift has no cross-module access level that lets
/// ChatOrchestration call a function MacControlBridge cannot. `mint` is public.
/// What the design buys is that minting is (a) a deliberate, greppable,
/// test-pinned act rather than a dictionary key anyone can copy, and (b)
/// useless unless you already hold the exact approved body — so the interesting
/// attack (model or remote caller escalating its OWN request) is closed
/// structurally.
public struct MacInjectionCapability: Sendable, Equatable {
    /// Approval record id (or an equivalent resolved-decision id) this
    /// capability was minted from. Recorded in refusals for audit.
    public let approvalID: String
    /// The single MacControl action this authorizes — "keystroke", "click",
    /// "scroll", or "ax_act".
    public let action: String
    /// SHA-256 over the canonicalized body this authorizes.
    public let bodyDigest: String
    /// Monotonic-ish issue stamp; the authorizing dispatcher supplies `now`.
    public let issuedAt: Date
    /// Seconds after `issuedAt` the capability stops authorizing anything.
    public let ttlSeconds: Double
    /// Unique per mint; the ledger consumes this to enforce single use.
    public let nonce: String

    private init(
        approvalID: String,
        action: String,
        bodyDigest: String,
        issuedAt: Date,
        ttlSeconds: Double,
        nonce: String
    ) {
        self.approvalID = approvalID
        self.action = action
        self.bodyDigest = bodyDigest
        self.issuedAt = issuedAt
        self.ttlSeconds = ttlSeconds
        self.nonce = nonce
    }

    /// Default lifetime of an injection authorization. Long enough to cross a
    /// dispatcher hop, far too short to bank.
    public static let defaultTTLSeconds: Double = 120

    /// THE ONLY CONSTRUCTOR. Call sites are pinned to one by
    /// `macInjectionCapability_hasExactlyOneMintSite`.
    ///
    /// - Parameter approvalID: the resolved approval record's id. Empty ⇒ nil;
    ///   an authorization with no approval behind it is exactly what this whole
    ///   mechanism exists to prevent.
    public static func mint(
        approvalID: String,
        action: String,
        body: [String: JSONValue],
        now: Date = Date(),
        ttlSeconds: Double = MacInjectionCapability.defaultTTLSeconds
    ) -> MacInjectionCapability? {
        let trimmedApproval = approvalID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedApproval.isEmpty else { return nil }
        let normalizedAction = Self.normalizedAction(action)
        guard macControlAccessibilityInjectionActions.contains(normalizedAction) else { return nil }
        guard let digest = Self.bodyDigest(action: normalizedAction, body: body) else { return nil }
        return MacInjectionCapability(
            approvalID: trimmedApproval,
            action: normalizedAction,
            bodyDigest: digest,
            issuedAt: now,
            ttlSeconds: ttlSeconds,
            nonce: UUID().uuidString
        )
    }

    /// Why an authorization failed. Surfaced verbatim in the refusal so a
    /// blocked injection is diagnosable without guessing.
    public enum AuthorizationFailure: String, Sendable, Equatable {
        case actionMismatch = "capability_action_mismatch"
        case bodyMismatch = "capability_body_mismatch"
        case expired = "capability_expired"
        case alreadyUsed = "capability_already_used"
        case digestUnavailable = "capability_digest_unavailable"
    }

    /// Pure predicate — no ledger side effect. `SwiftNativeMacControl` calls
    /// `MacInjectionCapabilityLedger.consume` after this passes.
    public func authorizationFailure(
        action rawAction: String,
        body: [String: JSONValue],
        now: Date
    ) -> AuthorizationFailure? {
        let normalized = Self.normalizedAction(rawAction)
        guard normalized == action else { return .actionMismatch }
        guard now.timeIntervalSince(issuedAt) <= ttlSeconds,
              now.timeIntervalSince(issuedAt) >= -5 else { return .expired }
        guard let digest = Self.bodyDigest(action: normalized, body: body) else {
            return .digestUnavailable
        }
        guard digest == bodyDigest else { return .bodyMismatch }
        return nil
    }

    static func normalizedAction(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Canonical digest over (action, body). Transport/plumbing keys the tool
    /// chain injects below the approval point are excluded so the digest a
    /// dispatcher computes over the model's arguments still matches the body
    /// MacControl receives:
    ///   • any `__`-prefixed key (`__session_id` and friends),
    ///   • `operationId` / `operation_id` (minted inside dispatch),
    ///   • `trigger` (a surface label, not an argument).
    public static func bodyDigest(action: String, body: [String: JSONValue]) -> String? {
        var canonicalBody: [String: JSONValue] = [:]
        for (key, value) in body {
            if key.hasPrefix("__") { continue }
            if key == "operationId" || key == "operation_id" || key == "trigger" { continue }
            canonicalBody[key] = value
        }
        let envelope = JSONValue.object([
            "action": .string(normalizedAction(action)),
            "body": .object(canonicalBody),
        ])
        guard let data = try? envelope.serializedData(pretty: false) else { return nil }
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }
}

/// Single-use enforcement for minted capabilities. Process-global by design:
/// the point is that ONE approval buys ONE injection no matter which dispatcher
/// instance, task, or actor presents the capability.
public actor MacInjectionCapabilityLedger {
    public static let shared = MacInjectionCapabilityLedger()

    private var consumed: Set<String> = []
    private var consumedAt: [String: Date] = [:]

    /// Consume `nonce`. Returns false if it was already spent.
    public func consume(nonce: String, now: Date = Date()) -> Bool {
        prune(now: now)
        guard !consumed.contains(nonce) else { return false }
        consumed.insert(nonce)
        consumedAt[nonce] = now
        return true
    }

    /// Test seam: forget everything (hermetic tests must not inherit nonces).
    public func reset() {
        consumed.removeAll()
        consumedAt.removeAll()
    }

    /// Entries older than an hour cannot authorize anything anyway (the TTL is
    /// two minutes), so retaining them only grows memory.
    private func prune(now: Date) {
        guard consumedAt.count > 256 else { return }
        for (nonce, stamp) in consumedAt where now.timeIntervalSince(stamp) > 3600 {
            consumed.remove(nonce)
            consumedAt.removeValue(forKey: nonce)
        }
    }
}

/// Carries a minted capability from the approval point down to
/// `impl_mac_injection_tool`, which cannot receive it as a parameter:
/// `ToolDispatchClient.dispatch(tool:input:surface:)` is a fixed protocol
/// signature shared by every tool.
///
/// A TaskLocal is the right shape here — it is scoped to the exact
/// `inner.dispatch` call the approval authorized and unwinds automatically, so
/// a later tool call in the same turn does not inherit it. It is NOT the
/// security boundary on its own: the capability's action+body binding and
/// single-use ledger are what make an inherited or captured value useless.
public enum MacInjectionCapabilityContext {
    @TaskLocal public static var current: MacInjectionCapability?
}

// MARK: - Typed-secret redaction (W2/W3-FIX 4)

/// `mac_keystroke.text` is the literal characters Agent is about to type. That
/// can be a password, a 2FA code, or a private message. The MacControl RESULT
/// already reduces it to a count — but the approval record and the turn-trace
/// bus were storing the raw string, and the approval record is
/// `remoteResolvable`, so it syncs to the phone and to Telegram.
///
/// This redacts at every persistence/emission boundary: the raw characters are
/// replaced by `{text_character_count, text_sha256}`. The approval card renders
/// "type 7 characters"; the digest lets a reviewer confirm after the fact that
/// what ran is what was approved, without the record ever holding the secret.
public enum MacInjectionArgRedaction {
    /// Argument keys that carry literal user-visible secrets, per tool/action.
    /// `keys` is the only place to add one — every sink calls through here.
    static let secretKeysByTool: [String: [String]] = [
        "mac_keystroke": ["text"],
        "mac.keystroke": ["text"],
        "keystroke": ["text"],
        "mac_ax_act": ["value"],
        "mac.ax_act": ["value"],
        "ax_act": ["value"],
    ]

    public static func carriesSecretArgs(tool: String) -> Bool {
        secretKeysByTool[normalized(tool)] != nil
    }

    /// Replace every secret-bearing string argument with count + digest.
    /// Non-secret arguments and non-injection tools pass through untouched.
    public static func redacted(tool: String, input: [String: JSONValue]) -> [String: JSONValue] {
        guard let keys = secretKeysByTool[normalized(tool)] else { return input }
        var out = input
        for key in keys {
            guard case .string(let secret)? = input[key] else { continue }
            out.removeValue(forKey: key)
            out["\(key)_character_count"] = .int(Int64(secret.count))
            if let digest = sha256(secret) {
                out["\(key)_sha256"] = .string(digest)
            }
            out["\(key)_redacted"] = .bool(true)
        }
        return out
    }

    /// The secrets stripped by `redacted`, keyed by argument name. The caller
    /// holds these in memory only — never on disk, never over a wire.
    public static func extractSecrets(tool: String, input: [String: JSONValue]) -> [String: String] {
        guard let keys = secretKeysByTool[normalized(tool)] else { return [:] }
        var out: [String: String] = [:]
        for key in keys {
            if case .string(let secret)? = input[key] { out[key] = secret }
        }
        return out
    }

    /// Put previously-extracted secrets back, dropping the redaction markers.
    /// Used only on the approved-replay path, and only after the digest check.
    public static func rehydrated(
        tool: String,
        input: [String: JSONValue],
        secrets: [String: String]
    ) -> [String: JSONValue] {
        guard let keys = secretKeysByTool[normalized(tool)] else { return input }
        var out = input
        for key in keys {
            guard let secret = secrets[key] else { continue }
            out[key] = .string(secret)
            out.removeValue(forKey: "\(key)_character_count")
            out.removeValue(forKey: "\(key)_sha256")
            out.removeValue(forKey: "\(key)_redacted")
        }
        return out
    }

    /// `redacted` for an already-boxed payload. Idempotent, so a sink can call
    /// it without knowing whether an upstream sink already did — which is the
    /// point: every persistence boundary redacts for itself rather than
    /// trusting its caller to have done it.
    public static func redactedPayload(tool: String, payload: JSONValue) -> JSONValue {
        guard case .object(let obj) = payload else { return payload }
        return .object(redacted(tool: tool, input: obj))
    }

    /// True when `input` is the redacted FORM of a secret-bearing call — i.e.
    /// the characters were removed and have to be rehydrated before it can run.
    public static func isRedacted(tool: String, input: [String: JSONValue]) -> Bool {
        guard let keys = secretKeysByTool[normalized(tool)] else { return false }
        for key in keys {
            if case .bool(true)? = input["\(key)_redacted"] { return true }
        }
        return false
    }

    public static func sha256(_ value: String) -> String? {
        #if canImport(CryptoKit)
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }

    static func normalized(_ tool: String) -> String {
        tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - Typed-secret redaction, RESULT side (W2/W3-FIX-R2 3)

/// The argument redactor above keeps the typed characters out of everything
/// that stores a REQUEST. This keeps them out of everything that stores a
/// RESULT.
///
/// `ax_act` re-reads the element it just wrote and returns both the element and
/// a `post_state`, so a value the caller set — a password, a 2FA code — came
/// straight back out through the tool result and from there into the turn-trace
/// preview, the operation store, and the approval record's `resultPreview`
/// (which is `remoteResolvable` and syncs to iOS/Telegram). The MacControl
/// handler now redacts at the source; this type is the same redaction applied
/// independently at each downstream preview boundary, so a future result shape
/// that reintroduces the field does not silently reopen the leak.
public enum MacInjectionResultRedaction {
    /// Result keys that can echo an injected secret back. Deliberately the
    /// value-bearing names only: counts, digests, roles, and frames are safe.
    public static let secretResultKeys: Set<String> = ["value", "text"]

    /// The replacement for one secret string: never the characters, always
    /// enough to audit them.
    public static func redactedSecret(_ secret: String) -> JSONValue {
        var object: [String: JSONValue] = [
            "redacted": .bool(true),
            "character_count": .int(Int64(secret.count)),
        ]
        if let digest = MacInjectionArgRedaction.sha256(secret) {
            object["sha256"] = .string(digest)
        }
        return .object(object)
    }

    /// Redact every secret-bearing string in an injection tool's RESULT.
    /// Non-injection tools pass through untouched, and the walk is idempotent
    /// (an already-redacted value is an object, not a string).
    public static func redacted(tool: String, result: JSONValue) -> JSONValue {
        guard MacInjectionToolNames.isInjectionTool(tool)
            || MacInjectionArgRedaction.carriesSecretArgs(tool: tool) else { return result }
        return walk(result)
    }

    private static func walk(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            var out: [String: JSONValue] = [:]
            for (key, item) in object {
                if secretResultKeys.contains(key.lowercased()), case .string(let secret) = item {
                    out[key] = redactedSecret(secret)
                } else {
                    out[key] = walk(item)
                }
            }
            return .object(out)
        case .array(let items):
            return .array(items.map(walk))
        default:
            return value
        }
    }
}

// MARK: - Approval-record binding digest (W2/W3-FIX-R2 1)

/// The digest an APPROVAL RECORD is bound to.
///
/// `MacInjectionCapability.bodyDigest` binds the capability to the body that
/// actually runs (secrets rehydrated). This binds the human's decision to the
/// body they were SHOWN — the redacted form, which is what the record persists.
/// Both are needed: the first stops a capability authorizing a different call,
/// the second stops a replay claiming an approval that was granted for
/// something else.
public enum MacInjectionApprovalDigest {
    /// Digest over the redacted (persisted) form of `input`, canonicalized the
    /// same way the capability digest is, so transport keys the tool chain
    /// injects below the approval point do not change it. Returns nil only when
    /// the input cannot be serialized.
    public static func digest(tool: String, input: [String: JSONValue]) -> String? {
        let action = MacInjectionToolNames.action(forTool: tool)
            ?? MacInjectionArgRedaction.normalized(tool)
        let redacted = MacInjectionArgRedaction.redacted(tool: tool, input: input)
        return MacInjectionCapability.bodyDigest(action: action, body: redacted)
    }
}

/// In-memory holding pen for the literal characters of a PENDING injection
/// approval.
///
/// The non-blocking approval path files a record (redacted), the human decides
/// later — possibly from their phone — and a separate executor replays the
/// stored input. Something has to remember the actual characters across that
/// gap. It is deliberately NOT the approval record and NOT a file:
///
///   • the record is `remoteResolvable` and syncs to iOS/Telegram;
///   • a plaintext password on disk is a worse failure than a lost replay.
///
/// So the secret lives in process memory with a TTL. If the app restarts before
/// the human decides, the replay refuses with `injection_secret_unavailable`
/// and Agent has to ask again. That is the correct trade: a re-ask costs a
/// sentence, a leaked password costs an account.
public actor MacInjectionSecretVault {
    public static let shared = MacInjectionSecretVault()

    private struct Entry {
        let secrets: [String: String]
        let storedAt: Date
    }

    private var entries: [String: Entry] = [:]
    /// Approvals resolve on human time; an hour is generous and bounded.
    public static let ttlSeconds: Double = 3600

    public func store(approvalID: String, secrets: [String: String], now: Date = Date()) {
        prune(now: now)
        guard !secrets.isEmpty else { return }
        entries[approvalID] = Entry(secrets: secrets, storedAt: now)
    }

    /// Take and REMOVE the secrets for `approvalID`. Single use, like the
    /// capability it feeds.
    public func take(approvalID: String, now: Date = Date()) -> [String: String]? {
        prune(now: now)
        guard let entry = entries.removeValue(forKey: approvalID) else { return nil }
        guard now.timeIntervalSince(entry.storedAt) <= Self.ttlSeconds else { return nil }
        return entry.secrets
    }

    public func reset() { entries.removeAll() }

    private func prune(now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value.storedAt) <= Self.ttlSeconds }
    }
}
