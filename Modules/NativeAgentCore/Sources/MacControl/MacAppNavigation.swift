import Foundation
import NativeAgentCore
import PersistenceCore
import Senses
import TrustCenter
#if canImport(Darwin)
import Darwin
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(AppKit)
import AppKit
import Carbon
import OSAKit
import os
import NativeAgentShared
#endif

// Blueprint: | `MacAppNavigation.swift` | `MacApplications`, `AppControlRunResult` and `OpenTarget`: exact application resolution, launch, measured focus, quit and URL/file opening under the existing driver authority |

public struct AppControlRunResult: Sendable, Equatable {
    public let requestedName: String
    public let matchedName: String?
    public let bundleIdentifier: String?
    public let processIdentifier: Int32?
    public let launched: Bool
    public let activated: Bool
    public let terminated: Bool
    public let alreadyInDesiredState: Bool

    public init(
        requestedName: String,
        matchedName: String?,
        bundleIdentifier: String?,
        processIdentifier: Int32?,
        launched: Bool,
        activated: Bool,
        terminated: Bool,
        alreadyInDesiredState: Bool = false
    ) {
        self.requestedName = requestedName
        self.matchedName = matchedName
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.launched = launched
        self.activated = activated
        self.terminated = terminated
        self.alreadyInDesiredState = alreadyInDesiredState
    }
}

public final class MacApplications: Sendable {
    public init() {}

    public func focusApp(named name: String) async throws -> AppControlRunResult {
        let query = normalizedAppQuery(name)
        guard !query.isEmpty else { throw MacControlError.missingField("app") }
        #if canImport(AppKit)
        let indexedURL = await Self.indexedApplicationURL(named: query)
        return try await Self.openAppOnMain(named: query, front: true, indexedURL: indexedURL)
        #else
        throw MacControlError.appControlFailed("AppKit unavailable on this platform")
        #endif
    }

    public func launchApp(named name: String) async throws -> AppControlRunResult {
        let query = normalizedAppQuery(name)
        guard !query.isEmpty else { throw MacControlError.missingField("app") }
        #if canImport(AppKit)
        let indexedURL = await Self.indexedApplicationURL(named: query)
        return try await Self.openAppOnMain(named: query, front: false, indexedURL: indexedURL)
        #else
        throw MacControlError.appControlFailed("AppKit unavailable on this platform")
        #endif
    }

    public func quitApp(named name: String) async throws -> AppControlRunResult {
        let query = normalizedAppQuery(name)
        guard !query.isEmpty else { throw MacControlError.missingField("app") }
        #if canImport(AppKit)
        let indexedURL = await Self.indexedApplicationURL(named: query)
        return try await Self.quitAppOnMain(named: query, indexedURL: indexedURL)
        #else
        throw MacControlError.appControlFailed("AppKit unavailable on this platform")
        #endif
    }

    public func isApplicationRunning(matching name: String) async -> Bool {
        let query = normalizedAppQuery(name)
        guard !query.isEmpty else { return false }
        #if canImport(AppKit)
        let indexedURL = await Self.indexedApplicationURL(named: query)
        return await Self.isApplicationRunningOnMain(matching: query, indexedURL: indexedURL)
        #else
        return false
        #endif
    }

