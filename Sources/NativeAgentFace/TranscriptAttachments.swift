import AppKit
import Foundation
import NativeAgentShared
import SwiftUI

/// Renderer diagnostics contain reader identities and geometry, never transcript words or body-store paths.
let transcriptLog = TranscriptDiagnostics()

/// The window's own record of what opened, followed, measured and loaded, beside FaceLink.log in her data root.
struct TranscriptDiagnostics: Sendable {
    private let fileName: String
    private let lane: DispatchQueue

    init(fileName: String = "TranscriptDocument.log") {
        self.fileName = fileName
        lane = DispatchQueue(label: "NativeAgentFace.diagnostics." + fileName, qos: .utility)
    }

    func callAsFunction(_ format: String, _ arguments: CVarArg...) {
        let message = arguments.isEmpty ? format : String(format: format, arguments: arguments)
        append { message }
    }

    /// The line is built on the diagnostics queue, so counting a large value costs the window nothing.
    func append(_ message: @escaping @Sendable () -> String) {
        guard let root = ProcessInfo.processInfo.environment["NATIVEAGENT_FACE_DATA_ROOT"], !root.isEmpty else { return }
        let at = Date()
        let fileName = fileName
        lane.async {
            let file = URL(fileURLWithPath: root).appendingPathComponent("diagnostics/" + fileName)
            do {
                if !FileManager.default.fileExists(atPath: file.path) { try Data().write(to: file, options: .withoutOverwriting) }
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                let stamp = at.ISO8601Format(.init(includingFractionalSeconds: true))
                try handle.write(contentsOf: Data((stamp + " face " + message() + "\n").utf8))
            } catch { NSLog("%@ diagnostic append failed: %@", fileName, error.localizedDescription) }
        }
    }
}

// Blueprint: | `TranscriptAttachments.swift` | Document view attachments: one hosted view per block id, fed from the model, sized to fit |

/// Retain one hosted view per block id; updates push the model and the controller places its measured frame.
@MainActor final class TranscriptAttachments {
    /// Set by the view. Called when a hosted view's height changes; the view re-lays that block's paragraph.
    var heightChanged: (_ blockID: String) -> Void = { _ in }
    /// Set by the view. An other-room row was clicked: open that contact thread.
    var openExchange: (OtherRoomExchange) -> Void = { _ in }
    var retryMessage: (String) -> Void = { _ in }

    private var entries: [String: Entry] = [:]
    private var data: TranscriptAttachmentData?
    private var environment: EnvironmentValues?
    private var columnWidth: CGFloat = 0
    /// Blocks whose size must be read again; read together on the next main-actor turn, outside any layout pass.
    private var pending: Set<String> = []
    private var measureScheduled = false

    init() {}

    /// The same block id returns the same attachment while the block lives.
    func attachment(blockID: String, ref: TranscriptAttachmentRef, role: String) -> NSTextAttachment {
        if let entry = entries[blockID] {
            // A growing reply can change what its block shows (a table gains rows) under the same id.
            if entry.ref != ref {
                entry.ref = ref
                entry.box.model = data.map { TranscriptAttachmentModel(ref, blockID: blockID, role: role, in: $0) }
                    ?? .waiting("Waiting on attachment data… Close this conversation to stop viewing it.")
                remeasure(blockID)
            }
            return entry.attachment
        }
        let model = data.map { TranscriptAttachmentModel(ref, blockID: blockID, role: role, in: $0) }
            ?? .waiting("Waiting on attachment data… Close this conversation to stop viewing it.")
        let box = TranscriptAttachmentBox(model: model, environment: environment)
        box.resized = { [weak self] in self?.remeasure(blockID) }
        box.open = { [weak self] exchange in self?.openExchange(exchange) }
        box.retry = { [weak self] message in self?.retryMessage(message) }
        // The controller's view (an NSHostingView) is the attachment's view; the controller measures it at the column width.
        let host = NSHostingController(rootView: TranscriptAttachmentRoot(box: box))
        // TextKit places the view by frame; the host neither drives Auto Layout nor insets for the window's bars.
        host.sizingOptions = []
        host.safeAreaRegions = []
        let entry = Entry(ref: ref, role: role, box: box, host: host, attachment: TranscriptAttachment(blockID: blockID))
        entries[blockID] = entry
        // Sized before TextKit first lays the paragraph out, so the first layout is the right one.
        measure(entry)
        transcriptLog("attach.new block=%@ column=%.0f size=%.0fx%.0f", blockID, columnWidth,
                      entry.attachment.bounds.width, entry.attachment.bounds.height)
        return entry.attachment
    }

