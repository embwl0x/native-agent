import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Experiences
// Blueprint: | `OutcomeFeedbackStore.swift` | `OutcomeFeedbackStore`, `record`, `recordConversationContinuation`. |

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

/// Payload-free feedback is a detail of the transcript's anchored turn, never a second outcome owner.
/// The feedback.reaction kind stays private: no backup, export or phone sync.
public struct OutcomeFeedbackStore: Sendable {
    public static let schema = "response.feedback.v2"
    public static let continuationSchema = "response.reaction.v2"
    private static let detailKind = "feedback.reaction"

    private let dataRoot: URL
    private let clock: @Sendable () -> Date
    private let makeEventID: @Sendable () -> String
    private var store: ExperienceStore { ExperienceStore.at(dataRoot) }

    public init(
        dataRoot: URL,
        clock: @escaping @Sendable () -> Date = { Date() },
        makeEventID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.dataRoot = dataRoot
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

        let anchor: (turnID: String, surface: String, contextSelectionReceiptID: String?) = try await SwiftNativePersistenceCore.withFileLock(transcript) {
            guard FileManager.default.fileExists(atPath: transcript.path) else {
                throw OutcomeFeedbackError.transcriptMissing
            }
            let rows: [JSONValue]
            do { rows = try await SwiftNativePersistenceCore.readJSONL(transcript) }
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

        let rawEventID = makeEventID()
        let eventID = OutcomeTraceIdentity.normalized(rawEventID)
            ?? CausalTransitionEvidence.opaqueIdentity(rawEventID)
        let at = clock()
        let observedAt = NativeTimestampFormat.fractionalZulu(at)
        let reaction = rating == "up" ? "thumbs_up" : "thumbs_down"
        let subject = anchor.turnID
        // The comparison and the write are one record transaction: the write lands only while the rating it supersedes is still the latest.
        // A miss means another rating landed between the read and the write; the next pass compares against it.
        while true {
            let rows = try await readExistingFeedback(subjects: [subject]).compactMap(\.objectValue)
            let prior = Self.latestRating(in: rows, sessionID: sessionID, messageID: messageID)
            // Repeated clicks on the current value are idempotent so they cannot manufacture calibration weight.
            if let prior, prior["reaction"] == .string(reaction) { return .object(prior) }
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
            if case .string(let priorEventID)? = prior?["eventId"] {
                object["supersedesEventId"] = .string(priorEventID)
            }
            let record = JSONValue.object(object)
            let superseded = prior?["eventId"]
            let detail = ExperienceStore.Detail(source: "feedback", at: at, subject: subject, kind: Self.detailKind,
                                                row: try record.serializedData(pretty: false))
            let wrote = try await store.note(detail) { details in
                try Self.latestRating(in: Self.feedbackRows(details, subject: subject), sessionID: sessionID, messageID: messageID)?["eventId"]
                    != superseded
            }
            if wrote { return record }
        }
    }

    /// The newest thumbs rating of one answer among its turn's feedback rows.
    private static func latestRating(in rows: [[String: JSONValue]], sessionID: String, messageID: String) -> [String: JSONValue]? {
        rows.last { $0["schema"] == .string(schema) && $0["sessionId"] == .string(sessionID) && $0["messageId"] == .string(messageID) }
    }

    /// The feedback rows among a subject's details, in record order; a feedback detail that is not this turn's object is a corrupt store.
    private static func feedbackRows(_ details: [ExperienceStore.Detail], subject: String) throws -> [[String: JSONValue]] {
        try details.filter { $0.kind == detailKind }.map { detail in
            guard case .object(let object)? = try? JSONValue.parse(detail.row), object["turnId"] == .string(subject) else {
                throw OutcomeFeedbackError.feedbackStoreCorrupt
            }
            return object
        }
    }

    /// Attribute continuation only to an exact anchored assistant outcome immediately before the named user tail row.
    /// Continuation never proves approval, disapproval or sentiment.
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
        let anchor: (messageID: String, turnID: String, surface: String)? = try await SwiftNativePersistenceCore.withFileLock(transcript) {
            guard FileManager.default.fileExists(atPath: transcript.path) else {
                throw OutcomeFeedbackError.transcriptMissing
            }
            let rows: [JSONValue]
            do { rows = try await SwiftNativePersistenceCore.readJSONL(transcript) }
            catch { throw OutcomeFeedbackError.transcriptCorrupt }
            guard rows.count >= 3,
                  case .object(let reactionRow) = rows[rows.count - 1],
                  reactionRow["id"] == .string(reactionMessageID),
                  case .object(let assistant) = rows[rows.count - 2],
                  Self.hasCanonicalContinuation(
                    assistant: assistant, reaction: rows[rows.count - 1],
                    precedingRows: rows[..<(rows.count - 2)].reversed(), sessionID: sessionID),
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

        let rawEventID = makeEventID()
        let eventID = OutcomeTraceIdentity.normalized(rawEventID)
            ?? CausalTransitionEvidence.opaqueIdentity(rawEventID)
        let at = clock()
        let record: JSONValue = .object([
            "schema": .string(Self.continuationSchema),
            "eventId": .string(eventID),
            "messageId": .string(anchor.messageID),
            "turnId": .string(anchor.turnID),
            "sessionId": .string(sessionID),
            "surface": .string(anchor.surface),
            "reaction": .string("conversation_continued"),
            "reactionMessageId": .string(reactionMessageID),
            "observedAt": .string(NativeTimestampFormat.fractionalZulu(at)),
            "observedBy": .string("canonical_transcript_adjacency"),
            "payloadFree": .bool(true),
            "controlAuthority": .bool(false),
        ])
        let subject = anchor.turnID
        func continues(_ row: [String: JSONValue]) -> Bool {
            row["schema"] == .string(Self.continuationSchema) && row["reactionMessageId"] == .string(reactionMessageID)
        }
        // The check for an existing continuation and the write are one record transaction.
        let detail = ExperienceStore.Detail(source: "feedback", at: at, subject: subject, kind: Self.detailKind,
                                                row: try record.serializedData(pretty: false))
        let wrote = try await store.note(detail) { details in
            try Self.feedbackRows(details, subject: subject).contains { row in
                row["schema"] == .string(Self.continuationSchema) && row["reactionMessageId"] == .string(reactionMessageID)
            }
        }
        if wrote { return record }
        return try await readExistingFeedback(subjects: [subject]).compactMap(\.objectValue).first(where: continues).map(JSONValue.object)
    }

    /// Adjacent assistant/user rows prove continuation only with a same-run originating request.
    static func hasCanonicalContinuation(
        assistant: [String: JSONValue],
        reaction: JSONValue,
        precedingRows: some Sequence<JSONValue>,
        sessionID: String
    ) -> Bool {
        guard assistant["role"] == .string("assistant"),
              assistant["sessionId"] == .string(sessionID),
              case .string(let assistantRunID)? = assistant["runId"],
              case .object(let row) = reaction,
              row["role"] == .string("user"),
              row["sessionId"] == .string(sessionID),
              case .string(let reactionMessageID)? = row["id"],
              OutcomeTraceIdentity.normalized(reactionMessageID) != nil else { return false }
        return hasOriginatingRequest(in: precedingRows, sessionID: sessionID, runID: assistantRunID)
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

    /// Ignore feedback without transcript-bound outcome identity; never invent an anchor.
    public func reactionEvidenceKeys() async throws -> Set<OutcomeReactionEvidenceKey> {
        let existing = try await readExistingFeedback()
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

    private func readExistingFeedback(subjects: [String]? = nil) async throws -> [JSONValue] {
        let details = try await store.details(.init(subjects: subjects, kinds: [Self.detailKind]))
        return try details.map { detail in
            let value: JSONValue
            do { value = try JSONValue.parse(detail.row) }
            catch { throw OutcomeFeedbackError.feedbackStoreCorrupt }
            guard case .object(let object) = value, object["turnId"] == .string(detail.subject) else {
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
                throw OutcomeFeedbackError.feedbackStoreCorrupt
            }
            return value
        }
    }
}
