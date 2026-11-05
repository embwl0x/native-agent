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
// Blueprint: | `MacWindowActivation.swift` | `SystemMacAXActSource`: Driver-checked raise and measured activation; app-only routes avoid self-AX |

#if canImport(ApplicationServices) && os(macOS)
extension SystemMacAXActSource {
    /// Only individual AX calls use the main lane; activation waits stay on the caller's thread.
    public func raise(_ window: MacAXWindowRef, context: MacOperationContext) -> MacAXActOutcome {
        #if canImport(AppKit)
        // Clear diagnostics before every early return so a refusal cannot inherit another call's cause.
        setRaiseDiagnostic(nil)
        // Apply the same self-process fence as path resolution.
        guard window.identity.pid != getpid() else { return .invalidTarget }
        guard let app = NSRunningApplication(processIdentifier: window.identity.pid) else {
            return .invalidTarget
        }
        // AXRaise orders the window inside its app; app activation is measured separately.
        let raiseStatus: AXError? = MacAXExecutionLane.sync {
            guard let element = element(window.handle) else { return nil }
            guard context.driver?.allowsEmission(context: context) == true else { return nil }
            do { try SystemMacAXElementSource.ensureRenderer(element, refresh: true, context: context) }
            catch { setRaiseDiagnostic(error.localizedDescription); return nil }
            guard context.driver?.allowsEmission(context: context) == true else { return nil }
            NativeAgentMotorEpoch.noteAgentMotorEvent()
            return AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        guard let raiseStatus else { return .invalidTarget }

        guard let front = activateAndMeasure(app: app, window: window, context: context) else { return .failed }
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

    /// App-only activation can restore this app without self-AX; suspend waits off the main lane while inheriting driver authority.
    public func activate(pid: Int32, context: MacOperationContext) async -> MacAXActOutcome {
        #if canImport(AppKit)
        setRaiseDiagnostic(nil)
        guard let app = NSRunningApplication(processIdentifier: pid) else { return .invalidTarget }
        guard context.driver?.allowsEmission(context: context) == true else { return .failed }
        return activateAndMeasure(app: app, window: nil, context: context) == true ? .performed : .failed
        #else
        return .unsupported
        #endif
    }

    /// Clear per-attempt diagnostics so later refusals cannot inherit another operation’s cause.
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
    /// Distinguish driver refusal from attempted but unconfirmed activation.
    private func activateAndMeasure(app: NSRunningApplication, window: MacAXWindowRef?, context: MacOperationContext) -> Bool? {
        // Confirm activation through the window server after each request; API success alone proves no foreground change.
        if isFrontAndFocused(app: app, window: window, context: context) { return true }
        _ = MacAXExecutionLane.sync {
            guard context.driver?.allowsEmission(context: context) == true else { return false }
            // Record app-only activation once after the driver check; raises already recorded their AX emission.
            if window == nil { NativeAgentMotorEpoch.noteAgentMotorEvent() }
            return app.activate()
        }
        if awaitFrontAndFocused(app: app, window: window, context: context) { return true }
        return false
    }

    /// Confirm front app and any supplied window against fresh AXFocusedWindow using CFEqual, never reference-handle equality. App-only activation avoids AX
    /// entirely, including self-process restoration.
    private func isFrontAndFocused(app: NSRunningApplication, window: MacAXWindowRef?, context: MacOperationContext) -> Bool {
        MacAXExecutionLane.sync {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
            else { return false }
            guard let window else { return true }
            guard let element = element(window.handle) else { return false }
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            guard let focused = MacAXAttributeRead.copyElement(appElement, kAXFocusedWindowAttribute, context: context) else { return false }
            return CFEqual(focused, element)
        }
    }

    /// Bound activation confirmation to 300ms per mechanism off the AX lane; only individual reads use that lane.
    private func awaitFrontAndFocused(app: NSRunningApplication, window: MacAXWindowRef?, context: MacOperationContext) -> Bool {
        for _ in 0..<12 {
            if isFrontAndFocused(app: app, window: window, context: context) { return true }
            Thread.sleep(forTimeInterval: 0.025)
        }
        return isFrontAndFocused(app: app, window: window, context: context)
    }

    #endif
}
#endif
