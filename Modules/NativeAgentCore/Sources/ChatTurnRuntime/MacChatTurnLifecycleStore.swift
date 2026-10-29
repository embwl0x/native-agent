import Foundation
import Darwin
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ChatToolParsing
@_exported import ChatToolRuntime
@_exported import ChatSessionWork
import Dispatcher
import MemoryV2
import ProviderRouting
import MacIntegration
import Context
import MacControl
@_exported import AgentWorkspace
import ToolRegistry
import Desk
import TrustCenter
import TurnTrace
import Privacy
import CryptoKit
import ApprovalInbox
import AuthoredCapabilities
import Experiences
import PersonaEngine
import SwarmRuns
import StandingBots
@_exported import ChatTurnContracts
import Transcripts
import Senses
import os
import CognitiveSubstrate
@_exported import AgentConversations
import UniformTypeIdentifiers
import Synchronization
import DreamREMCycle
import Observation
import Speech
import AVFoundation
import AppKit
import CoreGraphics
// Blueprint: | `MacChatTurnLifecycleStore.swift` | `MacChatTurnLifecycleStore` owns its envelope, file URL and durable read/write boundary; bounded exact-turn persistence and durable queue/attachments; new requests retain DataRootLife, missing stamps mean first life and cross-life requests project stopped |

