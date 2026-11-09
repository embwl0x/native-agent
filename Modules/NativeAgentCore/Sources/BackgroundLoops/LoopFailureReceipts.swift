import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Experiences
// Blueprint: | `LoopFailureReceipts.swift` | Loop failure occurrence details, read-time incident folding, classification and result accounting |

internal struct FailureReceiptIncident: Sendable {
    let loopId: String
    let error: String
    let firstAt: String
    let lastAt: String
    let occurrences: Int

    init(loopId: String, error: String, firstAt: String, lastAt: String, occurrences: Int = 1) {
        self.loopId = loopId
        self.error = error
        self.firstAt = firstAt
        self.lastAt = lastAt
        self.occurrences = max(1, occurrences)
    }

    func toJSON(id: String) -> JSONValue {
        .object([
            "id": .string(id),
            "kind": .string("background_loop.failure"),
            "loopId": .string(loopId),
            "status": .string("failed"),
            "error": .string(error),
            "createdAt": .string(firstAt),
            "firstAt": .string(firstAt),
            "lastAt": .string(lastAt),
            "occurrences": .int(Int64(occurrences)),
        ])
    }

}

/// Each occurrence keeps its own time. Incident identity joins only the same uninterrupted trailing failure streak.
public enum LoopFailureReceipts {
    public static let didWrite = Notification.Name("NativeAgent.loopFailureDidWrite")
    public struct Occurrence: Sendable {
        public let id: String
        public let loopId: String
        public let error: String
        public let at: Date
    }

    public struct Incident: Sendable {
        public let id: String
        public let loopId: String
        public let error: String
        public let dates: [Date]
        public var firstAt: Date { dates[0] }
        public var lastAt: Date { dates[dates.count - 1] }
        public var row: JSONValue {
            FailureReceiptIncident(loopId: loopId, error: error,
                firstAt: NativeTimestampFormat.plainZulu(firstAt), lastAt: NativeTimestampFormat.plainZulu(lastAt),
                occurrences: dates.count).toJSON(id: id)
        }
    }

    /// No source means no recorded occurrences. Unreadable evidence throws; it is never an empty, clean history.
    public static func occurrences(dataRoot: URL) async throws -> [Occurrence] {
        try await ExperienceStore.at(dataRoot).details(.init(kinds: ["loop.failure"])).map { detail in
            guard case .object(let row) = try JSONValue.parse(detail.row),
                  let id = row["id"]?.stringValue, !id.isEmpty,
                  let loopId = row["loopId"]?.stringValue, detail.subject == "loop:" + loopId,
                  let error = row["error"]?.stringValue,
                  row["kind"] == .string("background_loop.failure"), row["status"] == .string("failed"),
                  row["occurrences"]?.exactIntegerValue == 1,
                  let stamp = row["lastAt"]?.stringValue, let at = NativeTimestampFormat.parseISO8601(stamp),
                  row["firstAt"] == .string(stamp), row["createdAt"] == .string(stamp) else {
                throw PersistenceCoreError.ioFailure("Loop failure detail \(detail.seq) is unreadable; repair the record before judging loop health")
            }
            return Occurrence(id: id, loopId: loopId, error: error, at: at)
        }
    }

    public static func incidents(dataRoot: URL, limit: Int? = nil) async throws -> [Incident] {
        let occurrences = try await occurrences(dataRoot: dataRoot)
        var order: [String] = [], byId: [String: [Occurrence]] = [:]
        for occurrence in occurrences {
            if byId[occurrence.id] == nil { order.append(occurrence.id) }
            byId[occurrence.id, default: []].append(occurrence)
        }
        return try order.suffix(limit.map { max(0, $0) } ?? order.count).map { id in
            let entries = byId[id]!
            let first = entries[0]
            guard entries.allSatisfy({ $0.loopId == first.loopId && $0.error == first.error }) else {
                throw PersistenceCoreError.ioFailure("Loop failure incident \(id) has conflicting identities in the record")
            }
            return Incident(id: id, loopId: first.loopId, error: first.error, dates: entries.map(\.at).sorted())
        }
    }
}


extension SwiftNativeLoopScheduler {

    /// Only incident identity is retained; occurrence evidence is owned by the record.
    internal struct LastFailureReceipt: Sendable {
        let id: String
        let loopId: String
        let error: String
    }

    /// Offline errors mint no receipt, streak or push; plain timeouts remain failures.
    static func isOfflineError(_ error: String) -> Bool {
        let e = error.lowercased()
        if e.contains("internet connection appears to be offline") { return true }
        if e.contains("network connection was lost") { return true }
        if e.contains("socket is not connected") { return true }
        if e.contains("nsurlerrordomain") {
            for code in ["-1009", "-1005", "-1003"]
            where e.contains("code=\(code)") || e.contains("code \(code)") {
                return true
            }
        }
        if e.contains("nsposixerrordomain"),
           e.contains("code=57") || e.contains("code=60")
            || e.contains("code 57") || e.contains("code 60") {
            return true
        }
        return false
    }

