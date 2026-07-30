// DeviceCloudKitPreflight.swift — the CloudKit crash-guard for the device-sync
// transport. This is the single most important safety element of the CloudKit
// cutover (CK-3): it answers "may this process safely touch CKContainer?"
// WITHOUT ever constructing one.
//
// Why it exists — the 2026-06-03 launch crash: CKContainer.__allocating_init
// hit `_os_crash` (AMFI hard-kill, exit 137) because the provisioning profile
// granted the `CloudDocuments` iCloud service but NOT `CloudKit`. The trap is in
// the CONSTRUCTOR — there is no async boundary, no `try`/`catch`, and no
// timeout race (withDeviceCKTimeout) can intercept a synchronous `_os_crash`.
// The ONLY safe defense is to never call `CKContainer(identifier:)` unless the
// runtime entitlements prove CloudKit is granted.
//
// This lives in NativeAgentShared so the shared transport can guard itself on
// BOTH macOS and iOS. The entitlement read is necessarily PLATFORM-BRANCHED:
//   • macOS — the real Developer-ID direct-download crash surface. Reads the
//     signed entitlements via `SecTask` (the same mechanism as the shipped,
//     Mac-only `nativeAgentHasCloudKitServiceEntitlement` in
//     Sources/NativeAgentApp/Diagnostics/CKLandmine.swift). This is where a
//     profile can grant CloudDocuments but not CloudKit.
//   • iOS — there is NO public API to read your own binary entitlements
//     (`SecTaskCopyValueForEntitlement` is macOS-only, and App Store builds
//     carry no `embedded.mobileprovision`). iOS instead enforces at INSTALL
//     time that a build's code-signed entitlements are all granted by its
//     provisioning profile, so a running iOS app that DECLARES CloudKit (which
//     iOS/NativeAgentMobile/project.yml does, since CK-1) is guaranteed to have
//     it. We trust that enforcement; the injectable `configured:` init param and
//     the resolver's `.kvs` default remain the runtime overrides.

import Foundation
#if os(macOS)
import Security
#endif

/// Entitlement preflight for CloudKit. Every member decides whether it is safe
/// to construct a `CKContainer`; NONE constructs one.
public enum DeviceCloudKitPreflight {
    /// Runtime entitlement key listing the granted iCloud services.
    public static let iCloudServicesEntitlementKey = "com.apple.developer.icloud-services"
    /// Runtime entitlement key listing the granted iCloud container identifiers.
    public static let iCloudContainersEntitlementKey = "com.apple.developer.icloud-container-identifiers"

    /// THE HARD GATE. True iff this process may safely touch CloudKit.
    /// `CloudKitDeviceTransport` MUST return `.notConfigured` (and never touch
    /// `CKContainer`) whenever this is false.
    ///
    /// macOS: reads the signed entitlements via `SecTask` and confirms `CloudKit`
    /// is in `com.apple.developer.icloud-services`. On the 2026-06-03 crash the
    /// value was `["CloudDocuments"]` (no CloudKit) → returns false → the
    /// `CKContainer.__allocating_init` trap is skipped. This is what makes the
    /// cutover safe on the Developer-ID Mac app.
    ///
    /// iOS device: returns true — see the file header. Install-time
    /// provisioning enforcement guarantees the declared CloudKit entitlement
    /// is granted. The simulator returns false because unsigned simulator/test
    /// hosts do not carry this service entitlement and CKContainer otherwise
    /// terminates the process before a test can fail normally.
    public static func hasCloudKitEntitlement() -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let raw = SecTaskCopyValueForEntitlement(
                task, iCloudServicesEntitlementKey as CFString, nil)
        else { return false }
        if let services = raw as? [String] {
            return services.contains { $0.caseInsensitiveCompare("CloudKit") == .orderedSame }
        }
        if let service = raw as? String {
            return service.caseInsensitiveCompare("CloudKit") == .orderedSame
        }
        return false
        #elseif os(iOS) && targetEnvironment(simulator)
        return false
        #elseif os(iOS)
        // BUILD INVARIANT (enforced at build time, not here): an iOS build that
        // can select the CloudKit transport MUST declare the CloudKit
        // entitlement. iOS refuses to install/launch a binary whose code-signed
        // entitlements exceed its provisioning profile, so a running iOS app
        // that DECLARES CloudKit is guaranteed to have it granted. There is no
        // iOS runtime API to re-verify this (SecTask entitlement reads are
        // macOS-only; App Store builds ship no embedded.mobileprovision), so we
        // trust the install-time guarantee. The coupling "flag=cloudkit ⇒
        // CloudKit entitlement present" is asserted in the release build path
        // (CK-4) — that is the layer that can actually read the entitlements
        // file. Do NOT decouple the flag from the entitlement in any build.
        return true
        #else
        return false
        #endif
    }

    /// Diagnostic only — NOT a hard gate. True iff the process entitlements list
    /// `containerIdentifier` (macOS), or "can't introspect, no objection" (iOS).
    /// Container-id string formats vary across profiles (with/without an
    /// `iCloud.` prefix, case), so a macOS false here is worth LOGGING but must
    /// not disable CloudKit on its own — the hard gate stays
    /// `hasCloudKitEntitlement()`. iOS returns true so the diagnostic stays quiet
    /// where the entitlement can't be read.
    public static func entitlementGrantsContainer(_ containerIdentifier: String) -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let raw = SecTaskCopyValueForEntitlement(
                task, iCloudContainersEntitlementKey as CFString, nil),
              let ids = raw as? [String]
        else { return false }
        return ids.contains { $0.caseInsensitiveCompare(containerIdentifier) == .orderedSame }
        #else
        return true
        #endif
    }
}
