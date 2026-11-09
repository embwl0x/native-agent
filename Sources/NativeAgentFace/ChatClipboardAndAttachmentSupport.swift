import Foundation
import AppKit
import SwiftUI
import NativeAgentShared
// Blueprint: | `ChatClipboardAndAttachmentSupport.swift` | Picker, paste and drop transfers; body attachment validation, capture and voice acts |

extension NativeAgentShared.ChatAttachmentTypeResolver {
    static let attachmentTypeIdentifiers = ["public.file-url", "public.image"]

    @MainActor
    static func beginDictation(
        _ input: FaceVoiceInput, client: any FaceClient, draft: ChatComposerDraft, isCurrent: () -> Bool,
        prepareDraft: (String, UInt64) -> Void, showToast: (String) -> Void
    ) async -> Bool {
        guard isCurrent() else { return false }
        prepareDraft(draft.text, draft.manualEditRevision)
        showToast("Checking microphone…")
        do {
            let started = try await input.start(client: client, session: draft.sessionId, revision: draft.manualEditRevision)
            guard isCurrent() else { input.discardListening(); return false }
            if started.phase == .listening { showToast("Listening") }
            return started.phase == .listening
        } catch { showToast(error.localizedDescription); return false }
    }

    @MainActor
    struct ScreenshotDraft {
        let text: String
        let editedAt: Date
        let revision: UInt64
        let session: String
        let attachments: [FaceAttachment]

        init(_ draft: ChatComposerDraft, attachments: [FaceAttachment]) {
            text = draft.text; editedAt = draft.editedAt
            revision = draft.manualEditRevision; session = draft.sessionId
            self.attachments = attachments
        }

        func clearIfUnchanged(appModel: AppModel, draft: ChatComposerDraft, attachments current: inout [FaceAttachment]) -> Bool {
            guard draft.text == text, draft.editedAt == editedAt, draft.manualEditRevision == revision,
                  current == attachments else { return false }
            appModel.clearChatDraftAfterSend(text, sessionId: draft.sessionId, editedAt: editedAt)
            current = []
            return true
        }
    }

    @MainActor
    static func sendScreenshot(
        _ draft: ScreenshotDraft, client: any FaceClient, expectedSelection: String?, canSubmit: () -> Bool,
        submit: @MainActor (String, [FaceAttachment]) async -> AppModel.ChatTurnAcceptance,
        accepted: (String) -> Void, showToast: (String) -> Void
    ) async {
        do {
            let id = UUID()
            let request = ScreenCaptureRequest(operation: id, session: draft.session, composerRevision: draft.revision,
                                               expectedSelection: expectedSelection, sendWithText: nil)
            let attachment = try admittedAttachment(try await client.act(.captureScreen(request)), id: id.uuidString, warning: showToast)
            guard canSubmit() else { return }
            let prompt = draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Look at this screenshot and tell me what you see." : draft.text
            switch await submit(prompt, draft.attachments + [attachment]) {
            case .accepted(let session): accepted(session)
            case .rejected(let message): showToast(message)
            }
        } catch { showToast(error.localizedDescription) }
    }

    @MainActor
    static func finishDictation(
        _ input: FaceVoiceInput, draft: ChatComposerDraft, revision: UInt64,
        isCurrent: () -> Bool, base: () -> String, finished: () -> Void,
        attach: (FaceAttachment) -> Void, showToast: (String) -> Void
    ) async -> Bool {
        do {
            let result = try await input.finish()
            guard isCurrent() else { return false }
            defer { finished() }
            guard draft.manualEditRevision == revision else { return true }
            guard result.phase == .finished, let final = result.text,
                  ChatTranscriptPresentation.hasVisibleText(final) else {
                draft.edit(base())
                showToast(result.phase == .cancelled ? "Dictation cancelled" : "No speech detected")
                return false
            }
            draft.edit(voiceDraft(base: base(), transcript: final))
            if let attachment = result.attachment { attach(attachment) }
            return true
        } catch {
            if isCurrent() { finished() }
            showToast(error.localizedDescription)
            return false
        }
    }

