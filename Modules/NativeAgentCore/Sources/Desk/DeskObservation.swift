import Foundation
import PersistenceCore
// Blueprint: | `DeskObservation.swift` | `DeskObservationEvaluator`: note-free material fingerprints for BodyQueue |

public enum DeskObservationEvaluator {
    /// Keep fingerprints order-stable and note-free so retained evidence preserves its identity.
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
