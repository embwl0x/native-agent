import SwiftUI

/// The configuration page deliberately keeps its mutation boundary out of the
/// SwiftUI tree.  A remote node is an effect target, so the UI can only present
/// the result of the canonical `NativeClient` write; it must not infer that a
/// button press changed the executor store.
enum RemoteNodeConfigurationAction {
    enum SaveOutcome: Equatable {
        case saved(ExperienceRemoteNode)
        case failed(String)

        var errorMessage: String? {
            guard case let .failed(message) = self else { return nil }
            return message
        }
    }

    enum DeleteOutcome: Equatable {
        case deleted
        case noSelection
        case failed(String)

        var errorMessage: String? {
            guard case let .failed(message) = self else { return nil }
            return message
        }
    }

    static func save(
        draft: RemoteNodeDraft,
        selectedID: String?,
        client: NativeClient
    ) async -> SaveOutcome {
        do {
            return .saved(try await client.saveTrustedRemoteNode(draft.node(id: selectedID)))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func delete(selectedID: String?, client: NativeClient) async -> DeleteOutcome {
        guard let selectedID else { return .noSelection }
        do {
            try await client.removeTrustedRemoteNode(id: selectedID)
            return .deleted
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func nodeStateText(enabled: Bool) -> String {
        enabled ? "Enabled" : "Disabled"
    }
}

struct NativeExperienceRemoteNodesPage: View {
    @Environment(AppModel.self) private var appModel
    @State private var nodes: [ExperienceRemoteNode] = []
    @State private var selectedID: String?
    @State private var draft: RemoteNodeDraft
    @State private var error: String?
    @State private var deleteRequested = false

    init(initialDraft: RemoteNodeDraft = RemoteNodeDraft()) {
        _draft = State(initialValue: initialDraft)
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(nodes, selection: $selectedID) { node in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { Text(node.name); if node.enabled { Circle().fill(.green).frame(width: 7, height: 7) } }
                        Text("\(node.user)@\(node.host):\(node.port)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(RemoteNodeConfigurationAction.nodeStateText(enabled: node.enabled))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(node.enabled ? .green : .secondary)
                    }.tag(node.id)
                }
                Divider()
                Button("New node", systemImage: "plus") { selectedID = nil; draft = RemoteNodeDraft() }
                    .padding(10)
            }
            .frame(minWidth: 240, idealWidth: 290)

            NativeExperiencePage(
                title: draft.name.isEmpty ? "Trusted Remote Node" : draft.name,
                subtitle: "A narrow MacControl effect target—not a remote agent. SSH uses your existing local credentials, an exact pinned host key, executable allowlists, TrustCenter, approval, effect-time validation, and durable receipts."
            ) {
                NativeExperienceCard(title: "Identity pin", icon: "lock.shield") {
                    TextField("Display name", text: $draft.name)
                    HStack { TextField("Host", text: $draft.host); TextField("Port", value: $draft.port, format: .number).frame(width: 90) }
                    TextField("SSH user", text: $draft.user)
                    Picker("Host key algorithm", selection: $draft.hostKeyAlgorithm) {
                        ForEach(["ssh-ed25519", "ecdsa-sha2-nistp256", "rsa-sha2-512", "rsa-sha2-256", "ssh-rsa"], id: \.self) { Text($0) }
                    }
                    TextField("Pinned public host key (base64 body)", text: $draft.hostKey, axis: .vertical)
                        .font(.caption.monospaced()).lineLimit(2...4)
                    if let fingerprint = draft.fingerprint { LabeledContent("Fingerprint", value: fingerprint).font(.caption).textSelection(.enabled) }
                }

                NativeExperienceCard(title: "Effect boundary", icon: "checkmark.shield") {
                    TextField("Allowed absolute executables, one per line", text: $draft.allowedExecutables, axis: .vertical)
                        .font(.caption.monospaced()).lineLimit(4...10)
                    Toggle("Node enabled", isOn: $draft.enabled)
                    Text("Arguments are separate bounded values and individually quoted. Shell command strings, implicit trust discovery, password storage, remote memory, and remote schedules are not supported.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Button("Save configuration") { Task { await save() } }.buttonStyle(.borderedProminent)
                    if selectedID != nil { Button("Delete", role: .destructive) { deleteRequested = true } }
                    Spacer()
                    Button("Open Trust Center") { NativeAgentAppCoordinator.shared.request(.sidebar(.trust)) }
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                NativeExperienceCard(title: "How execution works", icon: "terminal") {
                    Text("The agent discovers enabled nodes with remote_node_list, then calls remote_node_execute with a node id, exact executable, and argv. Execution is always a confirm-class critical effect—even during Full Mac YOLO—and the node record is re-read immediately before SSH.")
                        .font(.callout)
                    Text("No connection is attempted from this configuration screen.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task { await load() }
        .onChange(of: selectedID) { _, id in
            if let node = nodes.first(where: { $0.id == id }) { draft = RemoteNodeDraft(node) }
        }
        .confirmationDialog("Delete this remote node configuration? Receipts remain for audit.", isPresented: $deleteRequested) {
            Button("Delete node", role: .destructive) { Task { await remove() } }
        }
    }

    @MainActor private func load() async {
        do { nodes = try await appModel.client.trustedRemoteNodes(); error = nil }
        catch { self.error = error.localizedDescription; nodes = [] }
    }

    @MainActor private func save() async {
        switch await RemoteNodeConfigurationAction.save(
            draft: draft,
            selectedID: selectedID,
            client: appModel.client
        ) {
        case .saved(let saved):
            error = nil
            await load(); selectedID = saved.id; draft = RemoteNodeDraft(saved)
        case .failed(let message):
            error = message
        }
    }

    @MainActor private func remove() async {
        switch await RemoteNodeConfigurationAction.delete(selectedID: selectedID, client: appModel.client) {
        case .deleted:
            error = nil
            self.selectedID = nil; draft = RemoteNodeDraft(); await load()
        case .noSelection:
            break
        case .failed(let message):
            error = message
        }
    }
}

struct RemoteNodeDraft {
    var name = ""
    var host = ""
    var port = 22
    var user = ""
    var hostKeyAlgorithm = "ssh-ed25519"
    var hostKey = ""
    var allowedExecutables = "/usr/bin/git\n/usr/bin/swift"
    var enabled = false

    init() {}
    init(
        name: String,
        host: String,
        port: Int = 22,
        user: String,
        hostKeyAlgorithm: String = "ssh-ed25519",
        hostKey: String,
        allowedExecutables: String,
        enabled: Bool
    ) {
        self.name = name
        self.host = host
        self.port = port
        self.user = user
        self.hostKeyAlgorithm = hostKeyAlgorithm
        self.hostKey = hostKey
        self.allowedExecutables = allowedExecutables
        self.enabled = enabled
    }
    init(_ node: ExperienceRemoteNode) {
        name = node.name; host = node.host; port = node.port; user = node.user
        hostKeyAlgorithm = node.hostKeyAlgorithm; hostKey = node.hostKey
        allowedExecutables = node.allowedExecutables.joined(separator: "\n"); enabled = node.enabled
    }
    var fingerprint: String? { node(id: "preview").hostKeyFingerprint }
    func node(id: String?) -> ExperienceRemoteNode {
        ExperienceRemoteNode(
            id: id ?? UUID().uuidString.lowercased(), name: name, host: host, port: port, user: user,
            hostKeyAlgorithm: hostKeyAlgorithm, hostKey: hostKey,
            allowedExecutables: allowedExecutables.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            enabled: enabled
        )
    }
}
