import Foundation
import NativeAgentCore

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
        guard let messageID = Self.closedToken(rawMessageID, maximum: 128) else {
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
                  Self.closedToken(turnID, maximum: 128) != nil,
                  Self.closedToken(surface, maximum: 128) != nil else {
                throw OutcomeFeedbackError.messageMissingOutcomeAnchor
            }
            let selectionReceiptID: String? = {
                guard case .string(let value)? = outcome["contextSelectionReceiptID"] else {
                    return nil
                }
                return Self.closedToken(value, maximum: 128)
            }()
            return (turnID, surface, selectionReceiptID)
        }

        let feedbackPath = dataRoot
            .appendingPathComponent("context", isDirectory: true)
            .appendingPathComponent("feedback.jsonl")
        let rawEventID = makeEventID()
        let eventID = Self.closedToken(rawEventID, maximum: 128)
            ?? CausalTransitionEvidence.opaqueIdentity(rawEventID)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let observedAt = formatter.string(from: clock())
        let reaction = rating == "up" ? "thumbs_up" : "thumbs_down"
        return try await persistence.withFileLock(feedbackPath) {
            try Self.validateExistingFeedbackFile(feedbackPath)
            let existing = FileManager.default.fileExists(atPath: feedbackPath.path)
                ? (try await persistence.readJSONL(feedbackPath)) : []
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
                trimWhenBytesExceed: Self.maximumExistingBytes
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
        guard let reactionMessageID = Self.closedToken(rawReactionMessageID, maximum: 128) else {
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
                  case .object(let requestRow) = rows[rows.count - 3],
                  requestRow["role"] == .string("user"),
                  requestRow["sessionId"] == .string(sessionID),
                  requestRow["runId"] == .string(assistantRunID),
                  case .string(let messageID)? = assistant["id"],
                  case .object(let metadata)? = assistant["metadata"],
                  case .object(let outcome)? = metadata["outcomeObservation"],
                  outcome["schema"] == .string("response.outcome-observation.v2"),
                  outcome["messageID"] == .string(messageID),
                  outcome["sessionID"] == .string(sessionID),
                  case .string(let turnID)? = outcome["turnID"],
                  case .string(let surface)? = outcome["surface"],
                  Self.closedToken(messageID, maximum: 128) != nil,
                  Self.closedToken(turnID, maximum: 128) != nil,
                  Self.closedToken(surface, maximum: 128) != nil else {
                return nil
            }
            return (messageID, turnID, surface)
        }
        guard let anchor else { return nil }

        let feedbackPath = dataRoot.appendingPathComponent("context/feedback.jsonl")
        let rawEventID = makeEventID()
        let eventID = Self.closedToken(rawEventID, maximum: 128)
            ?? CausalTransitionEvidence.opaqueIdentity(rawEventID)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let record: JSONValue = .object([
            "schema": .string(Self.continuationSchema),
            "eventId": .string(eventID),
            "messageId": .string(anchor.messageID),
            "turnId": .string(anchor.turnID),
            "sessionId": .string(sessionID),
            "surface": .string(anchor.surface),
            "reaction": .string("conversation_continued"),
            "reactionMessageId": .string(reactionMessageID),
            "observedAt": .string(formatter.string(from: clock())),
            "observedBy": .string("canonical_transcript_adjacency"),
            "payloadFree": .bool(true),
            "controlAuthority": .bool(false),
        ])
        return try await persistence.withFileLock(feedbackPath) {
            try Self.validateExistingFeedbackFile(feedbackPath)
            let existing = FileManager.default.fileExists(atPath: feedbackPath.path)
                ? (try await persistence.readJSONL(feedbackPath)) : []
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
                trimWhenBytesExceed: Self.maximumExistingBytes
            )
            return record
        }
    }

    /// Exact outcome anchors with structured reaction evidence. Legacy rows
    /// lacking transcript-bound identities are ignored, never upgraded.
    public func reactionEvidenceKeys() async throws -> Set<OutcomeReactionEvidenceKey> {
        let path = dataRoot.appendingPathComponent("context/feedback.jsonl")
        return try await persistence.withFileLock(path) {
            guard FileManager.default.fileExists(atPath: path.path) else { return [] }
            try Self.validateExistingFeedbackFile(path)
            return Set(try await persistence.readJSONL(path).compactMap { row in
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

    private static func validateExistingFeedbackFile(_ path: URL) throws {
        guard FileManager.default.fileExists(atPath: path.path) else { return }
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
        for line in lines {
            guard let value = try? JSONValue.parse(Data(line)), case .object(let object) = value else {
                throw OutcomeFeedbackError.feedbackStoreCorrupt
            }
            if object["schema"] == .string(Self.schema) {
                guard case .string(let eventID)? = object["eventId"],
                      case .string(let turnID)? = object["turnId"],
                      case .string(let messageID)? = object["messageId"],
                      case .string(let reaction)? = object["reaction"],
                      closedToken(eventID, maximum: 128) != nil,
                      closedToken(turnID, maximum: 128) != nil,
                      closedToken(messageID, maximum: 128) != nil,
                      (object["contextSelectionReceiptId"] == nil || {
                          guard case .string(let receiptID)? = object["contextSelectionReceiptId"] else {
                              return false
                          }
                          return closedToken(receiptID, maximum: 128) != nil
                      }()),
                      reaction == "thumbs_up" || reaction == "thumbs_down",
                      (object["supersedesEventId"] == nil || {
                          guard case .string(let prior)? = object["supersedesEventId"] else { return false }
                          return closedToken(prior, maximum: 128) != nil
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
                      closedToken(eventID, maximum: 128) != nil,
                      closedToken(turnID, maximum: 128) != nil,
                      closedToken(messageID, maximum: 128) != nil,
                      NativeAgentChatSessionID.normalizedPathComponent(sessionID) == sessionID,
                      closedToken(surface, maximum: 128) != nil,
                      closedToken(reactionMessageID, maximum: 128) != nil,
                      Self.parseDate(observedAt) != nil,
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
        }
    }

    private static func closedToken(_ raw: String?, maximum: Int) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._:"))
        guard raw == value, !value.isEmpty, value.count <= maximum,
              value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return value
    }

    private static func parseDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}