    static func voiceDraft(base: String, transcript: String) -> String {
        let base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return spoken }
        if spoken.isEmpty { return base }
        return base + " " + spoken
    }

    /// A transfer's reply contains the validated resource; no renderer path grants body authority.
    static func admittedAttachment(_ reply: FaceActReply, id: String, warning: (String) -> Void) throws -> FaceAttachment {
        switch reply {
        case .artifact(let artifact):
            guard artifact.bytes != nil || artifact.resource != nil else {
                throw WireFailure(code: "attachment_missing", message: "The attachment reply has no bytes or resource.", cause: nil, effects: .unknown)
            }
            if !artifact.warnings.isEmpty { warning(artifact.warnings.joined(separator: "\n")) }
            return FaceAttachment(id: id, name: artifact.name, mimeType: artifact.mimeType,
                                  byteCount: artifact.bytes?.count ?? 0, resource: artifact.resource, bytes: artifact.bytes)
        case .refused(let failure), .failed(let failure): throw failure
        default:
            throw WireFailure(code: "attachment_reply_mismatch", message: "I did not return a validated attachment.", cause: nil, effects: .unknown)
        }
    }

    @MainActor
    static func ingest(
        _ attachment: FaceAttachment, appModel: AppModel, session: String, showWarning: (String) -> Void
    ) async throws -> FaceAttachment {
        let reply = try await appModel.chatAct(.ingestAttachment(AttachmentTransfer(id: UUID(), session: session, attachment: attachment)))
        return try admittedAttachment(reply, id: attachment.id, warning: showWarning)
    }

    @MainActor
    static func attachFromClipboardOrPickFile(
        appModel: AppModel, session: String,
        appendImage: @escaping @MainActor (FaceAttachment) -> Void,
        attachFile: @escaping @MainActor (URL) -> Void,
        showToast: @escaping @MainActor (String) -> Void,
        emptySelectionMessage: String? = nil
    ) {
        let pasteboard = NSPasteboard.general
        if let type = imageType(in: (pasteboard.types ?? []).map(\.rawValue)) {
            guard let bytes = pasteboard.data(forType: .init(type)), let mime = imageMIME(type) else {
                showToast("Couldn't read the clipboard image"); return
            }
            Task {
                do {
                    let attachment = FaceAttachment(id: UUID().uuidString, name: "Clipboard image", mimeType: mime,
                                                    byteCount: bytes.count, resource: nil, bytes: bytes)
                    appendImage(try await ingest(attachment, appModel: appModel, session: session, showWarning: showToast))
                } catch { showToast(error.localizedDescription) }
            }
            return
        }
        guard let urls = pickAttachmentFiles() else { return }
        if urls.isEmpty, let emptySelectionMessage { showToast(emptySelectionMessage) }
        for url in urls { attachFile(url) }
    }

    static func imageType(in identifiers: [String]) -> String? {
        identifiers.first { imageMIME($0) != nil }
    }

    nonisolated static func loadProviderData(
        _ provider: NSItemProvider, type: String, completion: @escaping @Sendable (Data?, String?) -> Void
    ) {
        provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in completion(data, error?.localizedDescription) }
    }

    static func imageMIME(_ identifier: String) -> String? {
        switch identifier {
        case "public.png": "image/png"
        case "public.jpeg": "image/jpeg"
        case "public.tiff": "image/tiff"
        case "public.heic": "image/heic"
        case "com.compuserve.gif": "image/gif"
        case "org.webmproject.webp": "image/webp"
        default: nil
        }
    }

    @MainActor
    static func clipboardAttachmentProviders() -> [NSItemProvider] {
        (NSPasteboard.general.pasteboardItems ?? []).compactMap { item in
            if let value = item.string(forType: .fileURL), let url = URL(string: value), url.isFileURL {
                return NSItemProvider(item: url as NSURL, typeIdentifier: "public.file-url")
            }
            guard let type = imageType(in: item.types.map(\.rawValue)), let data = item.data(forType: .init(type)) else { return nil }
            return NSItemProvider(item: data as NSData, typeIdentifier: type)
        }
    }

    @MainActor
    static func attachProviders(
        _ providers: [NSItemProvider], appModel: AppModel, session: String,
        appendImage: @escaping @MainActor (FaceAttachment) -> Void,
        attachFile: @escaping @MainActor (URL) -> Void, showToast: @escaping @MainActor (String) -> Void
    ) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                loadProviderData(provider, type: "public.file-url") { data, failure in
                    let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    Task { @MainActor in
                        if let failure { showToast(failure); return }
                        guard let url, url.isFileURL else { showToast("Couldn't read the attached file"); return }
                        attachFile(url)
                    }
                }
            } else if let type = imageType(in: provider.registeredTypeIdentifiers), let mime = imageMIME(type) {
                loadProviderData(provider, type: type) { data, failure in
                    Task { @MainActor in
                        if let failure { showToast(failure); return }
                        guard let data else { showToast("Couldn't read the attached image"); return }
                        do {
                            let attachment = FaceAttachment(id: UUID().uuidString, name: "Attached image", mimeType: mime,
                                                            byteCount: data.count, resource: nil, bytes: data)
                            appendImage(try await ingest(attachment, appModel: appModel, session: session, showWarning: showToast))
                        } catch { showToast(error.localizedDescription) }
                    }
                }
            } else { showToast("Attach an image or a supported file") }
        }
    }

    @MainActor
    static func pickAttachmentFiles() -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .pdf, .plainText, .text, .data]
        panel.prompt = "Attach"; panel.message = "Choose an image or document to attach to your chat."
        return panel.runModal() == .OK ? panel.urls : nil
    }

    @MainActor
    static func attachLocalFile(
        _ url: URL, to appModel: AppModel, sessionId: @autoclosure () -> String,
        resolveType: (String) -> (type: String, mime: String)?,
        canAttach: @escaping @MainActor () -> Bool = { true }, showToast: @escaping @MainActor (String) -> Void
    ) {
        let session = sessionId()
        guard let kind = resolveType(url.pathExtension.lowercased()) else { showToast("Unsupported file type"); return }
        Task {
            do {
                let grant = try await Task.detached(priority: .userInitiated) {
                    let held = url.startAccessingSecurityScopedResource()
                    defer { if held { url.stopAccessingSecurityScopedResource() } }
                    return ResourceGrant(id: UUID(), name: url.lastPathComponent,
                                         bookmark: try url.bookmarkData(), writable: false)
                }.value
                let attachment = FaceAttachment(id: UUID().uuidString, name: grant.name, mimeType: kind.mime,
                                                byteCount: 0, resource: grant, bytes: nil)
                let admitted = try await ingest(attachment, appModel: appModel, session: session, showWarning: showToast)
                guard canAttach() else { return }
                appModel.chatPendingAttachments[session, default: []].append(admitted)
                showToast("Attached " + grant.name)
            } catch { showToast(error.localizedDescription) }
        }
    }
}

enum ChatClipboard {
    @MainActor static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
