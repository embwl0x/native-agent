import SwiftUI
import NativeAgentShared
// Blueprint: | `MobileFacePage.swift` | Any faced page on the phone: the shared FaceView over the face the Mac published, its links followed on the phone (a faced page or a saved run pushed here, every other place through the shell's router), its row actions answered by the page's owner on the Mac |

/// Where a link leads inside the page's own stack: another faced page, or a saved run's detail.
enum FaceDestination: Hashable {
    case page(String)
    case run(String)

    /// The link's place in this stack, when the phone holds it.
    @MainActor init?(_ link: String) {
        guard link.hasPrefix("page:") else { return nil }
        let parts = link.dropFirst("page:".count).split(separator: "/", maxSplits: 1).map(String.init)
        let sync = iCloudSyncEngine.shared
        if parts.count == 2, parts[0] == "diagnostics", sync.runs.contains(where: { $0.id == parts[1] }) {
            self = .run(parts[1])
        } else if parts.count == 1, sync.faces[parts[0]] != nil {
            self = .page(parts[0])
        } else {
            return nil
        }
    }

    @MainActor @ViewBuilder var view: some View {
        switch self {
        case .page(let page): MobileFacePage(page: page)
        case .run(let id):
            if let run = iCloudSyncEngine.shared.runs.first(where: { $0.id == id }) { RunDetailView(run: run) }
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

/// One page's face as rows of an `AlivePage`: the phone's header carries its title and sentence, so FaceView draws its sections.
/// A link to a place in this stack is pushed by the host; any other goes to the shell's router. A row's action goes to the page's owner on
/// the Mac. Its answer, a refusal or the words for a place the phone does not have show where the reader is, as the app's toast.
struct MobileFaceRows: View {
    let page: String
    let push: (FaceDestination) -> Void
    @Environment(\.faceRouter) private var router
    private let sync = iCloudSyncEngine.shared

    private var title: String { QuietToolPage.page(named: page)?.title ?? page }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snapshot = sync.faces[page] {
                if snapshot.status == .ready, let face = snapshot.face {
                    // The whole face is one List row; borderless controls keep each touch on the control under it,
                    // so the List never hands a tap anywhere in the face to the row's first choice.
                    FaceView(face: PartFace(sections: face.sections), open: open, act: act)
                        .buttonStyle(.borderless).pickerStyle(.menu)
                } else {
                    note(snapshot.error?.message ?? (snapshot.status == .ready
                        ? title + " has nothing to show from your Mac." : title + " is " + snapshot.status.rawValue + " on your Mac."))
                }
            } else {
                note(title + " has not arrived from your Mac yet.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 12, trailing: 4))
        .listRowSeparator(.hidden)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(AlivePalette.secondary).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func open(_ link: String) {
        if let destination = FaceDestination(link) { push(destination) }
        else if let words = router.follow(link) { SystemToastCenter.shared.push(info: words) }
    }

    private func act(_ row: String, _ action: String, _ value: String?) {
        Task {
            do {
                let words = try await sync.faceAction(page: page, row: row, action: action, value: value)
                SystemToastCenter.shared.push(success: words ?? "Done.")
            } catch {
                SystemToastCenter.shared.push(error: error.localizedDescription)
            }
        }
    }
}
