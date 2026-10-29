import CryptoKit
import Foundation
import PersistenceCore
import Desk
import NativeAgentShared
// Blueprint: | `MacSyncEngine+NeedsUserNotify.swift` | `NeedsUserEdgeNotifier` actor; `evaluate`, `stableDigest` |

// Notify once per new or changed owner-waiting Desk question; seed the persisted baseline silently.
actor NeedsUserEdgeNotifier {
    typealias Sender = @Sendable (
        _ title: String,
        _ body: String,
        _ userInfo: [String: String]
    ) async throws -> Void

    private struct Wait: Codable {
        var fingerprint: String
        var episodeID: String
    }

    private struct State: Codable {
        var seeded: Bool
        // Missing in the old count-based format: existing incomplete state
        // needs repair; only an absent store may seed a baseline.
        var requests: [String: Wait]?
    }

    private let dataRoot: URL
    private let sender: Sender
    private var cached: State?
    private var evaluating = false

    /// `sender` routes the knock (item 26: the edge decision stays here, the
    /// CHANNEL decision belongs to the attention router) and throws when it
    /// reached nobody, so the episode stays unwritten for the next pass.
    init(dataRoot: URL, sender: @escaping Sender) {
        self.dataRoot = dataRoot
        self.sender = sender
    }

    private var stateURL: URL {
        dataRoot
            .appendingPathComponent("notify", isDirectory: true)
            .appendingPathComponent("needs_user_edge.json")
    }

    func evaluate(items: [DeskItem]) async {
        guard !evaluating else { return }
        evaluating = true
        defer { evaluating = false }
        do { try await evaluateChecked(items: items) }
        catch {
            nativeLog("needs_user_notify: state unavailable; bytes and pending edges preserved: \(error.localizedDescription)")
        }
    }

    private func evaluateChecked(items: [DeskItem]) async throws {
        var state = try load()
        let items = items.filter(\.requiresOwnerInput).sorted { $0.handle < $1.handle }
        func fingerprint(_ item: DeskItem) -> String {
            Self.stableDigest(item.handle + "\n" + item.title + "\n" + (item.blockedReason ?? item.summary ?? ""))
        }
        guard state.seeded, state.requests != nil else {
            persist(State(seeded: true, requests: Dictionary(items.map {
                ($0.handle, Wait(fingerprint: fingerprint($0), episodeID: UUID().uuidString))
            }, uniquingKeysWith: { first, _ in first })))
            return
        }
        let handles = Set(items.map(\.handle))
        let retained = state.requests?.filter { handles.contains($0.key) }
        if retained?.count != state.requests?.count {
            state.requests = retained
            guard persist(state) else { return }
        }
        for item in items {
            let digest = fingerprint(item)
            var current = try load()
            let previous = current.requests?[item.handle]
            guard previous?.fingerprint != digest else { continue }
            let episode = previous?.episodeID ?? UUID().uuidString
            // Reserve the identity before sending; an empty fingerprint keeps
            // failed delivery eligible on the next pass with the same key.
            current.requests?[item.handle] = Wait(fingerprint: previous?.fingerprint ?? "", episodeID: episode)
            guard persist(current) else { return }
            let reason = (item.blockedReason ?? item.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let body = reason.isEmpty ? item.title : "\(item.title) — \(reason)"
            do {
                try await sender(
                    "\(NativeAgentNotificationDefaults.agentDisplayName(dataRoot: dataRoot)) needs you",
                    MobileDeskProjectionBounds.clipped(body, to: 500),
                    ["kind": "agent_needs_user", "screen": "desk", "taskId": item.handle,
                     "dedupKey": "needs_user+\(episode)+\(digest)"]
                )
                current = try load()
                guard current.requests?[item.handle]?.episodeID == episode else { continue }
                current.requests?[item.handle] = Wait(fingerprint: digest, episodeID: episode)
                guard persist(current) else { return }
            } catch {
                nativeLog("needs_user_notify: push failed, will retry: \(error.localizedDescription)")
            }
        }
    }

    private func load() throws -> State {
        if let cached { return cached }
        let data: Data
        do { data = try Data(contentsOf: stateURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return State(seeded: false, requests: nil)
        }
        let state = try JSONDecoder().decode(State.self, from: data)
        guard state.seeded, state.requests != nil else { throw CocoaError(.fileReadCorruptFile) }
        cached = state
        return state
    }

    @discardableResult
    private func persist(_ state: State) -> Bool {
        do {
            let data = try JSONEncoder().encode(state)
            try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: stateURL)
            // Do not advance the process cache until the durable state landed.
            // A post-delivery persistence failure may cause a duplicate retry,
            // which is safer than permanently suppressing the edge.
            cached = state
            return true
        } catch {
            nativeLog("needs_user_notify: state persistence failed: \(error.localizedDescription)")
            return false
        }
    }

    nonisolated static func stableDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
