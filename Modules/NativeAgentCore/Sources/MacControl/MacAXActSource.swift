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
import Carbon
import NativeAgentShared
#endif
// Blueprint: | `MacAXActSource.swift` | AX targets retain stage, cause and remedy; window identity and URL evidence stay exact |

/// Opaque handles remain source-owned; callers must not interpret them.
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

    public var centre: CGPoint? {
        guard let frame, frame.w > 0, frame.h > 0 else { return nil }
        return CGPoint(x: frame.x + frame.w / 2.0, y: frame.y + frame.h / 2.0)
    }

    /// - Parameter redactingValue: replace written values with count and digest before receipts, traces, operation storage or approval sync.
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

public struct MacAXActOutcome: Sendable, Equatable {
    public enum Status: String, Sendable {
        case performed, unsupported, failed, invalidTarget
        /// The request was accepted; its effect has not been observed yet.
        case unverified
    }
    public let status: Status
    public let emissionAttempted: Bool
    public let cause: String?
    public let nativeCode: Int?
    public let remedy: JSONValue?
    public var rawValue: String { status.rawValue }

    public init(status: Status, emissionAttempted: Bool, cause: String? = nil,
                nativeCode: Int? = nil, remedy: JSONValue? = nil) {
        self.status = status
        self.emissionAttempted = emissionAttempted
        self.cause = cause
        self.nativeCode = nativeCode
        self.remedy = remedy
    }
    public static let performed = Self(status: .performed, emissionAttempted: true)
    public static let unsupported = Self(status: .unsupported, emissionAttempted: false,
        cause: "The target does not support the requested AX operation.")
    public static let invalidTarget = Self(status: .invalidTarget, emissionAttempted: false,
        cause: "The captured AX target no longer resolves.")
    /// Sources without detailed evidence cannot claim a failure preceded emission.
    public static let failed = Self(status: .failed, emissionAttempted: true,
        cause: "The AX result is unavailable; inspect the affected app before another action.")

    public var receipt: [String: JSONValue] {
        ["ax_outcome": .string(rawValue), "ax_emission_attempted": .bool(emissionAttempted),
         "ax_cause": cause.map(JSONValue.string) ?? .null,
         "ax_native_code": nativeCode.map { .int(Int64($0)) } ?? .null,
         "remedy": remedy ?? .null]
    }
}

public enum MacAXPidResolution: Sendable, Equatable {
    case resolved(MacAXActTarget)
    /// Missing process or published window invalidates the captured frame.
    case appGone
    case pathNotFound
    case menuPathDrifted
    case windowGone
    case unavailable(String)
}

/// Window identity must survive the source's element handles.
public struct MacAXWindowRef: Sendable, Equatable {
    public let handle: Int
    public let identity: MacAXWindowIdentity

    public init(handle: Int, identity: MacAXWindowIdentity) {
        self.handle = handle
        self.identity = identity
    }
}

/// The live editor's insertion range uses UTF-16 offsets, as AX does.
public struct MacAXTextInput: Sendable, Equatable {
    public let target: MacAXActTarget
    public let value: String
    public let selection: NSRange

    public func inserting(_ text: String) -> String {
        (value as NSString).replacingCharacters(in: selection, with: text)
    }
}

