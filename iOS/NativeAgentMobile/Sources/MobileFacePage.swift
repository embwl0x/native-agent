import SwiftUI
import Foundation
import NativeAgentShared
import Observation
// Blueprint: | `MobileFacePage.swift` | Phone page rows, signed document demands and retained action outcomes |

extension FaceActOutcome {
    /// Pre-dispatch refusals have no effects; a terminal response must carry its owner's effect evidence.
    static func phoneFailure(_ error: any Error) -> Self {
        guard let sync = error as? SyncError else { return .interrupted(error) }
        let effects: FaceEffects
        switch sync {
        case .notSetup, .notSigned, .busy, .sendFailed: effects = .none
        case .macRejected, .unsupported, .responseUnconfirmed, .persistence, .approvalRequired: return .interrupted(error)
        }
        return .init(failure: .init(code: "phone_action_refused", message: sync.localizedDescription, cause: nil, effects: effects), effects: effects)
    }
}

/// Where a link leads inside the page's own stack: another faced page, or a saved run's detail.
enum FaceDestination: Hashable {
    case page(String)
    case run(String)
    case document(page: String, item: String)
    case item(page: String, item: String)

    /// The link's place in this stack, when the phone holds it.
    @MainActor init?(_ link: String) {
        guard case .page(let page, let item)? = FaceLink(link) else { return nil }
        let sync = iCloudSyncEngine.shared
        if let item, page == "diagnostics", sync.runs.contains(where: { $0.id == item }) {
            self = .run(item)
        } else if let item, Self.isDocument(page: page, item: item, sync: sync) {
            self = .document(page: page, item: item)
        } else if let item, sync.faces[page] != nil {
            self = .item(page: page, item: item)
        } else if item == nil, sync.faces[page] != nil {
            self = .page(page)
        } else {
            return nil
        }
    }

    @MainActor private static func isDocument(page: String, item: String, sync: iCloudSyncEngine) -> Bool {
        if ["capabilities", "connectors", "diagnostics"].contains(page) { return true }
        if page == "memories", let target = MemoriesFaceTarget(row: item) {
            switch target {
            case .memory, .rejected: return true
            case .graph, .upkeep: return false
            }
        }
        return sync.faces[page]?.face?.sections.compactMap(\.block).contains { $0.key == item } == true
    }

    @MainActor @ViewBuilder var view: some View {
        switch self {
        case .page(let page): MobileFacePage(page: page)
        case .run(let id):
            if let run = iCloudSyncEngine.shared.runs.first(where: { $0.id == id }) { RunDetailView(run: run) }
        case .document(let page, let item):
            MobileDocumentPage(identity: [page, item], subject: .pageItem(page: page, item: item), title: item)
        case .item(let page, let item): MobileDemandFacePage(page: page, item: item)
        }
    }
}

/// The shell's places for a face's links: Chat, Today and its queues, the Desk, a card, the browser. Answers the words for a place the
/// phone does not have.
struct FaceRouter {
    var follow: (String) -> String?
}

extension EnvironmentValues {
    @Entry var faceRouter = FaceRouter { _ in "This opens on your Mac." }
}

/// A faced page pushed on its own: its title and sentence in the phone's header, its face below.
struct MobileFacePage: View {
    let page: String
    /// A tab's root page draws the root header; a pushed one the pushed header.
    var style: AlivePageStyle = .pushed
    @State private var pushed: FaceDestination?
    private let sync = iCloudSyncEngine.shared

    var body: some View {
        let face = sync.faces[page]?.face
        AlivePage(title: face?.title ?? QuietToolPage.page(named: page)?.title ?? page, line: face?.line, style: style) {
            MobileFaceRows(page: page) { pushed = $0 }
        }
        .navigationDestination(item: $pushed) { $0.view }
    }
}

/// The shared renderer holds pending work and failures beside the row; accepted work survives navigation.
struct MobileFaceRows: View {
    let page: String
    let push: (FaceDestination) -> Void
    @Environment(\.faceRouter) private var router
    private let sync = iCloudSyncEngine.shared
    private var session: FacePageSession { sync.pageSessions.page(page) }

    private var title: String { QuietToolPage.page(named: page)?.title ?? page }

