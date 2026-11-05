import Foundation
import AppKit
import CoreServices
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
// Blueprint: | `MacAppIndex.swift` | Resident Spotlight snapshots retain row/directory gaps; bounded async gather never stops the query |

/// The Mac's app index, kept live by Spotlight. No app is opened or activated.
public final class MacAppIndex: @unchecked Sendable {
    public static let shared = MacAppIndex()

    public struct App: @unchecked Sendable {
        public let url: URL
        public let info: NSDictionary?
        public let name: String
        public let bundleID: String?
        public let version: String
        /// "mac" or "ios", from the bundle's own platforms (no declaration is a Mac app).
        public let platform: String
        /// "installed", "copy", or "unavailable" when installation evidence is missing.
        public let kind: String
        public let classificationFailures: [String]
        /// A known copy or iOS build is already outside the Mac installed projection; its missing sibling facts cannot block another app.
        public var installationUncertain: Bool {
            kind != "copy" && platform != "ios" && kind == "unavailable"
        }
        public var scriptable: Bool? { info.map { $0["OSAScriptingDefinition"] is String } }
        public var json: JSONValue { .object([
            "name": .string(name), "file_name": .string(url.deletingPathExtension().lastPathComponent),
            "bundle_id": bundleID.map(JSONValue.string) ?? .null,
            "path": .string(url.path), "version": .string(version), "scriptable": scriptable.map(JSONValue.bool) ?? .null,
            "platform": .string(platform), "kind": .string(kind),
            "classification_failures": .array(classificationFailures.map(JSONValue.string)),
        ]) }
    }

    /// One materialization: directory evidence belongs to the directory, rather than making every readable app below it unavailable.
    public struct Inventory: Sendable {
        public let apps: [App]
        public let directoryGaps: [String]
    }

    /// Rows that share a shown name: launch by bundle id or file name, never by that name alone.
    public static func collisions(_ apps: [App]) -> Set<String> {
        var seen: Set<String> = [], twice: Set<String> = []
        for app in apps where !seen.insert(app.name.lowercased()).inserted { twice.insert(app.name.lowercased()) }
        return twice
    }

    static let appFolders: [String] = ["/Applications", "/System/Applications",
        FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.appendingPathComponent("Applications").path]

    /// Exclude known build directories from installed-app identity regardless of bundle ID.
    static let buildFolders: Set<String> = ["DerivedData", "dist", "build", "Build", "target", "node_modules", ".build", "out", "Products", "__pycache__",
        "release-builds"]

    /// Use the localized Finder name so installed-app lookup matches what the person sees.
    static func shownName(_ url: URL) -> String {
        let shown = FileManager.default.displayName(atPath: url.path)
        return shown.hasSuffix(".app") ? String(shown.dropLast(4)) : shown
    }

    public static func installed(_ apps: [App]) -> [App] { apps.filter { $0.kind == "installed" && $0.platform == "mac" } }

    private let queue = DispatchQueue(label: "NativeAgent.MacAppIndex", qos: .utility)
    private var query: MDQuery!
    private var failure: Error?
    private var rows: [App] = []
    private var directoryGaps: [String] = []
    /// Keep materialized rows readable without waiting on the indexing queue.
    private let snapshotLock = NSLock()
    private var snapshot: Result<Inventory, Error>?
    private var observers: [NSObjectProtocol] = []
    private var listeners: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var gathering = true
    private var stopped = false
    private var gatherWaiters: [UUID: ContinuationOnce<Result<Void, Error>>] = [:]

