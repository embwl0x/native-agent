import Foundation
import Experiences
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Transcripts
import DeviceSync
import StandingBots
// Blueprint: | `AttentionRouter+RequestedResults.swift` | Result and bot-condition matters; transcript acknowledgement follows every door's acceptance |

extension AttentionRouter {
    /// The canonical result row retains pending intent; its matter's doors must accept before source acknowledgement.
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
            do { rows = try await SwiftNativePersistenceCore.readJSONL(path) }
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
            // Read the changed file before caching so a concurrent append cannot disappear.
            if !pending, let modified { retained[path] = modified }
        }
        settledResultFiles = retained
        let total = deliveries.count + helpers.count
        guard total > 0 else {
            resultRetryOffset = 0
            if let storageFailure { throw storageFailure }
            return
        }
        // Rotate three attempts per pass so one outage cannot starve later results; canonical rows survive restart.
        let start = resultRetryOffset % total
        let count = min(3, total)
        var acknowledgements: [(path: URL, intents: [[String: JSONValue]])] = []
        for offset in 0..<count {
            let index = (start + offset) % total
            do {
                if index < deliveries.count {
                    let (path, row, intent) = deliveries[index]
                    if try await deliverRequestedResult(row: row, intent: intent) {
                        if let group = acknowledgements.firstIndex(where: { $0.path == path }) {
                            acknowledgements[group].intents.append(intent)
                        } else {
                            acknowledgements.append((path, [intent]))
                        }
                    }
                } else {
                    let entry = helpers[index - deliveries.count]
                    guard let title = entry.conditionNotificationTitle else {
                        throw StandingBotsError.corruptStore("condition notification title unavailable")
                    }
                    let eventID = "bot_condition:\(entry.id.uuidString)"
                    let outcome = try await tell(Matter(
                        id: eventID, form: entry.runtimeStatus == .failed ? .wentWrong : entry.conditionMet == true ? .done : .words, from: "bot_condition",
                        title: TurnSecretRedactor.redactDisplayText(String(title.prefix(160))),
                        summary: TurnSecretRedactor.redactDisplayText(String((entry.conditionMet == nil
                            ? "Couldn't tell whether the condition was met. Open the saved run for its result and any failure."
                            : entry.headline).prefix(500))),
                        open: "page:bots", evidence: [.init(source: "bots/shelf-entries", id: entry.id.uuidString)]),
                        reach: .person(from: nil), turn: nil)
                    if outcome.deliveryProjection == .accepted {
                        try shelf.acknowledge(readerId: ShelfStore.conditionNotificationReaderID, entryIds: [entry.id])
                    }
                }
            } catch {
                nativeLog("requested_result: delivery remains pending: %@", error.localizedDescription)
            }
        }
        for group in acknowledgements {
            do { try await Self.acknowledgeResults(group.intents, at: group.path) }
            catch { nativeLog("requested_result: delivery remains pending: %@", error.localizedDescription) }
        }
        resultRetryOffset = start + count
        if let storageFailure { throw storageFailure }
    }

    /// Reuse publication's intent and identity; missing intent cannot prove delivery. `opening` identifies the requesting chat when the answer was written
    /// elsewhere.
    public func deliverRequestedResult(deliveryID: String, sessionID: String?, opening: String? = nil,
                                       dataRoot: URL) async throws -> Bool {
        guard let sessionID, let safe = NativeAgentChatSessionID.normalizedPathComponent(sessionID) else {
            throw NSError(domain: "RequestedResult", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Result delivery has no valid conversation."])
        }
        let path = dataRoot.appendingPathComponent("chat/messages/\(safe).jsonl")
        let rows = try await SwiftNativePersistenceCore.readJSONL(path)
        let eventID = "requested-result:" + deliveryID
        for row in rows.reversed() {
            guard case .object(let fields) = row, case .object(let metadata)? = fields["metadata"],
                  case .object(let intent)? = metadata["resultDelivery"], intent["eventId"] == .string(eventID) else { continue }
            if intent["state"] == .string("delivered") { return true }
            guard try await deliverRequestedResult(row: row, intent: intent, opening: opening) else { return false }
            try await Self.acknowledgeResults([intent], at: path)
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

    /// Require acceptance at every unsuppressed destination; unconfirmed handoff stays owed without duplicate sends.
    private func deliverRequestedResult(row: JSONValue, intent: [String: JSONValue], opening: String? = nil) async throws -> Bool {
        guard case .string(let eventID)? = intent["eventId"], eventID.hasPrefix("requested-result:"),
              case .string(let sessionID)? = intent["sessionId"],
              case .string(let runID)? = intent["runId"],
              case .object(let fields) = row, fields["sessionId"] == .string(sessionID),
              fields["runId"] == .string(runID), case .string(let messageID)? = fields["id"], !messageID.isEmpty,
              case .string(let content)? = fields["content"] else {
            throw NSError(domain: "RequestedResult", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "The saved result delivery intent is invalid."])
        }
        let preview = String(TurnSecretRedactor.redactDisplayText(content)
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        let outcome = try await tell(Matter(id: eventID, form: .done, from: "requested_result", title: "Result ready",
            summary: preview.isEmpty ? "Your result is ready." : preview,
            open: "chat:" + (opening ?? sessionID), evidence: [.init(source: Matter.messages(sessionID), id: messageID)]),
            reach: .person(from: nil), turn: nil)
        return outcome.deliveryProjection == .accepted
    }

    private static func acknowledgeResults(_ intents: [[String: JSONValue]], at path: URL) async throws {
        try await SwiftNativePersistenceCore.withFileLock(path) {
            let raw = try String(contentsOf: path, encoding: .utf8)
            var lines = raw.components(separatedBy: "\n")
            var changed = false
            for index in lines.indices {
                if lines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                let parsed = try JSONValue.parse(Data(lines[index].utf8))
                guard case .object(var row) = parsed else { throw CocoaError(.fileReadCorruptFile) }
                guard case .object(var metadata)? = row["metadata"],
                      case .object(var saved)? = metadata["resultDelivery"],
                      intents.contains(where: { saved["eventId"] == $0["eventId"] }),
                      saved["state"] == .string("pending") else { continue }
                saved["state"] = .string("delivered")
                metadata["resultDelivery"] = .object(saved)
                row["metadata"] = .object(metadata)
                lines[index] = try JSONValue.object(row).serialize(pretty: false)
                changed = true
            }
            if changed {
                try ContactThread.replace(Data(lines.joined(separator: "\n").utf8), to: path)
            }
        }
    }
}
