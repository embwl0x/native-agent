import AppKit
import Foundation
import NativeAgentShared
import SwiftUI
// Blueprint: | `FacePageView.swift` | Page slots, answering doors and document demands; MacFaceLinks owns destinations |

/// Every faced page draws the same description; navigation and owner answers are the Mac's only adapters.
struct FacePageView: View {
    static let standaloneInset: CGFloat = 20
    let page: String
    var only: String? = nil
    var rowID: String? = nil
    var isReading = false
    @Environment(AppModel.self) private var appModel
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    @State private var feedback: String?
    @State private var topRequest = UUID()
    @State private var activityTarget: ActivityTarget?
    @State private var document: PageDocument?
    @State private var selectedItem: String?
    private var session: FacePageSession { appModel.pageSessions.page(page) }

    private struct ActivityTarget: Identifiable {
        let reference: WorkOverviewReference
        var id: String { reference.kind.rawValue + ":" + reference.id }
    }

    /// A row's document as the page's owner answered it, or the owner's words for why it could not.
    private struct PageDocument: Identifiable {
        let id: UUID
        let subject: DocumentSubject
    }

    private var snapshot: PartFaceSnapshot? { appModel.face.slot(.page(page)).value(as: PartFaceSnapshot.self) }
    private var title: String { QuietPages.page(named: page)?.title ?? page }

    private var pageIssue: String? {
        guard AppDoorNames.ownPageRefusal(page) == nil,
              let catalog = appModel.face.slot(PageFaceKey.catalog).value(as: PartFaceCatalog.self) else { return nil }
        if let failure = catalog.failure { return failure.message }
        if catalog.claims[page] == nil { return "No active part claims this page. Restore its part or open an active page." }
        return nil
    }

    var body: some View {
        content
            .scrollEdgeEffectStyle(quietOffscreenRead ? nil : .soft, for: [.top, .bottom])
            .authoredSecretEntry(page: page).modifier(FaceObservation(demand: .key(.page(page)))).environment(\.boardPage, page)
            .sheet(item: $activityTarget) { target in
                MacWorkOverviewDetail(reference: target.reference) { activityTarget = nil }
            }
            .sheet(item: $document) { document in
                FaceDocumentSheet(request: DocumentRequest(id: document.id, subject: document.subject)) { self.document = nil }
            }
    }

