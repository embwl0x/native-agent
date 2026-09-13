import Foundation
import CoreGraphics
import ChatOrchestration

/// What the agent is looking at, as the chat's working card shows it.
///
/// Display-only and transient, like the card it lives in. Nothing here is
/// persisted, nothing here becomes memory, and the per-verb receipts remain the
/// record of what actually happened — this is the live view while it happens.
///
/// The frame arrives already downscaled and secret-masked by
/// ``MacScreenPreviewFrame`` on the capture side. The app neither crops nor
/// re-derives what may be shown.
struct MacChatScreenPreview: @unchecked Sendable {
    /// The masked, downscaled frame the last Mac verb captured. Optional
    /// because a verb can move the caption without producing a picture (no
    /// Screen Recording permission, a locked screen, a refused capture).
    let image: CGImage?
    /// One line of plain words for the verb in flight.
    let caption: String
    let updatedAt: Date

    /// Only worth a pane when there is something to show. A caption with no
    /// frame and no frame with no caption are both nothing to look at.
    var isShowable: Bool {
        image != nil && !caption.isEmpty
    }

    /// Folds one update into what the card is already showing. A `nil` field in
    /// the update means UNCHANGED: the verb that clicks a button publishes new
    /// words over the last frame, which is exactly the behaviour wanted —
    /// "Clicking Save" over the picture of the window Save is in.
    static func merged(
        _ previous: MacChatScreenPreview?,
        update: MacScreenPreviewUpdate
    ) -> MacChatScreenPreview? {
        let image = update.image ?? previous?.image
        let caption = update.caption ?? previous?.caption ?? ""
        guard image != nil || !caption.isEmpty else { return nil }
        return MacChatScreenPreview(image: image, caption: caption, updatedAt: update.at)
    }
}
