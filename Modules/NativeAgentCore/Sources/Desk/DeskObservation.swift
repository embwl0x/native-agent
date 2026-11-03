import Foundation
import PersistenceCore
// Blueprint: | `DeskObservation.swift` | `DeskObservationEvaluator`: note-free material fingerprints for HarnessQueue |

/// The surviving read helpers; no observation pass or mutation lives here.
public enum DeskObservationEvaluator {
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
