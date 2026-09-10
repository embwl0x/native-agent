import Foundation
import Darwin
import NativeAgentCore

// MARK: - Data root resolution

/// Marker files that prove a directory is a NativeAgent source repo.
/// Keep in sync with `NativeAgentPaths.isValidRepoStamp` in the app layer.
private let repoMarkerFiles: [String] = [
    "persona/SOUL.template.md",
    "script/init_persona.sh",
    "Package.swift",
]

/// True when any parent of `candidate` is named "Contents" and its parent
/// has a `.app` extension or name ending in ".app".
private func pathInsideAppBundle(_ candidate: URL) -> Bool {
    let resolved = candidate.resolvingSymlinksInPath()
    var url = resolved
    while url.path != "/" {
        if url.lastPathComponent == "Contents" {
            let grand = url.deletingLastPathComponent()
            if grand.pathExtension == "app" || grand.lastPathComponent.hasSuffix(".app") {
                return true
            }
        }
        let parent = url.deletingLastPathComponent()
        if parent.path == url.path { break }
        url = parent
    }
    return false
}

/// Resolve the native data root without creating directories:
/// explicit environment override, isolated test root, validated bundle stamp,
/// development CWD search, then Application Support. Unstamped public apps
/// skip the development search. Environment paths preserve a literal `~`.
/// The CWD search requires a Package.swift/package.swift and existing data/
/// outside an app bundle; bundle stamps require all three repository markers.
///
/// The internal resolver also receives bundle identity as a value, so its
/// public-app branch is executable without mutating process-global
/// `Bundle.main` state.
private let processDataRoot = ResolvedDataRootCache()

/// The process default is stable. Explicit resolver arguments below deliberately
/// bypass this cache (tests and callers resolving a different environment).
public func defaultDataRoot() -> URL {
    processDataRoot.resolve { resolveDefaultDataRoot() }
}

internal final class ResolvedDataRootCache: @unchecked Sendable {
    private let lock = NSLock()
    private var root: URL?

    func resolve(_ resolver: () -> URL) -> URL {
        lock.lock()
        defer { lock.unlock() }
        if let root { return root }
        let resolved = resolver()
        root = resolved
        return resolved
    }
}

public func defaultDataRoot(
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    processName: String = ProcessInfo.processInfo.processName
) -> URL {
    resolveDefaultDataRoot(
        fileManager: fileManager,
        environment: environment,
        processName: processName,
        bundleContext: .main
    )
}

/// The bundle identity consulted by the canonical data-root resolver. Keeping
/// this as a value rather than reaching for `Bundle.main` inside a branch makes
/// the installed-public-app boundary executable without changing the runtime
/// path: production always supplies `.main` above.
internal struct DefaultDataRootBundleContext: Sendable {
    let bundleURL: URL
    let resourcesURL: URL?

    static var main: Self {
        Self(bundleURL: Bundle.main.bundleURL, resourcesURL: Bundle.main.resourceURL)
    }

    init(bundleURL: URL, resourcesURL: URL?) {
        self.bundleURL = bundleURL
        self.resourcesURL = resourcesURL
    }
}

