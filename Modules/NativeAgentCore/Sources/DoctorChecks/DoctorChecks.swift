import Foundation
import PersistenceCore
// Blueprint: | `DoctorChecks.swift` | SwiftNativeDoctorChecks inventory and execution; seventeen ordered checks, StorageCheck-first preparation, concurrent measurements, scoped repairs and shared heartbeat exclusions |

/// Report internal failures as status "fail" with error detail so other checks still run.
public protocol DoctorCheck: Sendable {
    var id: String { get }
    var title: String { get }
    /// False excludes a check from unattended execution, failure counts and health; it remains visible in Doctor. Defaults to
    /// true; operator-only checks must opt out.
    var heartbeatEligible: Bool { get }
    func run() async -> CheckResult
}

public extension DoctorCheck {
    var heartbeatEligible: Bool { true }
}

/// Core exclusions derive from defaultChecks; app-mounted live IDs are explicit for persisted-report readers.
public enum DoctorHeartbeatPolicy {
    public static let ineligibleCheckIDs: Set<String> = Set(
        SwiftNativeDoctorChecks.defaultChecks
            .filter { !$0.heartbeatEligible }
            .map(\.id)
    ).union([
        // App-mounted Cognition checks include historical receipts and operator-only readings. They belong in Doctor, not phone
        // alerts.
        "live.cognition.runtime", "live.cognition.persistence",
        "live.cognition.receipts", "live.cognition.readouts",
        "live.cognition.body", "live.cognition.welfare",
        "live.cognition.capacity", "live.cognition.associations",
        "live.cognition.context_flow", "live.cognition.phone_pairing",
    ])

    /// True when an unattended sweep may judge this id.
    public static func isEligible(_ id: String) -> Bool {
        !ineligibleCheckIDs.contains(id)
    }
}

/// Checks that can safely repair app-owned state without an LLM.
public protocol RepairingDoctorCheck: DoctorCheck {
    func run(repair: Bool) async -> CheckResult
}

public extension RepairingDoctorCheck {
    func run() async -> CheckResult {
        await run(repair: false)
    }
}

public actor SwiftNativeDoctorChecks: Sendable {
    private let checks: [DoctorCheck]

    /// The production check list also owns DoctorHeartbeatPolicy's core exclusions.
    public static let defaultChecks: [DoctorCheck] = checks()

    public static func checks(root: URL? = nil) -> [DoctorCheck] {
        let dataRoot = root ?? defaultDataRoot()
        return [
            StorageCheck(root: dataRoot),
            RuntimeJSONStoresCheck(root: dataRoot),
            AbilityFilesCheck(root: dataRoot),
            RunLedgerIntegrityCheck(root: dataRoot),
            TurnTraceIntegrityCheck(root: dataRoot),
            ChatSessionsCheck(root: dataRoot),
            SessionIdentityCheck(root: dataRoot),
            // These bounded trace readings run only in Doctor and are excluded from unattended sweeps.
            PromptPrefixHealthCheck(root: dataRoot),
            SubconsciousVitalsCheck(root: dataRoot),
            ModelCompensationsCheck(root: dataRoot),
            ChatMessagesIntegrityCheck(root: dataRoot),
            PersonaEngineCheck(root: root),
            MemoryStoreCheck(root: dataRoot),
            CoreMLEmbedderCheck(root: dataRoot),
            ICloudBridgeStateCheck(dataRoot: dataRoot),
            OpLogHealthCheck(root: dataRoot),
            OAuthTokenExpiryCheck(root: dataRoot),
        ]
    }

    public init(checks: [DoctorCheck] = SwiftNativeDoctorChecks.defaultChecks) {
        self.checks = checks
    }

    public func runAll() async -> [CheckResult] {
        // Run StorageCheck first to prepare the tree, then the remaining checks concurrently; preserve declaration order.
        var sequentialResults: [(Int, CheckResult)] = []
        var concurrentChecks: [(Int, any DoctorCheck)] = []
        for (index, check) in checks.enumerated() {
            if check is StorageCheck {
                sequentialResults.append((index, await check.run()))
            } else {
                concurrentChecks.append((index, check))
            }
        }
        let ordered = await withTaskGroup(of: (Int, CheckResult).self) { group in
            for (index, check) in concurrentChecks {
                group.addTask {
                    return (index, await check.run())
                }
            }
            var collected = sequentialResults
            collected.reserveCapacity(checks.count)
            for await item in group { collected.append(item) }
            return collected
        }
        return ordered.sorted { $0.0 < $1.0 }.map(\.1)
    }

    public func runCheck(id: String, repair: Bool, scope: DoctorRepairScope) async -> CheckResult? {
        for check in checks where check.id == id {
            if let repairable = check as? any RepairingDoctorCheck {
                return await repairable.run(repair: repair && DoctorSafeRepairPolicy.allowsCoreRepair(id, scope: scope))
            }
            return await check.run()
        }
        return nil
    }
}

public func makeDoctorChecks(root: URL? = nil, freshMeasurement: Bool = false) -> SwiftNativeDoctorChecks {
    let root = root == defaultDataRoot() ? nil : root
    var checks = root.map { SwiftNativeDoctorChecks.checks(root: $0) } ?? SwiftNativeDoctorChecks.defaultChecks
    if freshMeasurement {
        checks = checks.map { check in
            switch check.id {
            case "prompt_prefix_health": PromptPrefixHealthCheck(root: root ?? defaultDataRoot(), cacheTTL: 0)
            case "subconscious_vitals": SubconsciousVitalsCheck(root: root ?? defaultDataRoot(), cacheTTL: 0)
            case "model.shims": ModelCompensationsCheck(root: root ?? defaultDataRoot(), cacheTTL: 0)
            default: check
            }
        }
    }
    return SwiftNativeDoctorChecks(checks: checks)
}
