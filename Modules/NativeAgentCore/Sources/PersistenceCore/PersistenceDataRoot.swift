import Foundation
import Darwin
import NativeAgentCore
// Blueprint: | `PersistenceDataRoot.swift` | `DataRootLife.life(of:)`; Stable process root; explicit roots retain literal spelling. |

// MARK: - Data root resolution

private let repoMarkerFiles: [String] = [
    "persona/SOUL.template.md",
    "script/init_persona.sh",
    "Package.swift",
]

/// Resolve once without creating directories: explicit nonempty environment path, stamped checkout/data, or Application Support. These are identity rules, not
/// retries; launch reports a missing selected root.
private let processDataRoot = resolveDefaultDataRoot()

/// The process default is stable. Explicit resolver arguments below deliberately bypass it for callers resolving a different environment.
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

    if let repo = _repoPathStampTarget(fileManager: fileManager) {
        return repo.appendingPathComponent("data", isDirectory: true)
    }

    return applicationSupportDataRoot()
}

/// Configuration paths keep literal whitespace and `~`, without home expansion.
public func literalFileURL(_ path: String) -> URL {
    var components = URLComponents()
    components.scheme = "file"
    components.path = path
    return components.url ?? URL(fileURLWithPath: path)
}

/// Derive persona placement from the supplied data root so every caller uses the same selected root. Checkout data keeps persona beside it; other roots contain
/// persona.
public func defaultPersonaRoot(
    dataRoot: URL = defaultDataRoot(),
    fileManager: FileManager = .default
) -> URL {
    if let repo = resolveSandboxRepoRoot(dataRoot: dataRoot, fileManager: fileManager) {
        return repo.appendingPathComponent("persona", isDirectory: true)
    }
    return dataRoot.appendingPathComponent("persona", isDirectory: true)
}

/// Launch preflight: missing roots, one line each; empty means none missing. Public first runs are expected to be blank and do not call this.
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
        missing.append("""
            REPO_PATH names \(stamp.text), which is not a NativeAgent checkout (missing, or without Package.swift, script/init_persona.sh and \
            persona/SOUL.template.md), so the app would start on \(dataRoot.path)
            """ + tail)
    } else if let stamp, !fileManager.fileExists(atPath: dataRoot.path) {
        missing.append("""
            data/ is missing: REPO_PATH names \(stamp.text), which has no data/ folder, so the app would start on \(dataRoot.path), which does not \
            exist.
            """)
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

/// Share the bare Application Support root without creating it or adding a data suffix.
public func applicationSupportDataRoot(
    appBundleIdentifier: String? = currentAppBundleIdentifier()
) -> URL {
    let folder = appSupportFolderName(for: appBundleIdentifier)
    return URL.applicationSupportDirectory.appendingPathComponent(folder, isDirectory: true)
}

/// The canonical public install's Application Support identity must never move.
public let canonicalPublicBundleIdentifier = "io.github.embwl0x.nativeagent.mac"

/// Non-bundle processes share the canonical folder; other app bundle ids select separate storage.
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
    // A bundle id is dot-separated reverse-DNS, but it is not guaranteed to be, and this becomes a single path component.
    let safe = identifier.map { $0 == "/" || $0 == ":" ? "-" : $0 }
    return "NativeAgent-" + String(safe)
}

/// Stamp presence distinguishes development bundles; unreadable text remains empty for launch validation.
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

/// Canonicalize the stamped checkout without validating existence; launch owns that failure, and an empty stamp names root.
private func _repoPathStampTarget(
    fileManager: FileManager
) -> URL? {
    guard let stamp = _repoPathStampFile(fileManager: fileManager) else {
        return nil
    }
    return URL(fileURLWithPath: stamp.text.isEmpty ? "/" : stamp.text).resolvingSymlinksInPath()
}

/// Launch validation and sandbox resolution require the same three repository markers.
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

/// Sandbox access requires a proven repository parent; an app data root cannot grant its entire Application Support parent.
public func resolveSandboxRepoRoot(
    dataRoot: URL = defaultDataRoot(),
    fileManager: FileManager = .default
) -> URL? {
    let parent = dataRoot.deletingLastPathComponent()
    // Defensive: a root-level or empty parent ("/" or "") is never a repo.
    if parent.path.isEmpty || parent.path == "/" { return nil }
    // Refuse the Application Support parent even if marker files are present; it can never be repository authority.
    if parent.lastPathComponent == "Application Support"
        || parent.path.hasSuffix("/Library/Application Support") {
        return nil
    }
    guard isValidRepoRootDir(parent, fileManager: fileManager) else { return nil }
    return parent
}

extension DataRootLife {
    public static func life(of stamp: JSONValue?) -> String {
        if case .string(let id)? = stamp { return id }
        return first
    }
}
