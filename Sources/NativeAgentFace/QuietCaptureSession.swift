import AppKit
import Foundation
import ImageIO
import NativeAgentShared
import QuickLookThumbnailing
import WebKit
// Blueprint: | `QuietCaptureSession.swift` | Read-only capture assets, native preview completion receipts and scoped resource settlement |

@MainActor
final class QuietCaptureSession {
    let pane: WorkPaneSnapshot?
    private(set) var make: MakePreviewFace?
    private(set) var makeImage: NSImage?
    private(set) var makeReadState: FaceReadState?
    private(set) var screenData: Data?
    private(set) var screenImage: NSImage?
    private(set) var attachmentImages: [String: NSImage] = [:]
    private(set) var resources: [FaceResourceAccess.Opened] = []
    private var shelf: MakeShelfFace?
    private var sense: SenseViewFace?
    private var web: [QuietWebCapture] = []
    private var thumbnail: QuietThumbnailCapture?
    private var closed = false
    private let session: String?
    private let reader: UUID
    private var attachmentReads: [String: FaceResolvedAttachment] = [:]

    init(pane: WorkPaneSnapshot?, session: String?, reader: UUID) {
        self.pane = pane; self.session = session; self.reader = reader
    }

    func prepare(appModel: AppModel, size: CGSize) async throws {
        if let session {
            if let bytes = appModel.turnFace(for: session)?.preview?.imageData {
                screenData = bytes
                screenImage = try await Self.decode(bytes)
            }
            guard let script = appModel.face.slot(.transcript(session: session)).value(as: TranscriptFace.self)?.readers[reader] else {
                throw Self.failure("The conversation's prepared capture reader has closed.")
            }
            let paragraphs = script.edits.flatMap(\.inserted)
            let imageIDs = Set(paragraphs.compactMap { paragraph -> String? in
                if case .attachment(.image) = paragraph.block.kind { return paragraph.block.id }
                return nil
            })
            let attachments = appModel.face.slot(.conversation(session: session)).value(as: ConversationFace.self)?.attachments ?? []
            for attachment in attachments where imageIDs.contains(attachment.id) {
                attachmentReads[attachment.id] = attachment
                if let failure = attachment.failure { throw failure }
                guard let resource = attachment.resource else { continue }
                let bytes = try await TranscriptResource.bytes(resource)
                attachmentImages[attachment.id] = try await Self.decode(bytes)
            }
        }
        guard let pane, pane.isVisible else { return }
        guard let sense = appModel.face.slot(.senseView).value(as: SenseViewFace.self) else {
            throw Self.failure("The Work pane has no prepared Sense reading.")
        }
        self.sense = sense
        if pane.tab == "sense", !(try Self.ready(sense.state)) { return }
        guard pane.tab == "make" else { return }
        guard let shelf = appModel.face.slot(.makeShelf).value(as: MakeShelfFace.self) else {
            throw Self.failure("The Make shelf has no prepared reading.")
        }
        self.shelf = shelf
        makeReadState = shelf.state
        guard try Self.ready(shelf.state) else { return }
        let reference = pane.reference ?? shelf.newest
        guard let reference else { return }
        guard let version = shelf.versions.last(where: { $0.reference == reference && (pane.version == nil || $0.version == pane.version) }),
              let preview = appModel.face.slot(.makePreview(reference: reference, version: version.version)).value(as: MakePreviewFace.self) else {
            throw Self.failure("The selected Make version has no prepared preview.")
        }
        makeReadState = preview.state
        guard try Self.ready(preview.state) else { return }
        make = preview
        if let key = preview.titleKey {
            guard let title = appModel.face.slot(key).value(as: PartFaceSnapshot.self), title.face != nil else {
                throw Self.failure("The Make preview title has not been prepared.")
            }
            if let failure = title.error { throw failure }
        }
        for grant in preview.resources {
            let opened = try await FaceResourceAccess.resolve(grant)
            resources.append(opened)
            try Task.checkCancellation()
        }
        guard let first = resources.first else {
            if preview.text != nil { return }
            throw Self.failure("The Make preview has no granted resource or prepared text.")
        }
        switch preview.kind {
        case "image":
            let bytes = try await FaceResourceAccess.bytes(first.url)
            makeImage = try await Self.decode(bytes)
        case "web":
            guard resources.dropFirst().first != nil else { throw Self.failure("The Make mockup has no granted resource folder.") }
        case "file":
            let read = QuietThumbnailCapture(file: first.url, size: size)
            thumbnail = read
            let bytes = try await read.read()
            makeImage = try await Self.decode(bytes)
        default: throw Self.failure("The Make preview supplied no supported native rendering kind.")
        }
        try Task.checkCancellation()
        try validate(appModel: appModel)
    }

