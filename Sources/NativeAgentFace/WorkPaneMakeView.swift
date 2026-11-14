import Foundation
import AppKit
import SwiftUI
import NativeAgentShared
import WebKit
import QuickLookUI
import UniformTypeIdentifiers
// Blueprint: | `WorkPaneMakeView.swift` | Shared Make page, retained version-bound actions, granted native leaves and checked exports |

extension MakePreviewFace {
    /// An SVG is a picture to whoever looks at it, so it is drawn as one at its own proportions, not in a page's web frame.
    var isPicture: Bool {
        kind == "image" || resources.first.map { ($0.name as NSString).pathExtension.lowercased() == "svg" } == true
    }
}

struct WorkPaneMakeView: View {
    let ref: String?
    @Environment(AppModel.self) private var appModel
    private var reference: String? { ref ?? shelf?.newest }
    private var selectedVersion: String? {
        get { reference.flatMap { WorkPaneState.shared.selectedMakeVersions[$0] } }
        nonmutating set {
            if let reference { WorkPaneState.shared.selectedMakeVersions[reference] = newValue }
        }
    }
    private var shelf: MakeShelfFace? { appModel.face.slot(.makeShelf).value(as: MakeShelfFace.self) }
    private var versions: [FaceMakeVersion] {
        guard let shelf else { return [] }
        let reference = ref ?? shelf.newest
        return shelf.versions.filter { $0.reference == reference }
    }
    private var version: FaceMakeVersion? {
        if let selectedVersion { return versions.first { $0.version == selectedVersion } }
        return versions.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FaceReadStatus(state: shelf?.state)
            if let version {
                MakeVersionPage(version: version, versions: versions,
                    selectedVersion: Binding(get: { selectedVersion }, set: { selectedVersion = $0 }),
                    session: appModel.pageSessions.page("work-make/" + version.reference + "/" + version.version))
                    .id(version.reference + "/" + version.version)
            } else if shelf?.state == .ready {
                Text("Nothing made yet.").foregroundStyle(.secondary).padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: versions) {
            if shelf?.state == .ready, let selectedVersion, !versions.contains(where: { $0.version == selectedVersion }) {
                self.selectedVersion = nil
            }
        }
        // Leaving a ref lets go of what its last table save said.
        .onChange(of: reference) { left, _ in if let left { MakeSheetWords.shared.said[left] = nil } }
        .onDisappear { if let reference { MakeSheetWords.shared.said[reference] = nil } }
        .modifier(FaceObservation(demand: .key(.makeShelf)))
    }
}

