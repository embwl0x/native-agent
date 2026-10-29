import Foundation
import Darwin
import NativeAgentCore
import PersistenceCore
@_exported import ChatSessionWork
import ChatToolParsing
@_exported import ChatToolRuntime
import NativeAgentShared
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
// Blueprint: | `MacChatTurnTranscriptProofReader.swift` | Bounded, symlink-refusing transcript proof with exact outcome correlation; terminal proof/error vocabulary and `MacChatTurnLifecycleRestartRepair` |

public enum MacChatTurnTranscriptTerminalProof: Sendable, Equatable {
    case completed
    case incomplete
    case failed
    case canceled
    case absent
    case unavailable
}

public enum MacChatTurnTranscriptProofReaderError: Error, Sendable, Equatable {
    case invalidEvidence
}

/// Strict, bounded transcript proof; only payload-free terminal classification escapes.
public actor MacChatTurnTranscriptProofReader {
    public static let maximumBytes = 2 * 1_024 * 1_024
    public static let maximumLines = 512

    private let dataRoot: URL

    public init(dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        self.dataRoot = dataRoot
    }

    public func proof(
        for identity: MacChatTurnIdentity
    ) async throws -> MacChatTurnTranscriptTerminalProof {
        let path = try Self.path(for: identity, dataRoot: dataRoot)
        return try await SwiftNativePersistenceCore.withFileLock(path) {
            try Self.readLocked(path: path, identity: identity)
        }
    }

    private nonisolated static func path(for identity: MacChatTurnIdentity, dataRoot: URL) throws -> URL {
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(
            identity.sessionId
        ) else {
            throw MacChatTurnTranscriptProofReaderError.invalidEvidence
        }
        return dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(safeSessionId).jsonl")
    }

    private nonisolated static func readLocked(
        path: URL,
        identity: MacChatTurnIdentity
    ) throws -> MacChatTurnTranscriptTerminalProof {
        var info = stat()
        let result = path.path.withCString { lstat($0, &info) }
        if result != 0 {
            guard errno == ENOENT else {
                throw MacChatTurnTranscriptProofReaderError.invalidEvidence
            }
            return .absent
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            // Symlinks, including dangling ones, cannot prove absent canonical evidence.
            throw MacChatTurnTranscriptProofReaderError.invalidEvidence
        }
        let values = try path.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize >= 0 else {
            throw MacChatTurnTranscriptProofReaderError.invalidEvidence
        }
        guard fileSize > 0 else { return .absent }

        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        let byteCount = min(fileSize, maximumBytes)
        let start = fileSize - byteCount
        try handle.seek(toOffset: UInt64(start))
        var data = try handle.read(upToCount: byteCount) ?? Data()
        if start > 0 {
            guard let newline = data.firstIndex(of: 0x0A) else {
                throw MacChatTurnTranscriptProofReaderError.invalidEvidence
            }
            data.removeSubrange(data.startIndex...newline)
        }
        guard data.isEmpty || data.last == 0x0A,
              let text = String(data: data, encoding: .utf8) else {
            throw MacChatTurnTranscriptProofReaderError.invalidEvidence
        }
        var lines = text.components(separatedBy: "\n")
        if lines.last?.isEmpty == true { lines.removeLast() }
        guard lines.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw MacChatTurnTranscriptProofReaderError.invalidEvidence
        }
        if lines.count > maximumLines {
            lines = Array(lines.suffix(maximumLines))
        }

        var rows: [[String: JSONValue]] = []
        rows.reserveCapacity(lines.count)
        for line in lines {
            guard let data = line.data(using: .utf8),
                  case .object(let row) = try JSONValue.parse(data) else {
                throw MacChatTurnTranscriptProofReaderError.invalidEvidence
            }
            rows.append(row)
        }
        return try classify(rows: rows, identity: identity)
    }

    private nonisolated static func classify(
        rows: [[String: JSONValue]],
        identity: MacChatTurnIdentity
    ) throws -> MacChatTurnTranscriptTerminalProof {
        for row in rows.reversed() {
            guard case .string("assistant")? = row["role"],
                  case .object(let metadata)? = row["metadata"],
                  case .string(let turnId)? = metadata["turnTraceId"],
                  turnId == identity.turnId else {
                continue
            }
            guard
                  case .string(let rowMessageId)? = row["id"],
                  case .string(let rowSessionId)? = row["sessionId"],
                  rowSessionId == identity.sessionId,
                  case .string(let rowSource)? = row["source"],
                  case .object(let observation)? = metadata["outcomeObservation"],
                  let receipt = ResponseOutcomeObservationV2(jsonValue: .object(observation)),
                  receipt.turnID == identity.turnId,
                  receipt.messageID == rowMessageId,
                  receipt.sessionID == identity.sessionId,
                  receipt.surface == rowSource else {
                throw MacChatTurnTranscriptProofReaderError.invalidEvidence
            }
            let partial = try strictBoolean(metadata["partial"])
            let canceled = try strictBoolean(metadata["cancelled"])
            switch receipt.responsePersistence {
            case "persisted" where !partial && !canceled:
                // Persisted answers include provider failures and pending cards, so need completion evidence.
                switch metadata["completionState"] {
                case .string("completed")?: return .completed
                case .string("incomplete")?: return .incomplete
                default: return .absent
                }
            case "failed" where !partial && !canceled:
                return .failed
            case "cancelled" where partial && canceled:
                return .canceled
            default:
                return .absent
            }
        }
        return .absent
    }

    private nonisolated static func strictBoolean(_ value: JSONValue?) throws -> Bool {
        switch value {
        case nil:
            return false
        case .bool(let value):
            return value
        default:
            throw MacChatTurnTranscriptProofReaderError.invalidEvidence
        }
    }
}

public enum MacChatTurnLifecycleRestartRepair {
    public static func repair(
        record: MacChatPersistedTurnLifecycle,
        transcriptProof: MacChatTurnTranscriptTerminalProof,
        hasCheckpoint: Bool,
        at instant: Date
    ) -> MacChatTurnLifecycleState? {
        guard let restored = record.restoredState() else { return nil }
        guard !restored.presentation.isTerminal else { return restored }
        let kind: MacChatTurnLifecycleInput.Kind
        switch transcriptProof {
        case .completed: kind = .completed
        case .incomplete:
            kind = .outcomeUnknown(reason: "This reply was saved, but the turn did not finish.")
        case .failed: kind = .failed(reason: nil)
        case .canceled: kind = .cancellationConfirmed
        case .absent, .unavailable:
            if hasCheckpoint { return restored }
            kind = .outcomeUnknown(reason: "This reply did not finish before the app restarted.")
        }
        return MacChatTurnLifecycleReducer.reduce(
            restored,
            input: MacChatTurnLifecycleInput(
                identity: restored.identity,
                kind: kind,
                occurredAt: max(instant, restored.presentation.lastMovementAt)
            )
        )
    }
}
