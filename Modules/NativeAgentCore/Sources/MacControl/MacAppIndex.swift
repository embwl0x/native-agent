import Foundation
import CoreServices
import NativeAgentCore
import PersistenceCore

/// The Mac's app index, kept live by Spotlight. No app is opened or activated.
public final class MacAppIndex: @unchecked Sendable {
    public static let shared = MacAppIndex()

    public struct App: @unchecked Sendable {
        public let url: URL
        public let info: NSDictionary?
        public let name: String
        public let bundleID: String?
        public let version: String
        /// "mac" or "ios" (a simulator or device build the Mac also indexes), from the bundle's own platforms.
        public let platform: String
        /// "installed": the copy Launch Services opens for this bundle id; "copy": another copy of it (a build, a backup).
        public let kind: String
        public var scriptable: Bool { info?["OSAScriptingDefinition"] is String }
        public var json: JSONValue { .object([
            "name": .string(name), "file_name": .string(url.deletingPathExtension().lastPathComponent),
            "bundle_id": bundleID.map(JSONValue.string) ?? .null,
            "path": .string(url.path), "version": .string(version), "scriptable": .bool(scriptable),
            "platform": .string(platform), "kind": .string(kind),
        ]) }
    }

    /// Rows that share a shown name: launch by bundle id or file name, never by that name alone.
    public static func collisions(_ apps: [App]) -> Set<String> {
        var seen: Set<String> = [], twice: Set<String> = []
        for app in apps where !seen.insert(app.name.lowercased()).inserted { twice.insert(app.name.lowercased()) }
        return twice
    }

    /// The Mac's own app folders, as the Apps screen reads them.
    static let appFolders: [String] = ["/Applications", "/System/Applications",
        FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.appendingPathComponent("Applications").path]

    /// Where build tools put what they build (Xcode, SwiftPM, npm, Cargo, Python, Electron packagers).
    static let buildFolders: Set<String> = ["DerivedData", "dist", "build", "Build", "target", "node_modules", ".build", "out", "Products", "__pycache__", "release-builds"]

    /// What Finder and the Apps screen call the bundle, in the person's language.
    static func shownName(_ url: URL) -> String {
        let shown = FileManager.default.displayName(atPath: url.path)
        return shown.hasSuffix(".app") ? String(shown.dropLast(4)) : shown
    }

    /// An ancestor that is a working tree: source lives there, so an app under it was built there.
    static func insideWorkingTree(_ url: URL) -> Bool {
        var parent = url.deletingLastPathComponent()
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        while parent.path != "/" && parent.standardizedFileURL.path != home {
            if FileManager.default.fileExists(atPath: parent.appendingPathComponent(".git").path)
                || FileManager.default.fileExists(atPath: parent.appendingPathComponent("Package.swift").path)
                || ((try? FileManager.default.contentsOfDirectory(atPath: parent.path))?.contains { $0.hasSuffix(".xcodeproj") } ?? false) {
                return true
            }
            parent.deleteLastPathComponent()
        }
        return false
    }

    /// What the Apps screen shows: the installed copy of each Mac app.
    public static func installed(_ apps: [App]) -> [App] { apps.filter { $0.kind == "installed" && $0.platform == "mac" } }

    private let queue = DispatchQueue(label: "NativeAgent.MacAppIndex", qos: .utility)
    private let gathered = DispatchGroup()
    private var query: MDQuery!
    private var failure: Error?
    private var rows: [App] = []
    /// The last materialized rows, readable without the indexing queue.
    private let snapshotLock = NSLock()
    private var snapshot: [App]?
    private var observers: [NSObjectProtocol] = []
    private var listeners: [UUID: AsyncStream<Void>.Continuation] = [:]