    private func normalizedAppQuery(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    #if canImport(AppKit)
    @MainActor
    private static func isApplicationRunningOnMain(matching query: String, indexedURL: Result<URL?, Error>) -> Bool {
        (try? runningApplications(matching: query, indexedURL: indexedURL).isEmpty) == false
    }

    @MainActor
    private static func openAppOnMain(named query: String, front: Bool, indexedURL: Result<URL?, Error>) async throws -> AppControlRunResult {
        try Task.checkCancellation()
        let running = try runningApp(matching: query, indexedURL: indexedURL)
        guard let url = try running?.bundleURL ?? applicationURL(matching: query, indexedURL: indexedURL) else {
            throw ToolFailureError("app_not_found: \(query)", argumentPath: "name",
                accepted: "An installed app's exact name, bundle identifier or .app path.", effects: .none)
        }
        // Only a request to come forward reopens a running app; one already
        // running in the background is left exactly as it is.
        if let running, !front {
            return runResult(requested: query, app: running, launched: false, activated: false, terminated: false)
        }
        // Opening a running bundle delivers its reopen event, just like the Dock.
        // Workspace also owns the cooperative activation hand-off.
        let app = try await openApplication(at: url, activates: front)
        if front { try await observeActivation(of: app.processIdentifier) }
        try Task.checkCancellation()
        let frontmost = NSWorkspace.shared.frontmostApplication
        let activated = front && frontmost?.processIdentifier == app.processIdentifier
        if front && !activated {
            throw ToolFailureError("Workspace opened \(url.path) with activation requested; after waiting up to 1.5 seconds for activation, the frontmost app is \(frontmost?.localizedName ?? "none") (pid: \(frontmost?.processIdentifier ?? 0)), not \(query) (pid: \(app.processIdentifier)).",
                effects: .occurred, owner: "macOS application activation", tap: "Dock > \(app.localizedName ?? query)")
        }
        return runResult(requested: query, app: app, fallbackURL: url,
            launched: running == nil, activated: activated, terminated: false)
    }

    @MainActor
    static func observeActivation(of pid: Int32, within seconds: TimeInterval = 1.5) async throws {
        let (events, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let center = NSWorkspace.shared.notificationCenter
        let observer = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: nil) { notification in
            if (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier == pid {
                signal.yield(())
            }
        }
        defer { center.removeObserver(observer); signal.finish() }
        // Register before reading so activation cannot fall between the read and the wait.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != pid else { return }
        _ = await raceAgainstTimeout(seconds: seconds) {
            for await _ in events { break }
        }
        try Task.checkCancellation()
    }

    @MainActor
    private static func quitAppOnMain(named query: String, indexedURL: Result<URL?, Error>) async throws -> AppControlRunResult {
        let running = try runningApplications(matching: query, indexedURL: indexedURL)
        guard !running.isEmpty else {
            if let url = try applicationURL(matching: query, indexedURL: indexedURL) {
                return AppControlRunResult(
                    requestedName: query,
                    matchedName: url.deletingPathExtension().lastPathComponent,
                    bundleIdentifier: Bundle(url: url)?.bundleIdentifier,
                    processIdentifier: nil,
                    launched: false,
                    activated: false,
                    terminated: false,
                    alreadyInDesiredState: true
                )
            }
            throw MacControlError.appControlFailed("app_not_running_or_not_found: \(query)")
        }
        let first = running[0]
        let identities = Set(running.map {
            $0.bundleURL?.standardizedFileURL.path ?? $0.bundleIdentifier ?? "pid:\($0.processIdentifier)"
        })
        guard identities.count == 1 else {
            throw MacControlError.appControlFailed("app_query_ambiguous: use an exact app name or bundle identifier")
        }
        var terminated = false
        for app in running {
            try Task.checkCancellation()
            guard MacDriverContext.binding?.allowsEmission == true else {
                throw MacControlError.appControlFailed(MacAttentionSessionStore.driverRefusal)
            }
            if app.terminate() { terminated = true }
        }
        return runResult(
            requested: query,
            app: first,
            launched: false,
            activated: false,
            terminated: terminated
        )
    }

    @MainActor
    private static func openApplication(at url: URL, activates: Bool) async throws -> NSRunningApplication {
        try Task.checkCancellation()
        guard (activates ? MacDriverContext.binding?.allowsEmission : MacDriverContext.binding?.allowsBackgroundEmission) == true else {
            throw ToolFailureError(MacAttentionSessionStore.driverRefusal, effects: .none,
                owner: "Mac attention", tap: "NativeAgent Mac chat > composer controls > Let [agent name] use the Mac",
                personDecides: true)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let config = NSWorkspace.OpenConfiguration()
            config.activates = activates
            config.allowsRunningApplicationSubstitution = false
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
                if let error {
                    let cause = error as NSError
                    continuation.resume(throwing: ToolFailureError("\(cause.domain) (\(cause.code)): \(cause.localizedDescription)",
                        effects: .unknown, owner: "macOS Launch Services", tap: "Finder > \(url.path) > Open"))
                } else if let app {
                    continuation.resume(returning: app)
                } else {
                    continuation.resume(throwing: ToolFailureError("Workspace returned no application for \(url.path)",
                        effects: .unknown, owner: "macOS Launch Services", tap: "Finder > \(url.path) > Open"))
                }
            }
        }
    }

    @MainActor
    private static func runningApp(matching query: String, indexedURL: Result<URL?, Error>) throws -> NSRunningApplication? {
        let running = try runningApplications(matching: query, indexedURL: indexedURL)
        let identities = Set(running.map {
            $0.bundleURL?.standardizedFileURL.path ?? $0.bundleIdentifier ?? "pid:\($0.processIdentifier)"
        })
        guard identities.count <= 1 else {
            let candidates = running.map { "\($0.localizedName ?? "unnamed") [\($0.bundleIdentifier ?? "no bundle id")] \($0.bundleURL?.path ?? "pid:\($0.processIdentifier)")" }.sorted().joined(separator: "; ")
            throw ToolFailureError("app_query_ambiguous: \(query) matches \(candidates). Choose an exact app name, bundle identifier or .app path.",
                argumentPath: "name", accepted: candidates, effects: .none)
        }
        return running.first
    }

    @MainActor
    private static func runningApplications(matching query: String, indexedURL: Result<URL?, Error>) throws -> [NSRunningApplication] {
        let running = NSWorkspace.shared.runningApplications
        let lower = query.lowercased()
        // Prefer apps with a Dock icon over helpers and services sharing their name.
        func preferRegular(_ apps: [NSRunningApplication]) -> [NSRunningApplication] {
            let regular = apps.filter { $0.activationPolicy == .regular }
            return regular.isEmpty ? apps : regular
        }
        if query.contains("/") {
            let requested = URL(fileURLWithPath: NativeAgentWorkspaceRoot.fileSpelling(query))
                .resolvingSymlinksInPath().standardizedFileURL
            return running.filter { $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == requested }
        }
        let appName = query.lowercased().hasSuffix(".app") ? String(query.dropLast(4)) : query
        if looksLikeBundleIdentifier(query) {
            let exactBundle = running.filter { ($0.bundleIdentifier ?? "").caseInsensitiveCompare(query) == .orderedSame }
            if !exactBundle.isEmpty { return preferRegular(exactBundle) }
        }
        let exactName = running.filter {
            ($0.localizedName ?? "").caseInsensitiveCompare(appName) == .orderedSame
                || $0.bundleURL?.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(appName) == .orderedSame
        }
        if !exactName.isEmpty { return preferRegular(exactName) }
        let exactBundle = running.filter { ($0.bundleIdentifier ?? "").caseInsensitiveCompare(query) == .orderedSame }
        if !exactBundle.isEmpty { return preferRegular(exactBundle) }
        // "Mail" with Mail stopped and MailMate running means Mail: a partial
        // name only when no app by that exact name is installed either.
        guard try applicationURL(matching: query, indexedURL: indexedURL) == nil else { return [] }
        let partial = running.filter { app in
            let name = (app.localizedName ?? "").lowercased()
            let bundle = (app.bundleIdentifier ?? "").lowercased()
            return name.contains(lower) || bundle.contains(lower)
        }
        return preferRegular(partial)
    }

    @MainActor
    private static func applicationURL(matching query: String, indexedURL: Result<URL?, Error>) throws -> URL? {
        if let url = try indexedURL.get() { return url }
        if looksLikeBundleIdentifier(query), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query) {
            nativeLog("MacApplications: Launch Services resolved %@ to %@", query, url.path)
            return url
        }
        // Anywhere else Launch Services knows an app by exactly this name.
        guard !query.contains("/") else { return nil }
        let name = query.hasSuffix(".app") ? String(query.dropLast(4)) : query
        guard let path = NSWorkspace.shared.fullPath(forApplication: name) else { return nil }
        let url = URL(fileURLWithPath: path)
        return url.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(name) == .orderedSame ? url : nil
    }

