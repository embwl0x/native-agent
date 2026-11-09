import Foundation
import Dispatch
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
// Blueprint: | `MacWindowActivation.swift` | `SystemMacAXActSource`: Synchronous raise; event-woken activation off the AX lane; app-only avoids self-AX |

#if canImport(ApplicationServices) && os(macOS)
extension SystemMacAXActSource {
    /// Only individual AX calls use the AX thread; activation waits stay on the caller's thread.
    public func raise(_ window: MacAXWindowRef, context: MacOperationContext) -> MacAXActOutcome {
        #if canImport(AppKit)
        // Clear diagnostics before every early return so a refusal cannot inherit another call's cause.
        setRaiseDiagnostic(nil)
        // Apply the same self-process fence as path resolution.
        guard !PersonOnlyWindows.isOwnProcess(window.identity.pid) else { return .invalidTarget }
        guard let app = NSRunningApplication(processIdentifier: window.identity.pid) else {
            return .invalidTarget
        }
        if isFrontAndFocused(app: app, window: window, context: context) { return .performed }
        let signals = MacWindowActivationSignals(pid: app.processIdentifier, observesWindow: true)
        defer { signals.stop() }
        if let failure = signals.installationFailure {
            setRaiseDiagnostic(failure)
            return MacAXActOutcome(status: .failed, emissionAttempted: false, cause: failure)
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

        let activation = activateAndMeasure(app: app, window: window, signals: signals, context: context)
        if activation.status != .unverified { return activation }

        // Report unsupported AX raising separately from unconfirmed activation; neither permits a success claim.
        switch raiseStatus {
        case .success:
            return activation
        case .actionUnsupported, .attributeUnsupported:
            return .unsupported
        default:
            let cause = "AXRaise returned AX error \(raiseStatus.rawValue); the exact window is not verified in front."
            setRaiseDiagnostic(cause)
            return MacAXActOutcome(status: .failed, emissionAttempted: true, cause: cause, nativeCode: Int(raiseStatus.rawValue))
        }
        #else
        return .unsupported
        #endif
    }

    /// App-only activation can restore this app without self-AX; waits stay off the AX thread while inheriting driver authority.
    @concurrent public func activate(pid: Int32, context: MacOperationContext) async -> MacAXActOutcome {
        #if canImport(AppKit)
        setRaiseDiagnostic(nil)
        guard let app = NSRunningApplication(processIdentifier: pid) else { return .invalidTarget }
        guard context.driver?.allowsEmission(context: context) == true else { return .failed }
        let signals = MacWindowActivationSignals(pid: pid, observesWindow: false)
        defer { signals.stop() }
        if let failure = signals.installationFailure {
            setRaiseDiagnostic(failure)
            return MacAXActOutcome(status: .failed, emissionAttempted: false, cause: failure)
        }
        return activateAndMeasure(app: app, window: nil, signals: signals, context: context)
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
    private func activateAndMeasure(app: NSRunningApplication, window: MacAXWindowRef?, signals: MacWindowActivationSignals,
                                    context: MacOperationContext) -> MacAXActOutcome {
        // Confirm activation through the window server after each request; API success alone proves no foreground change.
        if isFrontAndFocused(app: app, window: window, context: context) { return .performed }
        let refusal: MacAXActOutcome? = MacAXExecutionLane.sync {
            guard context.driver?.allowsEmission(context: context) == true else {
                return MacAXActOutcome(status: .failed, emissionAttempted: window != nil,
                    cause: "Driver authority ended before the activation request was made.")
            }
            // Record app-only activation once after the driver check; raises already recorded their AX emission.
            if window == nil { NativeAgentMotorEpoch.noteAgentMotorEvent() }
            guard app.activate() else {
                return MacAXActOutcome(status: .failed, emissionAttempted: true, cause: "macOS did not accept the activation request.")
            }
            return nil
        }
        if let refusal {
            setRaiseDiagnostic(refusal.cause)
            return refusal
        }
        if awaitFrontAndFocused(app: app, window: window, signals: signals, context: context) { return .performed }
        setRaiseDiagnostic(window == nil
            ? "Activation was requested; the app is not verified in front yet. Inspect it before another action."
            : "The raise was requested; the exact window is not verified in front yet. Inspect the app before another action.")
        return MacAXActOutcome(status: .unverified, emissionAttempted: true, cause: raiseDiagnostic)
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

    /// Notifications wake confirmation off the AX lane; patience leaves an unverified request, never a claim that activation did not happen.
    private func awaitFrontAndFocused(app: NSRunningApplication, window: MacAXWindowRef?, signals: MacWindowActivationSignals,
                                      context: MacOperationContext) -> Bool {
        let patience = DispatchTime.now() + 0.3
        while !Task.isCancelled, !context.expired {
            if isFrontAndFocused(app: app, window: window, context: context) { return true }
            if signals.wake.wait(timeout: patience) == .timedOut { break }
        }
        return !Task.isCancelled && !context.expired && isFrontAndFocused(app: app, window: window, context: context)
    }

    #endif
}

#if canImport(AppKit)
/// Each registration is armed before the request and released on every synchronous exit.
private struct MacWindowActivationSignals {
    let wake: DispatchSemaphore
    let effects: (any MacAXEffectObservation)?
    let activation: (any MacAXEffectObservation)?
    let installationFailure: String?

    init(pid: Int32, observesWindow: Bool) {
        let wake = DispatchSemaphore(value: 0)
        self.wake = wake
        effects = observesWindow ? SystemMacAXEffectObserverSource().install(pid: pid,
            kinds: [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification], onNotification: { _ in wake.signal() }) : nil
        activation = SystemMacAppActivationObserverSource().install(onActivation: { wake.signal() })
        installationFailure = activation == nil ? "App activation observation could not be installed; no activation was requested."
            : observesWindow && effects == nil ? "Focused-window observation could not be installed; no raise was requested." : nil
    }

    func stop() {
        effects?.stop()
        activation?.stop()
    }
}
#endif
#endif