private struct MakeVersionPage: View {
    let version: FaceMakeVersion
    let versions: [FaceMakeVersion]
    @Binding var selectedVersion: String?
    let session: FacePageSession
    @Environment(AppModel.self) private var appModel
    private var key: FaceKey { .makePreview(reference: version.reference, version: version.version) }
    private var preview: MakePreviewFace? { appModel.face.slot(key).value(as: MakePreviewFace.self) }
    private var titleSnapshot: PartFaceSnapshot? {
        guard let key = preview?.titleKey else { return nil }
        return appModel.face.slot(key).value(as: PartFaceSnapshot.self)
    }
    private var title: String {
        guard preview?.titleKey != nil else { return version.title }
        guard let title = titleSnapshot?.face?.sections.flatMap(\.rows).first?.title else { return "Waiting on the preview title…" }
        return title
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                FaceReadStatus(state: preview?.state)
                if let error = titleSnapshot?.error { Text(error.message).foregroundStyle(.red).textSelection(.enabled) }
                FaceView(face: WorkPaneFace.make(version, versions: versions, title: title, preview: preview),
                         door: door, session: session, leaf: { block in
                    if let preview, block.key == "make-preview", block.ref == preview.reference, block.revision == preview.revision {
                        return AnyView(GrantedMakePreview(preview: preview).id(preview.revision).frame(minHeight: preview.isPicture ? nil : 240))
                    }
                    return AnyView(Text("This preview does not match its owner's current resource grant.").foregroundStyle(.red))
                })
            }.padding(12)
        }
        // A picture fitted to the width gets shorter as the page narrows. A scroll bar that takes width would then appear, narrow the
        // page, stop being needed, hide, and be needed again without end; this page scrolls without one.
        .scrollIndicators(.never)
        .modifier(FaceObservation(demand: .key(key)))
    }

    private var door: ClosureFaceDoor {
        // Capture the drawn version: an incoming shelf cannot retarget an accepted operation.
        let version = version
        return ClosureFaceDoor(open: { _ in }, waitingOn: "Make") { submission in
            guard !submission.checking else {
                return .interrupted(WireFailure(code: "make_outcome_unconfirmed",
                    message: "Inspect this Make version and its export destination before making another copy. This read runs no write.",
                    cause: "Make has no operation-bound readback for this request.", effects: .unknown))
            }
            do {
                switch submission.expectedCall.action {
                case "selectMakeVersion":
                    guard let value = submission.value, versions.contains(where: { $0.version == value }) else {
                        throw WireFailure(code: "make_version_missing", message: "This Make version is absent from the displayed shelf.",
                                          cause: nil, effects: .none)
                    }
                    selectedVersion = value
                    return .init(effects: .none, accepted: true)
                case "exportMake":
                    return try await export(version)
                case "make_again":
                    let reply = try await appModel.client.act(.deskCommand(.init(command: "make_again",
                        handle: version.reference, arguments: ["version": .string(version.version)])))
                    return .init(words: try FaceWindowReply.message(reply), effects: .known, accepted: true)
                case "makeVariations":
                    let acceptance = await appModel.startActiveChatTurn(
                        "Variations of Make " + version.reference + " v" + version.version + " (make.read has its prompt)")
                    if case .rejected(let message) = acceptance {
                        throw WireFailure(code: "make_variations_refused", message: message, cause: nil, effects: .none)
                    }
                    return .init(effects: .known, accepted: true)
                default:
                    throw WireFailure(code: "make_action_unavailable", message: "This Make page has no owner for the drawn action.",
                                      cause: nil, effects: .none)
                }
            } catch { return .interrupted(error) }
        }
    }

    private func export(_ version: FaceMakeVersion) async throws -> FaceActOutcome {
        let planned = try await appModel.client.act(.exportMake(.init(reference: version.reference,
            version: version.version, destination: .project(session: appModel.activeChatSessionId))))
        guard case .makeExportChoice(let choice) = planned else {
            _ = try FaceWindowReply.committed(planned)
            return .init(words: try FaceWindowReply.message(planned), effects: .known, accepted: true)
        }
        let directory: FaceResourceAccess.Opened?
        if let grant = choice.directory { directory = try await FaceResourceAccess.resolve(grant) }
        else { directory = nil }
        defer { if let directory, directory.scoped { directory.url.stopAccessingSecurityScopedResource() } }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = choice.name
        panel.directoryURL = directory?.url
        if let type = UTType(filenameExtension: (choice.name as NSString).pathExtension) { panel.allowedContentTypes = [type] }
        guard try await FaceNativePanel.choose(panel) == .OK, let url = panel.url else {
            return .init(words: "Export cancelled.", effects: .none, accepted: true)
        }
        let folder = url.deletingLastPathComponent()
        let bookmark = try await FaceResourceAccess.bookmark(folder)
        let grant = ResourceGrant(id: UUID(), name: folder.lastPathComponent, bookmark: bookmark, writable: true)
        let reply = try await appModel.client.act(.exportMake(.init(reference: version.reference, version: version.version,
            destination: .chosen(directory: grant, name: url.lastPathComponent))))
        _ = try FaceWindowReply.committed(reply)
        return .init(words: try FaceWindowReply.message(reply), effects: .known, accepted: true)
    }
}

/// One Make version drawn on a page (a piece on the Desk), through the same granted preview the Make pane draws.
struct PageMakePreview: View {
    let reference: String
    let version: String
    @Environment(AppModel.self) private var appModel
    private var key: FaceKey { .makePreview(reference: reference, version: version) }
    private var preview: MakePreviewFace? { appModel.face.slot(key).value(as: MakePreviewFace.self) }

    var body: some View {
        Group {
            if let preview, preview.state == .ready, preview.reference == reference, preview.version == version {
                // A piece on a page is there to be looked at: tall enough to read a board without scrolling inside it. A table is as
                // tall as its rows, a picture as its own proportions.
                let table = preview.resources.first.map { SheetTable.delimiter(type: ($0.name as NSString).pathExtension) != nil } == true
                GrantedMakePreview(preview: preview).id(preview.revision).frame(minHeight: table || preview.isPicture ? nil : 440)
            } else { FaceReadStatus(state: preview?.state) }
        }
        .modifier(FaceObservation(demand: .key(key)))
        // The piece stays drawn here across its versions; leaving it lets go of what its last table save said.
        .onDisappear { MakeSheetWords.shared.said[reference] = nil }
    }
}

