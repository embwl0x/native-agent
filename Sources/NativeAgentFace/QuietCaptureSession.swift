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
    /// One Make version held for a picture: its decoded image, or the granted files a web preview loads.
    struct HeldMake {
        var image: NSImage?
        /// A table file, read whole, so a picture draws the table the window draws and not a thumbnail of its file.
        var table: SheetTable?
        var resources: [FaceResourceAccess.Opened] = []
    }
    private(set) var make: MakePreviewFace?
    /// Every Make version this picture draws, the pane's and each piece a page lays out, by reference and version.
    private(set) var makes: [String: HeldMake] = [:]
    private(set) var screenData: Data?
    private(set) var screenImage: NSImage?
    private(set) var attachmentImages: [String: NSImage] = [:]
    private var shelf: MakeShelfFace?
    private var sense: SenseViewFace?
    private var web: [QuietWebCapture] = []
    private var thumbnails: [QuietThumbnailCapture] = []
    /// The page whose pieces this picture draws, and the pieces it held for them.
    private let page: String?
    private var pieces: [String] = []
    private var observed: [UUID] = []
    private var client: (any FaceClient)?
    private var closed = false
    private let session: String?
    private let reader: UUID
    private var attachmentReads: [String: FaceResolvedAttachment] = [:]

    init(pane: WorkPaneSnapshot?, session: String?, reader: UUID, page: String? = nil) {
        self.pane = pane; self.session = session; self.reader = reader; self.page = page
    }

    /// The Make versions the page lays out right now, in the page's own order.
    private func laid(_ appModel: AppModel) -> [(reference: String, version: String)] {
        guard let page else { return [] }
        return appModel.face.slot(.page(page)).value(as: PartFaceSnapshot.self)?.drawnFace?.sections
            .compactMap { $0.block.flatMap(FacePageView.piece) } ?? []
    }

    func held(_ preview: MakePreviewFace) -> HeldMake? { makes[Self.key(preview.reference, preview.version)] }
    private static func key(_ reference: String, _ version: String) -> String { reference + "\n" + version }

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
        // A piece on the page is drawn like the window draws it. The picture asks the body for the piece's preview itself,
        // because a page that is not in front has no reader holding it.
        for piece in laid(appModel) where makes[Self.key(piece.reference, piece.version)] == nil {
            let key = FaceKey.makePreview(reference: piece.reference, version: piece.version)
            var preview = appModel.face.slot(key).value(as: MakePreviewFace.self)
            if preview?.state != .ready {
                // The reader is written down before it is asked for, so a picture stopped mid-ask still releases it.
                let id = UUID()
                client = appModel.client
                observed.append(id)
                try FaceWindowReply.check(try await appModel.client.act(.observe(id: id, demand: .key(key))))
                // Wait on the value itself: the body's answer wakes this, and a stopped picture ends it.
                let (changes, signal) = AsyncStream<Void>.makeStream()
                defer { signal.finish() }
                var events = changes.makeAsyncIterator()
                while true {
                    preview = withObservationTracking { appModel.face.slot(key).value(as: MakePreviewFace.self) } onChange: { signal.yield() }
                    if let state = preview?.state, try Self.ready(state) { break }
                    guard await events.next() != nil else { throw CancellationError() }
                }
            }
            guard let preview, try Self.ready(preview.state) else { continue }
            makes[Self.key(piece.reference, piece.version)] = try await hold(preview, size: size)
            pieces.append(Self.key(piece.reference, piece.version))
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
        guard try Self.ready(shelf.state) else { return }
        let reference = pane.reference ?? shelf.newest
        guard let reference else { return }
        guard let version = shelf.versions.last(where: { $0.reference == reference && (pane.version == nil || $0.version == pane.version) }),
              let preview = appModel.face.slot(.makePreview(reference: reference, version: version.version)).value(as: MakePreviewFace.self) else {
            throw Self.failure("The selected Make version has no prepared preview.")
        }
        guard try Self.ready(preview.state) else { return }
        make = preview
        if let key = preview.titleKey {
            guard let title = appModel.face.slot(key).value(as: PartFaceSnapshot.self), title.face != nil else {
                throw Self.failure("The Make preview title has not been prepared.")
            }
            if let failure = title.error { throw failure }
        }
        makes[Self.key(preview.reference, preview.version)] = try await hold(preview, size: size)
        try Task.checkCancellation()
        try validate(appModel: appModel)
    }

    /// Opens one ready preview's granted files and decodes what a native view would otherwise read while drawing.
    private func hold(_ preview: MakePreviewFace, size: CGSize) async throws -> HeldMake {
        var held = HeldMake()
        do {
            for grant in preview.resources {
                held.resources.append(try await FaceResourceAccess.resolve(grant))
                try Task.checkCancellation()
            }
            guard let first = held.resources.first else {
                if preview.text != nil { return held }
                throw Self.failure("The Make preview has no granted resource or prepared text.")
            }
            switch preview.kind {
            case "image":
                held.image = try await Self.decode(try await FaceResourceAccess.bytes(first.url))
            case "web" where !preview.isPicture:
                guard held.resources.dropFirst().first != nil else { throw Self.failure("The Make mockup has no granted resource folder.") }
            // ImageIO cannot decode an SVG; Quick Look draws it as the picture it is.
            case "file", "web":
                if let delimiter = SheetTable.delimiter(type: first.url.pathExtension),
                   let table = try await MakeSheetFile.table(first.url, delimiter: delimiter) {
                    held.table = table
                    break
                }
                let read = QuietThumbnailCapture(file: first.url, size: size)
                thumbnails.append(read)
                held.image = try await Self.decode(try await read.read())
            default: throw Self.failure("The Make preview supplied no supported native rendering kind.")
            }
            // A picture stopped while this was read has already let go of what it held; what was opened here goes with it.
            guard !closed else { throw CancellationError() }
            return held
        } catch {
            for resource in held.resources where resource.scoped { resource.url.stopAccessingSecurityScopedResource() }
            throw error
        }
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
        // A Make version never changes, so a piece is the same piece while the page still lays out the same versions.
        if page != nil, Set(laid(appModel).map { Self.key($0.reference, $0.version) }) != Set(pieces) {
            throw Self.failure("The page's pieces changed while its capture was being prepared.")
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
        for thumbnail in thumbnails { thumbnail.cancel() }
        thumbnails.removeAll()
        for receipt in web { receipt.close() }
        web.removeAll()
        for held in makes.values {
            for resource in held.resources where resource.scoped { resource.url.stopAccessingSecurityScopedResource() }
        }
        makes.removeAll()
        if let client {
            let ids = observed
            Task { for id in ids { _ = try? await client.act(.unobserve(id: id)) } }
        }
        observed.removeAll()
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
