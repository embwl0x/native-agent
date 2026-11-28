import Foundation
import NativeAgentShared
import Observation
import PersistenceCore
import NativeAgentCore
import SenseCore
import Synchronization
// Blueprint: | `ContactAddressBook.swift` | ContactListFacade owns checked address-book doors and their LatestRead publication |

extension ContactThreadReadouts {
    struct ContactsDidChange: BodyRootMessage {
        let root: URL
    }
}

/// Share one checked row per door across surfaces without merging its grant or elevation verdict.
@MainActor @Observable
public final class ContactListFacade {
    public nonisolated let dataRoot: URL
    public private(set) var doors: [AgentContactRow] = []
    public private(set) var loaded = false
    public private(set) var loadError: String?
    public var rows: [AgentContactRow] { doors.filter(\.primary) }
    @ObservationIgnored private lazy var latest = LatestRead()

    public nonisolated init(dataRoot: URL) { self.dataRoot = dataRoot }

    @discardableResult
    public func refresh() async throws -> [AgentContactRow] {
        try await refreshDoors().doors.filter(\.primary)
    }

    /// Return this read even when a newer read owns publication.
    func refreshDoors() async throws -> (doors: [AgentContactRow], records: Result<[AgentConversationRecord], Error>) {
        let root = dataRoot
        return try await latest.read({
            await Task.detached(priority: .utility) {
                let discovery = await AgentDiscoverySession.shared.candidates(dataRoot: root)
                return Result {
                    let records = Result { try AgentConversationStore(dataRoot: root).records() }
                    let peers = try AgentPeerStore(dataRoot: root).list()
                    let lasts = AgentConversationStore.lastExchanges(peers: peers,
                        records: try records.get(), dataRoot: root).mapValues(\.summary)
                    let doors = try AgentContactRow.rows(peers: peers, candidates: discovery, dataRoot: root).map { row in
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
                ContactThreadReadouts.ContactsDidChange(root: dataRoot).post()
            case .failure(let error):
                loadError = error.localizedDescription
            }
        }).get()
    }

}