    /// Fresh data, SwiftUI environment and column width before every document edit; live hosted views refresh from it.
    func update(_ data: TranscriptAttachmentData, environment: EnvironmentValues, columnWidth: CGFloat) {
        let resized = columnWidth != self.columnWidth
        self.data = data
        self.environment = environment
        self.columnWidth = columnWidth
        for (blockID, entry) in entries {
            entry.box.environment = environment
            let model = TranscriptAttachmentModel(entry.ref, blockID: blockID, role: entry.role, in: data)
            if model != entry.box.model {
                entry.box.model = model
                remeasure(blockID)
            } else if resized {
                remeasure(blockID)
            }
        }
    }

    /// The view is a block's hosted view or inside one.
    func hosts(_ view: NSView) -> Bool {
        entries.values.contains { view.isDescendant(of: $0.host.view) }
    }

    /// Blocks gone from the document.
    func forget(_ blockIDs: Set<String>) {
        for blockID in blockIDs {
            entries[blockID]?.host.view.removeFromSuperview()
            entries[blockID] = nil
        }
        pending.subtract(blockIDs)
    }

    /// Place retained hosts at their laid-out attachment frames; hide hosts outside layout.
    func place(_ frames: [String: CGRect], in textView: NSView) {
        for (blockID, entry) in entries {
            let view = entry.host.view
            guard let frame = frames[blockID] else {
                if view.superview != nil, !view.isHidden { view.isHidden = true }
                continue
            }
            if view.superview !== textView { textView.addSubview(view) }
            if view.frame != frame { view.frame = frame }
            if view.isHidden { view.isHidden = false }
        }
    }

    private func remeasure(_ blockID: String) {
        pending.insert(blockID)
        guard !measureScheduled else { return }
        measureScheduled = true
        Task { @MainActor [weak self] in self?.measurePending() }
    }

    private func measurePending() {
        measureScheduled = false
        let blockIDs = pending
        pending = []
        for blockID in blockIDs {
            guard let entry = entries[blockID], measure(entry) else { continue }
            transcriptLog("attach.resized block=%@ size=%.0fx%.0f", blockID, entry.attachment.bounds.width, entry.attachment.bounds.height)
            heightChanged(blockID)
        }
    }

    /// The hosted view's fitting size at the column width: its own width up to the column (so paragraph alignment can seat it)
    /// and its whole height. Returns whether the size changed. Before the view gives a column width there is nothing to fit.
    @discardableResult
    private func measure(_ entry: Entry) -> Bool {
        guard columnWidth > 0 else { return false }
        let fit = entry.host.sizeThatFits(in: CGSize(width: columnWidth, height: .greatestFiniteMagnitude))
        let size = CGSize(width: min(fit.width.rounded(.up), columnWidth), height: fit.height.rounded(.up))
        guard size != entry.attachment.bounds.size else { return false }
        entry.attachment.bounds = CGRect(origin: .zero, size: size)
        return true
    }

    private final class Entry {
        var ref: TranscriptAttachmentRef
        let role: String
        let box: TranscriptAttachmentBox
        let host: NSHostingController<TranscriptAttachmentRoot>
        let attachment: TranscriptAttachment

