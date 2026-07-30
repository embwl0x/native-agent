// Phase 11c: Centralised data-root resolver so all Swift-side writes
// (logs, macctl_bridge.json, browser_ipc.json/browser_ipc_token) go to <repo>/data/
// rather than the legacy ~/Library/Application Support/NativeAgent/ path.
//
// Resolution priority (mirrors native_agentd._resolve_data_root):
//   1. NATIVE_AGENT_DATA_ROOT env var (test / explicit override)
//   2. <REPO_PATH stamp>/data/ when running from the installed .app bundle
//   3. ~/Library/Application Support/NativeAgent/ (public release fallback)

import Foundation
import PersistenceCore

enum NativeAgentPaths {
    private static let publicReleaseDataMarker = "public_release_data_root.json"

    enum PublicReleaseDataRootPreparationResult {
        case notNeeded
        case prepared(String)
        case failed(String)
    }

    /// B6 (tightness-sweep 2026-07-17): this used to be a `static let` that
    /// hand-rolled its own env → stamp → AppSupport precedence, independently
    /// of `PersistenceCore.defaultDataRoot()` (which implements the same chain,
    /// plus a dev CWD-walkup step). Two resolvers computing the "same" root
    /// separately could split-root: an early first access here — before the
    /// REPO_PATH stamp is readable — would permanently cache the AppSupport
    /// fallback while the Core resolver later resolved the repo root, silently
    /// sending Swift-side writes to two different `data/` roots.
    ///
    /// It is now a thin delegating computed property over the single canonical
    /// resolver. Making it a computed `var` also kills the cache hazard from
    /// the N10 note below: there is no resolved-once value to poison. The
    /// resolver is cheap (a handful of `fileExists` probes) so recomputing per
    /// access — there are ~22 read sites — is not a hot-path concern.
    static var dataRoot: URL {
        // Review round 2 (HIGH): an unstamped PUBLIC-RELEASE bundle must never
        // adopt a repo data root found by the resolver's dev CWD walk — that
        // would read a private checkout's data/ AND bypass the blank-slate
        // quarantine below, which only runs when the root is the AppSupport
        // one. A public bundle has no REPO_PATH stamp by definition
        // (isPublicReleaseBundle checks that), so its only legitimate roots
        // are the env override or AppSupport. Stamped dev installs are
        // unaffected — isPublicReleaseBundle is false for them.
        // Round 3: match the Core resolver's env semantics exactly — an EMPTY
        // NATIVE_AGENT_DATA_ROOT is "unset" there, so it must be "unset" here
        // too, or an empty-env public launch would skip both the pin and the
        // quarantine while Core still resolves its own way.
        if isPublicReleaseBundle,
           (ProcessInfo.processInfo.environment["NATIVE_AGENT_DATA_ROOT"] ?? "").isEmpty {
            return applicationSupportDataRoot
        }
        return PersistenceCore.defaultDataRoot()
    }

    /// The standard Application Support data root — the only non-env root a
    /// public-release bundle may use, and the root the blank-slate quarantine
    /// operates on.
    static var applicationSupportDataRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NativeAgent", isDirectory: true)
            .standardizedFileURL
    }

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
                    .appendingPathComponent("NativeAgent.pre-public-backup.\(Self.utcBackupStamp())", isDirectory: true)
                try fm.createDirectory(at: backup, withIntermediateDirectories: true)
                for item in existing {
                    try fm.moveItem(at: item, to: backup.appendingPathComponent(item.lastPathComponent))
                }
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

    /// BUG-C FIX: persona-root resolver mirroring daemon
    /// `_resolve_persona_root` so Swift and
    /// Python both read/write the SAME persona docs (SOUL.md, VOICE.md,
    /// GROWTH.md, USER.md). The earlier BackgroundLoopsAssembly hardcoded
    /// `<dataRoot>/persona`, which silently diverged from the daemon
    /// whenever `NATIVE_AGENT_PERSONA_ROOT` was set or when running from a
    /// stamped bundle that put persona/ in a sibling repo dir, not under
    /// data/. REM cycle in Swift then mutated a phantom persona dir the
    /// daemon never read.
    ///
    /// Resolution priority (sync with daemon `_resolve_persona_root`):
    ///   1. `NATIVE_AGENT_PERSONA_ROOT` env var
    ///   2. `<stamped_repo>/persona` if REPO_PATH stamp is readable AND
    ///      `<stamped_repo>/persona` exists
    ///   3. `<dataRoot>/memory` legacy fallback (mirrors daemon final
    ///      fallback `_resolve_data_root() / "memory"`)
    ///
    /// Note: the daemon also has a step 3 ("`<repo_root>/persona`" from
    /// `Path(__file__).parent.parent`) for dev runs from source. Swift
    /// has no equivalent of `Path(__file__)` — the dev case is covered by
    /// the stamped bundle path or by the env-var override, which is what
    /// dev launchers already use. The legacy fallback differs intentionally
    /// from `dataRoot`'s fallback (memory/ vs the data dir itself) to
    /// match daemon behavior byte-for-byte.
    /// B6 (tightness-sweep 2026-07-17): delegates to the single canonical
    /// resolver, same rationale as `dataRoot` above. For the installed
    /// (stamped) app both the old hand-rolled chain and
    /// `PersistenceCore.defaultPersonaRoot()` resolve to `<repo>/persona`
    /// (where SOUL.md lives); the Core resolver is strictly more correct in the
    /// no-stamp dev/test case, where it finds `<repo>/persona` via the
    /// SOUL.md-anchored repo walk instead of the old `<dataRoot>/memory`
    /// cold-start fallback. One resolver, no split-root.
    static var personaRoot: URL {
        // Pass OUR guarded dataRoot (not the resolver's default) so a public
        // bundle's persona chain is confined to the AppSupport root too — the
        // persona resolver keys its sandbox/dev fallbacks off the dataRoot it
        // is given (review round 2, same class as the dataRoot HIGH).
        PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
    }

    /// Pure resolver used by tests that need to assert daemon-parity for a
    /// hypothetical dataRoot without touching the cached `personaRoot`
    /// `static let`. Mirrors the same precedence chain.
    static func resolvePersonaRoot(dataRoot: URL, env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        // B6: delegate to the single canonical resolver rather than hand-rolling
        // a second (now-divergent) precedence chain.
        PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot, environment: env)
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
    static var isPublicReleaseBundle: Bool {
        let fm = FileManager.default
        guard let resourcesURL = Bundle.main.resourceURL else { return false }
        if fm.fileExists(atPath: resourcesURL.appendingPathComponent("REPO_PATH").path) {
            return false
        }
        guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
        return fm.fileExists(atPath: resourcesURL.appendingPathComponent("VERSION").path)
    }

    private static func utcBackupStamp() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: Date())
    }
}
