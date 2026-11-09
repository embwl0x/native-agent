import Foundation
import Observation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
// Blueprint: | `FaceDocumentView.swift` | Held document reads and the shared read-only TextKit view, selection, Find and Copy |

@MainActor @Observable public final class FaceDocumentReads {
    struct Reading {
        let request: FaceReadRequest
        var holders: Set<UUID>
        var text: String?
        var failure: String?
        var cancelled = false
        var task: Task<Void, Never>?
    }
    private(set) var readings: [String: Reading] = [:]
    var projection: PartFace?
    public init() {}

    /// The page host holds reads; mounting or recycling a document's drawing starts nothing.
    func hold(_ blocks: [PartFace.Block], by viewer: UUID, door: any FaceDoor) {
        release(viewer, keeping: blocks)
        for block in blocks {
            if var held = readings[block.key], held.request.matches(block) {
                if held.holders.insert(viewer).inserted { readings[block.key] = held }
            } else {
                readings.removeValue(forKey: block.key)?.task?.cancel()
                read(block, viewer: viewer, door: door)
            }
        }
    }

    func release(_ viewer: UUID, keeping blocks: [PartFace.Block] = []) {
        for (key, var held) in Array(readings) {
            if blocks.contains(where: held.request.matches) { continue }
            guard held.holders.remove(viewer) != nil else { continue }
            if held.holders.isEmpty { readings.removeValue(forKey: key)?.task?.cancel() }
            else { readings[key] = held }
        }
    }

    private func read(_ block: PartFace.Block, viewer: UUID, door: any FaceDoor) {
        let request = FaceReadRequest(id: UUID(), key: block.key, expectedCall: block.read, revision: block.revision)
        readings[block.key] = Reading(request: request, holders: [viewer])
        let task = Task {
            do {
                let text = try await door.read(request)
                try Task.checkCancellation()
                guard readings[block.key]?.request == request else { return }
                readings[block.key]?.text = text
            } catch is CancellationError {
                if readings[block.key]?.request == request { readings[block.key]?.cancelled = true }
            } catch {
                if readings[block.key]?.request == request {
                    if Task.isCancelled { readings[block.key]?.cancelled = true }
                    else { readings[block.key]?.failure = error.localizedDescription }
                }
            }
            if readings[block.key]?.request == request { readings[block.key]?.task = nil }
        }
        readings[block.key]?.task = task
    }

    func cancel(_ key: String) {
        readings[key]?.cancelled = true
        readings[key]?.task?.cancel()
    }
}

private extension FaceReadRequest {
    func matches(_ block: PartFace.Block) -> Bool {
        key == block.key && expectedCall == block.read && revision == block.revision
    }
}

struct FaceDocumentBlock: View {
    let block: PartFace.Block
    let session: FacePageSession
    let door: any FaceDoor
    @Environment(\.faceStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if block.kind != "document" { Text(PartFace.Block.updateNote).font(style.detail).foregroundStyle(.secondary) }
            else if let text = block.text { FaceLongText(text: text, format: block.format, copy: block.copy != false).id([text, block.format ?? ""]) }
            else if let reading = session.documents.readings[block.key], reading.request.matches(block) {
                if let text = reading.text { FaceLongText(text: text, format: block.format, copy: block.copy != false).id([text, block.format ?? ""]) }
                else if let failure = reading.failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
                else if reading.cancelled { Text("Stopped waiting for the document.").foregroundStyle(.secondary) }
                else {
                    HStack {
                        Text("Waiting on " + door.waitingOn + "…")
                        Spacer()
                        Button("Cancel") { session.documents.cancel(block.key) }
                    }.font(style.detail)
                }
            } else { Text("Waiting on the document…").font(style.detail).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(style.insets)
    }
}

/// Native readouts supply the owner answer without putting a long body in a face value.
public struct FaceDocumentContent: View {
    private let text: String
    private let format: String?
    private let rows: [PartFace.Row]
    public init(text: String, format: String? = nil, rows: [PartFace.Row] = []) {
        self.text = text; self.format = format; self.rows = rows
    }
    /// A native readout already holds the whole record. Its body belongs to the document reader, not a row's clipped detail.
    public init(row: PartFace.Row, format: String? = nil) {
        var metadata = row
        metadata.detail = nil
        self.init(text: row.detail ?? "", format: format, rows: [metadata])
    }
    public var body: some View {
        FaceDocumentReader(identity: [text, format ?? ""], format: format, rows: rows, read: { _ in text })
    }
}

/// A passive document page holds its read for exactly as long as it is mounted.
public struct FaceDocumentReader: View {
    private let identity: AnyHashable
    private let title: String?
    private let format: String?
    private let cancellationLabel: String
    private let waitingOn: String
    private let rows: [PartFace.Row]
    fileprivate enum Reader {
        case text((FaceReadRequest) async throws -> String)
        case presentation((FaceReadRequest) async throws -> FaceDocumentPresentation)
    }
    private let reader: Reader
    public init(identity: some Hashable, title: String? = nil, format: String? = nil, cancellationLabel: String = "Cancel", waitingOn: String = "the document",
                rows: [PartFace.Row] = [],
                read: @escaping (FaceReadRequest) async throws -> String) {
        self.identity = AnyHashable(identity)
        self.title = title; self.format = format; self.cancellationLabel = cancellationLabel; reader = .text(read)
        self.waitingOn = waitingOn
        self.rows = rows
    }
    public init(identity: some Hashable, title: String? = nil, cancellationLabel: String = "Cancel", waitingOn: String = "the document",
                presentation: @escaping (FaceReadRequest) async throws -> FaceDocumentPresentation) {
        self.identity = AnyHashable(identity)
        self.title = title; format = nil; self.cancellationLabel = cancellationLabel; reader = .presentation(presentation)
        self.waitingOn = waitingOn
        rows = []
    }
    public var body: some View {
        FaceDocumentReaderBody(title: title, format: format, cancellationLabel: cancellationLabel,
                               waitingOn: waitingOn, rows: rows, reader: reader).id(identity)
    }
}

private struct FaceDocumentReaderBody: View {
    let title: String?
    let format: String?
    let cancellationLabel: String
    let waitingOn: String
    let rows: [PartFace.Row]
    let reader: FaceDocumentReader.Reader
    @State private var session = FacePageSession()