    /// Exact name, bundle id or bundle path from the Mac's own app index.
    public static func installedApplicationURL(named query: String) throws -> URL? {
        try installedApplicationURL(named: query, apps: { try MacAppIndex.shared.apps() })
    }

    /// Gather before the MainActor application transaction. Keep a failure as
    /// data until lookup is needed: an exact running app still wins as before.
    private static func indexedApplicationURL(named query: String) async -> Result<URL?, Error> {
        // An app already running under its exact name or bundle id needs no
        // index: its own bundle answers, so a stalled Spotlight never holds it.
        let runningExactly = await MainActor.run {
            NSWorkspace.shared.runningApplications.contains {
                let appName = query.lowercased().hasSuffix(".app") ? String(query.dropLast(4)) : query
                return ($0.localizedName ?? "").caseInsensitiveCompare(appName) == .orderedSame
                    || ($0.bundleIdentifier ?? "").caseInsensitiveCompare(query) == .orderedSame
                    || (query.contains("/") && $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL
                        == URL(fileURLWithPath: NativeAgentWorkspaceRoot.fileSpelling(query)).resolvingSymlinksInPath().standardizedFileURL)
            }
        }
        if runningExactly { return .success(nil) }
        do {
            if let url = explicitApplicationURL(named: query) { return .success(url) }
            let apps = try await MacAppIndex.shared.apps()
            return .success(try installedApplicationURL(named: query, apps: { apps }))
        } catch {
            return .failure(ToolFailureError(error.localizedDescription, effects: .none,
                owner: "macOS Spotlight app index", tap: "System Settings > Spotlight"))
        }
    }

