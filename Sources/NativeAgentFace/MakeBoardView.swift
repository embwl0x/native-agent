import AppKit
import Combine
import CoreGraphics
import Foundation
import NativeAgentShared
import SwiftUI
// Blueprint: | `MakeBoardView.swift` | Mac board host: inline editor and wheel navigation, element-scoped Table writes, versioned Make saves |

extension EnvironmentValues {
    @Entry var boardFillsWindow = false
    @Entry var boardPage: String? = nil
}

/// One version of a board as read from Make.
struct BoardArrival: Equatable {
    let document: BoardDocument
    let version: String
}

/// A board's state for its Make ref, shared by every drawing of it and outliving each one: the newest version read from Make, and the
/// person's changes on their way into the next version. Changes go to Make one save at a time; one made while a save runs waits for it
/// and goes onto the version that save laid. A save Make refuses because a newer version exists (`version_superseded`, nothing written)
/// waits for that version to be read and is made again on it; any other failure is said as it was said and never made again, since
/// it may have landed: what landed is drawn when it is read.
@MainActor @Observable final class MakeBoardState {
    private static var boards: [String: MakeBoardState] = [:]
    static func of(_ reference: String) -> MakeBoardState {
        if let held = boards[reference] { return held }
        let made = MakeBoardState(reference)
        boards[reference] = made
        return made
    }
    static func number(_ version: String) -> Int { Int(version) ?? 0 }

    let reference: String
    private(set) var latest: BoardArrival?
    /// The newest version read from Make. A drawing of an older one is a look back: it is drawn as it is, and changes go on the newest.
    private(set) var read = 0
    private(set) var isSaving = false
    /// How many versions arrived that no save from here laid: a change begun before one of them lands on a newer version than it was made on.
    private(set) var newer = 0
    private var laying: [BoardEdit] = []
    /// The version the save under way was made on. Once a newer version is read, that version holds the save's change or Make will
    /// refuse it, so the change is no longer drawn on top of it.
    private var layingOn: String?
    /// The version a save was refused on for a newer one: the change waits until a version past it is read.
    private var refusedOn: String?
    private var waiting: [BoardEdit] = []
    private var laid: Set<String> = []
    private var onNewer = false

    private init(_ reference: String) { self.reference = reference }

    /// The board as the person sees it: the newest version with every change of theirs not yet laid.
    var current: BoardDocument? {
        guard let latest else { return nil }
        var document = latest.document
        for edit in (latest.version == layingOn ? laying : []) + waiting { _ = edit.apply(&document) }
        return document
    }

    func arrive(_ arrival: BoardArrival, appModel: AppModel) {
        read = max(read, Self.number(arrival.version))
        if let latest, Self.number(arrival.version) < Self.number(latest.version) { return }
        if arrival.version != latest?.version, !laid.contains(arrival.version) { newer += 1 }
        latest = arrival
        lay(appModel)
    }

    /// `seen` is `newer` when the change began: a version that came since means the change lands on a version it was not made on.
    func change(_ edit: BoardEdit, seen: Int, appModel: AppModel) {
        if seen != newer { onNewer = true }
        waiting.append(edit)
        lay(appModel)
    }

    private func lay(_ appModel: AppModel) {
        guard !isSaving, !waiting.isEmpty, let base = latest, base.version != refusedOn else { return }
        refusedOn = nil
        var document = base.document
        var changed = false
        for edit in waiting {
            if edit.apply(&document) { changed = true }
        }
        let told = onNewer
        laying = waiting
        waiting = []
        onNewer = false
        guard changed else {
            laying = []
            MakePieceWords.shared.said[reference] = "What you changed is not on the newest version of this board any more, so nothing was saved."
            return
        }
        isSaving = true
        layingOn = base.version
        MakePieceWords.shared.said[reference] = nil
        Task {
            var words: String?
            do {
                let saved = try await MakePieceSave.save(appModel, reference: reference, version: base.version,
                                                         name: reference + "." + BoardDocument.type, content: document.text)
                laid.insert(saved.version)
                if Self.number(saved.version) > Self.number(latest?.version ?? "0") {
                    latest = BoardArrival(document: document, version: saved.version)
                }
                words = told ? "This board changed while you were changing it, so your change is saved on top of the newer version." : saved.words
            } catch let failure as WireFailure where failure.code == "version_superseded" {
                // Nothing was written: the same change goes onto the newer version, now if it is read, else when it is.
                waiting = laying + waiting
                onNewer = true
                if latest?.version == base.version { refusedOn = base.version }
                words = Self.number(latest?.version ?? "0") > Self.number(base.version) ? nil
                    : "This board changed while you were changing it. Your change goes onto the newer version once it is here."
            } catch { words = error.localizedDescription }
            laying = []
            layingOn = nil
            isSaving = false
            if let words { MakePieceWords.shared.said[reference] = words }
            // The Make pane follows the newest version after a save, as it does for a table.
            WorkPaneState.shared.selectedMakeVersions[reference] = nil
            lay(appModel)
        }
    }
}

