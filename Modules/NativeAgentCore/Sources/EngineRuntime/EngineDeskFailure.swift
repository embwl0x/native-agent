import Foundation
import Desk
// Blueprint: | `EngineDeskFailure.swift` | `DeskFacade`: `boundedLoadFailure`, `loadFailure` |

extension DeskFacade {
    public nonisolated static func boundedLoadFailure(_ detail: String) -> String {
        DeskLaneState<DeskItem>.boundedReason(detail)
    }

    /// Bound store failures for the banner; missing localized detail must not become an empty or clear desk.
    public nonisolated static func loadFailure(_ error: any Error) -> String {
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleDetail = detail.isEmpty
            ? "The storage read failed without details."
            : detail
        return boundedLoadFailure("Couldn't load the bench: \(visibleDetail)")
    }

}
