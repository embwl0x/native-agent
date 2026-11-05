import ChatSessionWork
import Foundation
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import Darwin
// Blueprint: | `DelegationStatusProjection.swift` | Retained reply deliveries; an unreadable record is its own gap and readable siblings proceed |
// Retain originating DataRootLife; lifecycle and transcript-origin gaps affect only their unreadable item.

public struct DelegationStatusProjector: Sendable {
    private let configRoot: URL
    private let dataRoot: URL

    public static let defaultLimit = 20
    public static let maxLimit = 100

    private var directories: [URL] { CodexCompletionReadout.delegationDirectories(configRoot: configRoot, dataRoot: dataRoot) }

    /// Every source read by the projection, including existing records updated in place.
    package var watchedPaths: [URL] {
        directories.flatMap { directory in
            [directory] + ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
        }
    }

    /// Resolve the lifecycle stores under the dispatcher's same config root.
    public init(configRoot: URL? = nil, dataRoot: URL = PersistenceCore.defaultDataRoot()) {
        self.dataRoot = dataRoot
        self.configRoot = configRoot ?? InstallPaths.current.bridgeConfigRoot
    }

    /// Read stores independently so an absent or unreadable store cannot hide readable siblings.
    public func recentJobs(now: Date, limit: Int = DelegationStatusProjector.defaultLimit) -> [DelegationReadout] {
        let bounded = max(1, min(limit, Self.maxLimit))
        return readSnapshot(now: now, limit: bounded).jobs
    }

    /// One disk read reports jobs and availability; only absent or fully readable stores count as readable.
    public func recentJobsWithAvailability(
        now: Date,
        limit: Int = DelegationStatusProjector.defaultLimit
    ) -> (jobs: [DelegationReadout], allStoresReadable: Bool) {
        let bounded = max(1, min(limit, Self.maxLimit))
        let snapshot = readSnapshot(now: now, limit: bounded)
        return (
            Array(snapshot.jobs.prefix(bounded)),
            snapshot.sources.allSatisfy { $0.status == "available" || $0.status == "absent" }
        )
    }

    /// Reconciliation needs complete history; the model-visible page limit must not skip older unsettled records.
    public func allJobs(now: Date) -> [DelegationReadout] {
        readSnapshot(now: now).jobs
    }

    /// One disk read reports all jobs and availability so cursors never advance past unreadable records.
    public func allJobsWithAvailability(
        now: Date
    ) -> (jobs: [DelegationReadout], allStoresReadable: Bool) {
        let snapshot = readSnapshot(now: now)
        return (
            snapshot.jobs,
            snapshot.sources.allSatisfy { $0.status == "available" || $0.status == "absent" }
        )
    }

    /// Read jobs and availability together so each verdict describes the same observation.
    package func readSnapshot(now: Date, limit: Int? = nil, offset: Int = 0,
                      agent: String? = nil, jobID: String? = nil) -> DelegationStatusReadSnapshot {
        let life: String
        do { life = try DataRootLife.current(in: dataRoot) }
        catch { return .init(jobs: [], sources: [.init(source: "life-id", agent: "self", status: "unavailable")], matchedCount: 0) }
        var rows: [DelegationReadout] = []
        var sources: [DelegationSourceAvailability] = []
        var seen: Set<String> = []
        for directory in directories {
            var lifecycles = Self.readDirectory(directory, source: "completion_lifecycle", agent: "self")
            for (url, fields) in lifecycles.objects.sorted(by: { $0.0.path < $1.0.path }) {
                let state: CodexCompletionReadout
                do {
                    state = try JSONDecoder().decode(CodexCompletionReadout.self,
                        from: JSONValue.object(fields).serializedData(pretty: false)).reading(life: life)
                } catch {
                    lifecycles.availability.status = "partial"
                    lifecycles.availability.malformedRecords += 1
                    let gap = "Lifecycle record \(url.path) could not be decoded: \(error.localizedDescription)"
                    lifecycles.availability.detail = [lifecycles.availability.detail, gap].compactMap { $0 }.joined(separator: "\n")
                    continue
                }
                guard let status = state.status else { continue }
                let id = state.deliveryId
                let principal: String
                do { principal = try state.knownPrincipal(dataRoot: dataRoot) ?? "unattributed" }
                catch {
                    lifecycles.availability.status = "partial"
                    lifecycles.availability.unreadableFiles += 1
                    let gap = "Transcript origin for lifecycle \(id) at \(url.path) could not be read: \(error.localizedDescription)"
                    lifecycles.availability.detail = [lifecycles.availability.detail, gap].compactMap { $0 }.joined(separator: "\n")
                    continue
                }
                var row = DelegationReadout(id: id, source: state.source ?? principal, agent: principal,
                    topicSlug: nil, deskHandle: nil, state: status == "delivered" ? "settled" : status, status: nil, runStatus: nil,
                    createdAt: nil, claimedAt: nil, startedAt: nil, lastLiveness: nil,
                    completedAt: nil, elapsedSeconds: nil, stalled: false,
                    stallBasis: status == "owed" ? .none : .terminal, deliveryLost: nil, deliveryOutcome: status, completionTextHead: nil)
                row.completionDeliveryID = id
                row.deliveryUpdatedAt = state.updatedAt
                row.recordKind = "completion_lifecycle"
                row.recoveryNote = status == "stopped" ? DataRootLife.stoppedReason : url.path
                row.recencyKey = Self.date(state.updatedAt)
                guard (agent == nil || row.agent == agent) && (jobID == nil || row.id == jobID),
                      seen.insert(row.source + ":" + id).inserted else { continue }
                rows.append(row)
            }
            sources.append(lifecycles.availability)
        }
        let matchedCount = rows.count
        rows.sort(by: Self.newestFirst)
        let page = Array(rows.dropFirst(min(offset, rows.count)).prefix(limit ?? rows.count))
        return DelegationStatusReadSnapshot(jobs: page, sources: sources, matchedCount: matchedCount)
    }

