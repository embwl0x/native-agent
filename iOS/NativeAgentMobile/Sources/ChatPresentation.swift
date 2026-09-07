import SwiftUI
import UIKit
import Speech
import PhotosUI
import NativeAgentShared

enum ChatSessionTabPresentation {
    static func isSelectionDisabled(isSwitchingSession: Bool, isClosingSession: Bool) -> Bool {
        isSwitchingSession || isClosingSession
    }
}

/// Pure decisions shared by ChatView's controls. Keeping these outside the
/// view makes an iPhone selection an explicit, testable value before it is
/// sent to the signed Mac route.
enum ChatRuntimeControlPresentation {
    static let fileAccessIDs = ICloudChatFileAccessPolicy.acceptedIDs

    static func processingModeTitle(fastMode: Bool) -> String {
        fastMode ? "Fast" : "Normal"
    }

    /// Runs the model-menu refresh and surfaces every unsuccessful outcome to
    /// the person who explicitly asked for it. Background refresh callers can
    /// still ignore the returned outcome without producing unsolicited toast.
    @MainActor
    static func refreshModels(
        refresh: () async -> ProviderControlsRefreshOutcome,
        presentError: (String) -> Void
    ) async {
        if let message = (await refresh()).feedbackMessage {
            presentError(message)
        }
    }

    static func normalizedFileAccessID(_ id: String) -> String {
        ICloudChatFileAccessPolicy.normalized(id)
    }

    static func providerID(
        selectedProviderID: String,
        activeProviderID: String?,
        model: String,
        providers: [ProviderInfo]
    ) -> String {
        let ready = providers.filter { $0.auth_status.state == "ready" }
        if ready.contains(where: { $0.provider_id == selectedProviderID }) { return selectedProviderID }
        if let activeProviderID, ready.contains(where: { $0.provider_id == activeProviderID }) { return activeProviderID }
        return ready.first(where: { provider in
            provider.models.contains(where: { $0.id == model })
        })?.provider_id ?? ""
    }

    static func reconciled(
        model: String,
        provider: ProviderInfo?,
        selectedEffort: String,
        selectedFastMode: Bool
    ) -> (model: String, effort: String, fastMode: Bool) {
        let modelInfo = provider?.models.first(where: { $0.id == model })
        let allowed = modelInfo?.supported_reasoning_efforts?.filter { !$0.isEmpty }
            ?? ["none", "low", "medium", "high"]
        let preferred = modelInfo?.default_reasoning_effort ?? "high"
        let effort = allowed.contains(selectedEffort)
            ? selectedEffort
            : (allowed.contains(preferred) ? preferred : (allowed.first ?? "high"))
        return (model, effort, modelInfo?.supports_fast == true ? selectedFastMode : false)
    }

    static func modelForProvider(
        currentModel: String,
        provider: ProviderInfo?,
        preferredModels: [String]
    ) -> String {
        guard let provider else { return currentModel }
        let modelIDs = provider.models.map(\.id).filter { !$0.isEmpty }
        guard !modelIDs.isEmpty, !modelIDs.contains(currentModel) else { return currentModel }
        return preferredModels.first(where: modelIDs.contains) ?? modelIDs[0]
    }

    static func selectionForProvider(
        providerID: String,
        current: Selection,
        providers: [ProviderInfo],
        preferredModels: [String]
    ) -> Selection? {
        guard let provider = providers.first(where: {
            $0.provider_id == providerID && $0.auth_status.state == "ready"
        }) else { return nil }
        let model = modelForProvider(
            currentModel: current.model,
            provider: provider,
            preferredModels: preferredModels
        )
        let controls = reconciled(
            model: model,
            provider: provider,
            selectedEffort: current.reasoningEffort,
            selectedFastMode: current.fastMode
        )
        return Selection(
            providerID: providerID,
            model: controls.model,
            reasoningEffort: controls.effort,
            fastMode: controls.fastMode
        )
    }

