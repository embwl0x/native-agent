import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter

// MARK: - Factories

public func makeRouterPlanClient() -> any RouterPlanClient {
    return SwiftNativeRouterPlanClient()
}

public func makeSystemRebuildClient() -> any SystemRebuildClient {
    return SwiftNativeSystemRebuildClient()
}

public func makeGitStashRecoverClient() -> any GitStashRecoverClient {
    return SwiftNativeGitStashRecoverClient()
}

public func makeCrashReportClient() -> any CrashReportClient {
    // Wave-9 NOTE: SwiftNativeCrashReportClient's default init leaves the
    // autonomy gates closed (masterAutonomyEnabled=false / autonomyGate=false),
    // so improvementSpawned=false until AppDelegate / DaemonSupervisor wires
    // the gate closures (and optionally a custom improvementSpawner pointing at
    // SwiftNativeSelfImprovement). See CUTOVER_PLAN.md §6.10.
    return SwiftNativeCrashReportClient()
}

public func makeProductionMigrationPlanClient() -> any ProductionMigrationPlanClient {
    return SwiftNativeProductionMigrationPlanClient()
}

public func makeProductionExportsClient() -> any ProductionExportsClient {
    return SwiftNativeProductionExportsClient()
}
