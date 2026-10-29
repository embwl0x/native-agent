import AgentConversations
import AgentWorkspace
import Foundation
import NativeAgentCore
import PersistenceCore
import MacIntegration
import ToolRegistry
import TrustCenter
import Senses
import ToolExecution
import NativeAgentShared
import AuthoredCapabilities
// Blueprint: | `AgentWorkspaceBinding.swift` | `ChatWorkspaceBinding` enum; `pending`, `glance`; workspace tool port derives bounded built/recent ability names from canonical tool, skill and sense availability |

package enum ChatWorkspaceBinding {
    package static let ports = AgentWorkspacePorts.Binding(conversations: Conversations(), tools: Tools())

    /// Read for a turn's facts: announced only at delivery (`announceDelivered`).
    package static func pending(dataRoot: URL?, scope: String?) async -> JSONValue? {
        await AgentWorkspacePorts.$binding.withValue(ports) {
            await AgentWorkspaceArrivals.pending(dataRoot: dataRoot, scope: scope, announce: false)
        }
    }

    package static func announceDelivered(dataRoot: URL, scope: String, in input: String) async {
        await AgentWorkspaceNavigation.shared.markAnnounced(dataRoot: dataRoot, scope: scope, in: input)
    }

    package static func currentPlace(dataRoot: URL, scope: String) async -> String? {
        await AgentWorkspaceNavigation.shared.currentPlace(dataRoot: dataRoot, scope: scope)
    }

    package static func glance(dataRoot: URL, scope: String, turn: Date?, message: String) async -> String? {
        await AgentWorkspacePorts.$binding.withValue(ports) {
            await HerScreen.glance(dataRoot: dataRoot, scope: scope, turn: turn, message: message)
        }
    }

    private struct Conversations: AgentWorkspaceConversationPort {
        func liveHealth(dataRoot: URL) -> [String: AgentLocalHealth] {
            AgentContactHealth.read(dataRoot: dataRoot)
        }
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
        func identity(dataRoot: URL) -> AgentContactIdentity { AgentContactIdentity(dataRoot: dataRoot) }
        func answeredRequests(dataRoot: URL) -> [(message: String?, run: String?, chat: String?, modified: Date)] {
            GrokRequestStore(dataRoot: dataRoot).answeredRequests()
        }
        func openHuman(sessionID: String, limit: Int?, dataRoot: URL) async throws -> JSONValue {
            // The read consumed each message it shows under its own row's stamp.
            await HumanConversationReader.open(sessionID: sessionID, limit: limit, dataRoot: dataRoot)
        }
        func presentation(_ row: AgentConversationRecord) -> JSONValue {
            AgentConversationView.conversationPresentation(row)
        }
        func liveHandOff(_ row: AgentConversationRecord) -> Bool { AgentConversationSession.liveHandOff(row) }
        func unsettledAttention(_ row: AgentConversationRecord) -> Bool { AgentConversationSession.unsettledAttention(row) }
        func shown(answers: [String: String], peer: String, scope: String, dataRoot: URL) {
            guard peer.hasPrefix("peer:") else { return }
            let store = GrokRequestStore(dataRoot: dataRoot), id = String(peer.dropFirst(5))
            // Its hand-over goes to the chat that asked; seen in another, it still goes.
            for (answer, words) in answers where (try? store.read(answer, peer: id))?.conversationID == scope {
                store.shown(answer, peer: id, by: "the room") { $0 == words }
            }
        }
    }

    private struct Tools: AgentWorkspaceToolPort {
        func readoutFace(_ input: JSONValue, dataRoot: URL) async -> PartCallResult<PartFace> {
            await WorkspaceFaces.read(input, dataRoot: dataRoot)
        }
        func readout(_ input: JSONValue, dataRoot: URL) async throws -> JSONValue {
            let result: PartCallResult<JSONValue> = await Parts(root: dataRoot).call(id: "workspace-readout", input: input)
            switch result {
            case .success(let value): return value
            case .failure(let error): throw error
            }
        }
        func builtAbilities(dataRoot: URL, now: Date) async -> String {
            do {
                async let senses = FileSenseRegistry(dataRoot: dataRoot).all()
                let tools = try await SwiftNativeToolRegistry(root: dataRoot).listTools()
                let callable = Set(SwiftToolDispatcher.authoredTools(records: tools).map { $0.schema.name })
                let since = now.addingTimeInterval(-7 * 86_400)
                var names: [(name: String, changed: Date, builtIn: Bool)] = []
                for part in tools where callable.contains(part.id) {
                    let changed = CapabilityLifecycle.date(part.updatedAt ?? part.createdAt) ?? .distantPast
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
                let suffix = "; you can reach Mac apps through your tools."
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
            } catch {
                return "Your built abilities are unavailable: " + String(error.localizedDescription.prefix(150))
            }
        }

        func usableAgentLanes(dataRoot: URL) -> Set<String> {
            Set(["codex", "claude", "omp"].filter {
                SwiftToolDispatcher.builtInAgentLaneUsable($0, dataRoot: dataRoot,
                    configRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot))
            })
        }
        func modelVisibleCatalogToolNames(_ names: Set<String>) -> Set<String> {
            SwiftToolDispatcher.modelVisibleCatalogToolNames(names)
        }
        func appAction(_ tool: String) -> String? { ToolNameAliases.appAction(tool) }
        func macIntegrationGate(_ name: String) -> (integration: String, mode: MacIntegrationPermissionMode)? {
            MacIntegrationGates.byTool[ToolNameAliases.canonical(name)]
        }
        func markConsumed(peer: String) { PeerDataTaint.markConsumed(peer: peer) }
        func withWebScheme(_ value: String) -> String { SwiftToolDispatcher.withWebScheme(value) }
        func builderSourceRepoRoot(dataRoot: URL) -> URL? { SwiftToolDispatcher.builderSourceRepoRoot(dataRoot: dataRoot) }
        var listedPeerState: String { AgentPeerContactState.listed.rawValue }
    }
}

/// The helper room and its native preview share one root-scoped pure face.
/// Source equality controls the source epoch; L0 owns publication and version
/// invalidation. No world state, observations or action authority live here.
@MainActor private final class WorkspaceFaces {
    private static var roots: [URL: WorkspaceFaces] = [:]
    private let faces: PartFaces
    private var input: JSONValue?
    private var epoch: UInt64 = 0

    private init(dataRoot: URL, host: (any OwnedProgramToolHost)?) {
        faces = PartFaces(dataRoot: dataRoot) { id, input, version in
            return await OwnedProgramInvocation.$host.withValue(host) {
                await Parts(root: dataRoot).face(id: id, input: input, version: version)
            }
        }
    }

    static func read(_ input: JSONValue, dataRoot: URL) async -> PartCallResult<PartFace> {
        let root = dataRoot.standardizedFileURL
        if roots[root] == nil { roots[root] = WorkspaceFaces(dataRoot: root, host: OwnedProgramInvocation.host) }
        let owner = roots[root]!
        if owner.input != input { owner.input = input; owner.epoch += 1 }
        let snapshot = await owner.faces.sourceChanged(id: "workspace-readout", epoch: owner.epoch, input: input)
        if snapshot.status == .ready, let face = snapshot.face { return .success(face) }
        return .failure(snapshot.error ?? .init(code: snapshot.status.rawValue, message: "Workspace face " + snapshot.status.rawValue))
    }
}
