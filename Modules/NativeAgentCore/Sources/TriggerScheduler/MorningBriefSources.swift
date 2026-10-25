import Foundation
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
    let persistence: any PersistenceCoreProtocol
    let now: Date
    let worklogPath: URL

    public init(root: URL, persistence: any PersistenceCoreProtocol, now: Date, worklogPath: URL?) {
        self.root = root; self.persistence = persistence; self.now = now
        self.worklogPath = worklogPath ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/state/claude-worklog.jsonl")
    }

    public func packet() async -> JSONValue {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "EEEE, MMMM d"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
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
            guard let native = persistence as? SwiftNativePersistenceCore else { throw CocoaError(.featureUnsupported) }
            let state = try await SwiftNativeDeskStore(dataRoot: root, persistence: native).liveState()
            return .object(["state": .string("ready"),
                "statuses": .array(state.items.map { .string($0.status.rawValue) }),
                // Desk owns the projection's readiness and dependency truth.
                "body": .string(NativeAppSecretRedactor.redactText(DeskProjection.render(state, now: now)))])
        } catch { return unavailable(error) }
    }

    private func workshop() async -> JSONValue {
        do {
            let rows = try await SwiftNativeWorkshopRunner(root: root, persistence: persistence)
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
        do {
            let handle = try FileHandle(forReadingFrom: worklogPath)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            let start = end > 128 * 1024 ? end - 128 * 1024 : 0
            try handle.seek(toOffset: start)
            let data = try handle.readToEnd() ?? Data()
            guard var text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            if start > 0 {
                guard let newline = text.firstIndex(of: "\n") else { throw CocoaError(.fileReadCorruptFile) }
                text = String(text[text.index(after: newline)...])
            }
            var rows: [JSONValue] = []
            var damaged = false
            for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard case .object(let row)? = try? JSONValue.parse(Data(line.utf8)),
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