    static func seededProviderID(
        selectedProviderID: String,
        activeProviderID: String?,
        model: String,
        readyProviders: [ProviderInfo]
    ) -> String? {
        guard !readyProviders.isEmpty else { return nil }
        if readyProviders.contains(where: { $0.provider_id == selectedProviderID }) { return selectedProviderID }
        if let activeProviderID, readyProviders.contains(where: { $0.provider_id == activeProviderID }) {
            return activeProviderID
        }
        return readyProviders.first(where: { $0.models.contains(where: { $0.id == model }) })?.provider_id
            ?? readyProviders[0].provider_id
    }

    static func shouldRollback(selectionGeneration: Int, requestGeneration: Int) -> Bool {
        selectionGeneration == requestGeneration
    }

    struct Selection: Equatable {
        var providerID: String
        var model: String
        var reasoningEffort: String
        var fastMode: Bool
    }

    static func rollback(
        currentGeneration: Int,
        requestGeneration: Int,
        previous: Selection
    ) -> Selection? {
        shouldRollback(selectionGeneration: currentGeneration, requestGeneration: requestGeneration)
            ? previous
            : nil
    }

    static let modelDefaultsKey = "chatModel"
    static let effortDefaultsKey = "chatReasoningEffort"
    static let fastDefaultsKey = "chatFastMode"
    static let providerDefaultsKey = "chatProviderId"
    static let generationDefaultsKey = "chatSurfaceSelectionGeneration"

    static func persist(_ selection: Selection, in defaults: UserDefaults) {
        defaults.set(selection.model, forKey: modelDefaultsKey)
        defaults.set(selection.reasoningEffort, forKey: effortDefaultsKey)
        defaults.set(selection.fastMode, forKey: fastDefaultsKey)
        defaults.set(selection.providerID, forKey: providerDefaultsKey)
    }

    static func acceptReceipt(
        _ receipt: MobileSurfaceSelectionReceipt,
        defaults: UserDefaults,
        requestGeneration: Int
    ) -> Selection? {
        guard receipt.surface == "ios",
              defaults.integer(forKey: generationDefaultsKey) == requestGeneration else { return nil }
        let selection = Selection(
            providerID: receipt.providerID, model: receipt.model,
            reasoningEffort: receipt.reasoningEffort, fastMode: receipt.serviceTier == "priority"
        )
        persist(selection, in: defaults)
        return selection
    }

    /// The shared action seam behind every optimistic runtime-control menu.
    /// It intentionally observes the persisted generation after the transport
    /// result, so an older failed request cannot restore over a newer iPhone
    /// pick—even if all four values happen to match again (ABA).
    @MainActor
    static func execute(
        defaults: UserDefaults,
        previous: Selection,
        requested: Selection,
        requestGeneration: Int,
        configure: (Selection) async throws -> Void
    ) async -> (restored: Selection?, error: Error?) {
        persist(requested, in: defaults)
        do {
            try await configure(requested)
            return (nil, nil)
        } catch {
            guard defaults.integer(forKey: generationDefaultsKey) == requestGeneration else { return (nil, error) }
            persist(previous, in: defaults)
            return (previous, error)
        }
    }
}

/// Resolves an eventually-consistent surface-model snapshot without allowing a
/// stale snapshot to undo a selection the user has just sent to the Mac.
enum ChatSurfaceModelPreferenceAdoption {
    struct Selection: Equatable {
        var providerID: String
        var model: String
        var reasoningEffort: String
        var fastMode: Bool
    }

    struct Resolution: Equatable {
        var selection: Selection
        var awaitingAcknowledgement: Bool
    }

    static func resolve(
        current: Selection,
        preference: SurfaceModelPref,
        awaitingAcknowledgement: Bool,
        selectableProviderIDs: Set<String>
    ) -> Resolution {
        if awaitingAcknowledgement {
            return Resolution(
                selection: current,
                awaitingAcknowledgement: !acknowledges(current, preference: preference)
            )
        }

        var selection = current
        if let providerID = preference.providerId,
           selectableProviderIDs.contains(providerID) {
            selection.providerID = providerID
        }
        selection.model = preference.model
        if let reasoningEffort = preference.reasoningEffort {
            selection.reasoningEffort = reasoningEffort
        }
        if let serviceTier = preference.serviceTier {
            selection.fastMode = serviceTier == "priority"
        }
        return Resolution(selection: selection, awaitingAcknowledgement: false)
    }

