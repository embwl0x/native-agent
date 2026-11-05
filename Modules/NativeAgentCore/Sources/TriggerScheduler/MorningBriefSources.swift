import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Privacy
import Desk
import NotificationInbox
import Experiences
// Blueprint: | `MorningBriefSources.swift` | Checked brief sources; unread notes read ForPerson's in-memory inbox |

/// The scheduler supplies checked observations, never a brief or model prompt. Each source says unavailable, ready (possibly empty), or unconfigured.
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
            "desk": await desk(), "worklog": worklog(),
            "inbox": await inbox(),
            "sessions": jsonArray(root.appendingPathComponent("chat/sessions.json")),
        ])
    }

    private func desk() async -> JSONValue {
        do {
            let state = try await SwiftNativeDeskStore(dataRoot: root).liveState()
            return .object(["state": .string("ready"),
                "statuses": .array(state.items.map { .string($0.status.rawValue) }),
                // Read readiness and dependencies from Desk's owner.
                "body": .string(NativeAppSecretRedactor.redactText(DeskPage.render(state, now: now)))])
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

    private func inbox() async -> JSONValue {
        do {
            let items = try await ForPerson.at(root).inbox()
            return .object(["state": .string("ready"),
                "unread": .int(Int64(items.filter { $0.status == "unread" }.count))])
        } catch { return unavailable(error) }
    }

    /// Only parsed, redacted summary fields leave this native reader; neither the private worklog's raw bytes nor unrelated fields enter the agent's part.
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

    /// Storage validity stays native. Unused fields, including card payloads, never enter the part; readable rows may accompany unavailable evidence.
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
