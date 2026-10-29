import Foundation
import Darwin
import NativeAgentCore
// Blueprint: | `PersistenceDataRoot.swift` | Swift initializes the stable process data root once; explicit resolver arguments bypass it; literalFileURL preserves configuration path spelling; `DataRootLife.life(of:)` interprets JSON stamps, with a missing or non-string stamp naming the first life |

// MARK: - Data root resolution

/// Marker files that prove a directory is a NativeAgent source repo.
private let repoMarkerFiles: [String] = [
    "persona/SOUL.template.md",
    "script/init_persona.sh",
    "Package.swift",
]

/// The native data root, decided once per process by what kind of process it
/// is, without creating directories. One rule each; none tries the next:
///   - `NATIVE_AGENT_DATA_ROOT` nonempty: that path, literally (a literal `~` is
///     kept). The children the app spawns set it.
///   - a bundle carrying a REPO_PATH stamp (every dev install): `<stamp>/data`,
///     whether or not it exists; launch names what is missing.
///   - anything else, the public release among them: Application Support.
private let processDataRoot = resolveDefaultDataRoot()

/// The process default is stable. Explicit resolver arguments below deliberately
/// bypass it for callers resolving a different environment.
public func defaultDataRoot() -> URL {
    processDataRoot
}

public func defaultDataRoot(
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> URL {
    resolveDefaultDataRoot(
        fileManager: fileManager,
        environment: environment
    )
}

internal func resolveDefaultDataRoot(
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> URL {
    if let raw = environment["NATIVE_AGENT_DATA_ROOT"], !raw.isEmpty {
        return literalFileURL(raw)
    }

    // 2. Dev bundle: the checkout its REPO_PATH stamp names.
    if let repo = _repoPathStampTarget(fileManager: fileManager) {
        return repo.appendingPathComponent("data", isDirectory: true)
    }

    // 3. Everything else, the public release among them (bare — no /data
    //    suffix, no dir creation).
    return libraryAppSupportFallback(fileManager: fileManager)
}

/// Configuration paths keep literal whitespace and `~`, without home expansion.
public func literalFileURL(_ path: String) -> URL {
    var components = URLComponents()
    components.scheme = "file"
    components.path = path
    return components.url ?? URL(fileURLWithPath: path)
}

/// The Swift-native persona root, decided by the data root alone: a
/// checkout's `data/` (every dev install) keeps its persona beside it at
/// `<repo>/persona`; any other data root holds it at `<dataRoot>/persona`.
///
/// `dataRoot` is the caller's resolved data root; we accept it rather than
/// re-resolving so a test can pin a `tmpDir`.
public func defaultPersonaRoot(
    dataRoot: URL = defaultDataRoot(),
    fileManager: FileManager = .default
) -> URL {
    if let repo = resolveSandboxRepoRoot(dataRoot: dataRoot, fileManager: fileManager) {
        return repo.appendingPathComponent("persona", isDirectory: true)
    }
    return dataRoot.appendingPathComponent("persona", isDirectory: true)
}

/// Launch preflight: missing roots, one line each; empty means none missing.
/// Public first runs are expected to be blank and do not call this.
public func missingLaunchRoots(
    dataRoot: URL,
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> [String] {
    var missing: [String] = []
    let envDataRoot = !(environment["NATIVE_AGENT_DATA_ROOT"] ?? "").isEmpty
    let stamp = envDataRoot ? nil : _repoPathStampFile(fileManager: fileManager)
    let tail = fileManager.fileExists(atPath: dataRoot.path) ? "." : ", which does not exist."
    if let stamp, stamp.text.isEmpty {
        missing.append("REPO_PATH (\(stamp.file.path)) is empty or unreadable, so the app would start on \(dataRoot.path)" + tail)
    } else if let stamp,
              !isValidRepoRootDir(dataRoot.deletingLastPathComponent(), fileManager: fileManager) {
        missing.append("REPO_PATH names \(stamp.text), which is not a NativeAgent checkout (missing, or without Package.swift, script/init_persona.sh and persona/SOUL.template.md), so the app would start on \(dataRoot.path)" + tail)
    } else if let stamp, !fileManager.fileExists(atPath: dataRoot.path) {
        missing.append("data/ is missing: REPO_PATH names \(stamp.text), which has no data/ folder, so the app would start on \(dataRoot.path), which does not exist.")
    } else if !fileManager.fileExists(atPath: dataRoot.path) {
        missing.append("The data root \(dataRoot.path) does not exist"
            + (envDataRoot ? " (set by NATIVE_AGENT_DATA_ROOT)." : "."))
    }

    let personaRoot = defaultPersonaRoot(dataRoot: dataRoot, fileManager: fileManager)
    if !fileManager.fileExists(atPath: personaRoot.appendingPathComponent("SOUL.md").path) {
        missing.append("SOUL.md is missing from \(personaRoot.path). The persona would start empty there.")
    }
    return missing
}

/// `~/Library/Application Support/NativeAgent` BARE — no `/data` suffix, no
/// directory creation; shared by every subsystem.
public func libraryAppSupportFallback(
    fileManager: FileManager = .default,
    appBundleIdentifier: String? = currentAppBundleIdentifier()
) -> URL {
    let folder = appSupportFolderName(for: appBundleIdentifier)
    if let appSupport = try? fileManager.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: false
    ) {
        return appSupport.appendingPathComponent(folder, isDirectory: true)
    }
    return URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/\(folder)")
}

/// The one public install whose data lives at the historic
/// `~/Library/Application Support/NativeAgent`. Its root must never move.
public let canonicalPublicBundleIdentifier = "io.github.embwl0x.nativeagent.mac"

/// The running .app's bundle id, or nil when this is not an app bundle (the
/// test runner, a command-line tool, a script). A non-bundle process keeps the
/// historic folder, so nothing that resolves the fallback outside an install
/// changes where it looks.
public func currentAppBundleIdentifier(bundle: Bundle = .main) -> String? {
    guard bundle.bundleURL.pathExtension == "app" else { return nil }
    return bundle.bundleIdentifier
}

/// Every noncanonical bundle id gets its own sibling data folder.
func appSupportFolderName(for bundleIdentifier: String?) -> String {
    guard let identifier = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
          !identifier.isEmpty,
          identifier != canonicalPublicBundleIdentifier
    else { return "NativeAgent" }
    // A bundle id is dot-separated reverse-DNS, but it is not guaranteed to be,
    // and this becomes a single path component.
    let safe = identifier.map { $0 == "/" || $0 == ":" ? "-" : $0 }
    return "NativeAgent-" + String(safe)
}

/// The running bundle's REPO_PATH stamp file and its trimmed text (empty when
/// unreadable), or nil when the bundle carries none (public release, test
/// runner, command-line tool).
private func _repoPathStampFile(
    fileManager: FileManager
) -> (file: URL, text: String)? {
    var bases: [URL] = []
    if let res = Bundle.main.resourceURL { bases.append(res) }
    bases.append(Bundle.main.bundleURL
        .appendingPathComponent("Contents", isDirectory: true)
        .appendingPathComponent("Resources", isDirectory: true))
    bases.append(Bundle.main.bundleURL)
    for base in bases {
        let stamp = base.appendingPathComponent("REPO_PATH")
        guard fileManager.fileExists(atPath: stamp.path) else { continue }
        let text = fileManager.contents(atPath: stamp.path).flatMap { String(data: $0, encoding: .utf8) }
        return (stamp, text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
    return nil
}

/// The checkout a REPO_PATH stamp names, canonicalized (symlinks followed),
/// whether or not it is a valid checkout — launch says so when it is not. An
/// empty stamp names `/`.
private func _repoPathStampTarget(
    fileManager: FileManager
) -> URL? {
    guard let stamp = _repoPathStampFile(fileManager: fileManager) else {
        return nil
    }
    return URL(fileURLWithPath: stamp.text.isEmpty ? "/" : stamp.text).resolvingSymlinksInPath()
}

/// True when all three repository markers exist directly under `candidate`.
/// Launch stamp validation and sandbox resolution share this proof.
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
    // The parent must be a NativeAgent repo with all three markers.
    guard isValidRepoRootDir(parent, fileManager: fileManager) else { return nil }
    return parent
}

extension DataRootLife {
    /// The life a stored JSON stamp names; no stamp is her first life.
    public static func life(of stamp: JSONValue?) -> String {
        if case .string(let id)? = stamp { return id }
        return first
    }
}