/// Separate action and read protocols so the read seam cannot mutate UI.
public protocol MacAXActSource: Sendable {
    func isTrusted() -> Bool
    /// Resolve in the captured process so a focus change cannot select another app.
    func resolve(path: [Int], inAppPid pid: Int32, context: MacOperationContext) -> MacAXPidResolution
    /// Composite identities survive source handles; PID alone cannot identify one of several windows after focus changes. Single-tree sources expose their sole
    /// window.
    func windows(pid: Int32, context: MacOperationContext) throws -> [MacAXWindowRef]
    /// Exact presence in the owning process's window inventory. Nil is an unreadable inventory, never evidence that a window was removed.
    func windowPresence(_ window: MacAXWindowRef, context: MacOperationContext) -> Bool?
    /// Resolve from the captured window; current focus may belong to another window.
    func resolve(path: [Int], inWindow window: MacAXWindowRef, context: MacOperationContext) -> MacAXPidResolution
    /// A stale child path cannot prove uniqueness after relayout. Incomplete reads throw their cause; nil establishes no unique target.
    func uniqueTarget(role: String, label: String, labelSource: String, inWindow window: MacAXWindowRef, context: MacOperationContext) throws -> MacAXActTarget?
    /// Resolve directly from AXMenuBar; window-relative paths cannot address menu items. Unavailable sources report `.appGone`.
    func resolve(menuPath: [Int], inAppPid pid: Int32, titlePath: [String]?, context: MacOperationContext) -> MacAXPidResolution
    func perform(_ target: MacAXActTarget, action: String, turn: Turn, context: MacOperationContext) -> MacAXActOutcome
    func setValue(_ target: MacAXActTarget, value: String, turn: Turn, context: MacOperationContext) -> MacAXActOutcome
    /// Insert AXSelectedText at the element's insertion point, including a background editor; unavailable sources report `.unsupported`.
    func setSelectedText(_ target: MacAXActTarget, text: String, turn: Turn, context: MacOperationContext) -> MacAXActOutcome
    /// AX selection offsets use UTF-16, not Swift character indices.
    func setSelectedTextRange(_ target: MacAXActTarget, range: NSRange, turn: Turn, context: MacOperationContext) -> MacAXActOutcome
    /// Keystrokes require the target or its descendant to own AX focus; unknown focus grants no admission.
    func isFocusedElement(_ target: MacAXActTarget, pid: Int32, context: MacOperationContext) -> Bool
    func focusedElement(pid: Int32, context: MacOperationContext) -> MacAXActTarget?
    /// Positive editability evidence, independent of readable value/selection.
    func acceptsTextInput(_ target: MacAXActTarget, context: MacOperationContext) -> Bool
    func matchesTextInputTarget(_ focused: MacAXActTarget, target: MacAXActTarget, context: MacOperationContext) -> Bool
    /// Hit-test inside the named app before clicking so a point cannot target another process.
    func elementAtPosition(x: Double, y: Double, pid: Int32, context: MacOperationContext) -> MacAXActTarget?
    func textInput(_ target: MacAXActTarget, context: MacOperationContext) -> MacAXTextInput?
    /// The element's native AXURL, not its display label or a guessed path.
    func url(of target: MacAXActTarget, context: MacOperationContext) throws -> URL?
    /// Missing menu key equivalents remain nil.
    func menuShortcut(_ target: MacAXActTarget, context: MacOperationContext) -> (glyphs: String, chord: String)?
    /// Keystroke typing focuses through AXFocused, never an activating AXPress.
    func setFocused(_ target: MacAXActTarget, turn: Turn, context: MacOperationContext) -> MacAXActOutcome
    /// The app's focused window, or nil when unknown; unknown is never evidence that synthesized input will reach the named window.
    func focusedWindow(pid: Int32, context: MacOperationContext) -> MacAXWindowRef?
    /// Raise the exact window and activate its app; either operation alone can leave a different window key.
    func raise(_ window: MacAXWindowRef, context: MacOperationContext) -> MacAXActOutcome
    /// Read the last raise diagnostic after a nonperformed raise, including an unverified activation.
    var raiseDiagnostic: String? { get }
    func reread(_ target: MacAXActTarget, context: MacOperationContext) -> MacAXActTarget?
}

public extension MacAXActSource {
    func url(of target: MacAXActTarget, context: MacOperationContext) throws -> URL? { nil }
    func windowPresence(_ window: MacAXWindowRef, context: MacOperationContext) -> Bool? { nil }
    func uniqueTarget(role: String, label: String, labelSource: String, inWindow window: MacAXWindowRef,
        context: MacOperationContext) throws -> MacAXActTarget? { nil }

