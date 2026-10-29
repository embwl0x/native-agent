import Foundation

// Blueprint: | `SomaticSignalValence.swift` | `SomaticSignalKind` intrinsic valence: one per-kind table shared by signal adaptation and organism field defaults |

/// The event adapter and organism field share this intrinsic-valence table.
extension SomaticSignalKind {
    /// Canonical intrinsic valence; the cognitive adapter leaves zero unset.
    var canonicalValence: Double {
        switch self {
        case .toolSucceeded, .deskItemClosed, .providerSucceeded, .providerRecovered,
             .phoneDeliveryReceived, .memoryCommitted, .memoryHygieneCompleted,
             .dreamCompleted, .remIntegrated:
            return 0.45
        case .toolFailed, .providerFailed, .phoneDeliveryFailed, .deskItemBlocked,
             .memoryCorrected, .correctionReceived:
            return -0.55
        case .appWake, .iPhoneReachable:
            return 0.15
        case .resourcePressureChanged, .iPhoneStale:
            return -0.5
        case .approvalResolved:
            return 0.4
        // No intrinsic valence (chat felt-meaning owned by the substrate; or a
        // neutral lifecycle marker).
        case .userSpoke, .assistantSpoke, .appSleep, .toolStarted, .toolCancelled,
             .providerStarted, .providerCancelled, .phoneDeliveryStarted,
             .deskItemCreated, .deskItemCancelled, .approvalRequested,
             .horizonRefresh:
            return 0
        }
    }
}
