import ChatTurnRuntime
import Foundation
import NativeAgentShared
import os
import Transcripts
import Privacy
// Blueprint: | `MacSyncEngine+LiveTurns.swift` | `MacSyncEngine`: `startLiveTurnRelay`, `stopLiveTurnRelay` |

private struct LiveTurnMovement: Sendable {
    var deltas = ICloudTextDeltaCoalescer()
    var writing: String?
}

/// Other-door turns use their own run id and live marker so the phone can distinguish them from turns its forwarder owns.
extension MacSyncEngine {
    func startLiveTurnRelay() {
        stopLiveTurnRelay()
        let (signals, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let mailbox = OSAllocatedUnfairLock(initialState: (
            turns: [String: LiveTurnMovement](),
            pending: [String: BridgeMessage]()
        ))
        // A serial queue keeps event order and gives the yield its own stack.
        let hop = DispatchQueue(label: "nativeagent.live-turn-relay")
        let generation = snapshotLifecycleGeneration
        let dataRoot = sync.dataRoot
        ChatLiveTap.observe { event in
            hop.async {
                guard event.surface != "ios",
                      ConversationAnchor.currentSessionId(dataRoot: dataRoot) == event.sessionId else { return }
                let queued = mailbox.withLock { state -> Bool in
                    let run = event.runId
                    let text: String
                    let kind: String?
                    let sequence: Int?
                    switch event.kind {
                    case .writing(let line):
                        guard state.turns[run]?.writing != line else { return false }
                        state.turns[run, default: LiveTurnMovement()].writing = line
                        text = line
                        kind = "writing"
                        sequence = nil
                    case .delta(let delta):
                        guard let flush = state.turns[run, default: LiveTurnMovement()].deltas.push(
                                delta: delta
                              ) else { return false }
                        state.turns[run]?.writing = nil
                        text = flush.text
                        kind = "text_delta"
                        sequence = flush.sequence
                    case .answered(let answer):
                        state.turns.removeValue(forKey: run)
                        text = answer
                        kind = "final"
                        sequence = nil
                    case .incomplete(let answer, _):
                        state.turns.removeValue(forKey: run)
                        text = answer
                        kind = "incomplete"
                        sequence = nil
                    case .failed:
                        state.turns.removeValue(forKey: run)
                        text = event.savedPartial ?? ""
                        kind = "error"
                        sequence = nil
                    case .cancelled:
                        state.turns.removeValue(forKey: run)
                        text = event.savedPartial ?? ""
                        kind = "cancelled"
                        sequence = nil
                    }
                    var metadata = ["live": "true", "transport": "icloud", "source": "mac"]
                    metadata["kind"] = kind
                    if case .failed(let failure) = event.kind {
                        metadata["errorDetail"] = NativeAppSecretRedactor.redactedRemoteErrorDetail(failure)
                    }
                    if case .incomplete(_, let status) = event.kind {
                        metadata["status"] = status.prefix(1).uppercased() + status.dropFirst()
                    }
                    metadata["seq"] = sequence.map(String.init)
                    // Each changed line is new movement, even when a later call repeats earlier words: the phone deduplicates by id.
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
        // Successful transport wakes retained finals without another retry loop; only the mailbox owns text.
        sync.bridge.onTransportSucceeded = { continuation.yield(()) }
        liveTurnRelayTask = Task { [weak self] in
            for await _ in signals {
                guard let self, generation == self.snapshotLifecycleGeneration, self.isActive else { break }
                let pending = mailbox.withLock { state in
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
                    if !terminal, mailbox.withLock({ $0.pending[run] != nil }) { continue }
                    do {
                        _ = try await self.sync.bridge.sendChatMessage(
                            text: message.text, sessionID: message.sessionID, correlationID: run,
                            metadata: message.metadata, messageID: message.id, timestamp: message.timestamp
                        )
                    } catch {
                        if terminal {
                            mailbox.withLock { state in
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
        ChatLiveTap.observe(nil)
        sync.bridge.onTransportSucceeded = nil
        liveTurnRelayTask?.cancel()
        liveTurnRelayTask = nil
    }
}
