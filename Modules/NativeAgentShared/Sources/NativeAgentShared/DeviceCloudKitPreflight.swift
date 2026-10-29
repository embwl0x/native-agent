// Entitlement admission precedes CKContainer construction because a missing CloudKit grant traps synchronously.

import Foundation
#if os(macOS)
import Security
#endif

// Blueprint: | `DeviceCloudKitPreflight.swift` | `DeviceCloudKitPreflight`: entitlement/container admission before constructing CKContainer |

/// Entitlement preflight for CloudKit. Every member decides whether it is safe
/// to construct a `CKContainer`; NONE constructs one.
public enum DeviceCloudKitPreflight {
    /// Runtime entitlement key listing the granted iCloud services.
    public static let iCloudServicesEntitlementKey = "com.apple.developer.icloud-services"
    /// Runtime entitlement key listing the granted iCloud container identifiers.
    public static let iCloudContainersEntitlementKey = "com.apple.developer.icloud-container-identifiers"

    /// THE HARD GATE. True iff this process may safely touch CloudKit.
    /// The transport factory refuses construction without this grant and the
    /// exact container entitlement, without touching `CKContainer`.
    ///
    /// macOS requires `CloudKit` in the signed `com.apple.developer.icloud-services` entitlement.
    ///
    /// iOS devices rely on install-time provisioning; simulators return false to avoid synchronous traps.
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
        // iOS builds selecting CloudKit must declare its entitlement; provisioning enforces the grant.
        return true
        #else
        return false
        #endif
    }

    /// Exact container gate. True iff the process entitlements list the selected
    /// `containerIdentifier` (macOS), or install-time provisioning has already
    /// enforced the declared container entitlement (iOS).
    public static func entitlementGrantsContainer(_ containerIdentifier: String) -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let raw = SecTaskCopyValueForEntitlement(
                task, iCloudContainersEntitlementKey as CFString, nil),
              let ids = raw as? [String]
        else { return false }
        return ids.contains(containerIdentifier)
        #else
        return true
        #endif
    }
}
