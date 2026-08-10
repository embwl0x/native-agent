import AppKit
import SwiftUI

private enum WorkbenchPane: String, CaseIterable, Identifiable {
    case files, review, terminal, preview, evidence
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct NativeExperienceWorkbenchPage: View {
    @Environment(AppModel.self) private var appModel
    @State private var workspaceID: String?
    @State private var pane: WorkbenchPane = .files
    @State private var files: [URL] = []
    @State private var selectedFile: URL?
    @State private var gitStatus = ""
    @State private var gitDiff = ""
    @State private var loading = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Project", selection: $workspaceID) {
                    Text("Choose a saved project").tag(String?.none)
                    ForEach(appModel.workspaces) { Text($0.name).tag(Optional($0.id)) }
                }
                .frame(maxWidth: 320)
                Picker("Pane", selection: $pane) {
                    ForEach(WorkbenchPane.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).frame(maxWidth: 480)
                Spacer()
                Button("Desk", systemImage: "checklist") { NativeAgentAppCoordinator.shared.request(.sidebar(.desk)) }
            }
            .padding(16)
            Divider()
            paneBody.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            await appModel.refreshForSidebarItem(.connectors)
            workspaceID = workspaceID ?? appModel.workspaces.first?.id
            await refresh()
        }
        .onChange(of: workspaceID) { _, _ in Task { await refresh() } }
    }

    @ViewBuilder private var paneBody: some View {
        if let workspace {
            switch pane {
            case .files:
                List(files, id: \.self, selection: $selectedFile) { file in
                    HStack {
                        Image(systemName: "doc")
                        Text(file.path.replacingOccurrences(of: workspace.path + "/", with: ""))
                            .font(.callout.monospaced()).lineLimit(1)
                    }
                    .tag(file)
                }
                .overlay { if files.isEmpty { ContentUnavailableView("No bounded files", systemImage: "doc") } }
            case .review:
                VSplitView {
                    textPane("Git status", gitStatus.ifBlank("Working tree is clean or Git is unavailable."))
                    textPane("Uncommitted diff", gitDiff.ifBlank("No textual diff."))
                }
            case .terminal:
                NativeExperiencePage(title: "Terminal", subtitle: "Use the system Terminal in this saved project. NativeAgent does not create a second command executor.") {
                    NativeExperienceCard(title: workspace.name, icon: "terminal") {
                        Text(workspace.path).font(.caption.monospaced()).textSelection(.enabled)
                        HStack {
                            Button("Open Terminal here", systemImage: "terminal") { openTerminal(workspace.path) }
                            Button("Run from Desk") { NativeAgentAppCoordinator.shared.request(.sidebar(.desk)) }
                        }
                        Text("Command effects continue through the Desk's canonical builder and execution lane with TrustCenter, approval, audit, and effect-time checks.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            case .preview:
                NativeExperiencePage(title: "Preview", subtitle: "Preview a selected project file with the native macOS owner.") {
                    NativeExperienceCard(title: selectedFile?.lastPathComponent ?? "No file selected", icon: "eye") {
                        if let selectedFile {
                            Text(selectedFile.path).font(.caption.monospaced()).textSelection(.enabled)
                            HStack {
                                Button("Open") { NSWorkspace.shared.open(selectedFile) }
                                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([selectedFile]) }
                            }
                        } else {
                            Text("Choose a file in Files, then return here.").foregroundStyle(.secondary)
                        }
                    }
                }
            case .evidence:
                List {
                    Section("Desk execution receipts") {
                        ForEach(appModel.executions.filter { $0.projectSpaceId == workspace.id }) { execution in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(execution.title).font(.headline)
                                Text("\(execution.status) · \(execution.id)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("Current Git evidence") {
                        Text(gitStatus.ifBlank("No status output.")).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
        } else {
            ContentUnavailableView("Choose a saved project", systemImage: "folder", description: Text("Project Spaces reuse the canonical workspace registry."))
        }
    }

    private var workspace: WorkspaceRecord? { appModel.workspaces.first { $0.id == workspaceID } }

    private func textPane(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ScrollView { Text(text).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }.padding(16)
    }

    @MainActor private func refresh() async {
        guard let workspace else { files = []; return }
        loading = true
        defer { loading = false }
        let root = URL(fileURLWithPath: workspace.path, isDirectory: true)
        files = await Task.detached(priority: .utility) {
            let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
            var result: [URL] = []
            while let url = enumerator.nextObject() as? URL {
                if [".git", ".build", "DerivedData", "node_modules"].contains(url.lastPathComponent) {
                    enumerator.skipDescendants(); continue
                }
                if (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true { result.append(url) }
                if result.count >= 300 { break }
            }
            return result.sorted { $0.path < $1.path }
        }.value
        async let status = try? NativeClient.runGit(["status", "--short", "--branch"], repoRoot: root, timeout: 8)
        async let diff = try? NativeClient.runGit(["diff", "--stat", "--", "."], repoRoot: root, timeout: 8)
        let values = await (status, diff)
        gitStatus = values.0?.stdout ?? values.0?.stderr ?? ""
        gitDiff = values.1?.stdout ?? values.1?.stderr ?? ""
    }

    private func openTerminal(_ path: String) {
        let shellPath = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = "cd " + shellPath
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to do script \"\(escaped)\""
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
    }
}

private extension String {
    func ifBlank(_ fallback: String) -> String { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : self }
}