    private static func explicitApplicationURL(named query: String) -> URL? {
        let expandedQuery = NativeAgentWorkspaceRoot.fileSpelling(query)
        if expandedQuery.hasPrefix("/"), expandedQuery.hasSuffix(".app") {
            let url = URL(fileURLWithPath: expandedQuery)
            if isApplicationBundle(url) { return url }
        }
        return nil
    }

    private static func installedApplicationURL(named query: String, apps readApps: () throws -> [MacAppIndex.App]) throws -> URL? {
        if let url = explicitApplicationURL(named: query) { return url }
        let name = query.hasSuffix(".app") ? String(query.dropLast(4)) : query
        let apps: [MacAppIndex.App]
        do { apps = try readApps() }
        catch {
            throw ToolFailureError(error.localizedDescription, effects: .none,
                owner: "macOS Spotlight app index", tap: "System Settings > Spotlight")
        }
        let matches = MacAppIndex.installed(apps).filter {
            $0.bundleID?.caseInsensitiveCompare(query) == .orderedSame
                || $0.name.caseInsensitiveCompare(name) == .orderedSame
                || $0.url.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
        }
        guard matches.count <= 1 else {
            let candidates = matches.map { "\($0.name) [\($0.bundleID ?? "no bundle id")] \($0.url.path)" }.joined(separator: "; ")
            throw ToolFailureError("app_query_ambiguous: \(query) matches \(candidates). Choose an exact .app path.",
                argumentPath: "name", accepted: candidates, effects: .none)
        }
        return matches.first?.url
    }

    private static func looksLikeBundleIdentifier(_ query: String) -> Bool {
        query.contains(".") && !query.contains("/") && !query.contains(" ")
    }

    private static func isApplicationBundle(_ url: URL) -> Bool {
        url.pathExtension.caseInsensitiveCompare("app") == .orderedSame
            && FileManager.default.fileExists(atPath: url.path)
    }

    @MainActor
    private static func runResult(
        requested: String,
        app: NSRunningApplication,
        fallbackURL: URL? = nil,
        launched: Bool,
        activated: Bool,
        terminated: Bool
    ) -> AppControlRunResult {
        let name = app.localizedName ?? fallbackURL?.deletingPathExtension().lastPathComponent
        let bundleIdentifier = app.bundleIdentifier ?? fallbackURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
        return AppControlRunResult(
            requestedName: requested,
            matchedName: name,
            bundleIdentifier: bundleIdentifier,
            processIdentifier: app.processIdentifier,
            launched: launched,
            activated: activated,
            terminated: terminated
        )
    }
    #endif
}

public struct OpenTarget: Sendable {
    public init() {}

    public func requestOpen(_ url: URL, background: Bool) async throws -> [String: JSONValue] {
        #if canImport(AppKit)
        return try await Self.requestOpenOnMain(url, background: background)
        #else
        throw MacControlError.appControlFailed("AppKit unavailable on this platform")
        #endif
    }

    #if canImport(AppKit)
    @MainActor
    private static func requestOpenOnMain(_ url: URL, background: Bool) async throws -> [String: JSONValue] {
        try Task.checkCancellation()
        guard (background ? MacDriverContext.binding?.allowsBackgroundEmission : MacDriverContext.binding?.allowsEmission) == true else {
            throw MacControlError.appControlFailed(MacAttentionSessionStore.driverRefusal)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = !background
        let app = try await NSWorkspace.shared.open(url, configuration: configuration)
        return [
            "matched_name": app.localizedName.map(JSONValue.string) ?? .null,
            "bundle_identifier": app.bundleIdentifier.map(JSONValue.string) ?? .null,
            "process_identifier": .int(Int64(app.processIdentifier)),
        ]
    }
    #endif
}
