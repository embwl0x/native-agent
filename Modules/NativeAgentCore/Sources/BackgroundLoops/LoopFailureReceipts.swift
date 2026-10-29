import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `LoopFailureReceipts.swift` | SwiftNativeLoopScheduler failure classification, coalesced durable receipts and result accounting |

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

    func coalescing(_ next: FailureReceiptIncident) -> FailureReceiptIncident {
        FailureReceiptIncident(
            loopId: loopId,
            error: error,
            firstAt: firstAt,
            lastAt: next.lastAt,
            occurrences: occurrences + next.occurrences
        )
    }

}


extension SwiftNativeLoopScheduler {

    /// Last written incident; coalescing rechecks these exact bytes against the locked feed tail.
    internal struct LastFailureReceipt: Sendable {
        let incident: FailureReceiptIncident
        let id: String
        let bytes: Data
    }

    /// Amortize the line cap so small appends do not read and rewrite the feed.
    private static let failureReceiptTrimTriggerBytes = 1024 * 1024

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

    /// Every error description names a cause, including errors with empty localized text.
    package static func describeLoopError(_ error: any Error) -> String {
        let described = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !described.isEmpty { return described }
        let ns = error as NSError
        return "\(type(of: error)) (\(ns.domain) code \(ns.code))"
    }

    /// Coalescing uses the in-memory streak and last written row. Repeats
    /// rewrite only the trailing line; new incidents use the shared capped
    /// append, retaining one coalesced row per incident.
    internal func appendFailureReceipt(loopId: String, error: String) async {
        guard let failureReceiptsPath else { return }
        guard !Self.isOfflineError(error) else { return }
        let trimmed = error.trimmingCharacters(in: .whitespacesAndNewlines)
        let boundedError = trimmed.isEmpty
            ? "unspecified failure (empty error description)"
            : String(trimmed.prefix(2_000))
        let now = NativeTimestampFormat.plainZulu(clock())
        let incident = FailureReceiptIncident(
            loopId: loopId,
            error: boundedError,
            firstAt: now,
            lastAt: now
        )
        // Coalesce only a matching last receipt while this loop is mid-streak.
        let coalesceTarget: LastFailureReceipt? = {
            guard (consecutiveFailures[loopId] ?? 0) > 0,
                  let last = lastFailureReceipt,
                  last.incident.loopId == loopId,
                  last.incident.error == boundedError else { return nil }
            return last
        }()
        let path = failureReceiptsPath
        do {
            let written: LastFailureReceipt? = try await SwiftNativePersistenceCore.withFileLock(path) {
                if let target = coalesceTarget {
                    let merged = target.incident.coalescing(incident)
                    let row = merged.toJSON(id: target.id)
                    if let bytes = try? SwiftNativePersistenceCore.serializeJSONL([row]),
                       Self.replaceTrailingLine(target.bytes, with: bytes, at: path) {
                        return LastFailureReceipt(incident: merged, id: target.id, bytes: bytes)
                    }
                    // The tail is not ours any more (another process appended,
                    // or the feed was trimmed): fall through and append.
                }
                let id = UUID().uuidString.lowercased()
                let row = incident.toJSON(id: id)
                try await appendJSONLCapped(
                    row,
                    to: path,
                    maxLines: JSONLLineCaps.backgroundLoopFailures,
                    logLabel: "BackgroundLoops.failures",
                    trimWhenBytesExceed: Self.failureReceiptTrimTriggerBytes,
                    durable: true
                )
                guard let bytes = try? SwiftNativePersistenceCore.serializeJSONL([row]) else { return nil }
                return LastFailureReceipt(incident: incident, id: id, bytes: bytes)
            }
            lastFailureReceipt = written
        } catch {
            // The row may or may not have landed — forget the memo rather than
            // coalescing the next failure into a line we cannot vouch for.
            lastFailureReceipt = nil
            FileHandle.standardError.write(Data(
                "BackgroundLoops: failed to persist \(loopId) failure receipt: \(error)\n".utf8
            ))
        }
    }

    /// Rewrites ONLY the feed's trailing line, in place, and returns whether it
    /// did. False means the tail is not the bytes we remember writing — another
    /// process appended, or a trim moved the file — and the caller must append a
    /// fresh row instead of clobbering someone else's receipt. The replacement
    /// is written BEFORE the truncate so no interruption can leave the row
    /// missing entirely. The caller holds the feed lock.
    private static func replaceTrailingLine(
        _ expected: Data, with replacement: Data, at path: URL
    ) -> Bool {
        guard !expected.isEmpty, !replacement.isEmpty else { return false }
        guard let handle = try? FileHandle(forUpdating: path) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= UInt64(expected.count) else { return false }
        let offset = size - UInt64(expected.count)
        guard (try? handle.seek(toOffset: offset)) != nil,
              let tail = try? handle.readToEnd(),
              tail == expected else { return false }
        do {
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: replacement)
            try handle.truncate(atOffset: offset + UInt64(replacement.count))
            // The append this replaces was fsync'd; the rewrite must not be the
            // weak link.
            try handle.synchronize()
        } catch {
            return false
        }
        return true
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
        if let reg = loops[loopId] {
            st.nextTickAt = now.addingTimeInterval(reg.loop.interval)
        }
        states[loopId] = st
        if advanceDurableRun {
            await recordDurableRun(loopId: loopId, at: now)
        }
        await appendFailureReceipt(loopId: loopId, error: error)
        await recordFailureOutcome(loopId: loopId, error: error)
    }

    /// completedWork false preserves completion; cadence uses admitted start while work keeps its completion time.
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
        if let reg = loops[loopId] {
            st.nextTickAt = (startedAt ?? now).addingTimeInterval(reg.loop.interval)
        }
        states[loopId] = st
        await recordDurableRun(loopId: loopId, at: startedAt ?? now)
        consecutiveFailures[loopId] = 0
        if failureRecoveryProbePending.contains(loopId),
           let recovery = failureRecoveryPush,
           await recovery(loopId, now) {
            failureRecoveryProbePending.remove(loopId)
        }
    }
}
