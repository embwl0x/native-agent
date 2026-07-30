import Foundation

/// Single source of truth for a signal kind's intrinsic valence.
///
/// Two per-kind valence tables used to drift (audit C10): the event→signal
/// adapter (`CognitiveSomaticSignalAdapter.valence`) stamped `toolFailed` at
/// −0.55, while the organism-field fallback (`OrganismField.defaultValence`)
/// used −0.50 for the same kind. They fire on different code paths — the
/// adapter SETS the signal's valence, the field default only applies when a
/// signal reaches the field with no explicit valence — but the numbers are the
/// same concept and must not diverge.
///
/// Decision (tightness sweep 2026-07-17): the ADAPTER's numbers win. Both
/// readers now consult this table. For every kind the adapter sets a valence on,
/// its non-nil value already reached the kernel, so aligning the field fallback
/// to the adapter number changes behavior only for the (non-production) case of
/// a signal of that kind arriving at the field with nil valence.
extension SomaticSignalKind {
    /// Canonical intrinsic valence for this kind. Adapter numbers where the
    /// adapter defines one; the field-fallback-only kinds (which the adapter
    /// intentionally leaves unset — see `adapterSuppressesIntrinsicValence`)
    /// keep the organism field's historical fallback value.
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
        // Field-fallback-only kinds: the adapter suppresses intrinsic valence
        // here, so these values surface only for signals that reach the field
        // with nil valence. Preserved from OrganismField.defaultValence.
        case .resourcePressureChanged, .iPhoneStale:
            return -0.5
        case .approvalResolved:
            return 0.4
        // No intrinsic valence (chat felt-meaning owned by the substrate; or a
        // neutral lifecycle marker).
        case .userSpoke, .assistantSpoke, .appSleep, .toolStarted, .toolCancelled,
             .providerStarted, .providerCancelled, .phoneDeliveryStarted,
             .deskItemCreated, .approvalRequested:
            return 0
        }
    }

    /// Kinds whose event→signal valence the adapter intentionally leaves unset —
    /// either the felt meaning is owned elsewhere (chat text → substrate) or the
    /// kind carries no intrinsic bodily valence. For these the produced signal
    /// has nil valence and the organism field's `canonicalValence` fallback
    /// applies downstream. Preserves the adapter's original nil-returning set.
    var adapterSuppressesIntrinsicValence: Bool {
        switch self {
        case .userSpoke, .assistantSpoke, .appSleep, .resourcePressureChanged,
             .toolStarted, .toolCancelled, .providerStarted, .providerCancelled,
             .phoneDeliveryStarted, .deskItemCreated, .approvalRequested,
             .approvalResolved, .iPhoneStale:
            return true
        default:
            return false
        }
    }
}
