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
// Blueprint: | `MacAXActSource.swift` | AX action targets, outcomes, source contract and unavailable-platform construction; window presence distinguishes unreadable inventory from absence |

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

public enum MacAXActOutcome: String, Sendable, Equatable {
    /// The AX call returned success. The APP ran its own handler.
    case performed
    /// The element does not advertise this action / attribute as settable.
    case unsupported
    /// AX availability or mutation failed; this is never proof of no effect.
    case failed
    /// The handle no longer resolves (window closed, element released).
    case invalidTarget
}

/// PID-anchored descent reports app, path and window absence or menu-path drift.
public enum MacAXPidResolution: Sendable, Equatable {
    case resolved(MacAXActTarget)
    /// No such process, or its AX application element publishes no window —
    /// the frame she acts from describes an app that is not there any more.
    case appGone
    /// The app is alive; that child-index chain is not.
    case pathNotFound
    case menuPathDrifted
    /// The app is alive, but the observed window is gone.
    case windowGone
}

/// One of an app's windows, as the ACT seam sees it: the source's own element
/// handle plus the identity that outlives it.
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

/// Semantic action on a live element. Separate protocol from
/// `MacAXElementSource` on purpose: the read seam has no member that can
/// mutate anything, and this one is the only place that can.
public protocol MacAXActSource: Sendable {
    func isTrusted() -> Bool
    /// Resolve a child-index chain from the frontmost window root. `[]` is the
    /// window itself. Returns nil when any index is out of range.
    ///
    /// Frontmost-anchored for `mac_ax_act`; semantic acts resolve in their
    /// observed app and window before passing the target to the actuator.
    func resolve(path: [Int]) -> MacAXActTarget?
    /// Resolve the SAME chain inside a NAMED process — the app the look frame
    /// was captured from and the app the effect observer is installed on.
    ///
    /// Required rather than defaulted: forwarding to `resolve(path:)` could
    /// target a different app if focus changed after the frame was captured.
    func resolve(path: [Int], inAppPid pid: Int32) -> MacAXPidResolution
    /// EVERY window of a named process, in `AXWindows` order, with the
    /// composite identity (`MacAXWindowIdentity`) that survives this source's
    /// element handles.
    ///
    /// PID anchoring alone cannot identify the captured window when an app has
    /// several windows and focus changes between observation and action.
    ///
    /// Default: the single window `resolve(path: [], inAppPid:)` answers with —
    /// truthful for a one-window source (which every synthetic source is), and
    /// what makes the identity match a no-op there rather than a fabrication.
    func windows(pid: Int32) -> [MacAXWindowRef]
    /// Exact presence in the owning process's window inventory. Nil is an
    /// unreadable inventory, never evidence that a window was removed.
    func windowPresence(_ window: MacAXWindowRef) -> Bool?
    /// Resolve a child-index chain from THAT window, not from whichever window
    /// of the app is focused now. `[]` is the window itself.
    func resolve(path: [Int], inWindow window: MacAXWindowRef) -> MacAXPidResolution
    /// Search the live window for one role/label identity. A stale child path
    /// cannot prove uniqueness after a relayout. Incomplete searches refuse.
    func uniqueTarget(role: String, label: String, labelSource: String, inWindow window: MacAXWindowRef) -> MacAXActTarget?
    /// Resolve directly from AXMenuBar; window-relative paths cannot address menu items. Unavailable sources report `.appGone`.
    func resolve(menuPath: [Int], inAppPid pid: Int32, titlePath: [String]?) -> MacAXPidResolution
    func perform(_ target: MacAXActTarget, action: String) -> MacAXActOutcome
    func setValue(_ target: MacAXActTarget, value: String) -> MacAXActOutcome
    /// Insert AXSelectedText at the element's insertion point, including a background editor; unavailable sources report `.unsupported`.
    func setSelectedText(_ target: MacAXActTarget, text: String) -> MacAXActOutcome
    /// Position this editor's selection using AX UTF-16 offsets, without changing its value.
    func setSelectedTextRange(_ target: MacAXActTarget, range: NSRange) -> MacAXActOutcome
    /// Is THIS element, or something inside it, the app's `AXFocusedUIElement`
    /// right now? The gate in front of every keystroke into a named field.
    /// Default false.
    func isFocusedElement(_ target: MacAXActTarget, pid: Int32) -> Bool
    func focusedElement(pid: Int32) -> MacAXActTarget?
    /// Match the focused editor to the target itself, its ancestor, or its descendant.
    func matchesTextInputTarget(_ focused: MacAXActTarget, target: MacAXActTarget) -> Bool
    /// Resolve the element under a screen point inside the named app before clicking.
    func elementAtPosition(x: Double, y: Double, pid: Int32) -> MacAXActTarget?
    /// A value and valid insertion range on the actual focused editor.
    func textInput(_ target: MacAXActTarget) -> MacAXTextInput?
    /// A menu item's key equivalent, as (glyphs "⇧⌘S", chord "cmd+shift+s"),
    /// or nil when it publishes none. Default nil.
    func menuShortcut(_ target: MacAXActTarget) -> (glyphs: String, chord: String)?
    /// Keystroke typing focuses through AXFocused, never an activating AXPress.
    func setFocused(_ target: MacAXActTarget) -> MacAXActOutcome
    /// Select via AXSelected without invoking the element; sources that cannot select report `.unsupported`.
    func setSelected(_ target: MacAXActTarget) -> MacAXActOutcome
    /// The app's focused window, or nil when unknown; unknown is never evidence that synthesized input will reach the named window.
    func focusedWindow(pid: Int32) -> MacAXWindowRef?
    /// Raise the exact window and activate its app; either operation alone can leave a different window key.
    func raise(_ window: MacAXWindowRef) -> MacAXActOutcome
    /// Why the last `raise` did not take, when there is more to say than "it
    /// did not" — read only after a raise that failed, and folded into the
    /// refusal so she is told the thing a person can actually act on. The one
    /// case today is a missing Automation (Apple Events) grant, which is
    /// invisible in every other signal this path produces.
    var raiseDiagnostic: String? { get }
    /// Re-read the element's attributes so the caller can see the POST-state.
    func reread(_ target: MacAXActTarget) -> MacAXActTarget?
}

