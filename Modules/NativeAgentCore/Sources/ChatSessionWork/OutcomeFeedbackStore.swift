import Foundation
import NativeAgentCore
import PersistenceCore

public enum OutcomeFeedbackError: Error, Sendable, Equatable {
    case invalidSessionID
    case invalidMessageID
    case invalidRating
    case transcriptMissing
    case transcriptCorrupt
    case messageNotUnique
    case messageNotAssistant
    case messageMissingOutcomeAnchor
    case feedbackStoreCorrupt
}

public struct OutcomeReactionEvidenceKey: Sendable, Hashable {
    public let sessionID: String
    public let messageID: String
    public let turnID: String

    public init(sessionID: String, messageID: String, turnID: String) {
        self.sessionID = sessionID
        self.messageID = messageID
        self.turnID = turnID
    }
}

/// Exact thumbs feedback over an already-persisted assistant response.
///
/// This is an additive receipt in the existing context feedback root, not a
/// second transcript or outcome owner. It stores no content, persona, path,
/// prompt, or provider output. Regenerate remains a separate canonical
/// transcript reaction.
public struct OutcomeFeedbackStore: Sendable {
    public static let schema = "response.feedback.v2"
    public static let continuationSchema = "response.reaction.v2"
    public static let maximumExistingRows = 20_000
    public static let maximumExistingBytes = 16 * 1_024 * 1_024

    private let dataRoot: URL
    private let persistence: any PersistenceCoreProtocol
    private let clock: @Sendable () -> Date
    private let makeEventID: @Sendable () -> String

    public init(
        dataRoot: URL,
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore(),
        clock: @escaping @Sendable () -> Date = { Date() },
        makeEventID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.dataRoot = dataRoot
        self.persistence = persistence
        self.clock = clock
        self.makeEventID = makeEventID
    }