    private init() {
        gathered.enter()
        queue.async { [self] in
            query = MDQueryCreate(nil, "kMDItemContentTypeTree == 'com.apple.application-bundle'" as CFString, nil, nil)
            guard let query else { return failedToStart() }
            MDQuerySetSearchScope(query, [kMDQueryScopeComputer] as CFArray, 0)
            MDQuerySetDispatchQueue(query, queue)
            for name in [kMDQueryDidFinishNotification, kMDQueryDidUpdateNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: Notification.Name(name! as String), object: query, queue: nil) { [self] notification in
                    let changed = materialize()
                    if notification.name.rawValue == kMDQueryDidFinishNotification as String { gathered.leave() }
                    if changed { for continuation in listeners.values { continuation.yield(()) } }
                })
            }
            if !MDQueryExecute(query, CFOptionFlags(kMDQueryWantsUpdates.rawValue)) { failedToStart() }
        }
    }

    private func failedToStart() {
        failure = MacControlError.ioFailure("The Mac's app index could not start. Check Spotlight indexing in System Settings → Spotlight, then try again.")
        gathered.leave()
    }

    /// Initial gathering and subsequent updates use this same query.
    public func changes() async throws -> AsyncStream<Void> {
        try await withCheckedThrowingContinuation { result in
            gathered.notify(queue: queue) { [self] in
                if let failure { return result.resume(throwing: failure) }
                let id = UUID()
                result.resume(returning: AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                    listeners[id] = continuation
                    continuation.yield(())
                    continuation.onTermination = { [self] _ in queue.async { self.listeners[id] = nil } }
                })
            }
        }
    }

    public func apps() async throws -> [App] {
        try await withCheckedThrowingContinuation { result in
            gathered.notify(queue: queue) { [self] in
                if let failure { result.resume(throwing: failure) }
                else { result.resume(returning: rows) }
            }
        }
    }

    /// The kept rows if the first gather has finished, else nil: a lookup on a hot
    /// path never waits for Spotlight.
    public func readyApps() -> [App]? { snapshotLock.withLock { snapshot } }

    /// Existing synchronous system adapters read the kept rows on their owning queue.
    public func apps() throws -> [App] {
        gathered.wait()
        return try queue.sync {
            if let failure { throw failure }
            return rows
        }
    }

    private func materialize() -> Bool {
        MDQueryDisableUpdates(query)
        defer { MDQueryEnableUpdates(query) }
        let next = (0..<MDQueryGetResultCount(query)).compactMap { index -> App? in
            let item = Unmanaged<MDItem>.fromOpaque(MDQueryGetResultAtIndex(query, index)).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { return nil }
            let url = URL(fileURLWithPath: path)
            // An app the person could open from the Apps screen: a real .app with a
            // bundle id, not a helper inside another bundle (an .app, a .framework,
            // a .service, an .xpc…), not a copy under a Library folder (an installer's
            // staging area, a tool's own versions, a cache).
            guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { return nil }
            var parent = url.deletingLastPathComponent()
            while parent.path != "/" {
                if parent.lastPathComponent == "Library" || !parent.pathExtension.isEmpty
                    || (try? parent.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { return nil }
                parent.deleteLastPathComponent()
            }
            let info = CFBundleCopyInfoDictionaryInDirectory(url as CFURL) as NSDictionary?
            guard let bundleID = info?["CFBundleIdentifier"] as? String ?? MDItemCopyAttribute(item, kMDItemCFBundleIdentifier) as? String,
                  !bundleID.isEmpty else { return nil }
            let platforms = (info?["CFBundleSupportedPlatforms"] as? [String] ?? [info?["DTPlatformName"] as? String ?? "MacOSX"]).map { $0.lowercased() }
            let platform = platforms.contains(where: { $0.hasPrefix("iphone") || $0.hasPrefix("ipad") || $0.hasPrefix("ios") }) && !platforms.contains("macosx") ? "ios" : "mac"
            // Build output is a copy whatever its bundle id: the folders build tools write
            // into, and anything built inside a working tree (a .git, a Package.swift, an
            // .xcodeproj above it). The Desktop and ~/Applications are not working trees.
            let buildOutput = url.pathComponents.contains { Self.buildFolders.contains($0) } || Self.insideWorkingTree(url)
            // Installed: every bundle in the Mac's own app folders (what the Apps screen shows,
            // a beta beside its release included), and elsewhere the one copy Launch Services
            // opens for that bundle id. Build output is never installed.
            let preferred = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL]
            let inAppFolder = Self.appFolders.contains { url.standardizedFileURL.path.hasPrefix($0 + "/") }
            let kind = !buildOutput && (inAppFolder || (preferred?.first.map { $0.standardizedFileURL.path == url.standardizedFileURL.path } ?? true)) ? "installed" : "copy"
            return App(url: url, info: info,
                // The name the Apps screen and Finder show: the Mac's own localized display name ("Find My").
                name: Self.shownName(url),
                bundleID: bundleID,
                version: info?["CFBundleShortVersionString"] as? String ?? info?["CFBundleVersion"] as? String ?? MDItemCopyAttribute(item, kMDItemVersion) as? String ?? "",
                platform: platform, kind: kind)
        }.sorted { ($0.name.localizedLowercase, $0.url.path) < ($1.name.localizedLowercase, $1.url.path) }
        let changed = Set(next.map { [$0.bundleID ?? "", $0.version, $0.url.path] })
            != Set(rows.map { [$0.bundleID ?? "", $0.version, $0.url.path] })
        rows = next
        snapshotLock.withLock { snapshot = next }
        nativeLog("MacAppIndex: materialized %ld rows (%ld plist reads), changed=%@", rows.count, rows.count, changed ? "true" : "false")
        return changed
    }
}
