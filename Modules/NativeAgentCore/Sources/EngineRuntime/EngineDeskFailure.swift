import Foundation
import Desk

extension DeskFacade {
    public nonisolated static func boundedLoadFailure(_ detail: String) -> String {
        DeskLaneState<DeskItem>.boundedReason(detail)
    }

    /// Maps the actual Desk-store read failure into the banner's visible,
    /// bounded state. A custom error may provide no localized detail; that is
    /// still a failure, never an empty or clear desk.
    public nonisolated static func loadFailure(_ error: any Error) -> String {
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleDetail = detail.isEmpty
            ? "The storage read failed without details."
            : detail
        return boundedLoadFailure("Couldn't load the bench: \(visibleDetail)")
    }

}
