import Foundation
import MindCore
import NativeAgentCore
import PersistenceCore
import MacNerves
import DeskCore
import SenseCore
import NativeAgentShared
// Blueprint: | `AgentWorkspaceBinding.swift` | Workspace ports bind the originating turn. Recent-life readers supply turn facts and trace breath. |

package enum ChatWorkspaceBinding {
    package static func operation(turn: Turn?, invocation: ChatToolInvocation, jobs: AgentJobStore) -> WorkspaceOperation {
        WorkspaceOperation(ports: .init(conversations: Conversations(turn: turn),
            tools: Tools(invocation: invocation.partInvocation(turn: turn, surface: "app"),
                         dataRoot: jobs.fileURL.deletingLastPathComponent().deletingLastPathComponent())), jobs: jobs, bodyField: invocation.bodyField, turn: turn)
    }

    package static func pending(turn: Turn, invocation: ChatToolInvocation, jobs: AgentJobStore, dataRoot: URL?, scope: String?) async -> JSONValue? {
        await AgentWorkspaceArrivals.pending(workspace: operation(turn: turn, invocation: invocation, jobs: jobs), dataRoot: dataRoot, scope: scope, announce: false)
    }

    package static func glance(turn: Turn, invocation: ChatToolInvocation, jobs: AgentJobStore, pages: PartFaces?, dataRoot: URL, scope: String, at: Date?,
        message: String) async -> PreparedWorkspaceGlance {
        await AgentScreen.glance(workspace: operation(turn: turn, invocation: invocation, jobs: jobs), pages: pages, dataRoot: dataRoot, scope: scope, turn: at, message: message)
    }

    package static func breath(turn: Turn, dataRoot: URL, scope: String, peer: Bool, since: Date?,
                               shown: Set<String>, at: Date) async -> (text: String?, read: Bool, acts: [String]) {
        let reading = await AgentScreen.breath(dataRoot: dataRoot, scope: scope, peer: peer,
                                               since: since, shown: shown, now: at)
        if let text = reading.text {
            TurnTraceBus.fireFromContext(kind: "context.breath", sessionId: scope,
                payload: .object(["lines": .array(text.components(separatedBy: "\n").map(JSONValue.string)),
                                  "read": .bool(reading.read)]), turn: turn)
        }
        return reading
    }

    private struct Conversations: AgentWorkspaceConversationPort {
        let turn: Turn?
        func liveHealth(dataRoot: URL) throws -> [String: AgentLocalHealth] {
            try AgentContactHealth.read(dataRoot: dataRoot)
        }
        /// Dot's presence is read live from its transport, which announces its own changes.
        var healthNotifications: [Notification.Name] { [ChatGPTDotIPCTransport.DidChange.name] }
        func records(dataRoot: URL, locked: Bool) throws -> [AgentConversationRecord] {
            let store = AgentConversationStore(dataRoot: dataRoot)
            return try locked ? store.records() : store.recordsUnlocked()
        }
        func find(dataRoot: URL, scopeSessionID: String, agent: String, label: String?) throws -> AgentConversationRecord? {
            try AgentConversationStore(dataRoot: dataRoot).find(scopeSessionID: scopeSessionID, agent: agent, label: label)
        }
        func peers(dataRoot: URL) throws -> [AgentWorkspacePeer] {
            try AgentPeerStore(dataRoot: dataRoot).list().map {
                .init(id: $0.id, name: $0.name, elevationAllowed: $0.elevationAllowed, canAnswerBack: $0.canAnswerBack)
            }
        }
        func identity(dataRoot: URL) throws -> AgentContactIdentity { try AgentContactIdentity(dataRoot: dataRoot) }
        func answeredRequests(dataRoot: URL) throws -> [(message: String?, run: String?, chat: String?, modified: Date)] {
            try GrokRequestStore(dataRoot: dataRoot).answeredRequests()
        }
        func openHuman(sessionID: String, limit: Int?, dataRoot: URL) async throws -> JSONValue {
            guard let turn else {
                throw ToolFailureError("Opening a conversation requires the originating turn.", effects: .none)
            }
            // Consume only shown messages under their owner's stamp.
            return await HumanConversationReader.open(turn: turn, sessionID: sessionID, limit: limit, dataRoot: dataRoot)
        }
        func presentation(_ row: AgentConversationRecord) -> JSONValue {
            AgentConversationView.conversationPresentation(row)
        }
        func unsettledAttention(_ row: AgentConversationRecord) -> Bool { AgentConversationSession.unsettledAttention(row) }
        func shown(answers: [String: String], peer: String, scope: String, dataRoot: URL) throws {
            guard peer.hasPrefix("peer:") else { return }
            let store = GrokRequestStore(dataRoot: dataRoot), id = String(peer.dropFirst(5))
            guard let contact = try AgentPeerStore(dataRoot: dataRoot).list().first(where: { $0.id == id }) else {
                throw AgentConversationStore.Failure(message: "Contact \(peer) is unavailable; reopen its room from the current contacts.")
            }
            guard contact.transport == .grokBot else { return }
            // A hand-over belongs to the requesting chat even when viewed elsewhere.
            for (answer, words) in answers {
                guard try store.kept(answer, peer: id)?.conversationID == scope else { continue }
                try store.shown(answer, peer: id, by: "the room") { $0 == words }
            }
        }
    }

    private struct Tools: AgentWorkspaceToolPort {
        let invocation: Parts.Invocation
        let dataRoot: URL
        func readoutFace(_ input: JSONValue, dataRoot: URL) async -> PartCallResult<PartFace> {
            await WorkspaceFaces.read(input, dataRoot: dataRoot, invocation: invocation)
        }
        func readout(_ input: JSONValue, dataRoot: URL) async throws -> JSONValue {
            let result: PartCallResult<JSONValue> = await Parts(root: dataRoot).call(id: "workspace-readout", input: input, invocation: invocation)
            switch result {
            case .success(let value): return value
            case .failure(let error): throw error
            }
        }
        func builtAbilities(dataRoot: URL, now: Date) async throws -> String {
            async let senses = FileSenseRegistry(dataRoot: dataRoot).all()
            let tools = try await SwiftNativeToolRegistry(root: dataRoot).listTools()
            let callable = Set(try SwiftToolDispatcher.authoredTools(records: tools).map { $0.schema.name })
            let since = now.addingTimeInterval(-7 * 86_400)
            var names: [(name: String, changed: Date, builtIn: Bool)] = []
            for part in tools where callable.contains(part.id) {
                let changed = NativeTimestampFormat.parseOptionalISO8601FractionalFirst(part.updatedAt ?? part.createdAt) ?? .distantPast
                let builtIn = part.fields["overrides"] == .string("built_in") || part.fields["origin"]?.objectValue?["by"] == .string("pack")
                if !builtIn || changed >= since { names.append((part.name + " (ability)", changed, builtIn)) }
            }
            for sense in try await senses where sense.status == .on {
                let changed = max(sense.createdAt ?? .distantPast, sense.enabledAt ?? .distantPast)
                if sense.origin == .grown || changed >= since {
                    names.append((sense.corner.key + " (sense)", changed, sense.origin != .grown))
                }
            }
            names.sort {
                if $0.builtIn != $1.builtIn { return !$0.builtIn }
                if $0.changed != $1.changed { return $0.changed > $1.changed }
                return $0.name < $1.name
            }
            let prefix = "Your live abilities you built or changed in 7d: "
            let suffix = "; you can reach Mac apps through app."
            var shown: [String] = []
            for name in names {
                let more = names.count - shown.count - 1
                let candidate = prefix + (shown + [name.name]).joined(separator: ", ")
                    + (more > 0 ? ", +\(more) more" : "") + suffix
                if candidate.count > 200 { break }
                shown.append(name.name)
            }
            let more = names.count - shown.count
            return prefix + (shown.isEmpty && more == 0 ? "none" : shown.joined(separator: ", "))
                + (more > 0 ? (shown.isEmpty ? "" : ", ") + "+\(more) more" : "") + suffix
        }

        func modelVisibleCatalogToolNames(_ names: Set<String>) -> Set<String> {
            SwiftToolDispatcher.modelVisibleCatalogToolNames(names)
        }
        func appAction(_ tool: String) -> String? { ToolNameAliases.appAction(tool) }
        func macIntegrationAccess(_ name: String) -> MacIntegrationAccess? {
            // Readiness only shapes which buttons a room shows; an unreadable catalog shows the button and the run's own switch gate refuses.
            do { return try SwiftToolDispatcher.integrationGate(tool: name, input: [:], turn: nil,
                parts: NativeAgentEngine.forRoot(dataRoot).partBinding) } catch { return nil }
        }
        func withWebScheme(_ value: String) -> String { SwiftToolDispatcher.withWebScheme(value) }
        func readTrust(_ sources: [String], dataRoot: URL) -> PeerDataTaint.TrustRead { PeerTrust.read(sources, dataRoot: dataRoot) }
        func builderSourceRepoRoot(dataRoot: URL) -> URL? { SwiftToolDispatcher.builderSourceRepoRoot(dataRoot: dataRoot) }
        var listedPeerState: String { AgentPeerContactState.listed.rawValue }
    }
}

/// Each helper-room reading receives its host explicitly. The face owner handles
/// publication and version invalidation without retaining another call's host.
@MainActor private final class WorkspaceFaces {
    private let faces: PartFaces

    private init(dataRoot: URL, invocation: Parts.Invocation) {
        faces = PartFaces(dataRoot: dataRoot) { id, input, version in
            await Parts(root: dataRoot).face(id: id, input: input, version: version, invocation: invocation)
        }
    }

    static func read(_ input: JSONValue, dataRoot: URL, invocation: Parts.Invocation) async -> PartCallResult<PartFace> {
        let root = dataRoot.standardizedFileURL
        let owner = WorkspaceFaces(dataRoot: root, invocation: invocation)
        let snapshot = await owner.faces.sourceChanged(id: "workspace-readout", epoch: 0, input: input)
        if snapshot.status == .ready, let face = snapshot.face { return .success(face) }
        return .failure(snapshot.error ?? .init(code: snapshot.status.rawValue, message: "Workspace face " + snapshot.status.rawValue))
    }
}
