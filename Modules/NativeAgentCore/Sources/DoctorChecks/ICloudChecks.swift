import Foundation
import Security
import CloudKit
import NativeAgentShared
import PersistenceCore
import DeviceSyncState
// Blueprint: | `ICloudChecks.swift` | ICloudBridgeStateCheck measures the active iCloud transport and local sync bookkeeping; repairs only missing bridge directories and preserves signed transport and account verdicts |

public struct ICloudBridgeStateCheck: RepairingDoctorCheck {
    public let id: String = "icloud_bridge_state"
    public let title: String = "iCloud Bridge State"
    /// Local sync bookkeeping root; durable failures join the bridge verdict.
    private let dataRoot: URL

    public init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        self.dataRoot = dataRoot
    }

    /// Warnings derived from the sync engine's own durable state files. Deliberately ordered most-actionable first.
    static func localSyncStateWarnings(dataRoot: URL) -> (details: [String], fault: Bool) {
        var warnings: [String] = []
        let stranded = ICloudSyncStatePaths.completedUnarchivedMsgIds(dataRoot: dataRoot)
        if !stranded.isEmpty {
            warnings.append(
                "\(stranded.count) iPhone command(s) completed but their completion record could not be filed "
                + "with local markers at \(stranded.prefix(3).map { ICloudSyncStatePaths.completedUnarchivedMarker(dataRoot: dataRoot, msgId: $0).path }.joined(separator: ", "))"
                + "\(stranded.count > 3 ? ", …" : ""); they remain marked completed"
            )
        }
        let skipsURL = ICloudSyncStatePaths.snapshotSkips(dataRoot: dataRoot)
        if let data = try? Data(contentsOf: skipsURL),
           let skips = try? JSONDecoder().decode([String: String].self, from: data) {
            let groups = skips.keys.filter { !$0.hasPrefix("_") }.sorted()
            if !groups.isEmpty {
                // Named with why, so a group that never reached the phone says so instead of only that it is old.
                let byReason = Dictionary(grouping: groups) { String(skips[$0, default: ""].prefix(160)) }
                warnings.append(
                    "iPhone is showing stale \(groups.joined(separator: ", ")) — the last snapshot pass could not "
                    + "build or publish \(groups.count == 1 ? "that group" : "those groups"): "
                    + byReason.keys.sorted().map { "\(byReason[$0, default: []].joined(separator: ", ")) (\($0))" }
                        .joined(separator: "; ")
                )
            }
        }
        return (warnings, !stranded.isEmpty)
    }

    /// Folds local sync-state warnings into the active transport verdict without downgrading a harder existing status.
    private func merging(_ result: CheckResult) -> CheckResult {
        let local = Self.localSyncStateWarnings(dataRoot: dataRoot)
        let warnings = local.details
        let corrupt = ICloudSyncStatePaths.processedIdsCorruptBackup(dataRoot: dataRoot)
        let history = FileManager.default.fileExists(atPath: corrupt.path)
            ? "the processed-command list was unreadable and was preserved as processed_ids.corrupt.json, so iPhone commands from before that point may be re-run" : ""
        guard !warnings.isEmpty || !history.isEmpty else { return result }
        var reading = result
        reading.status = result.status == "fail" || local.fault ? "fail" : "warn"
        reading.detail = ([result.detail.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))] + warnings + (history.isEmpty ? [] : [history])).joined(separator: "; ") + "."
        return reading
    }

    private static func entitlementValues(_ key: String) -> [String] {
        guard let task = SecTaskCreateFromSelf(nil),
              let raw = SecTaskCopyValueForEntitlement(task, key as CFString, nil) else { return [] }
        if let values = raw as? [String] { return values }
        if let value = raw as? String { return [value] }
        return []
    }

    public func run(repair: Bool) async -> CheckResult {
        let services = Self.entitlementValues(DeviceCloudKitPreflight.iCloudServicesEntitlementKey)
        guard let snapshot = await ICloudBridgeHealthReader.snapshot(dataRoot: dataRoot) else {
            return merging(CheckResult(source: "iCloud container " + NativeAgentICloudBridgeConstants.containerID,
                id: id, title: title, status: "unmeasured",
                detail: "iCloud transport health is unmeasured; the app's bridge has not started."
            ))
        }
        let containerID = NativeAgentICloudBridgeConstants.containerID
        let cloudKit = snapshot.transport == .cloudKit
        // A CloudKit-signed build whose configured container is not the one its signature grants never gets the CloudKit
        // transport; say that, not the iCloud Drive entitlement it fell back to and never needed.
        let grantedContainers = Self.entitlementValues(DeviceCloudKitPreflight.iCloudContainersEntitlementKey)
        if !cloudKit, services.contains("CloudKit"), !grantedContainers.isEmpty, !grantedContainers.contains(containerID) {
            return merging(CheckResult(source: "iCloud container " + containerID,
                id: id, title: title, status: "warn",
                detail: "This build is configured for iCloud container \(containerID), but its signature grants \(grantedContainers.joined(separator: ", ")), so it has no CloudKit transport for the phone.",
                harm: "The phone cannot exchange messages with her through iCloud.",
                owner: .builder
            ))
        }
        let service = cloudKit ? "CloudKit" : "CloudDocuments"
        let containerKey = cloudKit ? DeviceCloudKitPreflight.iCloudContainersEntitlementKey
            : "com.apple.developer.ubiquity-container-identifiers"
        guard services.contains(service), Self.entitlementValues(containerKey).contains(containerID) else {
            return merging(CheckResult(source: "iCloud container " + NativeAgentICloudBridgeConstants.containerID,
                id: id, title: title, status: "warn",
                detail: "The active \(cloudKit ? "CloudKit" : "iCloud Drive") transport lacks its signed \(service) service or container entitlement.",
                harm: "The phone cannot exchange messages with her through iCloud.",
                owner: .builder
            ))
        }
        if cloudKit {
            return merging(cloudKitResult(snapshot))
        }
        // Doctor's launch run can precede the bridge's first transfer. Not measured yet is a reading, not a defect: nothing is
        // wrong and nothing can be done, so it must not wake her or the phone.
        if case .unmeasured = snapshot.health {
            return merging(CheckResult(source: "iCloud container " + NativeAgentICloudBridgeConstants.containerID,
                id: id, title: title, status: "unmeasured", detail: "iCloud Drive is starting; transport health is not measured yet."
            ))
        }
        guard case .available = snapshot.health, let docsURL = snapshot.documentsURL else {
            let signedIn = FileManager.default.ubiquityIdentityToken != nil
            return merging(CheckResult(source: "iCloud container " + NativeAgentICloudBridgeConstants.containerID,
                id: id, title: title, status: "warn",
                detail: signedIn ? "The active iCloud Drive container is unavailable." : "The active iCloud Drive transport has no signed-in iCloud account.",
                harm: "The phone cannot exchange messages with her through iCloud.",
                repair: signedIn
                    ? "Open System Settings → Apple Account → iCloud → Drive and turn on Sync this Mac; allow NativeAgent under Apps Syncing to iCloud Drive."
                    : "Open System Settings → Apple Account and sign in to iCloud.",
                ask: signedIn ? .permission : .signIn
            ))
        }
        let bridgeDirs = [
            "outbox/mac",
            "outbox/ios",
            "processing",
            "processed",
            "snapshots",
            "inbox",
            "inbox/_rejected",
            "responses",
            "transactions/mac",
            "transactions/ios",
        ]
        var missing: [String] = []
        var created: [String] = []
        for rel in bridgeDirs {
            let dir = docsURL.appendingPathComponent(rel, isDirectory: true)
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) || !isDir.boolValue {
                missing.append(rel)
                if repair {
                    do {
                        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        created.append(rel)
                    } catch {
                        return CheckResult(source: docsURL.appendingPathComponent(rel).path,
                            id: id,
                            title: title,
                            status: "fail",
                            detail: "Could not create \(rel): \(error.localizedDescription)",
                            harm: "The phone cannot exchange messages with her through iCloud.",
                            repair: created.isEmpty ? nil : "Created: \(created.joined(separator: ", ")).",
                            repairApplied: !created.isEmpty,
                            repair_available: true
                        )
                    }
                }
            }
        }
        if repair, !created.isEmpty {
            return merging(CheckResult(source: "iCloud container " + NativeAgentICloudBridgeConstants.containerID,
                id: id,
                title: title,
                status: "ok",
                detail: "iCloud/APNS bridge directories are present after repair.",
                repair: "Created: \(created.joined(separator: ", ")).", repairApplied: true
            ))
        }
        if !missing.isEmpty {
            return merging(CheckResult(source: missing.map { docsURL.appendingPathComponent($0).path }.joined(separator: ", "),
                id: id,
                title: title,
                status: "warn",
                detail: "Missing iCloud/APNS bridge path(s): \(missing.joined(separator: ", ")).",
                harm: "The phone cannot exchange messages with her through iCloud.",
                repair: "Press Repair in Diagnostics → Health checks to recreate bridge directories.",
                repair_available: true
            ))
        }
        return merging(CheckResult(source: "iCloud container " + NativeAgentICloudBridgeConstants.containerID,
            id: id,
            title: title,
            status: "ok",
            detail: "iCloud/APNS bridge directories are present."
        ))
    }

    private func cloudKitResult(_ snapshot: ICloudBridgeHealthSnapshot) -> CheckResult {
        let receive = cloudKitResult(snapshot.health, operation: "receive")
        let failures = snapshot.sendFailures.sorted { $0.key < $1.key }.map {
            cloudKitResult($0.value, operation: "send (\($0.key))")
        }
        let send = failures.isEmpty
            ? (snapshot.sendMeasured ? "CloudKit has accepted outbound delivery; iOS receipt is not confirmed"
                                     : "CloudKit send health is unmeasured")
            : failures.map { $0.detail.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)) }.joined(separator: "; ")
        let adverse = ([receive] + failures).first { $0.status == "fail" }
            ?? ([receive] + failures).first { DoctorSafeRepairPolicy.isAdverse($0.status) }
        return CheckResult(source: "iCloud container " + NativeAgentICloudBridgeConstants.containerID,
            id: id, title: title,
            status: adverse?.status ?? (receive.status == "ok" && snapshot.sendMeasured && failures.isEmpty ? "ok" : "unmeasured"),
            detail: receive.detail.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)) + "; " + send + ".",
            harm: adverse?.harm, repair: adverse?.repair,
            human_action: adverse?.human_action, ask: adverse?.ask, owner: adverse?.owner
        )
    }

    private func cloudKitResult(_ health: ICloudBridgeHealthSnapshot.Health, operation: String) -> CheckResult {
        var status = "warn"
        let detail: String
        var action: String?
        var ask: DoctorAskKind?
        var owner: DoctorOwner?
        switch health {
        case .unmeasured:
            // Not measured yet (see the iCloud Drive branch above): a reading.
            status = "unmeasured"
            detail = "CloudKit \(operation) health is unmeasured; iCloud Drive is not required."
        case .available:
            status = "ok"
            detail = "CloudKit is active and its last \(operation) completed successfully; iCloud Drive is not required."
        case .signedOut:
            detail = "CloudKit \(operation) has no authenticated iCloud account."
            action = "Open System Settings → Apple Account and sign in to iCloud."
            ask = .signIn
        case .notEntitled:
            owner = .builder
            detail = "CloudKit \(operation) is not configured with its required entitlements."
            action = "Install a signed NativeAgent build granting CloudKit and container \(NativeAgentICloudBridgeConstants.containerID)."
        case .quotaExceeded:
            detail = "The active CloudKit transport cannot \(operation) because iCloud storage is full."
            action = "Open System Settings → Apple Account → iCloud → Manage and free iCloud storage."
            ask = .permission
        case .accountFailure(let code, let reason):
            detail = "CloudKit \(operation) was rejected: \(reason)"
            switch CKError.Code(rawValue: code) {
            case .notAuthenticated:
                action = "Open System Settings → Apple Account and complete iCloud sign-in."
                ask = .signIn
            case .missingEntitlement:
                owner = .builder
                action = "Install a signed NativeAgent build granting CloudKit and container \(NativeAgentICloudBridgeConstants.containerID)."
            case .managedAccountRestricted:
                action = "Ask your Apple Account administrator to allow CloudKit for NativeAgent."
                ask = .permission
            default: status = "fail"
            }
        case .unavailable(let reason):
            status = "fail"
            detail = "The active CloudKit transport's last \(operation) failed: \(reason)"
        case .pairedElsewhere:
            // The person's choice, not a fault: the phone follows one Mac.
            status = "ok"
            detail = "The iPhone is paired with another Mac (or an earlier install) on this Apple Account; this Mac stays quiet toward it."
            action = "Choose Use my iPhone with this Mac in Connectors → iPhone to disconnect it from the other Mac and connect it here."
        }
        return CheckResult(source: "iCloud container " + NativeAgentICloudBridgeConstants.containerID + ": " + operation, id: id, title: title, status: status, detail: detail,
                           harm: DoctorSafeRepairPolicy.isAdverse(status) ? "The phone cannot exchange messages with her through iCloud." : nil,
                           human_action: action, ask: ask, owner: owner)
    }
}
