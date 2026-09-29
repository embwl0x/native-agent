// Phase 11c: Centralised data-root resolver so all Swift-side writes
// (logs, macctl_bridge.json, browser_ipc.json/browser_ipc_token) go to <repo>/data/
// rather than the legacy ~/Library/Application Support/NativeAgent/ path.
//
// One rule per kind of process, owned by PersistenceCore.defaultDataRoot:
//   - NATIVE_AGENT_DATA_ROOT env var (tests / explicit override)
//   - <REPO_PATH stamp>/data/ for a dev bundle
//   - Application Support for the public release

import Foundation
import PersistenceCore

enum NativeAgentPaths {
    private static let publicReleaseDataMarker = "public_release_data_root.json"

    enum PublicReleaseDataRootPreparationResult {
        case notNeeded
        case prepared(String)
        case failed(String)
    }

    /// Delegates to the canonical process cache so app and Core share one
    /// resolution (B6, 2026-07-17: two resolvers used to split-root).
    static var dataRoot: URL {
        PersistenceCore.defaultDataRoot()
    }

    static func bridgeConfigRoot(dataRoot: URL) -> URL {
        InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot)
    }

    /// The standard Application Support data root — the only non-env root a
    /// public-release bundle may use, and the root the blank-slate quarantine
    /// operates on.
    /// 2026-09-17: DERIVED from Core's resolver rather than spelled out again.
    /// Core now suffixes the folder with the bundle id for any install that is
    /// not the canonical public one, so a second copy of the rule here — which
    /// still said plain "NativeAgent" — made the app and Core disagree about
    /// where this install's data lives. One rule, one place.
    static let applicationSupportDataRoot: URL =
        PersistenceCore.libraryAppSupportFallback().standardizedFileURL

    /// Public DMG builds must not silently inherit developer/test credentials
    /// left in the standard Application Support data root by a pre-release
    /// install. On first public-release launch, back up any pre-marker local
    /// data to a sibling folder and leave `dataRoot` empty for onboarding.
    ///
    /// Future upgrades preserve user data because the marker is written during
    /// the first public-release launch.
    @discardableResult
    static func preparePublicReleaseDataRootIfNeeded() -> PublicReleaseDataRootPreparationResult {
        let fm = FileManager.default
        // Round 3: empty env = unset (Core resolver parity).
        guard (ProcessInfo.processInfo.environment["NATIVE_AGENT_DATA_ROOT"] ?? "").isEmpty else { return .notNeeded }
        guard isPublicReleaseBundle else { return .notNeeded }

        let support = applicationSupportDataRoot
        let root = dataRoot.standardizedFileURL
        guard root.path == support.path else { return .notNeeded }

        let marker = root
            .appendingPathComponent("install", isDirectory: true)
            .appendingPathComponent(publicReleaseDataMarker)
        if fm.fileExists(atPath: marker.path) {
            return .notNeeded
        }

        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let existing = try fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )

            var backupURL: URL?
            if !existing.isEmpty {
                let backup = root.deletingLastPathComponent()
                    .appendingPathComponent("\(InstallPaths.current.name("NativeAgent")).pre-public-backup.\(Self.utcBackupStamp())", isDirectory: true)
                try fm.moveItem(at: root, to: backup)
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
                backupURL = backup
            }

            try fm.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            var payload: [String: Any] = [
                "markerVersion": 1,
                "channel": "public-release",
                "createdAt": ISO8601DateFormatter().string(from: Date()),
                "reason": "public_release_blank_slate_first_run",
                "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
                "bundleVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                "bundleShortVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            ]
            if let resourcesURL = Bundle.main.resourceURL,
               let buildSHA = try? String(
                contentsOf: resourcesURL.appendingPathComponent("VERSION_SHA"),
                encoding: .utf8
               ).trimmingCharacters(in: .whitespacesAndNewlines),
               !buildSHA.isEmpty {
                payload["buildSHA"] = buildSHA
            }
            if let backupURL {
                payload["backupPath"] = backupURL.path
            }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: marker, options: [.atomic])
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)

            if let backupURL {
                let message = "[paths] public release first run: backed up existing NativeAgent data to \(backupURL.path)"
                print(message)
                return .prepared(message)
            }
            let message = "[paths] public release first run: initialized blank data root at \(root.path)"
            print(message)
            return .prepared(message)
        } catch {
            let message = "[paths] public release first-run blank-slate preparation failed: \(error.localizedDescription)"
            print(message)
            return .failed(message)
        }
    }

    /// The persona root for `dataRoot`, from the one canonical rule.
    static var personaRoot: URL {
        PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
    }

    /// C5 fix: expose stamp validation as a public static method so
    /// DaemonProcessController (and any other caller that reads REPO_PATH)
    /// can validate the stamp before trusting it as a CLI argument to a child
    /// process — preventing a tampered stamp from redirecting the repo root to
    /// an arbitrary path.
    ///
    /// Returns the validated URL on success, nil if the stamp is invalid.
    static func validateStampedPath(_ url: URL) -> URL? {
        return isValidRepoStamp(url) ? url : nil
    }

    /// Phase 12 audit hardening (revised Phase 13): validate that a REPO_PATH
    /// stamp points at a NativeAgent source repo before trusting it.
    ///
    /// Phase 13 fix: use the CANONICAL (resolved) path for all marker checks,
    /// mirroring Python's Path.resolve(strict=True) semantics.  The previous
    /// approach compared resolvingSymlinksInPath() to standardizedFileURL and
    /// rejected stamps that differed — this caused false-positives on macOS
    /// where /var is a symlink to /private/var.  A stamp written as
    /// "/var/folders/…" would fail even though it is a legitimate system path.
    ///
    /// Marker list (sync with _repo_paths.py::REPO_MARKER_FILES):
    ///   - persona/SOUL.template.md
    ///   - script/init_persona.sh
    ///   - the retired daemon
    private static func isValidRepoStamp(_ url: URL) -> Bool {
        let fm = FileManager.default
        // Resolve canonical path (follows all symlinks, including /var → /private/var).
        let canonical = url.resolvingSymlinksInPath()
        guard fm.fileExists(atPath: canonical.path) else { return false }
        // Marker files must all exist on the canonical path.
        // Sync marker list with the retired daemon::REPO_MARKER_FILES.
        let markers = [
            "persona/SOUL.template.md",
            "script/init_persona.sh",
            "Package.swift",
        ]
        for marker in markers {
            let m = canonical.appendingPathComponent(marker)
            if !fm.fileExists(atPath: m.path) { return false }
        }
        return true
    }

    /// True only for a distributed public build: no REPO_PATH dev stamp, a real
    /// .app bundle, and a VERSION resource. Dev installs from install_app.sh are
    /// always stamped, so they can never read as public-release. Gates blank-slate
    /// data-root preparation and the first-run welcome greeting.
    static let isPublicReleaseBundle: Bool = {
        let fm = FileManager.default
        guard let resourcesURL = Bundle.main.resourceURL else { return false }
        if fm.fileExists(atPath: resourcesURL.appendingPathComponent("REPO_PATH").path) {
            return false
        }
        guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
        return fm.fileExists(atPath: resourcesURL.appendingPathComponent("VERSION").path)
    }()

    private static func utcBackupStamp() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: Date())
    }
}