    func setFocused(_ target: MacAXActTarget, turn: Turn, context: MacOperationContext) -> MacAXActOutcome { .unsupported }
    func setSelectedText(_ target: MacAXActTarget, text: String, turn: Turn, context: MacOperationContext) -> MacAXActOutcome { .unsupported }
    func setSelectedTextRange(_ target: MacAXActTarget, range: NSRange, turn: Turn, context: MacOperationContext) -> MacAXActOutcome { .unsupported }
    func isFocusedElement(_ target: MacAXActTarget, pid: Int32, context: MacOperationContext) -> Bool { false }
    func focusedElement(pid: Int32, context: MacOperationContext) -> MacAXActTarget? { nil }
    func acceptsTextInput(_ target: MacAXActTarget, context: MacOperationContext) -> Bool {
        target.enabled && !MacActClosedLoop.isSecureField(role: target.role)
            && MacActClosedLoop.canType(role: target.role)
    }
    func matchesTextInputTarget(_ focused: MacAXActTarget, target: MacAXActTarget, context: MacOperationContext) -> Bool { false }
    func elementAtPosition(x: Double, y: Double, pid: Int32, context: MacOperationContext) -> MacAXActTarget? { nil }
    func textInput(_ target: MacAXActTarget, context: MacOperationContext) -> MacAXTextInput? { nil }
    func menuShortcut(_ target: MacAXActTarget, context: MacOperationContext) -> (glyphs: String, chord: String)? { nil }

    /// A source with no menu-bar access reports `.appGone`, never a window-relative substitute.
    func resolve(menuPath: [Int], inAppPid pid: Int32, titlePath: [String]?, context: MacOperationContext) -> MacAXPidResolution { .appGone }

    /// A single-tree source has exactly one window; its root attributes supply the identity at index zero.
    func windows(pid: Int32, context: MacOperationContext) throws -> [MacAXWindowRef] {
        let root: MacAXActTarget
        switch resolve(path: [], inAppPid: pid, context: context) {
        case .resolved(let value): root = value
        case .unavailable(let detail): throw MacAccessibilityReader.NativeReadFailure(detail: detail)
        default: return []
        }
        return [MacAXWindowRef(
            handle: root.handle,
            identity: MacAXWindowIdentity(
                pid: pid,
                index: 0,
                role: root.role,
                subrole: nil,
                title: root.title,
                frame: root.frame
            )
        )]
    }

    func resolve(path: [Int], inWindow window: MacAXWindowRef, context: MacOperationContext) -> MacAXPidResolution {
        resolve(path: path, inAppPid: window.identity.pid, context: context)
    }

    /// Without a window server, key-window ownership is unknown.
    func focusedWindow(pid: Int32, context: MacOperationContext) -> MacAXWindowRef? { nil }

    /// Without a window server, raising is unsupported; never claim a fabricated success.
    func raise(_ window: MacAXWindowRef, context: MacOperationContext) -> MacAXActOutcome { .unsupported }

    var raiseDiagnostic: String? { nil }
}

public struct UnavailableMacAXActSource: MacAXActSource {
    public init() {}
    public func isTrusted() -> Bool { false }
    public func resolve(path: [Int], inAppPid pid: Int32, context: MacOperationContext) -> MacAXPidResolution { .pathNotFound }
    public func resolve(menuPath: [Int], inAppPid pid: Int32, titlePath: [String]?, context: MacOperationContext) -> MacAXPidResolution { .pathNotFound }
    public func perform(_ target: MacAXActTarget, action: String, turn: Turn, context: MacOperationContext) -> MacAXActOutcome { .invalidTarget }
    public func setValue(_ target: MacAXActTarget, value: String, turn: Turn, context: MacOperationContext) -> MacAXActOutcome { .invalidTarget }
    public func reread(_ target: MacAXActTarget, context: MacOperationContext) -> MacAXActTarget? { nil }
}

public func defaultMacAXActSource() -> any MacAXActSource {
    #if canImport(ApplicationServices) && os(macOS)
    return SystemMacAXActSource()
    #else
    return UnavailableMacAXActSource()
    #endif
}
