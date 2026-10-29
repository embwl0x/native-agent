import AgentConversations
import AgentWorkspace
import ChatToolRuntime
import Foundation
import NativeAgentShared
import Observation
import PersistenceCore
import NativeAgentCore
import BackgroundLoops
import DoctorChecks
import BackgroundWork
import Synchronization
// Blueprint: | `ContactAddressBook.swift` | ContactListFacade owns checked address-book doors and their LatestRead publication and contact-change watch |

/// The engine's address book: one checked row per door, including its grant
/// and effective elevation verdict. Agents, Trust and contact threads read it.
@MainActor @Observable
public final class ContactListFacade {
    public nonisolated let dataRoot: URL
    public private(set) var doors: [AgentContactRow] = []
    public private(set) var loaded = false
    public private(set) var loadError: String?
    public var rows: [AgentContactRow] { doors.filter(\.primary) }
    @ObservationIgnored private lazy var latest = LatestRead()
    @ObservationIgnored private var watchTask: Task<Void, Never>?

    public nonisolated init(dataRoot: URL) { self.dataRoot = dataRoot }
    deinit { watchTask?.cancel() }

    @discardableResult
    public func refresh() async throws -> [AgentContactRow] {
        try await refreshDoors().doors.filter(\.primary)
    }

    /// Return this read's doors and conversations even when a newer read owns publication.
    func refreshDoors() async throws -> (doors: [AgentContactRow], records: Result<[AgentConversationRecord], Error>) {
        let root = dataRoot
        return try await latest.read({
            await Task.detached(priority: .utility) {
                let discovery = await AgentDiscoverySession.shared.candidates(dataRoot: root)
                return Result {
                    let records = Result { try AgentConversationStore(dataRoot: root).records() }
                    let peers = try AgentPeerStore(dataRoot: root).list()
                    let lasts = AgentConversationStore.lastExchanges(peers: peers,
                        records: (try? records.get()) ?? [], dataRoot: root).mapValues(\.summary)
                    let doors = AgentContactRow.rows(peers: peers, candidates: discovery, dataRoot: root, everyDoor: true).map { row in
                        var row = row
                        row.lastExchange = row.contact.flatMap { lasts[$0.id] }
                        return row
                    }
                    return (doors: doors, records: records)
                }
            }.value
        }, publish: { result in
            loaded = true
            switch result {
            case .success(let next):
                doors = next.doors
                loadError = nil
            case .failure(let error):
                loadError = error.localizedDescription
            }
        }).get()
    }

    /// Watch contact and conversation owners for address-book changes.
    public func watch() {
        guard watchTask == nil else { return }
        let root = dataRoot
        watchTask = Task { [weak self] in
            let events = FileChangeEvents(paths: ["agents/peers.json", "agents/conversations.json",
                "agents/discovery.json", "chat/sessions.json"].map { root.appendingPathComponent($0) }
                + [AgentLocalHealth.url(root), InstallPaths.current.bridgeConfigRoot(dataRoot: root)
                    .appendingPathComponent("claude-bridge/claude-live")], emitInitial: true)
            let dot = NotificationCenter.default.addObserver(forName: ChatGPTDotIPCTransport.didChange,
                object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in _ = try? await self?.refresh() }
            }
            var askedDot = false
            await withTaskCancellationHandler {
                for await _ in events.stream {
                    if Task.isCancelled { break }
                    _ = try? await self?.refresh()
                    if !askedDot, self?.doors.contains(where: { $0.contact.map(ChatGPTDotIPCTransport.owns) == true }) == true {
                        askedDot = true
                        await Task.detached(priority: .userInitiated) {
                            _ = await SwiftToolDispatcher(dataRoot: root, allowProcessGlobalTools: false).chatGPTDotReadiness()
                        }.value
                        _ = try? await self?.refresh()
                    }
                }
            } onCancel: { events.cancel() }
            NotificationCenter.default.removeObserver(dot)
        }
    }
}