    /// Network weather belongs to the loop's retry cadence, not a finding.
    static func isRetriedNetworkError(_ error: String) -> Bool {
        if isOfflineError(error) { return true }
        let e = error.lowercased()
        if e.contains("nsurlerrordomain"), ["-1001", "-1003", "-1004", "-1005", "-1009"].contains(where: {
            e.contains("code=\($0)") || e.contains("code \($0)") || e.contains("error \($0)")
        }) { return true }
        if ["the request timed out", "could not connect to the server",
            "a server with the specified hostname could not be found"].contains(where: e.contains) { return true }
        return e.range(of: #"(server status|http) 5\d\d"#, options: .regularExpression) != nil
    }

    /// Even an empty localized description must retain a named failure cause.
    package static func describeLoopError(_ error: any Error) -> String {
        let described = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !described.isEmpty { return described }
        let ns = error as NSError
        return "\(type(of: error)) (\(ns.domain) code \(ns.code))"
    }

    /// Write each occurrence once; readers fold an incident without rewriting its earlier evidence.
    internal func appendFailureReceipt(loopId: String, error: String) async {
        guard !Self.isOfflineError(error) else { return }
        let trimmed = error.trimmingCharacters(in: .whitespacesAndNewlines)
        let boundedError = trimmed.isEmpty
            ? "unspecified failure (empty error description)"
            : String(trimmed.prefix(2_000))
        let at = clock()
        let now = NativeTimestampFormat.plainZulu(at)
        let incident = FailureReceiptIncident(
            loopId: loopId,
            error: boundedError,
            firstAt: now,
            lastAt: now
        )
        // Coalesce only a matching trailing receipt while this loop is in the same failure streak.
        let coalesceTarget: LastFailureReceipt? = {
            guard (consecutiveFailures[loopId] ?? 0) > 0,
                  let last = lastFailureReceipt,
                  last.loopId == loopId,
                  last.error == boundedError else { return nil }
            return last
        }()
        let id = coalesceTarget?.id ?? UUID().uuidString.lowercased()
        do {
            try await ExperienceStore.at(dataRoot).note([
                .init(source: "loops", at: at, subject: "loop:" + loopId, kind: "loop.failure", row: try incident.toJSON(id: id).serializedData(pretty: false))
            ])
            lastFailureReceipt = LastFailureReceipt(id: id, loopId: loopId, error: boundedError)
            NotificationCenter.default.post(name: LoopFailureReceipts.didWrite, object: nil)
        } catch {
            // An uncertain write invalidates the memo; never coalesce against bytes whose landing is unknown.
            lastFailureReceipt = nil
            FileHandle.standardError.write(Data(
                "BackgroundLoops: failed to persist \(loopId) failure receipt: \(error)\n".utf8
            ))
        }
    }

    private func recordFailureOutcome(
        loopId: String, error: String
    ) async {
        if !Self.isOfflineError(error) {
            consecutiveFailures[loopId, default: 0] += 1
        }
        failureRecoveryProbePending.insert(loopId)
        if !Self.isRetriedNetworkError(error) { await failureOutcome?(loopId, error) }
    }

    /// A timeout records failure without advancing the durable due clock.
    func recordFailure(
        loopId: String, error: String, advanceDurableRun: Bool = true
    ) async {
        var st = states[loopId] ?? LoopState(loopId: loopId)
        let now = clock()
        st.lastError = error
        st.lastTickAt = now
        st.tickCount += 1
        st.lastResult = "failed"
        st.nextTickAt = (loops[loopId]?.loop.wake.period).map { now.addingTimeInterval($0) }
        states[loopId] = st
        if advanceDurableRun {
            await recordDurableRun(loopId: loopId, at: now)
        }
        await appendFailureReceipt(loopId: loopId, error: error)
        await recordFailureOutcome(loopId: loopId, error: error)
    }

    /// Skips update live status only; completed work owns durable cadence, completion and recovery evidence.
    func recordResult(
        loopId: String, result: String, completedWork: Bool = true, startedAt: Date? = nil
    ) async {
        var st = states[loopId] ?? LoopState(loopId: loopId)
        let now = clock()
        st.lastResult = result
        st.lastError = nil
        if completedWork {
            st.lastCompletedAt = now
            persistedLastCompleted[loopId] = now
        }
        st.lastTickAt = now
        st.tickCount += 1
        st.nextTickAt = (loops[loopId]?.loop.wake.period).map { (startedAt ?? now).addingTimeInterval($0) }
        states[loopId] = st
        guard completedWork else { return }
        await recordDurableRun(loopId: loopId, at: startedAt ?? now)
        consecutiveFailures[loopId] = 0
        if failureRecoveryProbePending.contains(loopId),
           let recovery = failureRecoveryPush,
           await recovery(loopId, now) {
            failureRecoveryProbePending.remove(loopId)
        }
    }
}