    @discardableResult
    public func record(
        sessionID rawSessionID: String,
        messageID rawMessageID: String,
        rating rawRating: String
    ) async throws -> JSONValue {
        guard let sessionID = NativeAgentChatSessionID.normalizedPathComponent(rawSessionID) else {
            throw OutcomeFeedbackError.invalidSessionID
        }
        guard let messageID = OutcomeTraceIdentity.normalized(rawMessageID) else {
            throw OutcomeFeedbackError.invalidMessageID
        }
        let rating = rawRating.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard rating == "up" || rating == "down" else {
            throw OutcomeFeedbackError.invalidRating
        }
        let transcript = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")

        let anchor: (turnID: String, surface: String, contextSelectionReceiptID: String?) = try await persistence.withFileLock(transcript) {
            guard FileManager.default.fileExists(atPath: transcript.path) else {
                throw OutcomeFeedbackError.transcriptMissing
            }
            let rows: [JSONValue]
            do { rows = try await persistence.readJSONL(transcript) }
            catch { throw OutcomeFeedbackError.transcriptCorrupt }
            let matching = rows.filter { row in
                guard case .object(let object) = row,
                      case .string(let id)? = object["id"] else { return false }
                return id == messageID
            }
            guard matching.count == 1 else { throw OutcomeFeedbackError.messageNotUnique }
            guard case .object(let object) = matching[0],
                  case .string("assistant")? = object["role"] else {
                throw OutcomeFeedbackError.messageNotAssistant
            }
            guard case .object(let metadata)? = object["metadata"],
                  case .object(let outcome)? = metadata["outcomeObservation"],
                  outcome["schema"] == .string("response.outcome-observation.v2"),
                  case .string(let turnID)? = outcome["turnID"],
                  case .string(let anchoredMessageID)? = outcome["messageID"],
                  anchoredMessageID == messageID,
                  case .string(let anchoredSessionID)? = outcome["sessionID"],
                  anchoredSessionID == sessionID,
                  case .string(let surface)? = outcome["surface"],
                  OutcomeTraceIdentity.normalized(turnID) != nil,
                  OutcomeTraceIdentity.normalized(surface) != nil else {
                throw OutcomeFeedbackError.messageMissingOutcomeAnchor
            }
            let selectionReceiptID: String? = {
                guard case .string(let value)? = outcome["contextSelectionReceiptID"] else {
                    return nil
                }
                return OutcomeTraceIdentity.normalized(value)
            }()
            return (turnID, surface, selectionReceiptID)
        }

        let feedbackPath = dataRoot
            .appendingPathComponent("context", isDirectory: true)
            .appendingPathComponent("feedback.jsonl")
        let rawEventID = makeEventID()
        let eventID = OutcomeTraceIdentity.normalized(rawEventID)
            ?? CausalTransitionEvidence.opaqueIdentity(rawEventID)
        let observedAt = NativeTimestampFormat.fractionalZulu(clock())
        let reaction = rating == "up" ? "thumbs_up" : "thumbs_down"
        return try await persistence.withFileLock(feedbackPath) {
            let existing = try Self.readExistingFeedbackFile(feedbackPath)
            let prior = existing.reversed().first { row in
                guard case .object(let object) = row else { return false }
                return object["schema"] == .string(Self.schema)
                    && object["sessionId"] == .string(sessionID)
                    && object["messageId"] == .string(messageID)
            }
            // Repeated clicks on the already-current value are idempotent and
            // cannot manufacture additional calibration weight.
            if case .object(let object)? = prior,
               object["reaction"] == .string(reaction) {
                return .object(object)
            }
            var object: [String: JSONValue] = [
                "schema": .string(Self.schema),
                "eventId": .string(eventID),
                "messageId": .string(messageID),
                "turnId": .string(anchor.turnID),
                "sessionId": .string(sessionID),
                "surface": .string(anchor.surface),
                "reaction": .string(reaction),
                "observedAt": .string(observedAt),
                "observedBy": .string("canonical_transcript_feedback"),
                "payloadFree": .bool(true),
                "controlAuthority": .bool(false),
            ]
            if let selectionReceiptID = anchor.contextSelectionReceiptID {
                object["contextSelectionReceiptId"] = .string(selectionReceiptID)
            }
            if case .object(let priorObject)? = prior,
               case .string(let priorEventID)? = priorObject["eventId"] {
                object["supersedesEventId"] = .string(priorEventID)
            }
            let record = JSONValue.object(object)
            try await appendJSONLCapped(
                record,
                to: feedbackPath,
                using: persistence,
                maxLines: Self.maximumExistingRows,
                logLabel: "OutcomeFeedbackStore",
                takeLock: false,
                maxBytes: Self.maximumExistingBytes,
                capCheckStride: 1
            )
            return record
        }
    }