    private init() {
        queue.async { [self] in
            query = MDQueryCreate(nil, "kMDItemContentTypeTree == 'com.apple.application-bundle'" as CFString, nil, nil)
            guard let query else { return failedToStart() }
            MDQuerySetSearchScope(query, [kMDQueryScopeComputer] as CFArray, 0)
            MDQuerySetDispatchQueue(query, queue)
            for name in [kMDQueryDidFinishNotification, kMDQueryDidUpdateNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: Notification.Name(name! as String), object: query,
                    queue: nil) { [self] notification in
                    guard !stopped, failure == nil else { return }
                    let changed = materialize()
                    if notification.name.rawValue == kMDQueryDidFinishNotification as String { finishGather() }
                    if changed { for continuation in listeners.values { continuation.yield(()) } }
                })
            }
            if !MDQueryExecute(query, CFOptionFlags(kMDQueryWantsUpdates.rawValue)) { failedToStart() }
        }
    }

    private func failedToStart() {
        let cause = MacControlError.ioFailure("The Mac's app index could not start. Check Spotlight indexing in System Settings → Spotlight, then try again.")
        failure = cause
        snapshotLock.withLock { snapshot = .failure(cause) }
        stopQuery()
        finishGather()
    }

    private func finishGather() {
        guard gathering else { return }
        gathering = false
        if failure == nil { snapshotLock.withLock { snapshot = .success(Inventory(apps: rows, directoryGaps: directoryGaps)) } }
        let pending = Array(gatherWaiters.values)
        gatherWaiters.removeAll()
        for waiter in pending {
            if let failure { waiter.resume(.failure(failure)) }
            else { waiter.resume(.success(())) }
        }
    }

    private func initialGather(bounded: Bool = true, context: MacOperationContext) async throws {
        try Task.checkCancellation()
        if let snapshot = snapshotLock.withLock({ self.snapshot }) {
            _ = try snapshot.get()
            return
        }
        let id = UUID()
        let answer = ContinuationOnce<Result<Void, Error>>()
        queue.async { [self] in
            guard answer.isPending else { return }
            if gathering { gatherWaiters[id] = answer }
            else if let failure { answer.resume(.failure(failure)) }
            else { answer.resume(.success(())) }
        }
        defer { queue.async { self.gatherWaiters[id] = nil } }
        let ceiling = ContinuousClock.now.advanced(by: .seconds(4))
        // A resident observer lives until an edge or shutdown/Stop. Requests instead have a finite cold-gather wait even without a tool deadline.
        let deadline: ContinuousClock.Instant? = bounded ? context.deadline.map { min($0, ceiling) } ?? ceiling : context.deadline
        let pending = MacControlError.ioFailure("""
            app_index_not_ready: The request's wait ended before Spotlight finished gathering. The live query remains active; no installed-app verdict is \
            available yet.
            """)
        try await context.holding(\.deadline, deadline) { context in
            guard !context.expired else { throw pending }
            try await answer.wait(budget: context.waitBudget, cancellingWith: .failure(context.expired ? pending : context.cancellationError),
                onCancel: { [self] in
                queue.async { self.gatherWaiters[id] = nil }
            }).get()
            guard !context.expired else { throw pending }
        }
        try Task.checkCancellation()
    }

    private func stopQuery() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if let query { MDQueryStop(query) }
        query = nil
    }

    /// Terminal domain shutdown. Session/view stop does not own this resident query; the engine termination drain must call this explicitly.
    public func shutdown() async {
        await withCheckedContinuation { done in
            queue.async { [self] in
                stopped = true
                let cause = failure ?? CancellationError()
                failure = cause
                stopQuery()
                finishGather()
                listeners.values.forEach { $0.finish() }
                listeners.removeAll()
                rows.removeAll()
                directoryGaps.removeAll()
                snapshotLock.withLock { snapshot = .failure(cause) }
                nativeLog("MacAppIndex: shutdown complete; query and listeners retired")
                done.resume()
            }
        }
    }

    public func changes(context: MacOperationContext) async throws -> AsyncStream<Void> {
        try await initialGather(bounded: false, context: context)
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [self] _ in queue.async { self.listeners[id] = nil } }
        do {
            return try await withTaskCancellationHandler(operation: { () async throws -> AsyncStream<Void> in
                try Task.checkCancellation()
                let answer: AsyncStream<Void> = try await withCheckedThrowingContinuation { (result: CheckedContinuation<AsyncStream<Void>, Error>) in
                    queue.async { [self] in
                        if let failure { return result.resume(throwing: failure) }
                        guard case .enqueued = continuation.yield(()) else {
                            result.resume(throwing: CancellationError()); return
                        }
                        listeners[id] = continuation
                        result.resume(returning: stream)
                    }
                }
                try Task.checkCancellation()
                return answer
            }, onCancel: { continuation.finish() })
        } catch {
            continuation.finish()
            throw error
        }
    }

    public func apps(context: MacOperationContext) async throws -> [App] {
        try await inventory(context: context).apps
    }

    public func inventory(context: MacOperationContext) async throws -> Inventory {
        try await initialGather(context: context)
        try Task.checkCancellation()
        return try checkedSnapshot()
    }

    /// The kept rows if the first gather has finished, else nil: a lookup on a hot path never waits for Spotlight.
    public func readyApps() -> [App]? {
        snapshotLock.withLock {
            if case .success(let inventory)? = snapshot { return inventory.apps }
            return nil
        }
    }

    /// A synchronous request never waits for a cold query or its materialization queue.
    public func apps() throws -> [App] {
        try checkedSnapshot().apps
    }

    private func checkedSnapshot() throws -> Inventory {
        try snapshotLock.withLock {
            guard let snapshot else {
                throw MacControlError.ioFailure("""
                    app_index_not_ready: Spotlight has not finished gathering apps; no installed-app verdict is available. Try again after gathering \
                    completes.
                    """)
            }
            return try snapshot.get()
        }
    }

    private func materialize() -> Bool {
        MDQueryDisableUpdates(query)
        defer { MDQueryEnableUpdates(query) }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        // Facts last one materialization; home stops source inheritance, not package exclusion.
        var directories: [URL: (excluded: Bool, workingTree: Bool)] = [:]
        var gaps: [String] = []
        func classify(_ parent: URL) -> (excluded: Bool, workingTree: Bool) {
            guard parent.path != "/" else { return (false, false) }
            if let facts = directories[parent] { return facts }
            let above = classify(parent.deletingLastPathComponent())
            var excluded = above.excluded || parent.lastPathComponent == "Library" || !parent.pathExtension.isEmpty
            if !excluded {
                do {
                    let values = try parent.resourceValues(forKeys: [.isPackageKey])
                    if let package = values.isPackage { excluded = package }
                    else { gaps.append("\(parent.path): package classification unavailable") }
                } catch { gaps.append("\(parent.path): \(error.localizedDescription)") }
            }
            var workingTree = !excluded && parent.standardizedFileURL.path != home && (above.workingTree
                || FileManager.default.fileExists(atPath: parent.appendingPathComponent(".git").path)
                || FileManager.default.fileExists(atPath: parent.appendingPathComponent("Package.swift").path))
            if !excluded, !workingTree, parent.standardizedFileURL.path != home {
                do { workingTree = try FileManager.default.contentsOfDirectory(atPath: parent.path).contains { $0.hasSuffix(".xcodeproj") } }
                catch { gaps.append("\(parent.path): working-tree classification unavailable: \(error.localizedDescription)") }
            }
            let facts = (excluded, workingTree)
            directories[parent] = facts
            return facts
        }
        let next = (0..<MDQueryGetResultCount(query)).compactMap { index -> App? in
            let item = Unmanaged<MDItem>.fromOpaque(MDQueryGetResultAtIndex(query, index)).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { return nil }
            let url = URL(fileURLWithPath: path)
            // Exclude nested helpers and Library staging/cache copies so discovery reports launchable app bundles.
            guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { return nil }
            let ancestors = classify(url.deletingLastPathComponent())
            guard !ancestors.excluded else { return nil }
            var failures: [String] = []
            let info = CFBundleCopyInfoDictionaryInDirectory(url as CFURL) as NSDictionary?
            if info == nil { failures.append("\(path): bundle information dictionary unavailable") }
            let identifier = info?["CFBundleIdentifier"] as? String ?? MDItemCopyAttribute(item, kMDItemCFBundleIdentifier) as? String
            let bundleID = identifier.flatMap { $0.isEmpty ? nil : $0 }
            if bundleID == nil { failures.append("\(path): bundle identifier unavailable in bundle and Spotlight metadata") }
            let platforms: [String]
            if let supported = info?["CFBundleSupportedPlatforms"] as? [String], !supported.isEmpty {
                platforms = supported.map { $0.lowercased() }
            } else if let builtFor = info?["DTPlatformName"] as? String, !builtFor.isEmpty {
                platforms = [builtFor.lowercased()]
            } else { platforms = [] }
            // A bundle is a Mac app unless it declares only an iPhone/iPad platform: macOS launches an app that names no platform as a Mac app (Chrome declares
            // none).
            let platform = !platforms.contains("macosx")
                && platforms.contains(where: { $0.hasPrefix("iphone") || $0.hasPrefix("ipad") || $0.hasPrefix("ios") }) ? "ios" : "mac"
            // Build output is a copy whatever its bundle id: the folders build tools write into, and anything built inside a working tree (a .git, a
            // Package.swift, an .xcodeproj above it). The Desktop and ~/Applications are not working trees.
            let buildOutput = url.pathComponents.contains { Self.buildFolders.contains($0) } || ancestors.workingTree
            // Installed: every bundle in the Mac's own app folders (what the Apps screen shows, a beta beside its release included), and elsewhere the one copy
            // Launch Services opens for that bundle id. Build output is never installed.
            let inAppFolder = Self.appFolders.contains { NativeAgentWorkspaceRoot.relativePath(url.standardizedFileURL.path, under: $0)?.isEmpty == false }
            let kind: String
            if let bundleID, failures.isEmpty {
                if buildOutput { kind = "copy" }
                else if inAppFolder { kind = "installed" }
                else if let preferred = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).first {
                    kind = preferred.standardizedFileURL.path == url.standardizedFileURL.path ? "installed" : "copy"
                } else {
                    kind = "unavailable"
                    failures.append("\(path): Launch Services returned no preferred application for \(bundleID) outside the app folders")
                }
            } else {
                kind = "unavailable"
            }
            return App(url: url, info: info,
                name: Self.shownName(url),
                bundleID: bundleID,
                version: info?["CFBundleShortVersionString"] as? String ?? info?["CFBundleVersion"] as? String ?? MDItemCopyAttribute(item,
                    kMDItemVersion) as? String ?? "",
                platform: platform, kind: kind, classificationFailures: failures)
        }.sorted { ($0.name.localizedLowercase, $0.url.path) < ($1.name.localizedLowercase, $1.url.path) }
        func identity(_ app: App) -> [String] {
            [app.bundleID ?? "", app.version, app.url.path, app.name, app.platform, app.kind] + app.classificationFailures
        }
        let nextGaps = gaps.sorted()
        let changed = Set(next.map(identity)) != Set(rows.map(identity)) || nextGaps != directoryGaps
        rows = next
        directoryGaps = nextGaps
        if !gathering { snapshotLock.withLock { snapshot = .success(Inventory(apps: next, directoryGaps: nextGaps)) } }
        nativeLog("MacAppIndex: materialized %ld rows (%ld plist reads), changed=%@", rows.count, rows.count, changed ? "true" : "false")
        return changed
    }
}
