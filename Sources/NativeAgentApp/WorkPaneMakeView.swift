import Cognition
import AppKit
import PersistenceCore
import QuickLookUI
import Studio
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The Work pane's Make tab: what I made, one version at a time, with the
/// earlier ones one click back (`MakeStudio`). A mockup renders in an offline
/// web view; an image from image.generate carries Try again, Variations and
/// Use this; anything else shows through Quick Look. Nil `ref` is the newest.
struct WorkPaneMakeView: View {
    let ref: String?
    @Environment(AppModel.self) private var appModel
    @State private var shelf = MakeStudio.Shelf.shared
    @State private var preparedTitle = ""
    @State private var preparedImage: NSImage?
    @State private var preparedFile: URL?
    @State private var preparedRevision = -1
    @State private var revision = 0
    /// Index into the ref's versions; nil is the newest.
    @State private var shown: Int?
    @State private var making = false
    @State private var saving = false
    @State private var note: String?

    private var root: URL { appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot() }

    var body: some View {
        Group {
            if let meta = shelf.meta(ref), !meta.versions.isEmpty {
                let index = min(shown ?? meta.versions.count - 1, meta.versions.count - 1)
                let version = meta.versions[index]
                let file = MakeStudio(dataRoot: root).url(meta.ref, version)
                VStack(spacing: 0) {
                    header(meta, index: index, file: file)
                    Divider()
                    preview(file, folder: MakeStudio(dataRoot: root).folder(meta.ref))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let prompt = version.prompt, MakeStudio.imageTypes.contains(file.pathExtension.lowercased()) {
                        Divider()
                        imageActions(meta.ref, version, file: file, prompt: prompt)
                    }
                }
                .task(id: file) {
                    await EventDeadlinePhysiology.refreshOnChanges(paths: [file]) { revision &+= 1 }
                }
                .onChange(of: version) { _, _ in revision &+= 1 }
                .task(id: "\(file.path) \(revision)") {
                    let revision = revision
                    preparedTitle = ""
                    preparedImage = nil
                    preparedFile = nil
                    let prepared = await Task.detached(priority: .userInitiated) {
                        (MakeStudio.title(version, file: file), MakeStudio.imageTypes.contains(file.pathExtension.lowercased()) ? NSImage(contentsOf: file) : nil)
                    }.value
                    guard !Task.isCancelled else { return }
                    preparedTitle = prepared.0
                    preparedImage = prepared.1
                    preparedFile = file
                    preparedRevision = revision
                }
            } else {
                Text(shelf.fault == nil ? "Nothing made yet." : "Nothing on the shelf could be read.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // The shelf shows its last good read; what it could not read is said.
        .safeAreaInset(edge: .bottom) {
            if let fault = shelf.fault {
                Text(fault)
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: ref) {
            shown = nil
            note = nil
            shelf.open(dataRoot: root)
        }
        // A new version lands in front.
        .onChange(of: shelf.meta(ref).map { "\($0.ref) \($0.versions.count)" }) { shown = nil }
    }

    private func header(_ meta: MakeStudio.Meta, index: Int, file: URL) -> some View {
        HStack(spacing: 8) {
            Text(preparedFile == file && preparedRevision == revision ? preparedTitle : "")
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(meta.ref)
            Spacer()
            Button { shown = index - 1 } label: { Image(systemName: "chevron.left") }
                .disabled(index == 0)
                .help("Earlier version")
            Text("v\(meta.versions[index].n) of \(meta.versions.count)")
                .font(ShellType.caption.monospacedDigit())
                .foregroundStyle(NativeAgentShell.secondary)
            Button { shown = index + 1 } label: { Image(systemName: "chevron.right") }
                .disabled(index == meta.versions.count - 1)
                .help("Later version")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func preview(_ file: URL, folder: URL) -> some View {
        let type = file.pathExtension.lowercased()
        if MakeStudio.webTypes.contains(type) {
            MakeMockupView(file: file, folder: folder, revision: revision)
        } else if MakeStudio.imageTypes.contains(type) {
            if preparedFile == file, preparedRevision == revision, let image = preparedImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
                    .id(revision)
            } else if preparedFile == file, preparedRevision == revision {
                MakeQuickLookView(file: file, revision: revision)
            }
        } else {
            MakeQuickLookView(file: file, revision: revision)
        }
    }

    private func imageActions(_ ref: String, _ version: MakeStudio.Version, file: URL, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(prompt)
                .font(ShellType.caption)
                .foregroundStyle(NativeAgentShell.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Button {
                    tryAgain(ref, prompt: prompt)
                } label: {
                    if making { ProgressView().controlSize(.small) } else { Text("Try again") }
                }
                .disabled(making)
                Button("Variations") { variations(ref, version) }
                Button("Use this") { use(file, ref: ref, version: version, prompt: prompt) }
                    .disabled(saving)
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if let note {
                Text(note)
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(3)
            }
        }
        .padding(12)
    }

    // MARK: - The three buttons

    /// The same prompt through image.generate's own call and gates, as a
    /// click of User's (`DeskToolDispatchRouter`); the image lands as the
    /// ref's next version (`__make_ref`), and the shelf brings it forward.
    private func tryAgain(_ ref: String, prompt: String) {
        making = true
        note = nil
        let root = root
        Task {
            let answer: String?
            do {
                let result = try await DeskToolDispatchRouter(dataRoot: root)
                    .run(tool: "image_generate", input: ["prompt": .string(prompt), "__make_ref": .string(ref)])
                answer = Self.failureText(result)
            } catch {
                answer = UserFacingError.message(error, action: "make that image")
            }
            making = false
            note = answer
        }
    }

    /// Asked of me in this chat, through the composer's own send.
    private func variations(_ ref: String, _ version: MakeStudio.Version) {
        Task {
            let acceptance = await appModel.startActiveChatTurn(
                "Variations of Make \(ref) v\(version.n) (make.read has its prompt)")
            if case .rejected(let message) = acceptance { note = message }
        }
    }

    /// Into the conversation's project folder when it has one, else where
    /// User picks; the prompt rides beside it as <name>.prompt.txt.
    private func use(_ file: URL, ref: String, version: MakeStudio.Version, prompt: String) {
        guard !saving else { return }
        saving = true
        let name = "\(ref)-v\(version.n).\(file.pathExtension)"
        let projectPath = appModel.engine.transcripts.sessions
            .first { $0.id == appModel.activeChatSessionId }?.worktreePath
        Task {
            defer { saving = false }
            let (project, planned) = await Task.detached(priority: .userInitiated) {
                MakeStudio.exportDestination(projectPath: projectPath, name: name)
            }.value
            var target = planned
            if target == nil {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = name
                panel.directoryURL = project
                if let type = UTType(filenameExtension: file.pathExtension) { panel.allowedContentTypes = [type] }
                guard panel.runModal() == .OK, let picked = panel.url else { return }
                target = picked
            }
            guard let target else { return }
            note = await Task.detached(priority: .userInitiated) {
                do {
                    return try MakeStudio.export(file, to: target, prompt: prompt)
                } catch {
                    return UserFacingError.message(error, action: "save that image")
                }
            }.value
        }
    }

    /// Nil when the call made its image; otherwise what it said.
    private static func failureText(_ result: JSONValue) -> String? {
        guard case .object(let fields) = result else { return "image.generate gave no answer." }
        if fields["status"] == .string("ok") { return nil }
        for key in ["detail", "error", "message", "reason"] {
            if case .string(let text)? = fields[key], !text.isEmpty { return text }
        }
        return "image.generate did not make an image."
    }
}

/// A mockup, offline and script-free: every load that is not a local file, data or blob is
/// blocked by a content rule list compiled before the first load; navigation
/// stays inside the mockup's own folder, which is all it may read; no script
/// message handler reaches the app, and nothing opens a window.
struct MakeMockupView: NSViewRepresentable {
    let file: URL
    let folder: URL
    let revision: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // No scripts: content rules can't reach WebRTC's sockets, so a script
        // could still talk to the network. A mockup is markup and CSS.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        context.coordinator.show(file, folder: folder, revision: revision, in: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.show(file, folder: folder, revision: revision, in: view)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private var shown: (URL, Int)?
        private var folder: URL?
        private var guarded = false

        private static let rules = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^file:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}}]
        """
        private static var compiled: WKContentRuleList?

        func show(_ file: URL, folder: URL, revision: Int, in view: WKWebView) {
            guard shown.map({ $0.0 != file || $0.1 != revision }) ?? true else { return }
            shown = (file, revision)
            self.folder = folder.standardizedFileURL
            Task {
                if Self.compiled == nil {
                    Self.compiled = try? await WKContentRuleListStore.default()
                        .compileContentRuleList(forIdentifier: "NativeAgentMakeOffline", encodedContentRuleList: Self.rules)
                }
                guard let rules = Self.compiled else {
                    view.loadHTMLString("<p style=\"font: 13px -apple-system\">The offline guard did not compile, "
                                        + "so this mockup was not opened.</p>", baseURL: nil)
                    return
                }
                if !guarded {
                    view.configuration.userContentController.add(rules)
                    guarded = true
                }
                view.loadFileURL(file, allowingReadAccessTo: folder)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            let url = action.request.url
            if let url, ["about", "data", "blob"].contains(url.scheme ?? "") { return .allow }
            guard let url, url.isFileURL, let folder,
                  url.standardizedFileURL.path.hasPrefix(folder.path + "/") else { return .cancel }
            return .allow
        }
    }
}

/// Anything that is not a mockup or an image, through Quick Look.
struct MakeQuickLookView: NSViewRepresentable {
    let file: URL
    let revision: Int

    final class Coordinator { var shown: (URL, Int)? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> QLPreviewView {
        QLPreviewView(frame: .zero, style: .normal)!
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard context.coordinator.shown.map({ $0.0 != file || $0.1 != revision }) ?? true else { return }
        let sameFile = context.coordinator.shown?.0 == file
        context.coordinator.shown = (file, revision)
        if sameFile { view.refreshPreviewItem() } else { view.previewItem = file as NSURL }
    }
}