/// Internal resolver seam for the process-global public entry point above.
/// `fallbackRoot` exists only so the executable contract can prove where a
/// first write lands without touching a developer's real Application Support.
internal func resolveDefaultDataRoot(
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    processName: String = ProcessInfo.processInfo.processName,
    bundleContext: DefaultDataRootBundleContext = .main,
    fallbackRoot: URL? = nil
) -> URL {
    // 1. Env var wins. Empty string is treated as unset (matches Python:
    //    `if env: return Path(env)` — Python treats "" as falsy). The env
    //    var is used LITERALLY — `~` is NOT expanded, to match Python.
    //
    //    GOTCHA: every `URL(fileURLWithPath:)` / `URL(fileURLWithFileSystem-
    //    Representation:)` variant on Darwin Foundation silently expands a
    //    leading `~` ("`~/foo`" → "`$HOME/foo`"). Python's `Path(env)` does
    //    NOT expand. The only Foundation constructor that preserves a leading
    //    tilde is `URLComponents(scheme: "file", path: raw)` — that path
    //    bypasses the implicit tilde expansion entirely. Validated by
    //    `defaultDataRoot_envVarPreservesLeadingTilde` in PersistenceCoreTests.
    if let raw = environment["NATIVE_AGENT_DATA_ROOT"], !raw.isEmpty {
        var components = URLComponents()
        components.scheme = "file"
        components.path = raw
        if let url = components.url {
            return url
        }
        // Defensive fallback if URLComponents.url returns nil for some edge
        // case (shouldn't happen for well-formed paths). Accepts the
        // tilde-expansion divergence rather than crashing.
        return URL(fileURLWithPath: raw)
    }

    // 1b. Test-harness backstop (2026-08-23). Under a bare `swift test` the
    //     process is `swiftpm-testing-helper`, no env var is set, and branch 3
    //     walks up from the checkout into the LIVE repo `data/` — 639 fake
    //     `llm.call` rows landed in traces/events.jsonl in one week from
    //     adapter tests alone. Same predicate TurnTrace.automaticTestRoot uses;
    //     an explicit NATIVE_AGENT_DATA_ROOT (branch 1) still outranks it.
    if let testRoot = automaticTestDataRoot(environment: environment, processName: processName) {
        return testRoot
    }

    // 2. Stamped REPO_PATH (bundle install). Look for a `REPO_PATH` text file
    //    next to the running bundle's Resources hierarchy. Mirrors Python's
    //    `_bundle_repo_path` walk over `Path(__file__).parent`, etc.
    if let stamped = _stampedRepoFromBundle(
        fileManager: fileManager,
        bundleContext: bundleContext
    ) {
        let dataDir = stamped.appendingPathComponent("data", isDirectory: true)
        if fileManager.fileExists(atPath: dataDir.path) {
            return dataDir
        }
    }

    // 3. Dev heuristic — walk up from CWD looking for a repo root.
    //    Differs from Python (which uses Path(__file__).resolve().parent.parent)
    //    because Swift package code has no equivalent of __file__ at runtime.
    //    Adds TWO checks Python also enforces: data/ subdir must EXIST,
    //    path must NOT be inside an .app bundle.
    //
    //    Tightness review round 2 (HIGH, 2026-07-17): the CWD walk is a DEV
    //    convenience and must never fire for an UNSTAMPED PUBLIC-RELEASE app
    //    bundle — a public .app launched with a checkout as its cwd would
    //    silently adopt the private repo's data/ AND bypass the app layer's
    //    blank-slate quarantine (which only runs on the AppSupport root).
    //    Guarded HERE in the canonical resolver — not just in the app-side
    //    NativeAgentPaths wrapper — because hundreds of call sites reach this
    //    function directly.
    if _isUnstampedPublicAppBundle(
        fileManager: fileManager,
        bundleContext: bundleContext
    ) {
        return fallbackRoot ?? libraryAppSupportFallback(fileManager: fileManager)
    }
    let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
    var dir = cwd
    for _ in 0..<8 {
        // W1.3: case-insensitive Package.swift probe so case-sensitive
        // filesystems (or a checkout where the manifest got lowercased)
        // still resolve the dev repo. Package.swift alone is the dev-repo
        // marker now, mirroring NativeAgentPaths.isValidRepoStamp.
        let pkg = dir.appendingPathComponent("Package.swift")
        let pkgLower = dir.appendingPathComponent("package.swift")
        let dataDir = dir.appendingPathComponent("data", isDirectory: true)
        let isRepo = fileManager.fileExists(atPath: pkg.path)
            || fileManager.fileExists(atPath: pkgLower.path)
        let hasData = fileManager.fileExists(atPath: dataDir.path)
        let isInAppBundle = pathInsideAppBundle(dataDir)
        if isRepo && hasData && !isInAppBundle {
            return dataDir
        }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { break }
        dir = parent
    }

    // 4. AppSupport fallback (bare — no /data suffix, no dir creation;
    //    matches Python's `Path.home() / "Library" / ... / APP`).
    return fallbackRoot ?? libraryAppSupportFallback(fileManager: fileManager)
}

