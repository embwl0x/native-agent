import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `TurnTracePersistLane.swift` | One diagnostic writer for daily turn traces and standalone receipts; owns the filename/day calendar, guarded appends and durable terminal notifications |

/// One diagnostic writer: correlated events use bounded daily files;
/// standalone receipts use the shared feed and its retention policy.
/// `append` reports failures; checked and terminal writes propagate them.
public struct TurnTracePersistLane: Sendable {
    static let maxLines = 20_000
    static let maxBytes = JSONLLineCaps.turnTraceMaximumBytes
    static let trimToBytes = JSONLLineCaps.turnTraceTrimTargetBytes

    /// Reads and writes resolve the same root: environment, instance, default.
    public func resolvedDataRoot() -> URL {
        if let raw = ProcessInfo.processInfo.environment["NATIVE_AGENT_TURN_TRACE_ROOT"], !raw.isEmpty {
            return literalFileURL(raw)
        }
        return dataRootOverride ?? defaultDataRoot()
    }

    let dataRootOverride: URL?
    private let standalonePath: URL?

    public init(dataRootOverride: URL? = nil, standalonePath: URL? = nil) {
        self.dataRootOverride = dataRootOverride
        self.standalonePath = standalonePath
    }

    /// Daily ledger at `<dataRoot>/turn_traces/<yyyy-MM-dd>.jsonl`.
    public func path(for date: Date) -> URL {
        Self.fileURL(for: date, root: resolvedDataRoot())
    }

    static func fileURL(for date: Date, root: URL) -> URL {
        return root
            .appendingPathComponent("turn_traces", isDirectory: true)
            .appendingPathComponent("\(Self.dayString(from: date)).jsonl")
    }

    /// Doctor button path for a damaged day file. The persisted trace owner
    /// preserves every original byte before keeping only decodable event rows.
    /// A wholly unreadable file is left for human recovery.
    public func salvageValidRows(for date: Date) async throws -> Int? {
        let target = path(for: date)
        return try await SwiftNativePersistenceCore.withFileLock(target) {
            let maximumBytes = 16 * 1024 * 1024
            guard let size = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= maximumBytes else { return nil }
            let source = try FileHandle(forReadingFrom: target)
            defer { try? source.close() }
            var data = Data()
            while let chunk = try source.read(upToCount: maximumBytes + 1 - data.count), !chunk.isEmpty {
                data.append(chunk)
                guard data.count <= maximumBytes else { return nil }
            }
            var retained = Data()
            var removed = 0
            for line in data.split(separator: 10) {
                if let row = try? JSONValue.parse(Data(line)),
                   TurnTraceEvent(persistedJSONRow: row, physicalByteCount: line.count + 1) != nil {
                    retained.append(contentsOf: line)
                    retained.append(10)
                } else { removed += 1 }
            }
            guard removed > 0, !retained.isEmpty else { return nil }
            let backup = target.deletingLastPathComponent()
                .appendingPathComponent("\(target.lastPathComponent).doctor-preserved-\(UUID().uuidString).bak")
            try FileManager.default.copyItem(at: target, to: backup)
            try SwiftNativePersistenceCore.writeDataAtomicDurable(retained, to: target)
            return removed
        }
    }

    /// Append a capped row under its file lock; log persistence failures.
    public func append(_ event: TurnTraceEvent) async {
        do { try await appendChecked(event) }
        catch { ModuleLog(category: "TurnTracePersistLane")("append failed (\(event.kind), turn \(event.turnId)): \(error)", level: .error) }
    }

    public func appendChecked(_ event: TurnTraceEvent, transitionId: String? = nil) async throws {
        if event.turnId == "unknown", !event.diagnostic.isEmpty {
            let target = standalonePath ?? resolvedDataRoot().appendingPathComponent("traces/events.jsonl")
            try await SwiftNativePersistenceCore.withFileLock(target) {
                if let transitionId {
                    let read = try await SwiftNativePersistenceCore.tailJSONLReadReceipt(target, limit: JSONLLineCaps.traceEvents, maxBytes: nil)
                    guard read.malformedJSONRowCount == 0, !read.truncatedToByteWindow,
                          read.rows.allSatisfy({ $0.objectValue != nil }),
                          read.physicalRowsScanned > 0 || read.bytesRead == 0 else {
                        throw PersistenceCoreError.ioFailure("Trace projection cannot deduplicate \(target.path): its receipt feed is malformed or incomplete; existing bytes retained.")
                    }
                    if read.rows.contains(where: { $0.objectValue?["transitionId"] == .string(transitionId) }) { return }
                }
                guard case .object(var row) = event.jsonRow else {
                    throw PersistenceCoreError.ioFailure("Trace receipt envelope is not an object")
                }
                if let transitionId { row["transitionId"] = .string(transitionId) }
                try await appendPathOwnedJSONL(.object(row), to: target, logLabel: "TurnTracePersistLane")
            }
            return
        }
        let target = path(for: event.ts)
        // Ensure the directory exists — appendJSONLCapped writes the file but
        // not its parent dir.
        let dir = target.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await appendJSONLCapped(
            event.jsonRow,
            to: target,
            maxLines: Self.maxLines,
            logLabel: "TurnTracePersistLane",
            // Byte triggers avoid a whole-file line count on every append.
            trimWhenBytesExceed: JSONLLineCaps.turnTraceTrimTriggerBytes,
            maxBytes: Self.maxBytes,
            trimToBytes: Self.trimToBytes,
            capCheckStride: 4096,
            // Terminal notification follows durable persistence.
            durable: TurnTraceEvent.isTerminalKind(event.kind)
        )
        postTerminalIfNeeded(event, trace: target)
    }