        init(ref: TranscriptAttachmentRef, role: String, box: TranscriptAttachmentBox, host: NSHostingController<TranscriptAttachmentRoot>,
             attachment: TranscriptAttachment) {
            self.ref = ref
            self.role = role
            self.box = box
            self.host = host
            self.attachment = attachment
        }
    }
}

/// What the attachment side reads when it builds or refreshes a hosted view. The document view hands over a fresh snapshot before every edit.
struct TranscriptAttachmentData: Equatable {
    var sessionID: String
    var state: FaceReadState?
    var actions: [MessageActionFace]
    var attachments: [FaceResolvedAttachment]
    var visibleReply: VisibleReplyTarget?

    init(sessionID: String, conversation: ConversationFace?) {
        self.sessionID = sessionID
        state = conversation?.state
        actions = conversation.map(\.actions) ?? []
        attachments = conversation.map(\.attachments) ?? []
        visibleReply = conversation?.visibleReply
    }
}

/// What one live hosted view shows. The owner writes it on every update; the view reads it, so an answered card or a loaded
/// image redraws in place.
@MainActor @Observable
final class TranscriptAttachmentBox {
    var model: TranscriptAttachmentModel
    /// The transcript host's whole SwiftUI environment; nil until the view's first update, and nothing draws before it.
    var environment: EnvironmentValues?
    @ObservationIgnored var resized: () -> Void = {}
    @ObservationIgnored var open: (OtherRoomExchange) -> Void = { _ in }
    @ObservationIgnored var retry: (String) -> Void = { _ in }

    init(model: TranscriptAttachmentModel, environment: EnvironmentValues?) {
        self.model = model
        self.environment = environment
    }
}

/// Resolve an attachment's reference against the document's input snapshot.
enum TranscriptAttachmentModel: Equatable {
    case resolved(FaceResolvedAttachment, ref: TranscriptAttachmentRef, role: String)
    case table(ChatMarkdownTable, cells: [[AttributedString]])
    case otherRoom(OtherRoomExchange)
    case waiting(String)
    case unavailable(String)

    init(_ ref: TranscriptAttachmentRef, blockID: String, role: String, in data: TranscriptAttachmentData) {
        switch ref {
        case .table(let table):
            let cells = ([table.header] + table.rows).map { row in
                (0..<table.columnCount).map { ChatRichContentParser.inline(table.cell(row, $0)).presentation }
            }
            self = .table(table, cells: cells)
        case .otherRoom(let exchange): self = .otherRoom(exchange)
        default:
            guard let state = data.state else {
                self = .waiting("Waiting on conversation attachments… Close this conversation to stop viewing it.")
                return
            }
            if case .unavailable(let failure) = state {
                self = .unavailable(failure.localizedDescription)
                return
            }
            if let attachment = data.attachments.first(where: { $0.id == blockID }) {
                self = .resolved(attachment, ref: ref, role: role)
                return
            }
            switch state {
            case .waiting(let owner): self = .waiting("Waiting on \(owner)… Close this conversation to stop viewing it.")
            case .unavailable(let failure): self = .unavailable(failure.localizedDescription)
            case .ready:
                self = .waiting("Waiting on attachment \(blockID)'s resolved presentation. Its absence does not settle it.")
            }
        }
    }
}

/// TextKit reserves the measured room; the document controller places the hosted view over it.
final class TranscriptAttachment: NSTextAttachment {
    let blockID: String

    init(blockID: String) {
        self.blockID = blockID
        super.init(data: Data(blockID.utf8), ofType: "com.nativeagent.transcript.attachment")
        allowsTextAttachmentView = false
    }

    required init?(coder: NSCoder) { nil }

    /// The hosted view is the only drawing; there is no image under it.
    override func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                        textContainer: NSTextContainer?) -> NSImage? { nil }

    /// The hosted view's measured size (kept in `bounds` by the owner), never wider than the line; zero until measured.
    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        CGRect(x: 0, y: 0, width: min(bounds.width, proposedLineFragment.width), height: bounds.height)
    }
}