struct MacTableSlice: View {
    let block: PartFace.Block
    @Environment(AppModel.self) private var appModel
    @Environment(\.quietCaptureSession) private var capture
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var textScale = BoardGeometry.macTextScale

    var body: some View {
        if capture == nil { liveSlice }
        else { Text(block.alt ?? PartFace.Block.updateNote).foregroundStyle(.secondary) }
    }

    private var liveSlice: some View {
        let desk = appModel.face.slot(.page("desk")).value(as: PartFaceSnapshot.self)
        return Group {
            if let table = desk?.drawnFace?.sections.compactMap(\.block).first(where: \.isStandingTable), let version = table.revision {
                PageMakeBoard(reference: BoardDocument.tableRef, version: version, cards: table.cards ?? [:], slice: (block, textScale))
            } else {
                Text(block.alt ?? PartFace.Block.updateNote).foregroundStyle(.secondary)
            }
        }
        .modifier(FaceObservation(demand: .key(.page("desk"))))
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.AccessibilityDisplayOptionsDidChangeMessage.name)) { _ in
            textScale = BoardGeometry.macTextScale
        }
        .onChange(of: dynamicTypeSize, initial: true) { _, _ in textScale = BoardGeometry.macTextScale }
    }
}

/// A board piece on a page (the Desk), drawn across its versions: a new version replaces the one drawn only once it has been read, so a
/// card the person is holding stays in their hand and their change goes onto whatever arrived meanwhile.
struct PageMakeBoard: View {
    let reference: String
    let version: String
    var cards: [String: PartFace.Value] = [:]
    var choices: [[String: PartFace.Value]] = []
    let slice: (block: PartFace.Block, textScale: CGFloat)?
    @Environment(AppModel.self) private var appModel
    @Environment(\.quietCaptureSession) private var capture
    @Environment(\.boardFillsWindow) private var fillsWindow
    @State private var arrival: BoardArrival?
    @State private var issue: String?
    init(reference: String, version: String, cards: [String: PartFace.Value] = [:], choices: [[String: PartFace.Value]] = [],
         slice: (block: PartFace.Block, textScale: CGFloat)? = nil) {
        self.reference = reference; self.version = version; self.cards = cards; self.choices = choices
        self.slice = slice
        let empty = reference == BoardDocument.tableRef && version == "0"
        _arrival = State(initialValue: empty ? BoardArrival(document: BoardDocument(), version: "0") : nil)
    }
    private var key: FaceKey { .makePreview(reference: reference, version: version) }
    private var preview: MakePreviewFace? { appModel.face.slot(key).value(as: MakePreviewFace.self) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let issue { Text(issue).foregroundStyle(.red).textSelection(.enabled) }
            if let slice {
                if let arrival, arrival.version == version {
                    BoardSliceView(document: arrival.document, cards: cards, ids: slice.block.ids, textScale: slice.textScale,
                                   palette: BoardPalette.paint(textScale: slice.textScale)) {
                        ShellFaceCalls.showTable(appModel, elements: slice.block.ids, version: arrival.version)
                    }
                } else if issue == nil {
                    Text(slice.block.alt ?? PartFace.Block.updateNote).foregroundStyle(.secondary)
                }
            } else if let capture {
                if let preview, let board = capture.held(preview)?.board {
                    MakeBoardView(reference: reference, arrival: BoardArrival(document: board, version: version), cards: cards, choices: choices, still: true)
                } else { FaceReadStatus(state: preview?.state) }
            } else if let arrival {
                MakeBoardView(reference: reference, arrival: arrival, cards: cards, choices: choices)
            } else if let state = preview?.state, state != .ready {
                FaceReadStatus(state: state)
            } else if issue == nil { Text("Reading the board…").foregroundStyle(.secondary) }
        }
        // Until the board is read it holds the room it will take, so what follows it on the page does not jump down when it arrives.
        .frame(minHeight: slice == nil && capture == nil && arrival == nil && !fillsWindow ? MakeBoardView.height : nil, alignment: .top)
        .task(id: preview) {
            guard capture == nil, let preview, preview.state == .ready, preview.reference == reference, preview.version == version,
                  let grant = preview.resources.first else { return }
            do {
                let read = try await BoardFile.read(grant)
                try Task.checkCancellation()
                arrival = BoardArrival(document: read, version: version)
                issue = nil
            } catch is CancellationError {
            } catch { issue = "I couldn't read this board: " + error.localizedDescription }
        }
        .modifier(FaceObservation(demand: reference == BoardDocument.tableRef && version == "0" ? nil : .key(key)))
        // Leaving the board lets go of what its last save said.
        .onDisappear { if slice == nil { MakePieceWords.shared.said[reference] = nil } }
    }
}