    func validate(appModel: AppModel) throws {
        guard !closed else { throw CancellationError() }
        if let session {
            guard appModel.activeChatSessionId == session else { throw Self.failure("The captured conversation changed during preparation.") }
            guard appModel.turnFace(for: session)?.preview?.imageData == screenData else {
                throw Self.failure("The conversation's screen preview changed during preparation.")
            }
            let current = appModel.face.slot(.conversation(session: session)).value(as: ConversationFace.self)?.attachments ?? []
            for (id, attachment) in attachmentReads where current.first(where: { $0.id == id }) != attachment {
                throw Self.failure("A captured image attachment changed during preparation.")
            }
        }
        if let pane, WorkPaneState.shared.snapshot(appModel: appModel) != pane {
            throw Self.failure("The Work pane selection changed while its capture was being prepared.")
        }
        if let shelf, appModel.face.slot(.makeShelf).value(as: MakeShelfFace.self) != shelf {
            throw Self.failure("The Make shelf changed while its capture was being prepared.")
        }
        if let make, appModel.face.slot(.makePreview(reference: make.reference, version: make.version)).value(as: MakePreviewFace.self) != make {
            throw Self.failure("The Make preview changed while its capture was being prepared.")
        }
        if let sense, pane?.tab == "sense", appModel.face.slot(.senseView).value(as: SenseViewFace.self) != sense {
            throw Self.failure("The Sense view changed while its capture was being prepared.")
        }
    }

    func register(_ view: WKWebView, cancel: @escaping @MainActor () -> Void) -> QuietWebCapture {
        let receipt = QuietWebCapture(view: view, stop: cancel)
        web.append(receipt)
        if closed { receipt.close() }
        return receipt
    }

    func images(in hosting: NSView) async throws -> [(CGRect, NSImage)] {
        var images: [(CGRect, NSImage)] = []
        let receipts = web
        for receipt in receipts {
            let bytes = try await receipt.image()
            try Task.checkCancellation()
            guard receipt.view.isDescendant(of: hosting) else { throw Self.failure("A native preview left its capture layout.") }
            images.append((receipt.view.convert(receipt.view.bounds, to: hosting), try await Self.decode(bytes)))
        }
        guard receipts.map(ObjectIdentifier.init) == web.map(ObjectIdentifier.init) else {
            throw Self.failure("The native preview layout changed while its capture was being prepared.")
        }
        return images
    }

    func close() {
        guard !closed else { return }
        closed = true
        thumbnail?.cancel()
        thumbnail = nil
        for receipt in web { receipt.close() }
        web.removeAll()
        for resource in resources where resource.scoped { resource.url.stopAccessingSecurityScopedResource() }
        resources.removeAll()
    }

    @concurrent static func decode(_ data: Data) async throws -> sending NSImage {
        let options = [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options), CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, options) else {
            throw PartCallError(code: "capture_image_unreadable", message: "The captured image could not be decoded.")
        }
        return NSImage(cgImage: image, size: .zero)
    }

    private static func ready(_ state: FaceReadState) throws -> Bool {
        switch state {
        case .ready: return true
        case .unavailable(let failure): throw failure
        case .waiting: return false
        }
    }
    static func failure(_ message: String) -> PartCallError { .init(code: "capture_preview_unavailable", message: message) }
}

@MainActor
final class QuietWebCapture {
    let view: WKWebView
    private let stop: @MainActor () -> Void
    private var loaded = false
    private var requested = false
    private var closed = false
    private var result: Result<Data, Error>?
    private var continuation: CheckedContinuation<Data, Error>?

    init(view: WKWebView, stop: @escaping @MainActor () -> Void) { self.view = view; self.stop = stop }
    func navigationFinished() { loaded = true; snapshotIfReady() }
    func failed(_ error: Error) { finish(.failure(error)) }

    func image() async throws -> Data {
        try Task.checkCancellation()
        if let result { return try result.get() }
        guard continuation == nil else { throw QuietCaptureSession.failure("The native preview already has a capture reader.") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                snapshotIfReady()
            }
        } onCancel: { Task { @MainActor in self.close() } }
    }

    private func snapshotIfReady() {
        guard loaded, continuation != nil, !requested, result == nil else { return }
        requested = true
        guard view.bounds.width.isFinite, view.bounds.height.isFinite, view.bounds.width > 0, view.bounds.height > 0 else {
            failed(QuietCaptureSession.failure("The native web preview has no laid-out viewport.")); return
        }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = view.bounds
        configuration.afterScreenUpdates = true
        view.takeSnapshot(with: configuration) { [weak self] image, error in
            guard let self else { return }
            if let error { failed(error); return }
            guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                failed(QuietCaptureSession.failure("WebKit returned no encodable preview bitmap.")); return
            }
            finish(.success(png))
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
    func close() {
        guard !closed else { return }
        closed = true
        finish(.failure(CancellationError()))
        view.stopLoading()
        stop()
    }
}

@MainActor
private final class QuietThumbnailCapture {
    private let request: QLThumbnailGenerator.Request
    private var continuation: CheckedContinuation<Data, Error>?
    private var result: Result<Data, Error>?
    init(file: URL, size: CGSize) {
        request = .init(fileAt: file, size: size, scale: 1, representationTypes: .thumbnail)
        request.iconMode = false
    }
    func read() async throws -> Data {
        try Task.checkCancellation()
        if let result { return try result.get() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
                    let result = Self.encode(representation, error: error)
                    Task { @MainActor in self.finish(result) }
                }
            }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }
    nonisolated private static func encode(_ representation: QLThumbnailRepresentation?, error: Error?) -> Result<Data, Error> {
        if let error { return .failure(error) }
        guard let representation, representation.type == .thumbnail,
              let png = NSBitmapImageRep(cgImage: representation.cgImage).representation(using: .png, properties: [:]) else {
            return .failure(PartCallError(code: "capture_quicklook_unavailable", message: "Quick Look supplied no artifact thumbnail."))
        }
        return .success(png)
    }
    private func finish(_ result: Result<Data, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
    func cancel() { QLThumbnailGenerator.shared.cancel(request); finish(.failure(CancellationError())) }
}
