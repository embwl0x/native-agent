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

public func makeProductionMigrationPlanClient() -> any ProductionMigrationPlanClient {
    return SwiftNativeProductionMigrationPlanClient()
}

public func makeProductionExportsClient() -> any ProductionExportsClient {
    return SwiftNativeProductionExportsClient()
}