    var body: some View {
        FaceView(face: session.documents.projection
                    ?? PartFace(title: title, sections: (rows.isEmpty ? [] : [.init(id: "facts", style: .values, rows: rows)])
                        + [.init(id: "document", rows: [], block: .init(key: "body", format: format))]),
                 door: ClosureFaceDoor(open: { _ in }, cancellationLabel: cancellationLabel, waitingOn: waitingOn, read: { request in
                     switch reader {
                     case .text(let read): return try await read(request)
                     case .presentation(let read):
                         let answer = try await read(request)
                         try Task.checkCancellation()
                         session.documents.projection = answer.face
                         return answer.text
                     }
                 },
                                       perform: { _ in FaceActOutcome(effects: .none) }), session: session)
    }
}

/// TextKit owns glyph layout and scroll; the surrounding face supplies its card and type.
public struct FaceLongText: View {
    public let text: String
    public let format: String?
    public let copy: Bool
    @State private var find = UUID()
    @State private var markdown: AttributedString?
    @State private var formattingIssue: String?
    @State private var formattingCancelled = false
    @State private var formatting: Task<Void, Never>?
    public init(text: String, format: String? = nil, copy: Bool = true) { self.text = text; self.format = format; self.copy = copy }
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer()
                Button("Find", systemImage: "magnifyingglass") { find = UUID() }
                if copy, format != "markdown" || markdown != nil {
                    Button("Copy", systemImage: "doc.on.doc") {
                        let shown = if let markdown { String(markdown.characters) } else { text }
                        #if os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(shown, forType: .string)
                        #else
                        UIPasteboard.general.string = shown
                        #endif
                    }
                }
            }.buttonStyle(.borderless).font(.caption)
            Group {
                if format != "markdown" || markdown != nil {
                    FaceTextKit(text: text, code: format == "code", markdown: markdown, find: find)
                } else if let formattingIssue { Text(formattingIssue).foregroundStyle(.red).textSelection(.enabled) }
                else if formattingCancelled { Text("Document formatting cancelled.").foregroundStyle(.secondary) }
                else {
                    HStack {
                        Text("Preparing document…")
                        Button("Cancel") { formatting?.cancel() }
                    }
                }
            }
                .frame(minHeight: 180, idealHeight: 360, maxHeight: 480)
                .accessibilityLabel("Document")
        }
        .task(id: format == "markdown" ? text : nil) {
            guard format == "markdown" else { markdown = nil; return }
            markdown = nil
            formattingIssue = nil
            formattingCancelled = false
            let task = Task {
                do {
                    let value = try await Self.parse(text)
                    try Task.checkCancellation()
                    markdown = value
                } catch is CancellationError { formattingCancelled = true }
                catch { formattingIssue = error.localizedDescription }
            }
            formatting = task
            await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            formatting = nil
        }
    }

    @concurrent nonisolated private static func parse(_ text: String) async throws -> AttributedString {
        try Task.checkCancellation()
        return try AttributedString(markdown: text, options: .init(interpretedSyntax: .full, failurePolicy: .throwError))
    }
}

#if os(macOS)
private struct FaceTextKit: NSViewRepresentable {
    let text: String
    let code: Bool
    let markdown: AttributedString?
    let find: UUID
    final class Coordinator {
        var find: UUID
        init(_ find: UUID) { self.find = find }
    }
    func makeCoordinator() -> Coordinator { Coordinator(find) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = NSTextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 4, height: 4)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: 0)
        scroll.findBarPosition = .aboveContent
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if let markdown {
            let value = NSAttributedString(markdown)
            if view.attributedString() != value { view.textStorage?.setAttributedString(value) }
        } else if view.string != text { view.string = text }
        view.font = code ? .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular) : .systemFont(ofSize: NSFont.systemFontSize)
        view.textColor = .labelColor
        if context.coordinator.find != find {
            context.coordinator.find = find
            scroll.window?.makeFirstResponder(view)
            let command = NSMenuItem()
            command.tag = NSTextFinder.Action.showFindInterface.rawValue
            view.performTextFinderAction(command)
        }
    }
}
#else
private struct FaceTextKit: UIViewRepresentable {
    let text: String
    let code: Bool
    let markdown: AttributedString?
    let find: UUID
    final class Coordinator {
        var find: UUID
        init(_ find: UUID) { self.find = find }
    }
    func makeCoordinator() -> Coordinator { Coordinator(find) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.isFindInteractionEnabled = true
        view.backgroundColor = .clear
        view.adjustsFontForContentSizeCategory = true
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        if let markdown {
            let value = NSAttributedString(markdown)
            if view.attributedText != value { view.attributedText = value }
        } else if view.text != text { view.text = text }
        view.font = code ? .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
            : .preferredFont(forTextStyle: .body)
        view.textColor = .label
        if context.coordinator.find != find {
            context.coordinator.find = find
            view.findInteraction?.presentFindNavigator(showingReplace: false)
        }
    }
}
#endif