private struct GrantedMakePreview: View {
    let preview: MakePreviewFace
    @Environment(\.quietCaptureSession) private var capture
    @State private var resources: [FaceResourceAccess.Opened] = []
    @State private var image: Data?
    @State private var issue: String?
    var body: some View {
        Group {
            if let capture {
                let held = capture.held(preview)
                if let image = held?.image { Image(nsImage: image).resizable().scaledToFit().padding(12) }
                else if let table = held?.table, let file = held?.resources.first?.url,
                        let delimiter = SheetTable.delimiter(type: file.pathExtension) {
                    MakeSheetView(file: file, delimiter: delimiter, reference: preview.reference, version: preview.version, read: table)
                } else if preview.kind == "web", let file = held?.resources.first?.url,
                        let folder = held?.resources.dropFirst().first?.url {
                    MakeMockupView(file: file, folder: folder, revision: 0)
                } else { FaceReadStatus(state: preview.state) }
            } else if let issue { Text(issue).foregroundStyle(.red).textSelection(.enabled) }
            else if let image, let decoded = NSImage(data: image) {
                Image(nsImage: decoded).resizable().scaledToFit().padding(12)
            } else if let file = resources.first?.url {
                if preview.kind == "web", let folder = resources.dropFirst().first?.url {
                    MakeMockupView(file: file, folder: folder, revision: 0)
                } else if preview.kind == "web" {
                    Text("The body did not grant the mockup's resource folder.").foregroundStyle(.red)
                } else if let delimiter = SheetTable.delimiter(type: file.pathExtension) {
                    MakeSheetView(file: file, delimiter: delimiter, reference: preview.reference, version: preview.version)
                } else { MakeQuickLookView(file: file, revision: 0) }
            } else if preview.resources.isEmpty {
                Text("The ready Make preview supplied no resource grant.").foregroundStyle(.red)
            } else { Text("Waiting on preview resources…").foregroundStyle(.secondary) }
        }
        .task(id: preview) {
            guard capture == nil else { return }
            for resource in resources where resource.scoped { resource.url.stopAccessingSecurityScopedResource() }
            resources = []
            image = nil
            issue = nil
            do {
                var opened: [FaceResourceAccess.Opened] = []
                do {
                    for grant in preview.resources { opened.append(try await FaceResourceAccess.resolve(grant)) }
                    if preview.isPicture, let file = opened.first {
                        image = try await FaceResourceAccess.bytes(file.url)
                        guard image.flatMap(NSImage.init(data:)) != nil else {
                            throw PartCallError(code: "image_decode_failed", message: "The granted image could not be decoded.")
                        }
                    }
                    try Task.checkCancellation()
                    resources = opened
                } catch {
                    for resource in opened where resource.scoped { resource.url.stopAccessingSecurityScopedResource() }
                    throw error
                }
            } catch { issue = error.localizedDescription }
        }
        .onDisappear { for resource in resources where resource.scoped { resource.url.stopAccessingSecurityScopedResource() }; resources = [] }
    }
}

