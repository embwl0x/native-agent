// Entitlement admission precedes CKContainer construction because a missing CloudKit grant traps synchronously.

import Foundation
#if os(macOS)
import Security
#endif

// Blueprint: | `DeviceCloudKitPreflight.swift` | `DeviceCloudKitPreflight`: entitlement/container admission before constructing CKContainer |

/// Decide entitlement admission without constructing a container: construction can trap synchronously.
public enum DeviceCloudKitPreflight {
    public static let iCloudServicesEntitlementKey = "com.apple.developer.icloud-services"
    public static let iCloudContainersEntitlementKey = "com.apple.developer.icloud-container-identifiers"

    /// Construction requires the CloudKit service and exact container grant. macOS checks signed entitlements; iOS provisioning enforces them.
    /// Simulators refuse access to avoid synchronous traps.
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

    /// Exact container gate. True iff the process entitlements list the selected `containerIdentifier` (macOS), or install-time provisioning has
    /// already enforced the declared container entitlement (iOS).
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