/// Bounded actor-owned persistence; begin replaces a session, later writes require the exact turn.
public actor MacChatTurnLifecycleStore {
    private struct Envelope: Codable, Sendable {
        let schemaVersion: Int
        var turns: [MacChatPersistedTurnLifecycle]
        var queuedTurns: [String: [QueuedChatTurn]]? = nil
    }

    private let fileURL: URL

    private func read() throws -> Envelope {
        var info = stat()
        let result = fileURL.path.withCString { lstat($0, &info) }
        if result != 0 {
            guard errno == ENOENT else {
                throw MacChatTurnLifecycleStoreError.invalidRecord
            }
            return Envelope(schemaVersion: 1, turns: [])
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0 else {
            throw MacChatTurnLifecycleStoreError.invalidRecord
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fileURL))
        guard envelope.schemaVersion == 1 else {
            throw MacChatTurnLifecycleStoreError.unsupportedSchema
        }
        return envelope
    }

    private func write(_ envelope: Envelope) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: fileURL)
    }

    public static var liveFileURL: URL {
        PersistenceCore.defaultDataRoot()
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("mac_turn_lifecycle.json")
    }

    private let maximumRecords: Int
    private var loadedState: Envelope?
    private var mutationInProgress = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(fileURL: URL = MacChatTurnLifecycleStore.liveFileURL, maximumRecords: Int = 64) {
        self.fileURL = fileURL
        self.maximumRecords = max(1, maximumRecords)
    }

    public func begin(_ state: MacChatTurnLifecycleState) async throws {
        await acquireMutation()
        defer { releaseMutation() }
        guard let record = MacChatPersistedTurnLifecycle(state: state),
              !record.isTerminal else {
            throw MacChatTurnLifecycleStoreError.invalidRecord
        }
        var records = try currentRecords()
        let addingSession = !records.contains { $0.sessionId == record.sessionId }
        if addingSession, records.count >= maximumRecords {
            // Evict only the oldest terminal projection; accepted turns still needing repair stay.
            guard let terminalIndex = records.firstIndex(where: \.isTerminal) else {
                throw MacChatTurnLifecycleStoreError.capacityExceeded(maximumRecords)
            }
            records.remove(at: terminalIndex)
        }
        records.removeAll { $0.sessionId == record.sessionId }
        records.append(record)
        try commit(records)
    }

    @discardableResult
    public func update(_ state: MacChatTurnLifecycleState) async throws -> Bool {
        await acquireMutation()
        defer { releaseMutation() }
        guard let record = MacChatPersistedTurnLifecycle(state: state) else {
            throw MacChatTurnLifecycleStoreError.invalidRecord
        }
        var records = try currentRecords()
        guard let index = records.firstIndex(where: {
            $0.sessionId == record.sessionId && $0.turnId == record.turnId
        }) else { return false }
        if records[index].isTerminal { return records[index] == record }
        records[index] = record
        try commit(records)
        return true
    }

    public func remove(sessionId: String, turnId: String? = nil) async throws {
        await acquireMutation()
        defer { releaseMutation() }
        var records = try currentRecords()
        let priorCount = records.count
        records.removeAll { record in
            record.sessionId == sessionId && (turnId == nil || record.turnId == turnId)
        }
        guard records.count != priorCount else { return }
        try commit(records)
    }

    public func records() async throws -> [MacChatPersistedTurnLifecycle] {
        await acquireMutation()
        defer { releaseMutation() }
        return try currentRecords()
    }

    private func currentRecords() throws -> [MacChatPersistedTurnLifecycle] {
        try currentState().turns
    }

    private func currentState() throws -> Envelope {
        if let loadedState { return loadedState }
        var loaded = try read()
        let root = fileURL.deletingLastPathComponent().deletingLastPathComponent()
        let life = try DataRootLife.current(in: root)
        loaded.queuedTurns = loaded.queuedTurns?.mapValues { turns in
            turns.map { turn in
                var turn = turn
                if DataRootLife.life(of: turn.lifeID) != life { turn.stoppedReason = DataRootLife.stoppedReason }
                return turn
            }
        }
        guard loaded.turns.count <= maximumRecords,
              loaded.turns.allSatisfy({ $0.restoredState() != nil }),
              Set(loaded.turns.map(\.sessionId)).count == loaded.turns.count else {
            throw MacChatTurnLifecycleStoreError.invalidRecord
        }
        var ids = Set<String>()
        for (session, turns) in loaded.queuedTurns ?? [:] {
            guard NativeAgentChatSessionID.normalizedPathComponent(session) != nil,
                  turns.allSatisfy({ NativeAgentChatSessionID.normalizedPathComponent($0.id) != nil && ids.insert($0.id).inserted }) else {
                throw MacChatTurnLifecycleStoreError.invalidRecord
            }
        }
        loadedState = loaded
        return loaded
    }

    private func commit(_ records: [MacChatPersistedTurnLifecycle]) throws {
        var state = try currentState()
        state.turns = Self.sorted(records)
        try write(state)
        loadedState = state
    }

    public func queuedTurns() async throws -> [String: [QueuedChatTurn]] {
        await acquireMutation()
        defer { releaseMutation() }
        return try currentState().queuedTurns ?? [:]
    }

    public func saveQueuedTurns(_ turns: [String: [QueuedChatTurn]]) async throws -> [String: [QueuedChatTurn]] {
        await acquireMutation()
        defer { releaseMutation() }
        var state = try currentState()
        var saved = turns
        let known = Set((state.queuedTurns ?? [:]).values.flatMap { $0 }.map(\.id))
        let life = try DataRootLife.current(in: fileURL.deletingLastPathComponent().deletingLastPathComponent())
        for (session, queue) in turns {
            for (index, turn) in queue.enumerated() {
                if !known.contains(turn.id) { saved[session]?[index].lifeID = life }
                for (attachmentIndex, attachment) in turn.attachments.enumerated() where !attachment.base64.isEmpty {
                    guard NativeAgentChatSessionID.normalizedPathComponent(turn.id) != nil,
                          let bytes = Data(base64Encoded: attachment.base64) else {
                        throw MacChatTurnLifecycleStoreError.invalidRecord
                    }
                    let path = try await SwiftNativeChatOrchestrationClient.persistAttachment(bytes,
                        chatRoot: fileURL.deletingLastPathComponent(), runId: turn.id, index: attachmentIndex)
                    saved[session]?[index].attachments[attachmentIndex].base64 = ""
                    saved[session]?[index].attachments[attachmentIndex].path = path.path
                }
            }
        }
        state.queuedTurns = saved
        try write(state)
        loadedState = state
        return saved
    }

    public func attachments(for turn: QueuedChatTurn) throws -> [NativeAgentShared.MultimodalAttachment] {
        try turn.attachments.map { attachment in
            var value = attachment
            if value.base64.isEmpty {
                guard let path = value.path else { throw MacChatTurnLifecycleStoreError.invalidRecord }
                value.base64 = try Data(contentsOf: URL(fileURLWithPath: path)).base64EncodedString()
            }
            return value
        }
    }

    private func acquireMutation() async {
        guard mutationInProgress else {
            mutationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    private func releaseMutation() {
        guard !mutationWaiters.isEmpty else {
            mutationInProgress = false
            return
        }
        mutationWaiters.removeFirst().resume()
    }

    private static func sorted(
        _ records: [MacChatPersistedTurnLifecycle]
    ) -> [MacChatPersistedTurnLifecycle] {
        records.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.sessionId < $1.sessionId }
            return $0.updatedAt < $1.updatedAt
        }
    }
}

public enum MacChatTurnLifecycleStoreError: Error, Sendable, Equatable {
    case capacityExceeded(Int)
    case invalidRecord
    case missingExactTurn
    case unsupportedSchema
}