    static func newestFirst(_ lhs: DelegationReadout, _ rhs: DelegationReadout) -> Bool {
        switch (lhs.recencyKey, rhs.recencyKey) {
        case let (l?, r?) where l != r: return l > r
        case (nil, .some): return false
        case (.some, nil): return true
        default: return lhs.id > rhs.id
        }
    }

    private static let fileCache = DelegationFileCache()

    /// Schedule the exact stall crossing so quiet writers become observable without polling.
    public func nextStallDeadline(after now: Date) -> Date? {
        allJobs(now: now)
            .compactMap(\.stallDeadline)
            .filter { $0 > now }
            .min()
    }

    // MARK: - Directory scanning

    /// Only an initial missing-path error means absent. A later read failure or a wrong file kind is unavailable, never an empty healthy source.
    private static func sourceStatus(_ url: URL, expected: FileAttributeType) -> String {
        do {
            // Existing reads follow configured symlinks; availability is not a new path/authority restriction on those readable sources.
            let attributes = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
            return attributes[.type] as? FileAttributeType == expected ? "available" : "unavailable"
        } catch {
            let error = error as NSError
            return error.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code)
                ? "absent" : "unavailable"
        }
    }

    private static func readDirectory(_ directory: URL, source: String, agent: String)
        -> (objects: [(URL, [String: JSONValue])], availability: DelegationSourceAvailability) {
        var availability = DelegationSourceAvailability(source: source, agent: agent)
        availability.status = sourceStatus(directory, expected: .typeDirectory)
        guard availability.status == "available" else { return ([], availability) }
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: directory.path) }
        catch { availability.status = "unavailable"; return ([], availability) }
        var objects: [(URL, [String: JSONValue])] = []
        let previous = fileCache.jobSnapshot(directory.path)
        var parsedFiles: [String: (stamp: SnapshotTailOpLog.FileStamp, object: [String: JSONValue])] = [:]
        for name in names.filter({ $0.hasSuffix(".json") && !$0.hasPrefix(".") }).sorted() {
            let url = directory.appendingPathComponent(name)
            let stamp: SnapshotTailOpLog.FileStamp?
            do { stamp = try DelegationFileCache.stamp(url) }
            catch {
                availability.unreadableFiles += 1
                continue
            }
            // Reuse the parse only while its file stamp is unchanged.
            if let stamp, let cached = previous[name], cached.stamp == stamp {
                parsedFiles[name] = cached
                availability.readableRecords += 1
                objects.append((url, cached.object))
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                availability.unreadableFiles += 1
                continue
            }
            guard let parsed = try? JSONValue.parse(data), case .object(let object) = parsed else {
                availability.malformedRecords += 1
                continue
            }
            if let stamp { parsedFiles[name] = (stamp, object) }
            availability.readableRecords += 1
            objects.append((url, object))
        }
        fileCache.putJobs(directory.path, parsedFiles)
        if availability.unreadableFiles > 0 || availability.malformedRecords > 0 { availability.status = "partial" }
        return (objects, availability)
    }

    /// Both fractional and whole-second UTC timestamps are valid record times.
    static func date(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        return NativeTimestampFormat.parseISO8601FractionalFirst(iso)
    }
}