public extension MacAXActSource {
    func windowPresence(_ window: MacAXWindowRef) -> Bool? { nil }
    func uniqueTarget(role: String, label: String, labelSource: String, inWindow window: MacAXWindowRef) -> MacAXActTarget? { nil }

    func setFocused(_ target: MacAXActTarget) -> MacAXActOutcome { .unsupported }
    func setSelectedText(_ target: MacAXActTarget, text: String) -> MacAXActOutcome { .unsupported }
    func setSelectedTextRange(_ target: MacAXActTarget, range: NSRange) -> MacAXActOutcome { .unsupported }
    func isFocusedElement(_ target: MacAXActTarget, pid: Int32) -> Bool { false }
    func focusedElement(pid: Int32) -> MacAXActTarget? { nil }
    func matchesTextInputTarget(_ focused: MacAXActTarget, target: MacAXActTarget) -> Bool { false }
    func elementAtPosition(x: Double, y: Double, pid: Int32) -> MacAXActTarget? { nil }
    func textInput(_ target: MacAXActTarget) -> MacAXTextInput? { nil }
    func menuShortcut(_ target: MacAXActTarget) -> (glyphs: String, chord: String)? { nil }

    /// A source with no menu-bar access reports `.appGone`, never a window-relative substitute.
    func resolve(menuPath: [Int], inAppPid pid: Int32, titlePath: [String]?) -> MacAXPidResolution { .appGone }

    /// A source with ONE tree per app has exactly one window, and that window
    /// IS the one the frame was captured from — there is no second window for
    /// the resolve to land in by mistake. Reporting it at index 0 with the
    /// window element's own attributes is the truthful answer, not a stub;
    /// a multi-window source (the live one) implements this for real.
    func windows(pid: Int32) -> [MacAXWindowRef] {
        guard case .resolved(let root) = resolve(path: [], inAppPid: pid) else { return [] }
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

    func resolve(path: [Int], inWindow window: MacAXWindowRef) -> MacAXPidResolution {
        resolve(path: path, inAppPid: window.identity.pid)
    }
    func setSelected(_ target: MacAXActTarget) -> MacAXActOutcome { .unsupported }

    /// A synthetic source publishes one tree and no window server, so it has no
    /// notion of key. nil ⇒ "cannot tell"; the live source answers for real.
    func focusedWindow(pid: Int32) -> MacAXWindowRef? { nil }

    /// No window server ⇒ nothing to raise. `.unsupported`, never a fabricated
    /// success: a test that believes it raised a window it cannot raise is how
    /// a gate becomes vacuous.
    func raise(_ window: MacAXWindowRef) -> MacAXActOutcome { .unsupported }

    /// Nothing to add. A source that cannot raise has already said everything
    /// it knows with `.unsupported`.
    var raiseDiagnostic: String? { nil }
}

public struct UnavailableMacAXActSource: MacAXActSource {
    public init() {}
    public func isTrusted() -> Bool { false }
    public func resolve(path: [Int]) -> MacAXActTarget? { nil }
    public func resolve(path: [Int], inAppPid pid: Int32) -> MacAXPidResolution { .pathNotFound }
    public func resolve(menuPath: [Int], inAppPid pid: Int32, titlePath: [String]?) -> MacAXPidResolution { .pathNotFound }
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
