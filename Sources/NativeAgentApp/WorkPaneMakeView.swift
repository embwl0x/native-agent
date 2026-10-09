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
    @State private var shelf = MakeShelf()
    /// Index into the ref's versions; nil is the newest.
    @State private var shown: Int?
    @State private var making = false
    @State private var note: String?

    private var root: URL { appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot() }

    var body: some View {
        Group {
            if let meta = shelf.meta, !meta.versions.isEmpty {
                let index = min(shown ?? meta.versions.count - 1, meta.versions.count - 1)
                let version = meta.versions[index]
                let file = MakeStudio(dataRoot: root).url(meta.ref, version)
                VStack(spacing: 0) {
                    header(meta, index: index)
                    Divider()
                    preview(file, folder: MakeStudio(dataRoot: root).folder(meta.ref))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let prompt = version.prompt, Self.imageTypes.contains(file.pathExtension.lowercased()) {
                        Divider()
                        imageActions(meta.ref, version, file: file, prompt: prompt)
                    }
                }
                .onChange(of: file) { shelf.watch(file) }
                .onAppear { shelf.watch(file) }
            } else {
                Text("Nothing made yet.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: ref) {
            shown = nil
            note = nil
            shelf.open(ref, dataRoot: root)
        }
        // A new version lands in front.
        .onChange(of: shelf.meta.map { "\($0.ref) \($0.versions.count)" }) { shown = nil }
    }

    private func header(_ meta: MakeStudio.Meta, index: Int) -> some View {
        HStack(spacing: 8) {
            Text(Self.title(meta.versions[index], file: MakeStudio(dataRoot: root).url(meta.ref, meta.versions[index])))
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

    /// What User reads in the header: a mockup's own <title>, else an image's
    /// prompt, else the file's name. The ref stays in the tooltip.
    static func title(_ version: MakeStudio.Version, file: URL) -> String {
        if webTypes.contains(file.pathExtension.lowercased()),
           let html = try? String(contentsOf: file, encoding: .utf8),
           let open = html.range(of: "<title>", options: .caseInsensitive),
           let close = html.range(of: "</title>", options: .caseInsensitive, range: open.upperBound..<html.endIndex) {
            let text = html[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        if let prompt = version.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty { return prompt }
        return file.lastPathComponent
    }

    static let webTypes: Set = ["html", "htm", "xhtml", "svg"]
    static let imageTypes: Set = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff"]

    @ViewBuilder
    private func preview(_ file: URL, folder: URL) -> some View {
        let type = file.pathExtension.lowercased()
        if Self.webTypes.contains(type) {
            MakeMockupView(file: file, folder: folder, revision: shelf.revision)
        } else if Self.imageTypes.contains(type), let image = NSImage(contentsOf: file) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(12)
                .id(shelf.revision)
        } else {
            MakeQuickLookView(file: file, revision: shelf.revision)
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
        let name = "\(ref)-v\(version.n).\(file.pathExtension)"
        let project = appModel.engine.transcripts.sessions
            .first { $0.id == appModel.activeChatSessionId }?.worktreePath
            .flatMap { path -> URL? in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                    ? URL(fileURLWithPath: path, isDirectory: true) : nil
            }
        var target = project?.appendingPathComponent(name)
        // Never over a file already there: the panel asks first.
        if let planned = target, FileManager.default.fileExists(atPath: planned.path)
            || FileManager.default.fileExists(atPath: planned.deletingPathExtension().appendingPathExtension("prompt.txt").path) {
            target = nil
        }
        if target == nil {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.directoryURL = project
            if let type = UTType(filenameExtension: file.pathExtension) { panel.allowedContentTypes = [type] }
            guard panel.runModal() == .OK, let picked = panel.url else { return }
            target = picked
        }
        guard let target else { return }
        // The same file by identity (a hard link or symlink too), not by path.
        let identity = { (url: URL) in
            try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        }
        guard identity(target).map({ $0.isEqual(identity(file)) }) != true else {
            note = "That is the studio's own file, so nothing was saved. Pick another place."
            return
        }
        let sidecar = target.deletingPathExtension().appendingPathExtension("prompt.txt")
        do {
            // Written beside the target and swapped in: a failed save leaves what was there.
            try Data(contentsOf: file).write(to: target, options: .atomic)
            try prompt.write(to: sidecar, atomically: true, encoding: .utf8)
            note = "Saved to \(target.path)"
        } catch {
            note = UserFacingError.message(error, action: "save that image")
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

/// One ref's meta, reread whenever its meta or the studio folder changes; a
/// rewritten shown file bumps `revision`, so it reloads under the same path.
@MainActor
@Observable
final class MakeShelf {
    private(set) var meta: MakeStudio.Meta?
    private(set) var revision = 0
    private var asked: String?
    private var studio: MakeStudio?
    private var watcher: FileChangeWatcher?
    private var watchedFile: URL?
    private var armed: [URL] = []

    func open(_ ref: String?, dataRoot: URL) {
        asked = ref
        let studio = MakeStudio(dataRoot: dataRoot)
        self.studio = studio
        try? FileManager.default.createDirectory(at: studio.root, withIntermediateDirectories: true)
        watchedFile = nil
        reload()
    }

    func watch(_ file: URL) {
        guard file.standardizedFileURL != watchedFile, let studio else { return }
        watchedFile = file.standardizedFileURL
        rearm(studio)
    }

    private func changed(_ path: URL) {
        if path == watchedFile { revision += 1 }
        reload()
    }

    private func reload() {
        guard let studio else { return }
        let fresh = (asked ?? studio.newestRef()).flatMap(studio.meta)
        if fresh != meta { meta = fresh }
        rearm(studio)
    }

    /// Every ref's meta, not only the shown one's: a new version of another
    /// ref is the new newest. A new ref changes the set, so it is re-armed.
    private func rearm(_ studio: MakeStudio) {
        let refs = ((try? FileManager.default.contentsOfDirectory(atPath: studio.root.path)) ?? []).filter(MakeStudio.isRef)
        var paths = [studio.root] + refs.sorted().map { studio.folder($0).appendingPathComponent("meta.json") }
        if let watchedFile { paths.append(watchedFile) }
        guard paths != armed else { return }
        armed = paths
        watcher?.cancel()
        watcher = FileChangeWatcher(paths: paths) { [weak self] path in
            Task { @MainActor in self?.changed(path.standardizedFileURL) }
        }
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