    /// Records only a structurally attributable continuation: the named user
    /// row must be the transcript tail and the immediately preceding row must
    /// be one exact anchored assistant outcome. The receipt says conversation
    /// continued; it never infers approval, disapproval, or sentiment.
    @discardableResult
    public func recordConversationContinuation(
        sessionID rawSessionID: String,
        reactionMessageID rawReactionMessageID: String
    ) async throws -> JSONValue? {
        guard let sessionID = NativeAgentChatSessionID.normalizedPathComponent(rawSessionID) else {
            throw OutcomeFeedbackError.invalidSessionID
        }
        guard let reactionMessageID = OutcomeTraceIdentity.normalized(rawReactionMessageID) else {
            throw OutcomeFeedbackError.invalidMessageID
        }
        let transcript = dataRoot
            .appendingPathComponent("chat/messages", isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
        let anchor: (messageID: String, turnID: String, surface: String)? = try await persistence.withFileLock(transcript) {
            guard FileManager.default.fileExists(atPath: transcript.path) else {
                throw OutcomeFeedbackError.transcriptMissing
            }
            let rows: [JSONValue]
            do { rows = try await persistence.readJSONL(transcript) }
            catch { throw OutcomeFeedbackError.transcriptCorrupt }
            guard rows.count >= 3,
                  case .object(let reactionRow) = rows[rows.count - 1],
                  reactionRow["id"] == .string(reactionMessageID),
                  reactionRow["sessionId"] == .string(sessionID),
                  reactionRow["role"] == .string("user"),
                  case .object(let assistant) = rows[rows.count - 2],
                  assistant["role"] == .string("assistant"),
                  assistant["sessionId"] == .string(sessionID),
                  case .string(let assistantRunID)? = assistant["runId"],
                  Self.hasOriginatingRequest(
                    in: rows[..<(rows.count - 2)].reversed(),
                    sessionID: sessionID, runID: assistantRunID),
                  case .string(let messageID)? = assistant["id"],
                  case .object(let metadata)? = assistant["metadata"],
                  case .object(let outcome)? = metadata["outcomeObservation"],
                  outcome["schema"] == .string("response.outcome-observation.v2"),
                  outcome["messageID"] == .string(messageID),
                  outcome["sessionID"] == .string(sessionID),
                  case .string(let turnID)? = outcome["turnID"],
                  case .string(let surface)? = outcome["surface"],
                  OutcomeTraceIdentity.normalized(messageID) != nil,
                  OutcomeTraceIdentity.normalized(turnID) != nil,
                  OutcomeTraceIdentity.normalized(surface) != nil else {
                return nil
            }
            return (messageID, turnID, surface)
        }
        guard let anchor else { return nil }

        let feedbackPath = dataRoot.appendingPathComponent("context/feedback.jsonl")
        let rawEventID = makeEventID()
        let eventID = OutcomeTraceIdentity.normalized(rawEventID)
            ?? CausalTransitionEvidence.opaqueIdentity(rawEventID)
        let record: JSONValue = .object([
            "schema": .string(Self.continuationSchema),
            "eventId": .string(eventID),
            "messageId": .string(anchor.messageID),
            "turnId": .string(anchor.turnID),
            "sessionId": .string(sessionID),
            "surface": .string(anchor.surface),
            "reaction": .string("conversation_continued"),
            "reactionMessageId": .string(reactionMessageID),
            "observedAt": .string(NativeTimestampFormat.fractionalZulu(clock())),
            "observedBy": .string("canonical_transcript_adjacency"),
            "payloadFree": .bool(true),
            "controlAuthority": .bool(false),
        ])
        return try await persistence.withFileLock(feedbackPath) {
            let existing = try Self.readExistingFeedbackFile(feedbackPath)
            if let prior = existing.first(where: { row in
                guard case .object(let object) = row else { return false }
                return object["schema"] == .string(Self.continuationSchema)
                    && object["reactionMessageId"] == .string(reactionMessageID)
            }) {
                return prior
            }
            try await appendJSONLCapped(
                record,
                to: feedbackPath,
                using: persistence,
                maxLines: Self.maximumExistingRows,
                logLabel: "OutcomeFeedbackStore",
                takeLock: false,
                maxBytes: Self.maximumExistingBytes,
                capCheckStride: 1
            )
            return record
        }
    }

    /// Walk only same-run tool receipts back to the originating request.
    /// Another role, session or run breaks attribution.
    package static func hasOriginatingRequest(
        in precedingRows: some Sequence<JSONValue>,
        sessionID: String,
        runID: String
    ) -> Bool {
        guard OutcomeTraceIdentity.normalized(runID) != nil else { return false }
        for value in precedingRows {
            guard case .object(let row) = value,
                  row["sessionId"] == .string(sessionID),
                  row["runId"] == .string(runID) else { return false }
            if row["role"] == .string("user") { return true }
            guard row["role"] == .string("tool") else { return false }
        }
        return false
    }

    /// Exact outcome anchors with structured reaction evidence. Legacy rows
    /// lacking transcript-bound identities are ignored, never upgraded.
    public func reactionEvidenceKeys() async throws -> Set<OutcomeReactionEvidenceKey> {
        let path = dataRoot.appendingPathComponent("context/feedback.jsonl")
        return try await persistence.withFileLock(path) {
            let existing = try Self.readExistingFeedbackFile(path)
            return Set(existing.compactMap { row in
                guard case .object(let object) = row,
                      object["schema"] == .string(Self.schema)
                        || object["schema"] == .string(Self.continuationSchema),
                      case .string(let sessionID)? = object["sessionId"],
                      case .string(let messageID)? = object["messageId"],
                      case .string(let turnID)? = object["turnId"] else { return nil }
                return OutcomeReactionEvidenceKey(
                    sessionID: sessionID, messageID: messageID, turnID: turnID
                )
            })
        }
    }

    private static func readExistingFeedbackFile(_ path: URL) throws -> [JSONValue] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
              let number = attributes[.size] as? NSNumber,
              number.intValue <= maximumExistingBytes,
              let data = try? Data(contentsOf: path, options: [.mappedIfSafe]) else {
            throw OutcomeFeedbackError.feedbackStoreCorrupt
        }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard lines.count <= maximumExistingRows else {
            throw OutcomeFeedbackError.feedbackStoreCorrupt
        }
        return try lines.compactMap { line -> JSONValue? in
            guard let value = try? JSONValue.parse(Data(line)), case .object(let object) = value else {
                throw OutcomeFeedbackError.feedbackStoreCorrupt
            }
            if object["schema"] == .string(Self.schema) {
                guard case .string(let eventID)? = object["eventId"],
                      case .string(let turnID)? = object["turnId"],
                      case .string(let messageID)? = object["messageId"],
                      case .string(let reaction)? = object["reaction"],
                      OutcomeTraceIdentity.normalized(eventID) != nil,
                      OutcomeTraceIdentity.normalized(turnID) != nil,
                      OutcomeTraceIdentity.normalized(messageID) != nil,
                      (object["contextSelectionReceiptId"] == nil || {
                          guard case .string(let receiptID)? = object["contextSelectionReceiptId"] else {
                              return false
                          }
                          return OutcomeTraceIdentity.normalized(receiptID) != nil
                      }()),
                      reaction == "thumbs_up" || reaction == "thumbs_down",
                      (object["supersedesEventId"] == nil || {
                          guard case .string(let prior)? = object["supersedesEventId"] else { return false }
                          return OutcomeTraceIdentity.normalized(prior) != nil
                      }()),
                      object["payloadFree"] == .bool(true),
                      object["controlAuthority"] == .bool(false) else {
                    throw OutcomeFeedbackError.feedbackStoreCorrupt
                }
            } else if object["schema"] == .string(Self.continuationSchema) {
                guard case .string(let eventID)? = object["eventId"],
                      case .string(let turnID)? = object["turnId"],
                      case .string(let messageID)? = object["messageId"],
                      case .string(let sessionID)? = object["sessionId"],
                      case .string(let surface)? = object["surface"],
                      case .string(let reactionMessageID)? = object["reactionMessageId"],
                      case .string(let observedAt)? = object["observedAt"],
                      OutcomeTraceIdentity.normalized(eventID) != nil,
                      OutcomeTraceIdentity.normalized(turnID) != nil,
                      OutcomeTraceIdentity.normalized(messageID) != nil,
                      NativeAgentChatSessionID.normalizedPathComponent(sessionID) == sessionID,
                      OutcomeTraceIdentity.normalized(surface) != nil,
                      OutcomeTraceIdentity.normalized(reactionMessageID) != nil,
                      NativeTimestampFormat.parseISO8601FractionalFirst(observedAt) != nil,
                      object["reaction"] == .string("conversation_continued"),
                      object["observedBy"] == .string("canonical_transcript_adjacency"),
                      object["payloadFree"] == .bool(true),
                      object["controlAuthority"] == .bool(false) else {
                    throw OutcomeFeedbackError.feedbackStoreCorrupt
                }
            } else {
                // Additive compatibility for rows written by the former Mac
                // seam. They remain observational and are never upgraded into
                // exact feedback because they lack transcript validation.
                guard case .string? = object["message_id"],
                      case .string? = object["rating"],
                      case .string? = object["logged_at"] else {
                    throw OutcomeFeedbackError.feedbackStoreCorrupt
                }
            }
            // Match readJSONL's UTF-8 admission after validating every row.
            return String(data: Data(line), encoding: .utf8) == nil ? nil : value
        }
    }
}
