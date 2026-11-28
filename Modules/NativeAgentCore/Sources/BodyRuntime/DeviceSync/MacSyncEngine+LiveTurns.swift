import Synchronization
import Dispatch
import Foundation
import NativeAgentShared
import SenseCore
import PersistenceCore
import os
// Blueprint: | `MacSyncEngine+LiveTurns.swift` | `MacSyncEngine`: `startLiveTurnRelay`, `stopLiveTurnRelay` |

private struct LiveTurnMovement: Sendable {
    let admitted: Bool
    var deltas = ICloudTextDeltaCoalescer()
    var writing: String?
}

final class MacLiveTurnRelay: Sendable {
    fileprivate let mailbox = Mutex((
        turns: [String: LiveTurnMovement](),
        pending: [String: BridgeMessage]()
    ))
    private let hop = DispatchQueue(label: "nativeagent.live-turn-relay")
    private let dataRoot: URL
    private let continuation: AsyncStream<Void>.Continuation

    init(dataRoot: URL, continuation: AsyncStream<Void>.Continuation) {
        self.dataRoot = dataRoot
        self.continuation = continuation
    }

    func enqueue(_ event: ChatLiveTap.Event) {
        hop.async { [self] in
            guard event.surface != "ios" else { return }
            let run = event.runId, movement = event.runId + " " + event.sessionId
            let admitted = mailbox.withLock { $0.turns[movement]?.admitted }
                ?? (ConversationAnchor.currentSessionId(dataRoot: dataRoot) == event.sessionId)
            let queued = mailbox.withLock { state -> Bool in
                if state.turns[movement] == nil {
                    state.turns[movement] = LiveTurnMovement(admitted: admitted)
                }
                let text: String
                let kind: String?
                let sequence: Int?
                switch event.kind {
                case .writing(let line):
                    guard admitted, state.turns[movement]?.writing != line else { return false }
                    state.turns[movement]?.writing = line
                    text = line
                    kind = "writing"
                    sequence = nil
                case .delta(let delta):
                    guard admitted, let flush = state.turns[movement]?.deltas.push(delta: delta) else { return false }
                    state.turns[movement]?.writing = nil
                    text = flush.text
                    kind = "text_delta"
                    sequence = flush.sequence
                case .answered(let answer):
                    state.turns.removeValue(forKey: movement)
                    text = answer
                    kind = "final"
                    sequence = nil
                case .incomplete(let answer, _):
                    state.turns.removeValue(forKey: movement)
                    text = answer
                    kind = "incomplete"
                    sequence = nil
                case .failed:
                    state.turns.removeValue(forKey: movement)
                    text = event.savedPartial ?? ""
                    kind = "error"
                    sequence = nil
                case .cancelled:
                    state.turns.removeValue(forKey: movement)
                    text = event.savedPartial ?? ""
                    kind = "cancelled"
                    sequence = nil
                }
                guard admitted else { return false }
                var metadata = ["live": "true", "transport": "icloud", "source": "mac"]
                metadata["kind"] = kind
                if case .failed(let failure) = event.kind {
                    metadata["errorDetail"] = NativeAppSecretRedactor.redactedRemoteErrorDetail(failure)
                }
                if case .incomplete(_, let status) = event.kind {
                    metadata["status"] = status.prefix(1).uppercased() + status.dropFirst()
                }
                metadata["seq"] = sequence.map(String.init)
                let movementID = kind == "writing"
                    ? "writing-" + UUID().uuidString
                    : sequence.map(String.init) ?? "terminal"
                state.pending[run] = BridgeMessage.make(
                    id: "live-\(run)-\(movementID)",
                    sender: "mac", text: text, sessionID: event.sessionId,
                    correlationID: run, metadata: metadata
                )
                return true
            }
            if queued { continuation.yield(()) }
        }
    }
}

extension MacSyncEngine {
    func startLiveTurnRelay() {
        stopLiveTurnRelay()
        let (signals, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let generation = snapshotLifecycleGeneration
        let relay = MacLiveTurnRelay(dataRoot: sync.dataRoot, continuation: continuation)
        sync.liveTurns.connect(relay)
        // Successful transport wakes retained finals without another retry loop; only the mailbox owns text.
        sync.bridge.onTransportSucceeded = { continuation.yield(()) }
        liveTurnRelayTask = Task { [weak self] in
            for await _ in signals {
                guard let self, generation == self.snapshotLifecycleGeneration, self.isActive else { break }
                let pending = relay.mailbox.withLock { state in
                    let messages = Array(state.pending.values)
                    state.pending.removeAll()
                    return messages.sorted {
                        ($0.metadata?["kind"] != "text_delta" ? 0 : 1)
                            < ($1.metadata?["kind"] != "text_delta" ? 0 : 1)
                    }
                }
                for message in pending {
                    guard !Task.isCancelled, generation == self.snapshotLifecycleGeneration else { break }
                    guard let run = message.correlationID else { continue }
                    let terminal = ["final", "incomplete", "error", "cancelled"].contains(message.metadata?["kind"] ?? "")
                    if !terminal, relay.mailbox.withLock({ $0.pending[run] != nil }) { continue }
                    do {
                        _ = try await self.sync.bridge.sendChatMessage(
                            text: message.text, sessionID: message.sessionID, correlationID: run,
                            metadata: message.metadata, messageID: message.id, timestamp: message.timestamp
                        )
                    } catch {
                        if terminal {
                            relay.mailbox.withLock { state in
                                if state.pending[run] == nil { state.pending[run] = message }
                            }
                        }
                        nativeLog("[iCloudBridge] live turn %@ not sent: %@", run, "\(error)")
                    }
                }
            }
        }
    }

    func stopLiveTurnRelay() {
        sync.liveTurns.connect(nil)
        sync.bridge.onTransportSucceeded = nil
        liveTurnRelayTask?.cancel()
        liveTurnRelayTask = nil
    }
}