    /// Only a durably persisted live terminal wakes turn-end observers;
    /// reconciliation does not announce that a turn just finished.
    private func postTerminalIfNeeded(_ event: TurnTraceEvent, trace: URL) {
        guard TurnTraceEvent.isTerminalKind(event.kind) else { return }
        if case .object(let payload) = event.payload,
           case .string("terminal_reconciliation")? = payload["observedBy"] {
            return
        }
        var info: [String: Any] = ["turnId": event.turnId, "kind": event.kind, "trace": trace.path]
        info["sessionId"] = event.sessionId
        info["surface"] = event.surface
        if case .object(let fields) = event.payload {
            if case .string(let part)? = fields["part"] { info["part"] = part }
            if case .string(let steer)? = fields["steered_by"] { info["agent"] = steer }
        }
        NotificationCenter.default.post(name: .turnTraceTerminalPersisted, object: nil, userInfo: info)
    }

    /// Under sorted day/sibling locks, decode once, evaluate the predicate, then durably append.
    /// Missing is empty/clean; damage retains coverage. False skips append; read, predicate and write failures throw.
    @discardableResult
    public func appendGuarded(
        _ event: TurnTraceEvent,
        alsoLocking siblings: [URL] = [],
        shouldAppend: @escaping @Sendable (TurnTraceReplayReader.ReadResult) throws -> Bool
    ) async throws -> Bool {
        let target = path(for: event.ts)
        let dir = target.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lockOrder = Set(siblings.map(\.path))
            .union([target.path])
            .sorted()
            .map { URL(fileURLWithPath: $0) }
        return try await withFileLocks(lockOrder) {
            let data = FileManager.default.fileExists(atPath: target.path) ? try Data(contentsOf: target) : Data()
            let existing = TurnTraceReplayReader.parse(data)
            guard try shouldAppend(existing) else { return false }
            try await appendJSONLCapped(
                event.jsonRow,
                to: target,
                maxLines: Self.maxLines,
                logLabel: "TurnTracePersistLane",
                trimWhenBytesExceed: JSONLLineCaps.turnTraceTrimTriggerBytes,
                maxBytes: Self.maxBytes,
                trimToBytes: Self.trimToBytes,
                capCheckStride: 4096,
                // appendBytes terminates a nonempty tail before writing the new row.
                validatedExistingCounts: (existing.report.physicalLineCount, data.count + (data.isEmpty || data.last == 0x0A ? 0 : 1)),
                durable: true
            )
            postTerminalIfNeeded(event, trace: target)
            return true
        }
    }

    /// Take every lock in `paths` (already in the caller's fixed order) and run
    /// `body` inside all of them.
    private func withFileLocks(
        _ paths: [URL],
        _ body: @escaping @Sendable () async throws -> Bool
    ) async throws -> Bool {
        guard let first = paths.first else { return try await body() }
        return try await SwiftNativePersistenceCore.withFileLock(first) {
            try await withFileLocks(Array(paths.dropFirst()), body)
        }
    }

    /// Every lane and the sweep share one day formatter, from many tasks at
    /// once, so it is only used under `dayLock`.
    private static let dayLock = NSLock()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    package static func dayString(from date: Date) -> String {
        dayLock.withLock { dayFormatter.string(from: date) }
    }

    package static func day(from string: String) -> Date? {
        dayLock.withLock { dayFormatter.date(from: string) }
    }

    /// Day arithmetic shares the filename timezone, including across DST changes.
    package static var dayCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = dayLock.withLock { dayFormatter.timeZone }
        return calendar
    }
}

extension Notification.Name {
    /// Posted after a turn's TERMINAL row (`turn.terminal` / `turn.cancelled` /
    /// `turn.failed`) has been durably appended to the trace. userInfo carries
    /// `turnId`, `kind`, `trace` (the day file), and `sessionId`, `surface`,
    /// `part` and `agent` (whose words steered it) when known. Unlike `.chatTurnCompleted` this cannot fire
    /// without a turn.
    public static let turnTraceTerminalPersisted =
        Notification.Name("turnTraceTerminalPersisted")
}
