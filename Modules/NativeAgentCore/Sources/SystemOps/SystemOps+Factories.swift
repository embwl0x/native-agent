import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter

// MARK: - Factories

public func makeRouterPlanClient() -> any RouterPlanClient {
    return SwiftNativeRouterPlanClient()
}