    @ViewBuilder private var content: some View {
        if let rowID {
            ScrollView {
                if let face = snapshot?.drawnFace {
                    if let row = face.allRows.first(where: { $0.id == rowID }) {
                        FaceView(face: PartFace(sections: [.init(id: rowID, style: .list, rows: [row])]),
                                 door: door, session: session, leaf: { Self.leaf($0) })
                    } else { Text("This item is absent from the current \(title) reading.") }
                } else { Text(snapshot?.error?.message ?? "Waiting on \(title)…") }
                if let feedback { linkFeedback(feedback) }
            }
            .padding(Self.standaloneInset)
        } else if let only {
            VStack(alignment: .leading, spacing: 0) {
                if let face = snapshot?.drawnFace {
                    FaceView(face: PartFace(sections: face.sections.filter { $0.id == only }),
                             door: door, session: session, leaf: { Self.leaf($0) })
                } else {
                    Text(snapshot?.error?.message ?? pageIssue ?? "Waiting on the table's reading.").foregroundStyle(.secondary)
                }
            }
            .environment(\.boardFillsWindow, true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(Self.standaloneInset)
        } else if let snapshot, let face = snapshot.drawnFace, face.detail != nil || face.sections.contains(where: { $0.more != nil }) {
            collection(snapshot, face: face)
        } else { scrollingContent }
    }

    @ViewBuilder private func collection(_ snapshot: PartFaceSnapshot, face: PartFace) -> some View {
        if face.detail != nil {
            let combined = PartFace(title: face.title, line: face.line, sections: (snapshot.levers ?? []) + face.sections, detail: face.detail)
            FaceSelectionView(face: combined, session: session, selection: $selectedItem, door: door, page: page,
                              leaf: { Self.leaf($0) }) { selected, row in
                var item = selected
                if let row {
                    guard let open = row.open, case .page(let target, item: let linked?)? = FaceLink(open), target == page else {
                        return AnyView(Text("This row has no item link on " + page + ".").foregroundStyle(.secondary))
                    }
                    item = linked
                }
                return AnyView(FaceItemView(item: item, readCall: row?.read, door: appModel.pageDoor(page: page + "/" + item, open: self.open),
                                           reader: door, session: appModel.pageSessions.page(page + "/" + item), leaf: { Self.leaf($0) }))
            }
        } else {
            VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
                pinnedHeader
                if let feedback {
                    linkFeedback(feedback)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .frame(maxWidth: TodayMetrics.contentWidth, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
                List {
                    FaceView(snapshot: snapshot, title: title, header: false, door: door, session: session, leaf: { Self.leaf($0) })
                }
                .faceList()
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .pageScrollColumn()
                .environment(\.faceListColumnWidth, TodayMetrics.contentWidth)
                .contentMargins(.bottom, quietOffscreenRead ? 32 : 48, for: .scrollContent)
            }
            .padding(.top, TodayMetrics.topPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder private var pinnedHeader: some View {
        let face = snapshot?.status == .ready ? snapshot?.face : nil
        AlivePageHeader(title: face?.title.flatMap { $0.isEmpty ? nil : $0 } ?? title, line: face?.line, wrapsLine: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .frame(maxWidth: TodayMetrics.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
    }

    private var scrollingContent: some View {
        // The page is one frame: its header holds still and only what is under it scrolls.
        VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
        pinnedHeader
        ScrollViewReader { reader in
        ScrollView {
            // Nothing empty takes a section's space: the first thing shown sits at the top, under the rail's tabs when it is a tab.
            VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
                // A page that shows its face never moves while it re-reads: the read status stands only until the first face arrives.
                if isReading, snapshot == nil { PageReadStatus(isReading: true, text: "Reading " + title + "…") }
                if let snapshot {
                    FaceView(snapshot: snapshot, title: title, header: false, door: door, session: session, leaf: { Self.leaf($0) }).id(page)
                } else if let pageIssue {
                    Text(pageIssue).foregroundStyle(.secondary).textSelection(.enabled)
                } else if !isReading {
                    Text("Waiting on " + title + "'s face.").foregroundStyle(.secondary)
                }
                if let feedback { linkFeedback(feedback) }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, quietOffscreenRead ? 32 : 48)
            .frame(maxWidth: TodayMetrics.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
            .id("face-top")
        }
        .scrollPosition(id: Binding(get: { session.scrollAnchor }, set: { session.scrollAnchor = $0 }), anchor: .top)
        // A link within this page (an item opened in place) shows what it opened at the top.
        .onChange(of: topRequest) { withAnimation(.snappy) { reader.scrollTo("face-top", anchor: .top) } }
        }
        .pageScrollColumn()
        }
        .padding(.top, TodayMetrics.topPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func linkFeedback(_ words: String) -> some View {
        Text(words).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var door: ClosureFaceDoor {
        appModel.pageDoor(page: page, open: open)
    }

    /// A piece a page lays out (key `piece:…`, ref its Make ref, revision its version) is drawn through the Make pane's granted preview,
    /// and a board piece (leaf `board`) as a board that holds across its versions; any other leaf reads as its words.
    static func leaf(_ block: PartFace.Block) -> AnyView {
        guard let piece = piece(block) else {
            return AnyView(Text(block.alt ?? PartFace.Block.updateNote).foregroundStyle(.secondary))
        }
        if block.leaf == BoardDocument.type {
            return AnyView(PageMakeBoard(reference: piece.reference, version: piece.version, cards: block.cards ?? [:], choices: block.choices ?? [])
                .id(piece.reference))
        }
        return AnyView(PageMakePreview(reference: piece.reference, version: piece.version))
    }

    /// The Make version a leaf block lays on a page, read the same way by the window and by a picture of the page.
    static func piece(_ block: PartFace.Block) -> (reference: String, version: String)? {
        guard block.kind == "leaf", block.key.hasPrefix("piece:"), let reference = block.ref, let version = block.revision else { return nil }
        return (reference, version)
    }

    private func open(_ link: String) {
        feedback = nil
        // A row of this page that opens its own document reads it from the page's owner, the same answer the agent's door reads.
        Task {
            do {
                if page == "personality", case .page("personality", item: let item?)? = FaceLink(link) {
                    try PersonalityFaceDestinations.open(item)
                    return
                }
                if snapshot?.drawnFace?.detail != nil, case .page(let target, item: let item?)? = FaceLink(link), target == page {
                    selectedItem = item
                    return
                }
                if case .page(let target, item: let item?)? = FaceLink(link), target == page, page != "desk", page != "memories" {
                    document = PageDocument(id: UUID(), subject: .pageItem(page: page, item: item))
                    return
                }
                if page == "desk", case .page("desk", item: let item?)? = FaceLink(link) {
                    feedback = try FaceWindowReply.message(await appModel.client.act(.deskCommand(.init(
                        command: "open", handle: item, arguments: [:]))))
                    topRequest = UUID()
                    return
                }
                let opened = try await MacFaceLinks.follow(link, appModel: appModel) { activityTarget = ActivityTarget(reference: $0) }
                if opened == page { topRequest = UUID() }
            } catch { feedback = error.localizedDescription }
        }
    }
}

extension AppModel {
    func documentPresentation(_ subject: DocumentSubject) async throws -> FaceDocumentPresentation {
        let value = try FaceWindowReply.value(await client.act(.requestDocument(.init(id: UUID(), subject: subject, presentation: true))))
        return try await Task.detached(priority: .userInitiated) {
            try JSONDecoder().decode(FaceDocumentPresentation.self, from: JSONEncoder().encode(value))
        }.value
    }

    func pageDoor(page: String, open: @escaping (String) -> Void) -> ClosureFaceDoor {
        let client = client
        return ClosureFaceDoor(open: open, read: { request in
            let reply = try FaceWindowReply.value(await client.act(.requestDocument(.init(id: request.id,
                subject: .pageItem(page: page, item: request.key), expectedCall: request.expectedCall, textOnly: true))))
            guard case .string(let text) = reply else {
                throw PartCallError(code: "document_unconfirmed", message: "The document owner did not return its text.")
            }
            return text
        }, pageRead: { request in
            let reply = try FaceWindowReply.value(await client.act(.requestDocument(.init(id: request.id,
                subject: .pageItem(page: page, item: request.key), pageRead: request))))
            return try await Task.detached(priority: .userInitiated) {
                try JSONDecoder().decode(PartFace.self, from: JSONEncoder().encode(reply))
            }.value
        }, releaseFace: { request in
            do {
                try FaceWindowReply.check(await client.act(.requestDocument(.init(id: request.id, subject: .pageItem(page: page, item: request.key),
                                                                                 pageRead: request, release: true))))
            } catch { self.setFailureStatus(error, action: "release the page") }
        }, scope: { item in self.pageDoor(page: page + "/" + item, open: open) }, perform: { submission in
            let outcome: FaceActOutcome
            do {
                outcome = try FaceActOutcome.reply(await client.protectedAct(.pageAct(.init(
                    page: page, row: submission.row, action: submission.action,
                    value: submission.values.map(PartFace.Value.object) ?? submission.value.map(PartFace.Value.string),
                    expectedRevision: submission.formRevision, expectedCall: submission.expectedCall, answers: true,
                    operation: submission.id, undoOf: submission.undoOf, checking: submission.checking))))
            } catch { outcome = .interrupted(error) }
            return outcome
        })
    }
}

/// The Mac's places for a row's link, for every page it draws (the link itself is read by `FaceLink`). A link into the page being drawn goes
/// to `here` first (a Home room); a card opens its own conversation; an approval opens through `card`. Returns the page a page link opened.
enum MacFaceLinks {
    @MainActor static func follow(_ destination: FaceDestination, appModel: AppModel) async throws {
        if let session = destination.session {
            try FaceWindowReply.check(await appModel.client.act(.selectConversation(session: session, userInitiated: true)))
            appModel.pendingChatMessageID = destination.message
            ApplicationLifetime.shared.request(.sidebar(.chat))
            return
        }
        try FaceWindowReply.check(await appModel.client.act(.pageAct(.init(
            page: destination.page, row: destination.item ?? "", action: "open", value: nil,
            expectedRevision: nil, expectedCall: nil))))
        try openPage(destination.page)
    }

    @MainActor static func follow(_ link: String, appModel: AppModel, here: (String, String?) -> Bool = { _, _ in false },
                                  card: (WorkOverviewReference) -> Void) async throws -> String? {
        guard let target = FaceLink(link) else { throw PartCallError(code: "bad_link", message: "This row has no supported destination.") }
        switch target {
        case .chat(let id):
            try FaceWindowReply.check(await appModel.client.act(.selectConversation(session: id, userInitiated: true)))
            ApplicationLifetime.shared.request(.sidebar(.chat))
        case .dream(let date):
            ApplicationLifetime.shared.request(.savedThing(.dream(date)))
        case .page(let page, let item):
            if here(page, item) { return nil }
            if page == "today", let item, let section = ActivitySection(rawValue: item) {
                ApplicationLifetime.shared.request(.activity(section))
                return nil
            }
            try FaceWindowReply.check(await appModel.client.act(.pageAct(.init(
                page: page, row: item ?? "", action: "open", value: nil, expectedRevision: nil, expectedCall: nil))))
            try openPage(page)
            return page
        case .approval(let id): card(.init(kind: .approval, id: id))
        case .card(let id):
            // A card opens in its own conversation, where it is answered; following the link answers nothing.
            try FaceWindowReply.check(await appModel.client.act(.openCard(id: id)))
        case .url(let url):
            guard NSWorkspace.shared.open(url) else {
                throw PartCallError(code: "url_unavailable", message: "The browser could not open this web link.")
            }
        }
        return nil
    }

    @MainActor private static func openPage(_ name: String) throws {
        guard let page = QuietPages.page(named: name) else {
            throw PartCallError(code: "page_unavailable", message: "The opened page is absent from my current face.")
        }
        ApplicationLifetime.shared.request(page.item == .ownPage ? .ownPage(page.id) : .sidebar(page.item))
    }
}

/// Commands consume their own reply; a retained display frame cannot confirm an effect.
enum FaceWindowReply {
    static func check(_ reply: FaceActReply) throws {
        switch reply {
        case .refused(let failure), .failed(let failure): throw failure
        case .committed(let result), .operation(.completed(let result)):
            if let failure = result.publicationFailure { throw failure }
        case .acknowledged, .accepted, .result, .observation: break
        case .operation:
            throw WireFailure(code: "operation_unsettled", message: "The body operation has not settled.",
                              cause: nil, effects: .unknown)
        default:
            throw PartCallError(code: "unexpected_face_reply", message: "The body returned a different command's reply.")
        }
    }

    static func committed(_ reply: FaceActReply) throws -> CommittedResult {
        try check(reply)
        switch reply {
        case .committed(let result), .operation(.completed(let result)): return result
        default:
            throw WireFailure(code: "effect_unconfirmed", message: "The body has not confirmed this change.",
                              cause: nil, effects: .unknown)
        }
    }

    static func value(_ reply: FaceActReply) throws -> PartFace.Value {
        try check(reply)
        switch reply {
        case .result(let value): return value
        case .committed(let result), .operation(.completed(let result)): return result.value
        default: throw PartCallError(code: "unexpected_face_reply", message: "The body did not return the requested value.")
        }
    }

    static func message(_ reply: FaceActReply) throws -> String? {
        try check(reply)
        switch reply {
        case .acknowledged, .accepted: return nil
        case .result(.string(let text)): return text
        case .committed(let result), .operation(.completed(let result)):
            if case .string(let text) = result.value { return text }
            return nil
        case .result(.null): return nil
        default: throw PartCallError(code: "unexpected_face_reply", message: "The body did not return this command's outcome.")
        }
    }
}

struct FaceReadStatus: View {
    let state: FaceReadState?
    var body: some View {
        switch state {
        case .waiting(let on): Text("Waiting on " + on + "…").foregroundStyle(.secondary)
        case .unavailable(let failure): Text(failure.localizedDescription).foregroundStyle(.red).textSelection(.enabled)
        case .ready: EmptyView()
        case nil: Text("Waiting…").foregroundStyle(.secondary)
        }
    }
}

/// Subscription identities belong to this mounted view and are released by disappearance or link teardown.
struct FaceObservation: ViewModifier {
    @Environment(AppModel.self) private var appModel
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    @State private var subscription = FaceObservationSubscription()
    @State private var issue: String?
    let demand: FaceDemand?
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom) {
            if let issue {
                Text(issue).font(.callout).foregroundStyle(.red).textSelection(.enabled).padding(12)
            }
        }.task(id: quietOffscreenRead ? nil : demand) {
            issue = nil
            guard !quietOffscreenRead, let demand else { return }
            do { try await subscription.observe(demand, client: appModel.client) }
            catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                issue = FaceActionFeedback.message(error, action: "observe this presentation")
            }
        }
    }
}

@MainActor private final class FaceObservationSubscription {
    private var held: Task<Void, Error>?
    private var releaseFailure: WireFailure?

    func observe(_ demand: FaceDemand, client: any FaceClient) async throws {
        let previous = held
        previous?.cancel()
        let next = Task {
            // Each caller receives its own admission error; every replacement waits for release.
            _ = await previous?.result
            if let releaseFailure { throw releaseFailure }
            try Task.checkCancellation()
            let id = UUID()
            var issue: (any Error)?
            do {
                let reply = try await client.act(.observe(id: id, demand: demand))
                try FaceWindowReply.check(reply)
                guard case .observation(let confirmed) = reply, confirmed == id else {
                    throw PartCallError(code: "observation_unconfirmed", message: "The body did not confirm the requested observation.")
                }
                let (lifetime, end) = AsyncStream<Void>.makeStream()
                defer { end.finish() }
                for await _ in lifetime { }
            } catch is CancellationError {
            } catch { if !Task.isCancelled { issue = error } }
            let release = Task { try await client.act(.unobserve(id: id)).checkedAcknowledgement() }
            do { try await release.value }
            catch {
                let failure = WireFailure(code: "observation_release_failed", message: "The presentation could not release its body reader.",
                    cause: error.localizedDescription, effects: .unknown)
                releaseFailure = failure
                throw failure
            }
            if let issue { throw issue }
        }
        held = next
        defer { if held == next { held = nil } }
        try await withTaskCancellationHandler { try await next.value } onCancel: { next.cancel() }
    }
}

struct FaceDocumentSheet: View {
    @Environment(AppModel.self) private var appModel
    let request: DocumentRequest
    let onDone: () -> Void
    var body: some View {
        PageSheetHost(title: "Document", onDone: onDone) {
            FaceDocumentReader(identity: request.id, presentation: { _ in try await appModel.documentPresentation(request.subject) })
            .padding(16)
        }
    }
}
