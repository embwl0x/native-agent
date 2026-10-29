import Foundation
import NativeAgentShared
import MemoryV2
import Observation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
// Blueprint: | `OnboardingTourReplay.swift` | MainActor tour replay request and once-only claim |
/// Settings sends an explicit replay edge to the main-content tour mount.
@MainActor
@Observable
public final class OnboardingTourReplay {
    public static let shared = OnboardingTourReplay()
    public private(set) var requestID = 0
    private var deliveredRequestID = 0
    @discardableResult
    public func requestReplay() -> Int {
        requestID += 1
        return requestID
    }
    /// The persisted showTour preference still covers a later scene mount.
    public func claim(_ requestID: Int) -> Bool {
        guard requestID == self.requestID,
              requestID > deliveredRequestID,
              requestID > 0 else { return false }
        deliveredRequestID = requestID
        return true
    }
}