    private static func acknowledges(_ selection: Selection, preference: SurfaceModelPref) -> Bool {
        guard preference.model == selection.model else { return false }
        if let providerID = preference.providerId, providerID != selection.providerID { return false }
        if let reasoningEffort = preference.reasoningEffort,
           reasoningEffort != selection.reasoningEffort { return false }
        if let serviceTier = preference.serviceTier,
           (serviceTier == "priority") != selection.fastMode { return false }
        return true
    }
}

enum ChatFollowPresentation {
    static func userScrolledAway() -> (autoFollow: Bool, showsLatest: Bool) { (false, true) }
    static func followLatest() -> (autoFollow: Bool, showsLatest: Bool) { (true, false) }
}

/// One pending callback is enough for a streaming burst. Each later ordinary
/// mutation replaces its target rather than scheduling another scroll, while a
/// forced/animated request supersedes the prior callback through a new serial.
struct ChatScrollScheduler: Equatable {
    private(set) var serial = 0
    private(set) var isScheduled = false
    private var pendingTargetID: String?

    mutating func schedule(targetID: String, animated: Bool, force: Bool) -> Int? {
        if isScheduled && !animated && !force {
            pendingTargetID = targetID
            return nil
        }
        serial &+= 1
        isScheduled = true
        pendingTargetID = targetID
        return serial
    }

    mutating func complete(serial: Int, messagesAreAvailable: Bool) -> String? {
        guard serial == self.serial else { return nil }
        defer {
            isScheduled = false
            pendingTargetID = nil
        }
        guard messagesAreAvailable else { return nil }
        return pendingTargetID
    }
}

enum ChatAttachmentPresentation {
    static func hasRenderableImage(_ attachment: ChatAttachmentSummary) -> Bool {
        guard attachment.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "image",
              let raw = attachment.base64?.trimmingCharacters(in: .whitespacesAndNewlines),
              let data = Data(base64Encoded: raw), !data.isEmpty else { return false }
        return UIImage(data: data) != nil
    }

    static func previewableImages(in attachments: [ChatAttachmentSummary]) -> [ChatAttachmentSummary] {
        attachments.filter(hasRenderableImage)
    }

    static func fallbackCount(in attachments: [ChatAttachmentSummary]) -> Int {
        max(0, attachments.count - previewableImages(in: attachments).count)
    }
}

enum PendingPhotoPresentation {
    struct Removal {
        var photos: [PendingPhotoAttachment]
        var clearsPicker: Bool
        var suppressesNextEmptySelection: Bool
    }

    static func removing(_ id: String, from photos: [PendingPhotoAttachment]) -> Removal {
        let remaining = photos.filter { $0.id != id }
        return Removal(
            photos: remaining,
            clearsPicker: true,
            suppressesNextEmptySelection: !remaining.isEmpty
        )
    }
}

enum PhotosPickerLoadPresentation {
    /// The Photos picker can successfully return selections that cannot fit the
    /// signed CloudKit turn. If every selection is rejected, the composer has
    /// no thumbnail strip, so the message must say that no attachment was
    /// added rather than merely naming the rejected source files.
    static func message(loadedCount: Int, skippedCount: Int) -> String? {
        guard skippedCount > 0 else { return nil }
        if loadedCount == 0 {
            return skippedCount == 1
                ? "No photo was added because it was too large or unsupported. Try a smaller image."
                : "No photos were added because all \(skippedCount) were too large or unsupported. Try smaller images."
        }
        return skippedCount == 1
            ? "One photo was too large or unsupported; \(loadedCount) photo\(loadedCount == 1 ? "" : "s") is ready to send."
            : "\(skippedCount) photos were too large or unsupported; \(loadedCount) photo\(loadedCount == 1 ? "" : "s") \(loadedCount == 1 ? "is" : "are") ready to send."
    }
}

enum VoicePresentation {
    static func deniedSpeechMessage() -> String {
        "Speech recognition permission denied. Enable it in Settings."
    }

    static func deniedMicrophoneMessage() -> String {
        "Microphone permission denied. Enable it in Settings."
    }

}