/// Per-process temp data root for test-harness processes, nil otherwise.
/// PID-keyed so parallel test processes stay isolated; bare (no dir creation),
/// like every other branch — callers create on first write.
public func automaticTestDataRoot(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    processName: String = ProcessInfo.processInfo.processName,
    temporaryDirectory: URL = FileManager.default.temporaryDirectory
) -> URL? {
    let p = processName.lowercased()
    guard environment["XCTestConfigurationFilePath"] != nil
            || p.contains("xctest")
            || p.contains("swiftpm-testing-helper")
            || p.contains("packagetests") else { return nil }
    return temporaryDirectory.appendingPathComponent(
        "NativeAgent-TestDataRoot-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
}

/// True only for a distributed public build: a real `.app` bundle carrying a
/// VERSION resource but NO REPO_PATH dev stamp. Dev installs from
/// install_app.sh are always stamped, and test/CLI processes are not `.app`
/// bundles, so both keep full dev resolution. Mirrors (and must stay in sync
/// with) `NativeAgentPaths.isPublicReleaseBundle` in the app layer.
internal func _isUnstampedPublicAppBundle(
    fileManager: FileManager,
    bundleContext: DefaultDataRootBundleContext = .main
) -> Bool {
    guard bundleContext.bundleURL.pathExtension == "app",
          let resourcesURL = bundleContext.resourcesURL else { return false }
    if fileManager.fileExists(atPath: resourcesURL.appendingPathComponent("REPO_PATH").path) {
        return false
    }
    return fileManager.fileExists(atPath: resourcesURL.appendingPathComponent("VERSION").path)
}

/// Resolve the Swift-native persona root.
///
/// Resolution priority:
///   1. `NATIVE_AGENT_PERSONA_ROOT` env var (literal; no tilde expansion).
///   2. `<dataRoot>/persona/<identity>` when it contains SOUL.md, otherwise
///      `<dataRoot>/persona` when SOUL.md lives directly there. These are the
///      installed-app user-editable canonical locations once fully seeded.
///   3. `<stamped_repo>/persona/Agent` when it contains SOUL.md; otherwise
///      `<stamped_repo>/persona` when that root contains SOUL.md. This handles
///      the current repo layout where `persona/Agent` is notes/workspace only.
///   4. `<repo>/persona` when `dataRoot` is `<repo>/data` and SOUL.md exists.
///   5. `<dataRoot>/memory` legacy cold-start fallback.
///
/// `dataRoot` is the caller's resolved data root; we accept it rather than
/// re-resolving so a test can pin a `tmpDir` without env vars leaking from
/// the host process.
public func defaultPersonaRoot(
    dataRoot: URL = defaultDataRoot(),
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> URL {
    if let raw = environment["NATIVE_AGENT_PERSONA_ROOT"], !raw.isEmpty {
        var components = URLComponents()
        components.scheme = "file"
        components.path = raw
        if let url = components.url {
            return url
        }
        return URL(fileURLWithPath: raw)
    }
    let canonicalPersonaRoot = dataRoot.appendingPathComponent("persona", isDirectory: true)
    if let personaDir = firstSeededPersonaDirectory(in: canonicalPersonaRoot, fileManager: fileManager) {
        return personaDir
    }
    if fileManager.fileExists(
        atPath: canonicalPersonaRoot.appendingPathComponent("SOUL.md").path
    ) {
        return canonicalPersonaRoot
    }
    if let stamped = _stampedRepoFromBundle(fileManager: fileManager) {
        let personaRoot = stamped.appendingPathComponent("persona", isDirectory: true)
        if let personaDir = firstSeededPersonaDirectory(in: personaRoot, fileManager: fileManager) {
            return personaDir
        }
        if fileManager.fileExists(atPath: personaRoot.appendingPathComponent("SOUL.md").path) {
            return personaRoot
        }
    }
    if let repoRoot = resolveSandboxRepoRoot(dataRoot: dataRoot, fileManager: fileManager) {
        let personaDir = repoRoot.appendingPathComponent("persona", isDirectory: true)
        if fileManager.fileExists(atPath: personaDir.appendingPathComponent("SOUL.md").path) {
            return personaDir
        }
    }
    return dataRoot.appendingPathComponent("memory", isDirectory: true)
}

package func firstSeededPersonaDirectory(in parent: URL, fileManager: FileManager) -> URL? {
    guard let entries = try? fileManager.contentsOfDirectory(
        at: parent,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return nil }
    for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else { continue }
        if fileManager.fileExists(atPath: entry.appendingPathComponent("SOUL.md").path) {
            return entry
        }
    }
    return nil
}

/// `~/Library/Application Support/NativeAgent` BARE — no `/data` suffix, no
/// directory creation. Matches Python's fallback at the retired daemon.
/// Subsystems (ApprovalInbox, MCPDispatcher) used to duplicate this resolution;
/// they now delegate here.
public func libraryAppSupportFallback(
    fileManager: FileManager = .default
) -> URL {
    if let appSupport = try? fileManager.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: false
    ) {
        return appSupport.appendingPathComponent("NativeAgent", isDirectory: true)
    }
    return URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/NativeAgent")
}

