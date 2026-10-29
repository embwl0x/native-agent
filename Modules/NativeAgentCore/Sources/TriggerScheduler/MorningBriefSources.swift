import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Privacy
import Desk
import WorkshopExecution
// Blueprint: | `MorningBriefSources.swift` | Frozen checked Desk, Workshop, inbox, session and bounded parsed/redacted worklog observations; only consumed fields enter the part, with native row validity and unavailable/empty distinctions; native local-day and date-label facts |

/// The scheduler supplies checked observations, never a brief or model prompt.
/// Each source says unavailable, ready (possibly empty), or unconfigured.
public struct MorningBriefSources: Sendable {
    let root: URL
    let now: Date
    let worklogPath: URL?

    public init(root: URL, now: Date, worklogPath: URL?) {
        self.root = root; self.now = now
        self.worklogPath = worklogPath
    }

    public func packet() async -> JSONValue {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "EEEE, MMMM d"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) else {
            return .object(["state": .string("unavailable"), "error": .string("brief_calendar_unavailable: cannot determine the previous local day")])
        }
        return .object([
            "operation": .string("brief"), "dayLabel": .string(formatter.string(from: now)),
            "now": .string(NativeTimestampFormat.fractionalUTCOffset(now)),
            "yesterday": .string(NativeTimestampFormat.fractionalUTCOffset(yesterday)),
            "desk": await desk(), "worklog": worklog(), "workshop": await workshop(),
            "inbox": jsonLines(root.appendingPathComponent("notifications/inbox.jsonl")),
            "sessions": jsonArray(root.appendingPathComponent("chat/sessions.json")),
        ])
    }

    private func desk() async -> JSONValue {
        do {
            let state = try await SwiftNativeDeskStore(dataRoot: root).liveState()
            return .object(["state": .string("ready"),
                "statuses": .array(state.items.map { .string($0.status.rawValue) }),
                // Desk owns the projection's readiness and dependency truth.
                "body": .string(NativeAppSecretRedactor.redactText(DeskPage.render(state, now: now)))])
        } catch { return unavailable(error) }
    }

    private func workshop() async -> JSONValue {
        do {
            let rows = try await SwiftNativeWorkshopRunner(root: root)
                .listWorkshopExecutions()
            return checked(rows, fields: ["status", "completedAt", "completed_at", "updatedAt", "updated_at"]) { row in
                guard case .string(let status)? = row["status"] else { return false }
                return !status.isEmpty && status.lowercased() != "corrupt"
            }
        } catch { return unavailable(error) }
    }

    private func jsonArray(_ path: URL) -> JSONValue {
        do {
            let value = try JSONValue.parse(Data(contentsOf: path))
            guard case .array(let rows) = value else { throw CocoaError(.fileReadCorruptFile) }
            return checked(rows, fields: ["archived", "title", "updatedAt"]) { row in
                if row["archived"] == .bool(true) { return true }
                guard case .string(let stamp)? = row["updatedAt"] else { return false }
                return NativeTimestampFormat.parseISO8601FractionalFirst(stamp) != nil
            }
        } catch { return unavailable(error) }
    }

    private func jsonLines(_ path: URL) -> JSONValue {
        do {
            let text = try String(contentsOf: path, encoding: .utf8)
            let rows = try text.split(separator: "\n").map { try JSONValue.parse(Data($0.utf8)) }
            return checked(rows, fields: ["id", "status"]) { row in
                if case .string? = row["id"] { return true }
                return false
            }
        } catch { return unavailable(error) }
    }

    /// Only parsed, redacted summary fields leave this native reader; neither
    /// the private worklog's raw bytes nor unrelated fields enter her part.
    private func worklog() -> JSONValue {
        guard let worklogPath else { return .object(["state": .string("unconfigured")]) }
        do {
            guard let read = try SwiftNativePersistenceCore.tailPhysicalLines(worklogPath, limit: .max, maxBytes: 128 * 1024)
            else { throw CocoaError(.fileReadNoSuchFile) }
            if read.leadingFragment, read.lines.count == 1, read.lines[0].count == read.bytesRead { throw CocoaError(.fileReadCorruptFile) }
            var rows: [JSONValue] = []
            var damaged = false
            for line in read.lines.dropFirst(read.leadingFragment ? 1 : 0) {
                guard let text = String(data: line, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                guard case .object(let row)? = try? JSONValue.parse(line),
                      case .string(let ts)? = row["ts"], NativeTimestampFormat.parseISO8601FractionalFirst(ts) != nil,
                      case .string(let summary)? = row["summary"] else { damaged = true; continue }
                rows.append(.object(["ts": .string(ts), "summary": .string(NativeAppSecretRedactor.redactText(summary))]))
            }
            return .object(["state": .string(damaged ? "unavailable" : "ready"), "rows": .array(rows)])
        } catch CocoaError.fileReadNoSuchFile { return .object(["state": .string("unconfigured")]) }
        catch { return unavailable(error) }
    }

    /// Storage validity stays native. Unused fields, including card payloads,
    /// never enter the part; readable rows may accompany unavailable evidence.
    private func checked(_ rows: [JSONValue], fields: Set<String>,
        valid: ([String: JSONValue]) -> Bool) -> JSONValue {
        var available = true
        let observations = rows.compactMap { row -> JSONValue? in
            guard case .object(let values) = row, valid(values) else { available = false; return nil }
            return NativeAppSecretRedactor.redactValue(.object(values.filter { fields.contains($0.key) }))
        }
        return .object(["state": .string(available ? "ready" : "unavailable"), "rows": .array(observations)])
    }
    private func unavailable(_ error: Error) -> JSONValue {
        .object(["state": .string("unavailable"), "error": .string(NativeAppSecretRedactor.redactText(error.localizedDescription))])
    }
}
