import MemoryV2
import PersistenceCore
#if canImport(CloudKit)
import CloudKit
#endif
import Foundation
import NativeAgentShared
#if canImport(Security)
import Security
// Blueprint: | `CKLandmine.swift` | CloudKit entitlement probes and guarded account-status projection |
#endif

// CloudKit database availability does not determine KVS or iCloud Drive availability.
public let nativeAgentCloudKitDisabledStatus = "DB sync off (KVS sync active)"

public func nativeAgentCloudKitAccountProbeEnabled(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    hasCloudKitEntitlement: @Sendable () -> Bool = nativeAgentHasCloudKitServiceEntitlement
) -> Bool {
    let raw = (environment["NATIVE_AGENT_ENABLE_CLOUDKIT"] ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    guard raw == "1" || raw == "true" || raw == "yes" else { return false }
    return hasCloudKitEntitlement()
}

public func nativeAgentHasCloudKitServiceEntitlement() -> Bool {
    DeviceCloudKitPreflight.hasCloudKitEntitlement()
}

public func nativeAgentCloudKitAccountStatus(label: String) async -> String {
    guard nativeAgentCloudKitAccountProbeEnabled() else { return nativeAgentCloudKitDisabledStatus }
    #if canImport(CloudKit)
    return await withCKTimeout(label) {
        nativeAgentCloudKitAccountWords(try await CKContainer.default().accountStatus())
    } ?? "iCloud didn't answer in time"
    #else
    return "iCloud isn't available"
    #endif
}

#if canImport(CloudKit)
private func nativeAgentCloudKitAccountWords(_ status: CKAccountStatus) -> String {
    switch status {
    case .available: return "Signed in to iCloud"
    case .noAccount: return "Not signed in to iCloud"
    case .restricted: return "iCloud is restricted on this Mac"
    case .temporarilyUnavailable: return "iCloud needs you to confirm your account"
    case .couldNotDetermine: return "Couldn't check iCloud"
    @unknown default: return "Couldn't check iCloud"
    }
}
#endif

extension MemoryV2NativeStackSnapshot {
    public static func load(dataRoot: URL = PersistenceCore.defaultDataRoot()) async -> Self {
        var snap = await read(dataRoot: dataRoot)
        snap.cloudKitAccountStatus = await nativeAgentCloudKitAccountStatus(label: "MemoryV2NativeStackSnapshot.cloudKitAccount")

        return snap
    }
}
