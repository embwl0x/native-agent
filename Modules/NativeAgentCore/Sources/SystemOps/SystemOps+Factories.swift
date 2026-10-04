import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter

// MARK: - Factories

public func makeRouterPlanClient() -> any RouterPlanClient {
    return SwiftNativeRouterPlanClient()
}

public func makeSystemRebuildClient() -> any SystemRebuildClient {
    // The in-process Swift runtime is unconditional; current Trust policy
    // owns the autonomy switch and the per-action rebuild authorization.
    return SwiftNativeSystemRebuildClient(daemonAutonomy: true)
}