/// Mirrors Python's `_bundle_repo_path`: look for a `REPO_PATH` stamp file in
/// the running bundle's Resources hierarchy and return its target as a URL.
/// Returns `nil` outside a stamped bundle (dev path, swift test runner) —
/// callers fall through to the next resolution step.
private func _stampedRepoFromBundle(
    fileManager: FileManager,
    bundleContext: DefaultDataRootBundleContext = .main
) -> URL? {
    var bases: [URL] = []
    if let res = bundleContext.resourcesURL { bases.append(res) }
    bases.append(bundleContext.bundleURL
        .appendingPathComponent("Contents", isDirectory: true)
        .appendingPathComponent("Resources", isDirectory: true))
    bases.append(bundleContext.bundleURL)
    return _stampedRepoFromBundleBases(bases, fileManager: fileManager)
}

/// Test seam for `_stampedRepoFromBundle` — accepts injected bundle bases so
/// tests can build a synthetic Resources/REPO_PATH layout without needing a
/// real .app bundle. All three `repoMarkerFiles` must exist on the
/// canonicalized stamp target.
internal func _stampedRepoFromBundleBases(
    _ bases: [URL],
    fileManager: FileManager
) -> URL? {
    for base in bases {
        let stamp = base.appendingPathComponent("REPO_PATH")
        guard fileManager.fileExists(atPath: stamp.path) else { continue }
        guard let data = try? Data(contentsOf: stamp) else { continue }
        guard let text = String(data: data, encoding: .utf8) else { continue }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }
        let raw = URL(fileURLWithPath: trimmed)
        // Canonicalize — follows symlinks like Python's Path.resolve().
        let canonical = raw.resolvingSymlinksInPath()
        guard fileManager.fileExists(atPath: canonical.path) else { continue }
        var allMarkersExist = true
        for marker in repoMarkerFiles {
            let m = canonical.appendingPathComponent(marker)
            if !fileManager.fileExists(atPath: m.path) {
                allMarkersExist = false; break
            }
        }
        if allMarkersExist { return canonical }
    }
    return nil
}

/// True when all three repository markers exist directly under `candidate`.
/// Bundle-stamp validation and sandbox resolution share this proof.
internal func isValidRepoRootDir(
    _ candidate: URL,
    fileManager: FileManager
) -> Bool {
    for marker in repoMarkerFiles {
        let m = candidate.appendingPathComponent(marker)
        if !fileManager.fileExists(atPath: m.path) { return false }
    }
    return true
}

/// Resolve a repository root for the native dispatch sandbox only when the
/// data root's parent carries all three repository markers. An Application
/// Support data root must never grant access to its entire parent directory.
/// Returns nil for an unproven parent; callers must handle that locally.
public func resolveSandboxRepoRoot(
    dataRoot: URL = defaultDataRoot(),
    fileManager: FileManager = .default
) -> URL? {
    let parent = dataRoot.deletingLastPathComponent()
    // Defensive: a root-level or empty parent ("/" or "") is never a repo.
    if parent.path.isEmpty || parent.path == "/" { return nil }
    // Belt-and-suspenders against the named failure mode: if the data root is
    // the bare AppSupport fallback (its LAST component is the app dir and its
    // parent is "…/Application Support"), refuse outright even if — implausibly
    // — someone planted marker files in Application Support. The marker check
    // below already rejects this, but naming it makes the intent explicit and
    // immune to a future Application-Support layout that happens to look repo-y.
    if parent.lastPathComponent == "Application Support"
        || parent.path.hasSuffix("/Library/Application Support") {
        return nil
    }
    // The proof: the parent must be a real NativeAgent repo (all three markers),
    // mirroring the daemon's `self.repo_root` being a validated checkout.
    guard isValidRepoRootDir(parent, fileManager: fileManager) else { return nil }
    return parent
}