/// A board file is read off the main actor, and only within the words Make takes in hand.
enum BoardFile {
    static func read(_ grant: ResourceGrant) async throws -> BoardDocument {
        let opened = try await FaceResourceAccess.resolve(grant)
        defer { if opened.scoped { opened.url.stopAccessingSecurityScopedResource() } }
        return try await read(opened.url)
    }

    @concurrent static func read(_ file: URL) async throws -> BoardDocument {
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw CocoaError(.fileReadUnknown) }
        guard size <= MakePreviewFace.wordsLimit else {
            throw BoardDocument.Unreadable(message: "It is over 2 MB, too large to draw here. The whole file is in Make.")
        }
        guard let text = String(data: try Data(contentsOf: file), encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return try BoardDocument(text)
    }
}

struct MakeBoardView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let reference: String
    let arrival: BoardArrival
    var cards: [String: PartFace.Value] = [:]
    var choices: [[String: PartFace.Value]] = []
    /// A picture of the page: drawn as read, nothing to change.
    var still = false
    @Environment(AppModel.self) private var appModel
    @Environment(\.boardFillsWindow) private var fillsWindow
    @Environment(\.boardPage) private var boardPage
    @State private var tool: TableBoardTool = .select
    @State private var picking = false
    @State private var connectFrom: String?
    @State private var barSize = CGSize(width: 360, height: 36)
    @State private var toolsHeight: CGFloat = 50
    @State private var chosen: String?
    @State private var writing: String?
    @State private var newNote: BoardDocument.Element?
    @State private var camera: BoardCamera?
    @State private var textScale = BoardGeometry.macTextScale
    @State private var failed: Set<String> = []
    @State private var held: [String: Hold] = [:]
    @State private var chains: [String: Task<Void, Never>] = [:]
    @FocusState private var focused: Bool

    /// Fields held over the last read until the store's returned version arrives; nil fields hold a removal.
    private struct Hold {
        var fields: [String: PartFace.Value]?
        var calls = 0
        var until: Int?
        var added: Int?
        let generation = UUID()
    }

    static let height: CGFloat = 560
    static let pristineIdleInlineHeight: CGFloat = 220
    static let tableToolsInset: CGFloat = 10
    private var geometry: BoardGeometry {
        BoardGeometry(cards: reference == BoardDocument.tableRef ? cards : nil, textScale: textScale)
    }

    private func isPristineIdleInline(_ document: BoardDocument) -> Bool {
        !fillsWindow && reference == BoardDocument.tableRef && boardPage == "desk"
            && document.elements.isEmpty && newNote == nil && writing == nil
    }

    var body: some View {
        let state = MakeBoardState.of(reference)
        let still = self.still || (reference == BoardDocument.tableRef && boardPage != "desk")
        let older = !still && state.read > MakeBoardState.number(arrival.version)
        let changeable = !still && !older && state.latest != nil
        let table = reference == BoardDocument.tableRef
        let base = table ? picture : changeable ? (state.current ?? arrival.document) : arrival.document
        let pristine = isPristineIdleInline(base)
        let tableFocus = fillsWindow && !still && reference == BoardDocument.tableRef ? appModel.tableFocus : nil
        let focusID = tableFocus.flatMap { focus in
            MakeBoardState.number(arrival.version) >= MakeBoardState.number(focus.version) ? focus.id : nil
        }
        VStack(alignment: .leading, spacing: 8) {
            if !still, let said = MakePieceWords.shared.said[reference] {
                Text(said).font(ShellType.label).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if older {
                Text("This is version \(arrival.version). Changes by hand go on the newest, version \(state.read).")
                    .font(ShellType.label).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                let camera = self.camera ?? self.geometry.fit(base, in: geometry.size)
                let placementSize = pristine ? CGSize(width: geometry.size.width, height: Self.height) : geometry.size
                ZStack(alignment: .topLeading) {
                    if fillsWindow {
                        BoardScrollPan { delta in
                            self.camera = BoardCamera(offset: CGPoint(x: camera.offset.x + delta.width, y: camera.offset.y + delta.height),
                                                      scale: camera.scale)
                        }
                    }
                    SharedBoardCanvasView(document: base, cards: cards, geometry: self.geometry,
                        palette: BoardPalette.paint(textScale: textScale), table: table, changeable: changeable, behind: older, seen: state.newer,
                        camera: camera, size: geometry.size, placementSize: placementSize, cameraOverride: $camera,
                        tool: $tool, chosen: $chosen, connectFrom: $connectFrom, writing: writing, focus: $focused,
                        failed: $failed, hidden: Set(held.keys.filter { held[$0]?.fields == nil }), edit: commit,
                        save: { state.change($0, seen: $1, appModel: appModel) }, canOpen: canOpen, open: open,
                        writeNote: { writeNote($0, state) }, pointAt: { dot, inside in
                            guard inside else { NSCursor.arrow.set(); return }
                            (dot || tool == .connect || tool == .pen ? NSCursor.crosshair : tool == .note ? .iBeam : .arrow).set()
                        })
                    .overlayPreferenceValue(BoardCanvasDrawing.self) { drawing in
                        if let drawing {
                            BoardContextMenu { point in
                                guard let element = self.geometry.hit(drawing, at: camera.board(point), scale: camera.scale) else { return nil }
                                return NSHostingMenu(rootView: menuItems(element))
                            }
                        }
                    }
                    if let writing, let element = base.element(writing), let frame = self.geometry.frame(element) {
                        let shown = table ? camera.view(frame) : camera.view(frame).insetBy(dx: element.type == "shape" ? 6 * camera.scale : 0, dy: 0)
                        BoardWordsEditor(text: element.string("text") ?? "",
                                         font: BoardGeometry.editorFont(element, zoom: camera.scale, table: table && element.type == "shape",
                                                                        textScale: textScale), table: table,
                                         scale: camera.scale, keepOnEscape: newNote?.id == writing) { words in
                            self.writing = nil
                            focused = true
                            let fields: [String: PartFace.Value] = words.map { ["text": .string($0)] } ?? [:]
                            if var note = newNote, note.id == writing {
                                newNote = nil
                                guard let words, !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { chosen = nil; return }
                                note.fields.merge(fields) { _, new in new }
                                commit([.init(.put, writing, note.fields)])
                                return
                            }
                            guard let words else { return }
                            if table { commit([.init(.put, writing, fields)]) }
                            else { state.change(BoardEdit { $0.setText(writing, words) }, seen: state.newer, appModel: appModel) }
                        }
                        .foregroundStyle(reference == BoardDocument.tableRef ? BoardPalette.words(element.string("color"), table: true) : .primary)
                        .id(reference == BoardDocument.tableRef ? writing : "")
                        .frame(width: table ? shown.width : max(shown.width, 160), height: table ? shown.height : nil, alignment: .topLeading)
                        .position(x: (table ? shown.width : max(shown.width, 160)) / 2 + shown.minX, y: shown.midY)
                    }
                    if changeable, !table { controls(state, camera: camera, size: geometry.size, changeable: changeable) }
                }
                .overlayPreferenceValue(BoardCanvasDrawing.self, alignment: .topLeading) { drawing in
                    if let drawing {
                        HouseGlassContainer(spacing: 0) {
                            ZStack(alignment: .topLeading) {
                                tableControls(camera: camera, size: geometry.size, placementSize: placementSize, document: drawing)
                            }
                        }
                    }
                }
                .onChange(of: focusID, initial: true) { _, id in
                    guard let id, let focus = appModel.tableFocus, focus.id == id else { return }
                    let slice = self.geometry.slice(base, ids: focus.elements)
                    if !slice.elements.isEmpty { self.camera = self.geometry.fit(slice, in: geometry.size, minimumScale: 0) }
                    appModel.tableFocus = nil
                }
            }
            .frame(height: fillsWindow ? nil : pristine ? Self.pristineIdleInlineHeight : Self.height)
            .background(reference == BoardDocument.tableRef ? NativeAgentShell.list : Color.primary.opacity(0.03),
                        in: RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous).strokeBorder(TodayPalette.cardStroke))
            .help(reference == BoardDocument.tableRef ? "" : changeable
                  ? "Drag a card to move it, its corner to size it, or its edge onto another card to join them. Double-click to write." : "")
            if state.isSaving, !still { Text("Saving…").font(ShellType.label).foregroundStyle(.secondary) }
        }
        .onChange(of: arrival, initial: true) { _, now in
            readHolds(now.version)
            if !still { state.arrive(now, appModel: appModel) }
        }
        .onChange(of: held.mapValues { $0.calls == 0 ? $0.until ?? 0 : -1 }) { _, _ in
            readHolds(arrival.version)
        }
        .onChange(of: tool) { _, now in
            if now != .card { picking = false }
            if now != .select, writing != nil { focused = true }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.AccessibilityDisplayOptionsDidChangeMessage.name)) { _ in
            textScale = BoardGeometry.macTextScale
        }
        .onChange(of: dynamicTypeSize, initial: true) { _, _ in textScale = BoardGeometry.macTextScale }
        .onDisappear { if reference == BoardDocument.tableRef { NSCursor.arrow.set() } }
    }

    private func readHolds(_ version: String) {
        held = held.filter { $0.value.calls > 0 || ($0.value.until.map { $0 > MakeBoardState.number(version) } ?? false) }
    }

    @ViewBuilder private func menuItems(_ element: BoardDocument.Element) -> some View {
        if canOpen(element) { Button("Open") { open(element) } }
        Button("Cross off") { commit([.init(.cross, element.id)]) }
        Button("Remove", role: .destructive) {
            if chosen == element.id { chosen = nil }
            if connectFrom == element.id { connectFrom = nil }
            commit([.init(.remove, element.id)])
        }
    }

    private var picture: BoardDocument {
        var document = arrival.document
        for (id, hold) in held {
            guard let end = hold.fields else { _ = document.remove(id); continue }
            if let index = document.elements.firstIndex(where: { $0.id == id }) {
                document.elements[index].fields.merge(end) { _, new in new }
            } else if end["type"] != nil, hold.added.map({ MakeBoardState.number(arrival.version) < $0 }) ?? true {
                document.elements.append(BoardDocument.Element(end.merging(["id": .string(id)]) { _, new in new }))
            }
        }
        if let newNote { document.elements.append(newNote) }
        return document
    }

    private func commit(_ edits: [TableElementEdit]) {
        for edit in edits {
            let id = edit.id
            let fields = edit.verb == .remove ? nil : edit.fields
            var hold = held[id] ?? Hold(fields: fields)
            if hold.fields != nil { hold.fields = fields.map { hold.fields!.merging($0) { _, new in new } } }
            hold.calls += 1
            held[id] = hold
            let previous = chains[id], generation = hold.generation
            chains[id] = Task {
                await previous?.value
                guard held[id]?.generation == generation else { return }
                do {
                    if let version = try await tableCall(edit.verb.rawValue, edit.arguments) {
                        held[id]?.until = max(held[id]?.until ?? version, version)
                        if fields?["type"] != nil { held[id]?.added = version }
                    }
                    held[id]?.calls -= 1
                    if held[id]?.calls == 0 { chains[id] = nil }
                } catch {
                    held[id] = nil
                    chains[id] = nil
                    failed.insert(id)
                    if writing == id { writing = nil }
                    if chosen == id { chosen = nil }
                    if connectFrom == id { connectFrom = nil }
                    MakePieceWords.shared.said[reference] = error.localizedDescription
                }
            }
        }
    }

    @discardableResult private func tableCall(_ action: String, _ arguments: [String: PartFace.Value]) async throws -> Int? {
        let value = try FaceWindowReply.value(await appModel.client.act(.deskCommand(.init(
            command: action, handle: action == "open_piece" ? arguments["ref"]?.stringValue : reference,
            arguments: action == "open_piece" ? [:] : arguments))))
        let outcome = try FaceActOutcome.reply(.result(value))
        if let failure = outcome.failure { throw failure }
        guard !outcome.unresolved else {
            throw PartCallError(code: "table_change_unconfirmed", message: "The table change is unconfirmed. Read the table before changing it again.")
        }
        MakePieceWords.shared.said[reference] = nil
        if case .int(let version)? = outcome.committed?.first?.value { return Int(version) }
        return nil
    }

    private func controls(_ state: MakeBoardState, camera: BoardCamera, size: CGSize, changeable: Bool) -> some View {
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
        return HouseGlassContainer(spacing: 0) {
            HStack(spacing: 10) {
                if changeable {
                    Menu {
                        ForEach(BoardPalette.names, id: \.self) { name in
                            Button(name.prefix(1).uppercased() + name.dropFirst()) {
                                let note = SharedBoardCanvasView.note(color: name, at: camera.board(middle),
                                                                      in: arrival.document, geometry: geometry)
                                writeNote(note, state)
                            }
                        }
                    } label: { Label("Add a card", systemImage: "plus") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                Button { self.camera = camera.zoomed(by: 0.8, at: middle) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out")
                Text("\(Int((camera.scale * 100).rounded()))%")
                Button { self.camera = camera.zoomed(by: 1.25, at: middle) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in")
                Button("Fit") { self.camera = nil }.help("Fit the board")
            }
            .buttonStyle(.borderless)
            .font(ShellType.label)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .houseSurface(in: Capsule())
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder private func tableControls(
        camera: BoardCamera, size: CGSize, placementSize: CGSize, document: BoardDocument
    ) -> some View {
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
        TableBoardTools(tool: $tool, picking: $picking, choices: choices, percent: Int((camera.scale * 100).rounded()), choose: { choice in
            guard let edit = SharedBoardCanvasView.linkedCard(choice, camera: camera, size: placementSize,
                                                               document: document, geometry: geometry) else { return }
            self.camera = camera
            commit([edit])
            chosen = edit.id; picking = false; tool = .select
        }, zoom: { self.camera = camera.zoomed(by: $0, at: middle) }, fit: { self.camera = nil }).padding(Self.tableToolsInset)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { toolsHeight = $0 }
        if let chosen, let element = document.element(chosen), writing == nil,
           let frame = geometry.elementFrame(element, in: document) {
            let shown = camera.view(frame)
            let x = min(max(shown.midX, barSize.width / 2 + 8), size.width - barSize.width / 2 - 8) - barSize.width / 2
            let above = CGRect(x: x, y: shown.minY - barSize.height - 8, width: barSize.width, height: barSize.height)
            let below = CGRect(x: x, y: shown.maxY + 8, width: barSize.width, height: barSize.height)
            let others = document.elements.filter { $0.id != chosen }.compactMap(geometry.frame).map { camera.view($0) }
            let place = [above, below].first { candidate in
                candidate.minY >= toolsHeight + 8 && candidate.maxY <= size.height - 8 && !others.contains { $0.intersects(candidate) }
            } ?? above
            elementTools(element).fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { barSize = $0 }
                .position(x: place.midX, y: place.midY)
        }
    }

    private func elementTools(_ element: BoardDocument.Element) -> some View {
        let id = element.id
        let pointer = element.string("item") != nil || element.string("piece") != nil
        return TableElementTools(starting: connectFrom == id, connectable: element.type == "shape", colours: element.type == "shape" && !pointer,
                                 color: element.string("color"), recolor: { color in
            commit([.init(.put, id, ["color": .string(color)])])
        }, cross: {
            commit([.init(.cross, id)])
        }, connect: { tool = .connect; connectFrom = id }, remove: {
            chosen = nil
            if connectFrom == id { connectFrom = nil }
            commit([.init(.remove, id)])
        }, open: pointer && canOpen(element) ? { open(element) } : nil)
    }

    private func canOpen(_ element: BoardDocument.Element) -> Bool {
        guard ["shape", "text", "container"].contains(element.type) else { return false }
        if reference == BoardDocument.tableRef, let piece = element.string("piece") {
            return piece.hasPrefix("make:") && piece.count > "make:".count
        }
        return true
    }

    private func open(_ element: BoardDocument.Element) {
        if reference == BoardDocument.tableRef, let item = element.string("item") {
            Task {
                do { _ = try await MacFaceLinks.follow("page:desk/" + item, appModel: appModel, card: { _ in }) }
                catch { MakePieceWords.shared.said[reference] = error.localizedDescription }
            }
        } else if reference == BoardDocument.tableRef, let piece = element.string("piece"), piece.hasPrefix("make:") {
            let ref = String(piece.dropFirst("make:".count))
            Task {
                do { try await tableCall("open_piece", ["ref": .string(ref)]) }
                catch { MakePieceWords.shared.said[reference] = error.localizedDescription }
            }
        } else { writing = element.id }
    }

    private func writeNote(_ note: BoardDocument.Element, _ state: MakeBoardState) {
        if reference == BoardDocument.tableRef { newNote = note }
        else {
            state.change(BoardEdit { document in
                document.add(note.fields)
                return true
            }, seen: state.newer, appModel: appModel)
        }
        chosen = note.id
        writing = note.id
    }
}

private struct BoardContextMenu: NSViewRepresentable {
    let menuAt: (CGPoint) -> NSMenu?
    func makeNSView(context: Context) -> MenuView { MenuView() }
    func updateNSView(_ view: MenuView, context: Context) { view.menuAt = menuAt }

    final class MenuView: NSView {
        var menuAt: ((CGPoint) -> NSMenu?)?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, event.type == .rightMouseDown
                    || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) else { return nil }
            return super.hitTest(point)
        }
        override func menu(for event: NSEvent) -> NSMenu? { menuAt?(convert(event.locationInWindow, from: nil)) }
    }
}

/// Receives board wheel movement while native click, drag and text editing keep the normal event route.
private struct BoardScrollPan: NSViewRepresentable {
    let pan: (CGSize) -> Void
    func makeNSView(context: Context) -> WheelView { WheelView() }
    func updateNSView(_ view: WheelView, context: Context) { view.pan = pan }
    static func dismantleNSView(_ view: WheelView, coordinator: ()) { view.removeMonitor() }

    /// A transparent wheel receiver bounded by the board's visible rectangle.
    final class WheelView: NSView {
        var pan: ((CGSize) -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, let content = window.contentView, event.window === window,
                      !self.isHiddenOrHasHiddenAncestor,
                      self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                var target = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
                while let view = target {
                    if view is NSTextView || view is NSTextField { return event }
                    target = view.superview
                }
                self.scrollWheel(with: event)
                return nil
            }
        }
        override func scrollWheel(with event: NSEvent) {
            let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            pan?(CGSize(width: event.scrollingDeltaX * factor, height: event.scrollingDeltaY * factor))
        }
        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
    }
}

/// One element's words being written in place: Return keeps them, Escape leaves them as they were, and clicking away keeps them. It
/// settles once. On the Desk's table the editor fills the card, a click inside the card keeps writing, and Escape keeps a new note's words.
private struct BoardWordsEditor: View {
    let text: String
    let font: Font
    var table = false
    var scale: CGFloat = 1
    var keepOnEscape = false
    let end: (String?) -> Void
    @State private var draft = ""
    @State private var opening = ""
    @State private var ended = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if table {
                TextEditor(text: $draft).textEditorStyle(.plain).scrollContentBackground(.hidden)
                    .onKeyPress(.return, phases: [.down, .repeat]) { key in
                        if key.modifiers.contains(.shift) { return .ignored }
                        settle(draft); return .handled
                    }
                    .padding(.horizontal, 12 * scale).padding(.vertical, 8 * scale)
            } else { TextField("", text: $draft, axis: .vertical).textFieldStyle(.plain) }
        }
            .font(font)
            .focused($focused)
            .frame(maxWidth: .infinity, maxHeight: table ? .infinity : nil, alignment: .topLeading)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { if table { focused = true } })
            .onSubmit { settle(draft) }
            .onKeyPress(.escape) {
                settle(keepOnEscape ? draft : nil)
                return .handled
            }
            .onExitCommand { settle(keepOnEscape ? draft : nil) }
            .onChange(of: focused) { _, now in if !now { settle(draft) } }
            .onAppear {
                opening = text
                draft = opening
                DispatchQueue.main.async { focused = true }
            }
    }

    private func settle(_ words: String?) {
        guard !ended else { return }
        ended = true
        end(words == opening ? nil : words)
    }
}
