import Foundation
import DeskCore
// Blueprint: | `EngineDeskFailure.swift` | `DeskFacade.loadFailure` |

extension DeskFacade {
    /// Bound store failures for the banner; missing localized detail must not become an empty or clear desk.
    public nonisolated static func loadFailure(_ error: any Error) -> String {
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleDetail = detail.isEmpty
            ? "The storage read failed without details."
            : detail
        return DeskLaneState<DeskItem>.boundedReason("Couldn't load the bench: \(visibleDetail)")
    }

}
