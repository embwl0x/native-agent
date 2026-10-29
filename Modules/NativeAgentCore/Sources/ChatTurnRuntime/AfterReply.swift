import Foundation
import NativeAgentCore
import os
import AuthoredCapabilities
import ChatToolParsing
import ChatTurnContracts
import Experiences
import ChatSessionWork
import Desk
import ToolRegistry
import CryptoKit
import Dispatcher
import PersistenceCore
import TurnTrace
import Transcripts
import MemoryV2
import ProviderRouting
import MacIntegration
import Context
import Senses
import TrustCenter
// Blueprint: | `AfterReply.swift` | `AfterReply`, `SwiftNativeTurnEngine.afterReply`: saved-answer release, recording before start, abandonment release and retained private flights through once-only settlement, surviving conversational Stop |

extension SwiftNativeTurnEngine {
    /// The saved answer releases private work on this actor with the turn's own scopes.
    func afterReply(_ work: @escaping () async -> Void) -> AfterReply {
        let held = AfterReply()
        let id = UUID()
        afterReplyFlights[id] = Task { [started = held.started, settled = held.settled, completion = held.completion] in
            defer { afterReplyFlights[id] = nil }
            await settled.park()
            if started.withLock({ $0 }) { await work() }
            // The turn includes private work, or its abandonment if the reply
            // could not be saved. Its predictions settle exactly once here.
            if let finish = completion.withLock({ $0 }) { await finish() }
        }
        return held
    }
}

/// Work released by the saved answer; abandonment releases private settlement unrun.
public final class AfterReply: Sendable {
    fileprivate let started = OSAllocatedUnfairLock(initialState: false)
    fileprivate let settled = ScopedWaiter()
    fileprivate let completion = OSAllocatedUnfairLock<(@Sendable () async -> Void)?>(initialState: nil)
    func onSettled(_ finish: @escaping @Sendable () async -> Void) {
        completion.withLock { $0 = finish }
    }
    private let recording = OSAllocatedUnfairLock<(@Sendable () async -> Void)?>(initialState: nil)
    var recordsMemory: Bool { recording.withLock { $0 != nil } }
    func beforeStart(_ record: @escaping @Sendable () async -> Void) {
        recording.withLock { $0 = record }
    }
    public func start() async {
        guard started.withLock({ started in
            if started { return false }
            started = true
            return true
        }) else { return }
        if let record = recording.withLock({ $0 }) { await record() }
        settled.resume()
    }
    deinit { settled.resume() }
}
