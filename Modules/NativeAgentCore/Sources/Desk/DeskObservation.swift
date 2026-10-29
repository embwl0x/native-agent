import Foundation
import PersistenceCore
// Blueprint: | `DeskObservation.swift` | `DeskObservationEvaluator`: note-free material fingerprints for HarnessQueue and strict interpretation of historical drift notes; the retired external-observation evaluator and writer are removed |

/// Kinds retained to interpret historical Desk notes.
public enum DeskDriftKind: String, Sendable, CaseIterable, Equatable {
    case blockedButShipped = "blocked_but_shipped"
    case reopenedAfterClose = "reopened_after_close"
    case parkedButShipped = "parked_but_shipped"
    case untrackedButShipped = "untracked_but_shipped"
    case shippedWithoutReceipt = "shipped_without_receipt"
}

/// The surviving read helpers; no observation pass or mutation lives here.
public enum DeskObservationEvaluator {
    public static let driftMarker = "⚑ drift"

    /// Accept only the native historical shape: marker, [, known kind, :, refs, ].
    public static func driftKind(inNote text: String) -> DeskDriftKind? {
        let opening = "\(driftMarker)["
        guard text.hasPrefix(opening) else { return nil }
        let body = text.dropFirst(opening.count)
        guard let close = body.firstIndex(of: "]"),
              let colon = body[..<close].firstIndex(of: ":") else { return nil }
        return DeskDriftKind(rawValue: String(body[..<colon]))
    }

    /// The item's substance, order-stable and note-free. Keep its existing
    /// representation so retained HarnessQueue evidence keeps the same identity.
    public static func materialFingerprint(_ item: DeskItem) -> String {
        let refs = Set(item.refs.compactMap { ref -> String? in
            switch ref.kind {
            case let .ghPr(repo, number, _, _, _): return "\(repo.lowercased())#pr#\(number)"
            case let .ghIssue(repo, number, _, _): return "\(repo.lowercased())#issue#\(number)"
            default: return nil
            }
        }).sorted().joined(separator: ",")
        return [
            item.status.rawValue,
            item.title,
            item.summary ?? "",
            item.parent ?? "",
            item.blockedReason ?? "",
            item.waitingOn ?? "",
            item.deferUntil ?? "",
            item.blockedOn.sorted().joined(separator: ","),
            item.kind.rawValue,
            item.cadence.refreshSources.map { $0.lowercased() }.sorted().joined(separator: ","),
            refs,
        ].joined(separator: "\u{1F}")
    }
}