    var body: some View {
        Group {
            if let snapshot = sync.faces[page] {
                FaceView(snapshot: snapshot, title: title, header: false, door: door, session: session).id(page)
                    .onAppear { session.notice = { SystemToastCenter.shared.push(success: $0) } }
            } else {
                note(title + " has not arrived from your Mac yet.")
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(AlivePalette.secondary).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func open(_ link: String) {
        if let destination = FaceDestination(link) { push(destination) }
        else if let words = router.follow(link) { SystemToastCenter.shared.push(info: words) }
    }

    private var door: ClosureFaceDoor {
        MobileRemoteFaceDoor.make(page: page, open: open)
    }
}

/// One row of a page's face standing alone: a matter's card in a conversation is its Inbox row. The same FaceView draws it and a tap
/// goes to the page's owner on the Mac, as on the page itself; every link goes to the shell's router.
struct MobileFaceRow: View {
    let page: String
    let row: PartFace.Row
    @Environment(\.faceRouter) private var router
    private let sync = iCloudSyncEngine.shared
    private var session: FacePageSession { sync.pageSessions.page(page) }

    var body: some View {
        FaceView(face: PartFace(sections: [.init(id: row.id, style: .list, rows: [row])]), door: door, session: session)
            .id(page + "/" + row.id)
            .buttonStyle(.borderless).pickerStyle(.menu)
            .environment(\.faceInList, false)
            .environment(\.faceStyle, .phone)
            .onAppear { session.notice = { SystemToastCenter.shared.push(success: $0) } }
    }

    private var door: ClosureFaceDoor {
        MobileRemoteFaceDoor.make(page: page, open: { link in
            if let words = router.follow(link) { SystemToastCenter.shared.push(info: words) }
        })
    }
}

struct MobileDocumentPage<Identity: Hashable>: View {
    let identity: Identity
    let subject: DocumentSubject
    let title: String
    var body: some View {
        AlivePage(title: title, style: .pushed) {
            FaceDocumentReader(identity: identity, cancellationLabel: "Cancel waiting", waitingOn: "your Mac", presentation: { request in
                try await iCloudSyncEngine.shared.faceReadPresentation(.init(id: request.id, subject: subject, textOnly: true))
            })
        }
    }
}

@MainActor private enum MobileRemoteFaceDoor {
    static func make(page: String, open: @escaping (String) -> Void) -> ClosureFaceDoor {
        let sync = iCloudSyncEngine.shared
        return ClosureFaceDoor(open: open, cancellationLabel: "Cancel waiting", waitingOn: "your Mac", read: { request in
            try await sync.faceRead(.init(id: request.id, subject: .pageItem(page: page, item: request.key),
                                         expectedCall: request.expectedCall, textOnly: true))
        }, pageRead: { try await sync.faceReadFace(page: page, request: $0) }, releaseFace: { request in
            do { try await sync.releaseFaceRead(page: page, request: request) }
            catch { sync.syncError = "The Mac page demand could not be released: " + TurnSecretRedactor.redactDisplayText(error.localizedDescription) }
        }, scope: { item in make(page: page + "/" + item, open: open) },
           perform: { await sync.faceOutcome(page: page, submission: $0) })
    }
}

private struct MobileDemandFacePage: View {
    let page: String
    let item: String
    @State private var pushed: FaceDestination?
    @Environment(\.faceRouter) private var router
    private let sync = iCloudSyncEngine.shared

    var body: some View {
        AlivePage(title: item) {
            FaceItemView(item: item, door: door.scoped(to: item), reader: door, session: sync.pageSessions.page(page + "/" + item))
        }
        .navigationDestination(item: $pushed) { $0.view }
        .macSyncErrorBanner()
    }

    private var door: ClosureFaceDoor {
        MobileRemoteFaceDoor.make(page: page) { link in
            if let target = FaceDestination(link) { pushed = target }
            else if let words = router.follow(link) { SystemToastCenter.shared.push(info: words) }
        }
    }
}

/// A phone page reads its already received values through its own owner, independently of the Mac's action door.
@MainActor protocol MobileLocalFaceOwner {
    var waitingOn: String { get }
    func readFace(_ request: FaceReadRequest) async throws -> PartFace
    func readText(_ request: FaceReadRequest) async throws -> String
}

extension MobileLocalFaceOwner {
    func readText(_ request: FaceReadRequest) async throws -> String {
        throw PartCallError(code: "local_document_missing", message: "This local page has no document named \(request.key).")
    }
}

struct MobileLocalFaceRows: View {
    let face: PartFace
    let owner: any MobileLocalFaceOwner
    let session: FacePageSession
    var open: (String) -> Void = { _ in }

    var body: some View {
        FaceView(face: face, door: door, session: session)
    }

    private var door: ClosureFaceDoor {
        ClosureFaceDoor(open: open, waitingOn: owner.waitingOn,
                        read: { try await owner.readText($0) }, pageRead: { try await owner.readFace($0) }, perform: { _ in
            let failure = WireFailure(code: "local_page_read_only", message: "This page only reads this iPhone's received copy.",
                                      cause: nil, effects: .none)
            return FaceActOutcome(failure: failure, effects: .none)
        })
    }
}
