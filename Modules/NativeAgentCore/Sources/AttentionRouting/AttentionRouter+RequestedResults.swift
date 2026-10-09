import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import DeviceSync
import StandingBots

extension AttentionRouter {
    /// Publication edges and the existing sync integrity pass retry only the
    /// result's delivery. The canonical row is the durable pending intent;
    /// Attention's existing ledger commits acceptance before acknowledging it.
    public func retryRequestedResults(dataRoot: URL) async throws {
        guard !resultScanInFlight else { return }
        resultScanInFlight = true
        defer { resultScanInFlight = false }
        let shelf = ShelfStore(dataRoot: dataRoot)
        var storageFailure: Error?
        var helpers: [ShelfEntry] = []
        do { helpers = try shelf.pendingConditionNotifications() }
        catch { storageFailure = error }
        let directory = dataRoot.appendingPathComponent("chat/messages", isDirectory: true)
        var paths: [URL] = []
        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                paths = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
                    .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            }
        } catch { storageFailure = storageFailure ?? error }
        var retained: [URL: Date] = [:]
        var deliveries: [(URL, JSONValue, [String: JSONValue])] = []
        for path in paths {
            let modified: Date?
            do { modified = try path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            catch { storageFailure = storageFailure ?? error; continue }
            if let modified, settledResultFiles[path] == modified {
                retained[path] = modified
                continue
            }
            let rows: [JSONValue]
            do { rows = try await SwiftNativePersistenceCore().readJSONL(path) }
            catch {
                nativeLog("requested_result: transcript unavailable, retained for retry: %@", error.localizedDescription)
                storageFailure = storageFailure ?? error
                continue
            }
            var pending = false
            for row in rows {
                guard let intent = Self.pendingResult(row) else { continue }
                pending = true
                deliveries.append((path, row, intent))
            }
            // Acknowledgement changed the file. Read it next pass before
            // caching; a concurrent append must never be hidden by this scan.
            if !pending, let modified { retained[path] = modified }
        }
        settledResultFiles = retained
        let total = deliveries.count + helpers.count
        guard total > 0 else {
            resultRetryOffset = 0
            if let storageFailure { throw storageFailure }
            return
        }
        // Three attempts per pass, rotating so one outage cannot starve later
        // results. Restart reconstructs this bounded work from the same rows.
        let start = resultRetryOffset % total
        let count = min(3, total)
        for offset in 0..<count {
            let index = (start + offset) % total
            do {
                if index < deliveries.count {
                    let (path, row, intent) = deliveries[index]
                    if try await deliverRequestedResult(row: row, intent: intent) {
                        try await Self.acknowledgeResult(intent, at: path)
                    }
                } else {
                    let entry = helpers[index - deliveries.count]
                    guard let title = entry.conditionNotificationTitle else {
                        throw StandingBotsError.corruptStore("condition notification title unavailable")
                    }
                    let outcome = try await route(
                        eventId: "bot_condition:\(entry.id.uuidString)", importance: .requestedResult,
                        title: TurnSecretRedactor.redactDisplayText(String(title.prefix(160))),
                        body: TurnSecretRedactor.redactDisplayText(String(entry.headline.prefix(500))),
                        userInfo: ["screen": "activity", "source": "bot_condition", "botId": entry.botId.uuidString])
                    if outcome.deliveryProjection.reachedAChannel || outcome.deliveryProjection == .previouslyHandled {
                        try shelf.acknowledge(readerId: ShelfStore.conditionNotificationReaderID, entryIds: [entry.id])
                    }
                }
            } catch {
                nativeLog("requested_result: delivery remains pending: %@", error.localizedDescription)
            }
        }
        resultRetryOffset = start + count
        if let storageFailure { throw storageFailure }
    }

    /// Completion transport uses the same intent and identity as publication.
    /// A missing intent cannot claim delivery of interrupted or waiting work.
    /// `opening`: the chat the push opens, when the answer was written in
    /// another (a contact's conversation answering the chat that asked).
    public func deliverRequestedResult(deliveryID: String, sessionID: String?, opening: String? = nil,
                                       dataRoot: URL) async throws -> Bool {
        guard let sessionID, let safe = NativeAgentChatSessionID.normalizedPathComponent(sessionID) else {
            throw NSError(domain: "RequestedResult", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Result delivery has no valid conversation."])
        }
        let path = dataRoot.appendingPathComponent("chat/messages/\(safe).jsonl")
        let rows = try await SwiftNativePersistenceCore().readJSONL(path)
        let eventID = "requested-result:" + deliveryID
        for row in rows.reversed() {
            guard case .object(let fields) = row, case .object(let metadata)? = fields["metadata"],
                  case .object(let intent)? = metadata["resultDelivery"], intent["eventId"] == .string(eventID) else { continue }
            if intent["state"] == .string("delivered") { return true }
            guard try await deliverRequestedResult(row: row, intent: intent, opening: opening) else { return false }
            try await Self.acknowledgeResult(intent, at: path)
            return true
        }
        return false
    }

    private static func pendingResult(_ row: JSONValue) -> [String: JSONValue]? {
        guard case .object(let fields) = row, fields["role"] == .string("assistant"),
              case .object(let metadata)? = fields["metadata"],
              case .object(let intent)? = metadata["resultDelivery"],
              intent["state"] == .string("pending") else { return nil }
        return intent
    }

    private func deliverRequestedResult(row: JSONValue, intent: [String: JSONValue], opening: String? = nil) async throws -> Bool {
        guard case .string(let eventID)? = intent["eventId"],
              case .string(let sessionID)? = intent["sessionId"],
              case .string(let runID)? = intent["runId"],
              case .object(let fields) = row, fields["sessionId"] == .string(sessionID),
              fields["runId"] == .string(runID) else {
            throw NSError(domain: "RequestedResult", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "The saved result delivery intent is invalid."])
        }
        let content: String
        if case .string(let text)? = fields["content"] { content = text } else { content = "" }
        let preview = String(TurnSecretRedactor.redactDisplayText(content)
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        let outcome = try await route(
            eventId: eventID, importance: .requestedResult,
            title: "Result ready",
            body: preview.isEmpty ? "Your result is ready." : preview,
            reason: eventID,
            userInfo: ["eventId": eventID, "source": "requested_result", "screen": "chat",
                       "sessionId": opening ?? sessionID, "correlationId": runID,
                       "resultCreatedAt": Self.string(fields["createdAt"])]
        )
        return outcome.deliveryProjection.reachedAChannel || outcome.deliveryProjection == .previouslyHandled
    }

    private static func string(_ value: JSONValue?) -> String {
        if case .string(let text)? = value { return text }; return ""
    }

    private static func acknowledgeResult(_ intent: [String: JSONValue], at path: URL) async throws {
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            let raw = try String(contentsOf: path, encoding: .utf8)
            var lines = raw.components(separatedBy: "\n")
            var changed = false
            for index in lines.indices {
                guard let parsed = try? JSONValue.parse(Data(lines[index].utf8)),
                      case .object(var row) = parsed,
                      case .object(var metadata)? = row["metadata"],
                      case .object(var saved)? = metadata["resultDelivery"],
                      saved["eventId"] == intent["eventId"], saved["state"] == .string("pending") else { continue }
                saved["state"] = .string("delivered")
                metadata["resultDelivery"] = .object(saved)
                row["metadata"] = .object(metadata)
                lines[index] = try JSONValue.object(row).serialize(pretty: false)
                changed = true
            }
            if changed {
                try await persistence.writeDataAtomicDurable(Data(lines.joined(separator: "\n").utf8), to: path)
            }
        }
    }
}
