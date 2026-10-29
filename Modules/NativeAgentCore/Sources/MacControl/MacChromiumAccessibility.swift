import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(AppKit)
import AppKit
import os
import CoreGraphics
import UserNotifications
import Senses
import Experiences
import CryptoKit
import CoreText
import ScreenCaptureKit
#endif
// Blueprint: | `MacChromiumAccessibility.swift` | Chromium accessibility flags and verified native readback |
/// Chromium/Electron expose web AX content when told a screen reader is present.
/// Set both `AXEnhancedUserInterface` (Chrome) and `AXManualAccessibility` (Electron).
/// Read-back proves the setting: Chrome can apply it despite `kAXErrorCannotComplete`.
/// This writes accessibility mode only; the reader remains mutation-free.
/// Keep flags for the frame lifetime; clear lazily on app change/expiry, without a timer.
public enum MacChromiumAccessibility {
    /// An INACTIVITY window. Observed renderer nodes/text growth renews it without any
    /// total duration ceiling; AX notifications only trigger another read.
    static let rendererStallSeconds: TimeInterval = 6
    public enum Flag: String, CaseIterable, Sendable {
        case enhancedUserInterface = "AXEnhancedUserInterface"
        case manualAccessibility = "AXManualAccessibility"
    }
    /// Renderer identity comes from the running app's bundle, not its name or
    /// a thin-tree guess (a small native window can legitimately be thin).
    public static func looksChromium(bundleId: String?, pid: Int32? = nil, snapshot: MacAXTreeSnapshot?) -> Bool {
        // Browser identity is available before Chromium builds any AXWebArea.
        // Do not make renderer activation depend on the tree it activates or
        // on browser helper layout (which changes between distributions).
        if let bundleId, chromiumBrowserBundles.contains(bundleId) { return true }
        guard let pid else { return false }
        return shipsChromium(pid: pid)
    }
    private static let chromiumBrowserBundles: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary",
        "com.operasoftware.Opera", "com.operasoftware.OperaNext", "com.operasoftware.OperaDeveloper",
        "com.vivaldi.Vivaldi", "company.thebrowser.Browser",
    ]
    private static let shipsChromiumCache = OSAllocatedUnfairLock(initialState: [String: Bool]())
    /// The running process's own bundle carries a Chromium renderer helper:
    /// Electron and CEF apps beside their framework, Chrome-style apps inside
    /// it. Read from the process (two installs can share a bundle id) and
    /// scanned once per bundle path per launch.
    static func shipsChromium(pid: Int32) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return false }
        if let known = shipsChromiumCache.withLock({ $0[app.path] }) { return known }
        let files = FileManager.default
        let frameworks = app.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let entries = (try? files.contentsOfDirectory(atPath: frameworks.path)) ?? []
        let isRenderer = { (name: String) in name.hasSuffix("Renderer).app") }
        let found = entries.contains { name in
            name == "Electron Framework.framework" || name == "Chromium Embedded Framework.framework"
                || isRenderer(name)
                || (name.hasSuffix(".framework") && ((try? files.contentsOfDirectory(
                    atPath: frameworks.appendingPathComponent("\(name)/Versions/Current/Helpers").path
                )) ?? []).contains(where: isRenderer))
        }
        shipsChromiumCache.withLock { $0[app.path] = found }
        return found
    }
    public static func hasWebArea(_ snapshot: MacAXTreeSnapshot?) -> Bool {
        snapshot?.nodes.contains { $0.attributes.role == "AXWebArea" } ?? false
    }
}
/// Which apps and flags this module changed, so the next look can clear only
/// those flags when the target app changes or the frame dies.
public actor MacChromiumAccessibilityState {
    public static let shared = MacChromiumAccessibilityState()
    private var owned: [Int32: Set<MacChromiumAccessibility.Flag>] = [:]
    public init() {}
    public func current() -> [Int32: Set<MacChromiumAccessibility.Flag>] { owned }
    public func note(pid: Int32, flags: Set<MacChromiumAccessibility.Flag>) {
        owned[pid] = flags.isEmpty ? nil : flags
    }
}
#if canImport(ApplicationServices) && os(macOS)
public extension SystemMacAXElementSource {
    /// Set the requested enhanced-accessibility flags on an APPLICATION element and
    /// report what they READ BACK as. Chrome's set returns
    /// `kAXErrorCannotComplete` while the flag takes effect, so the status is
    /// discarded on purpose and only the read-back is reported.
    /// Values are tri-state: true is on, false is off, absent is unknown.
    ///
    /// On the AX execution lane, like every other AX transaction in this module
    /// (`MacAXExecutionLane` — AppKit/SwiftUI handlers are main-thread isolated
    /// and an off-lane AX call can crash the TARGET app).
    @discardableResult
    static func setEnhancedAccessibility(
        pid: Int32, flags: Set<MacChromiumAccessibility.Flag>, enabled: Bool
    ) -> [MacChromiumAccessibility.Flag: Bool] {
        MacAXExecutionLane.sync {
            // Refuse self-process flag writes: in-process AppKit re-entry can deadlock.
            guard pid != getpid() else { return [:] }
            let app = AXUIElementCreateApplication(pid)
            let value: CFTypeRef = (enabled ? kCFBooleanTrue : kCFBooleanFalse)
            for flag in MacChromiumAccessibility.Flag.allCases where flags.contains(flag) {
                guard MacAXAttributeRead.prepare(app) else { break }
                _ = AXUIElementSetAttributeValue(app, flag.rawValue as CFString, value)
            }
            if MacAXLimits.readDeadline != nil { _ = AXUIElementSetMessagingTimeout(app, 0) }
            return readsEnhancedAccessibility(app: app)
        }
    }
    /// Read each flag independently; absent entries are unknown, not false.
    static func enhancedAccessibilityFlags(pid: Int32) -> [MacChromiumAccessibility.Flag: Bool] {
        MacAXExecutionLane.sync {
            guard pid != getpid() else { return [:] }
            return readsEnhancedAccessibility(app: AXUIElementCreateApplication(pid))
        }
    }
    /// Only successful Boolean reads are evidence, whatever the setter returned.
    private static func readsEnhancedAccessibility(app: AXUIElement) -> [MacChromiumAccessibility.Flag: Bool] {
        var flags: [MacChromiumAccessibility.Flag: Bool] = [:]
        for flag in MacChromiumAccessibility.Flag.allCases {
            if let value = MacAXAttributeRead.copyBool(app, flag.rawValue) { flags[flag] = value }
        }
        return flags
    }
}
#endif
