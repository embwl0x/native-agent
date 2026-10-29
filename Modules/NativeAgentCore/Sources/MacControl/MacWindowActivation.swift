import Foundation
import NativeAgentCore
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Carbon) && os(macOS)
import Carbon
import PersistenceCore
import TrustCenter
import CryptoKit
import CoreGraphics
import NativeAgentShared
import UserNotifications
import Experiences
import Senses
#endif
// Blueprint: | `MacWindowActivation.swift` | `SystemMacAXActSource`: driver-checked window raising and measured app activation with Automation diagnostics; app-only activation preserves the self-AX fence |

#if canImport(ApplicationServices) && os(macOS)
extension SystemMacAXActSource {
    /// Only individual AX calls use the main lane; activation waits and Apple Events stay on the caller's thread.
    public func raise(_ window: MacAXWindowRef) -> MacAXActOutcome {
        #if canImport(AppKit)
        // Clear diagnostics before every early return so a refusal cannot inherit another call's cause.
        setRaiseDiagnostic(nil)
        // Same self-process fence as `resolveOnExecutionLane(path:pid:)`.
        guard window.identity.pid != getpid() else { return .invalidTarget }
        guard let app = NSRunningApplication(processIdentifier: window.identity.pid) else {
            return .invalidTarget
        }
        // AXRaise orders the window inside its app; app activation is measured separately.
        let raiseStatus: AXError? = MacAXExecutionLane.sync {
            guard let element = element(window.handle) else { return nil }
            guard MacDriverContext.binding?.allowsEmission == true else { return nil }
            NativeAgentMotorEpoch.noteAgentMotorEvent()
            return AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        guard let raiseStatus else { return .invalidTarget }

        guard let front = activateAndMeasure(app: app, window: window) else { return .failed }
        if front { return .performed }

        // Report unsupported AX raising separately from unconfirmed activation; neither permits a success claim.
        switch raiseStatus {
        case .actionUnsupported, .attributeUnsupported:
            return .unsupported
        default:
            return .failed
        }
        #else
        return .unsupported
        #endif
    }

    /// App ordering alone, using the same measured activation as `raise`.
    /// No AX window read: this can also restore our own app without crossing
    /// the self-process AX fence. The async entry keeps waits and Apple Events
    /// off the main/AX lane while inheriting the caller's driver binding.
    public func activate(pid: Int32) async -> MacAXActOutcome {
        #if canImport(AppKit)
        setRaiseDiagnostic(nil)
        guard let app = NSRunningApplication(processIdentifier: pid) else { return .invalidTarget }
        guard MacDriverContext.binding?.allowsEmission == true else { return .failed }
        return activateAndMeasure(app: app, window: nil) == true ? .performed : .failed
        #else
        return .unsupported
        #endif
    }

    /// The latest raise or activation's Automation diagnostic, cleared before every attempt.
    public var raiseDiagnostic: String? {
        lock.lock()
        defer { lock.unlock() }
        return lastRaiseDiagnostic
    }

    private func setRaiseDiagnostic(_ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        lastRaiseDiagnostic = value
    }

    #if canImport(AppKit)
    /// The app-ordering half of a raise. nil means the driver refused further
    /// emission; false means activation was attempted but not confirmed.
    private func activateAndMeasure(app: NSRunningApplication, window: MacAXWindowRef?) -> Bool? {
        // Confirm activation through the window server after each request; API success alone proves no foreground change.
        if isFrontAndFocused(app: app, window: window) { return true }
        _ = MacAXExecutionLane.sync {
            guard MacDriverContext.binding?.allowsEmission == true else { return false }
            // A window raise already recorded its AXRaise. App-only activation
            // records its first emission here, once, after the driver check.
            if window == nil { NativeAgentMotorEpoch.noteAgentMotorEvent() }
            return app.activate()
        }
        if awaitFrontAndFocused(app: app, window: window) { return true }
        guard MacDriverContext.binding?.allowsEmission == true else { return nil }
        activateViaAppleEvent(app)
        return awaitFrontAndFocused(app: app, window: window)
    }

    /// The app is frontmost; when a window is supplied, it is also focused.
    /// App-only activation never reads AX, including when the target is us.
    /// `CFEqual`, not handle equality: this is the identity comparison, and it
    /// is measured against a freshly copied `AXFocusedWindow` every call.
    private func isFrontAndFocused(app: NSRunningApplication, window: MacAXWindowRef?) -> Bool {
        MacAXExecutionLane.sync {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
            else { return false }
            guard let window else { return true }
            guard let element = element(window.handle) else { return false }
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            guard let focused = MacAXAttributeRead.copyElement(appElement, kAXFocusedWindowAttribute) else { return false }
            return CFEqual(focused, element)
        }
    }

    /// Bound activation confirmation to 300ms per mechanism off the AX lane; only individual reads use that lane.
    private func awaitFrontAndFocused(app: NSRunningApplication, window: MacAXWindowRef?) -> Bool {
        for _ in 0..<12 {
            if isFrontAndFocused(app: app, window: window) { return true }
            Thread.sleep(forTimeInterval: 0.025)
        }
        return isFrontAndFocused(app: app, window: window)
    }

    /// Send activation off the AX lane: a synchronous Apple Event may wait for Automation consent.
    /// Record consent denial and other errors for diagnosis; front/focus readback decides the outcome.
    private func activateViaAppleEvent(_ app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return }

        // Refuse an existing Automation denial; an unasked permission must reach the Apple Event so macOS can request consent.
        let permission = bundleID.withCString { cString -> OSStatus in
            var target = AEAddressDesc()
            let built = AECreateDesc(
                AEKeyword(typeApplicationBundleID),
                cString,
                strlen(cString),
                &target
            )
            guard built == noErr else { return OSStatus(built) }
            defer { AEDisposeDesc(&target) }
            return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
        }
        if permission == OSStatus(errAEEventNotPermitted) {
            setRaiseDiagnostic(automationDeniedNote(app, bundleID: bundleID))
            return
        }
        let event = NSAppleEventDescriptor.appleEvent(withEventClass: kAEMiscStandards, eventID: kAEActivate,
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: app.processIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        guard MacDriverContext.binding?.allowsEmission == true else { return }
        let code: Int
        do {
            let reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: 5)
            code = Int(reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value ?? 0)
        } catch { code = (error as NSError).code }
        if code == Int(errAEEventNotPermitted) {
            setRaiseDiagnostic(automationDeniedNote(app, bundleID: bundleID))
        } else if code != 0 {
            setRaiseDiagnostic("activating \(bundleID) by Apple Event failed with error \(code)")
        }
    }

    private func automationDeniedNote(_ app: NSRunningApplication, bundleID: String) -> String {
        "automation_not_trusted: macOS denied NativeAgent's activation request to \(app.localizedName ?? bundleID) (\(bundleID)). "
        + "Ask the owner to enable System Settings > Privacy & Security > Automation > NativeAgent > \(app.localizedName ?? bundleID)."
    }
    #endif
}
#endif