enum FaceResourceAccess {
    struct Opened: Sendable { let url: URL; let scoped: Bool }
    @concurrent static func bookmark(_ url: URL) async throws -> Data {
        try url.bookmarkData()
    }
    @concurrent static func resolve(_ grant: ResourceGrant) async throws -> Opened {
        var stale = false
        let url = try URL(resolvingBookmarkData: grant.bookmark, options: [.withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else {
            throw PartCallError(code: "resource_grant_unavailable", message: "The resource grant is stale or could not be opened: " + grant.name)
        }
        return Opened(url: url, scoped: url.startAccessingSecurityScopedResource())
    }
    @concurrent static func bytes(_ url: URL) async throws -> Data { try Data(contentsOf: url) }
}

/// Compile network-blocking rules before loading; navigation may read only the mockup folder.
/// Keep scripts and message handlers absent so offline markup cannot reach app actions or open windows.
struct MakeMockupView: NSViewRepresentable {
    let file: URL
    let folder: URL
    let revision: Int
    @Environment(\.quietCaptureSession) private var capture

    func makeCoordinator() -> SandboxedPreview { SandboxedPreview() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Content rules cannot block WebRTC sockets, so offline mockups must disable scripts.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        if let capture {
            context.coordinator.capture = capture.register(view, cancel: { [weak coordinator = context.coordinator] in coordinator?.cancel() })
        }
        context.coordinator.show(file, folder: folder, revision: revision, in: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.show(file, folder: folder, revision: revision, in: view)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: SandboxedPreview) {
        coordinator.cancel()
        view.stopLoading()
        view.navigationDelegate = nil
    }

    @MainActor
    final class SandboxedPreview: NSObject, WKNavigationDelegate {
        var capture: QuietWebCapture?
        private var shown: (URL, URL, Int)?
        private var folder: URL?
        private var guarded = false
        private var preparation: Task<Void, Never>?

        private static let rules = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^file:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}}]
        """
        private static var compiled: WKContentRuleList?

        func cancel() {
            preparation?.cancel()
            preparation = nil
            folder = nil
            capture?.close()
        }

        func show(_ file: URL, folder: URL, revision: Int, in view: WKWebView) {
            let folder = folder.standardizedFileURL
            guard shown.map({ $0.0 != file || $0.1 != folder || $0.2 != revision }) ?? true else { return }
            shown = (file, folder, revision)
            preparation?.cancel()
            preparation = nil
            self.folder = nil
            view.stopLoading()
            preparation = Task { [weak self, weak view] in
                guard let self, let view, !Task.isCancelled else { return }
                do {
                    let rules: WKContentRuleList
                    if let compiled = Self.compiled { rules = compiled }
                    else {
                        guard let compiled = try await WKContentRuleListStore.default()
                            .compileContentRuleList(forIdentifier: "NativeAgentMakeOffline", encodedContentRuleList: Self.rules) else {
                            throw PartCallError(code: "offline_rules_missing", message: "WebKit returned no offline rule list.")
                        }
                        Self.compiled = compiled
                        rules = compiled
                    }
                    try Task.checkCancellation()
                    if !self.guarded {
                        view.configuration.userContentController.add(rules)
                        self.guarded = true
                    }
                    self.folder = folder
                    view.loadFileURL(file, allowingReadAccessTo: folder)
                } catch is CancellationError {
                    capture?.failed(CancellationError())
                } catch {
                    if let capture { capture.failed(error); return }
                    let reason = error.localizedDescription
                        .replacingOccurrences(of: "&", with: "&amp;")
                        .replacingOccurrences(of: "<", with: "&lt;")
                        .replacingOccurrences(of: ">", with: "&gt;")
                    view.loadHTMLString("<p>Could not prepare the offline preview: " + reason + "</p>", baseURL: nil)
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            let url = action.request.url
            if let url, ["about", "data", "blob"].contains(url.scheme ?? "") { return .allow }
            guard let url, url.isFileURL, let folder,
                  url.standardizedFileURL.pathComponents.starts(with: folder.pathComponents) else {
                if action.targetFrame?.isMainFrame == true {
                    capture?.failed(QuietCaptureSession.failure("The Make preview requested navigation outside its granted folder."))
                }
                return .cancel
            }
            return .allow
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { capture?.navigationFinished() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { capture?.failed(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            capture?.failed(error)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            capture?.failed(QuietCaptureSession.failure("The Make preview's WebKit process terminated."))
        }
    }
}

struct MakeQuickLookView: NSViewRepresentable {
    let file: URL
    let revision: Int

    final class QuickLookSelection { var shown: (URL, Int)? }

    func makeCoordinator() -> QuickLookSelection { QuickLookSelection() }

    func makeNSView(context: Context) -> NSView {
        guard let preview = QLPreviewView(frame: .zero, style: .normal) else {
            return NSHostingView(rootView: Text("Quick Look preview unavailable.").foregroundStyle(.secondary))
        }
        return preview
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let view = view as? QLPreviewView else { return }
        guard context.coordinator.shown.map({ $0.0 != file || $0.1 != revision }) ?? true else { return }
        let sameFile = context.coordinator.shown?.0 == file
        context.coordinator.shown = (file, revision)
        if sameFile { view.refreshPreviewItem() } else { view.previewItem = file as NSURL }
    }
}
