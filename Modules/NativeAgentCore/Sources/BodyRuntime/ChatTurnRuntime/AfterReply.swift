import Foundation
import NativeAgentCore
import Synchronization
import SenseCore
import MacNerves
import MindCore
import DeskCore
import PersistenceCore
import ProviderRouting
// Blueprint: | `AfterReply.swift` | `AfterReply`; `SwiftNativeTurnEngine.afterReply`; Saved-answer release and once-only private settlement |

extension SwiftNativeTurnEngine {
    /// Saved output releases private work under the originating turn's scopes.
    func afterReply(_ work: @escaping () async -> Void) -> AfterReply {
        let held = AfterReply()
        let id = UUID()
        afterReplyFlights[id] = Task { [flight = held.flight] in
            defer { afterReplyFlights[id] = nil }
            await flight.settled.park()
            if flight.started.load(ordering: .acquiring) { await work() }
            // Dispatch closes after private work, including abandonment when the reply cannot be saved.
            if let finish = flight.completion.withLock({ $0 }) { await finish.run() }
        }
        return held
    }
}

public final class AfterReply: Sendable {
    fileprivate final class Flight: Sendable {
        let started = Atomic(false)
        let settled = ScopedWaiter()
        let completion = Mutex<Completion?>(nil)
    }
    fileprivate let flight = Flight()
    fileprivate struct Completion: Sendable {
        let run: @Sendable () async -> Void
    }
    func onSettled(_ finish: @escaping @Sendable () async -> Void) {
        flight.completion.withLock { $0 = Completion(run: finish) }
    }
    private struct Recording: Sendable {
        let run: @Sendable () async -> Void
    }
    private let recording = Mutex<Recording?>(nil)
    var recordsMemory: Bool { recording.withLock { $0 != nil } }
    func beforeStart(_ record: @escaping @Sendable () async -> Void) {
        recording.withLock { $0 = Recording(run: record) }
    }
    public func start() async {
        guard !flight.started.exchange(true, ordering: .acquiringAndReleasing) else { return }
        if let record = recording.withLock({ $0 }) { await record.run() }
        flight.settled.resume()
    }
    deinit { flight.settled.resume() }
}
