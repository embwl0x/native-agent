import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - PersonaRoot resolution contract (Fix 1 — canonical path FIRST)
//
// Resolution order (priority high → low):
//   1. `<dataRoot>/persona/Agent/` — optional fully seeded installed-app
//      persona root. Wins only when SOUL.md exists there. A lone generated
//      USER.md never makes this directory active.
//   2. `NATIVE_AGENT_PERSONA_ROOT` env override — for dev / CI overrides.
//   3. `<stamped_repo>/persona/Agent/` — stamped REPO_PATH from the running
//      bundle; used as SEED on first install when dataRoot is empty.
//   4. `<dev_repo>/persona/` — dev repo fallback (git checkout, Package.swift
//      marker present, NOT inside a .app bundle).
//
// LITERAL-TILDE GOTCHA: see existing comment below in PersonaRootResolver.

// MARK: - Errors

public enum PersonaEngineError: Error, LocalizedError {
    case rootUnreadable(reason: String)
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .rootUnreadable(let r): return "persona root unreadable: \(r)"
        case .underlying(let m): return m
        }
    }
}

// MARK: - PersonaDoc

/// A single persona doc loaded from disk. Read-only — mutation of persona
/// docs is out of scope for subsystem #5a (USER.md cap, GROWTH.md cap,
/// REM-cycle writes, and memory consolidation are deliberately carved out
/// for subsystems #10 DreamREMCycle and #11 SelfImprovement).
///
/// `id` is the filename without the `.md` suffix (e.g. `SOUL`, `VOICE`,
/// `SOUL.template`). `sizeBytes` is the UTF-8 byte length of `content` —
/// always equal to the file size on disk for well-formed UTF-8 markdown.
/// `mtime` is the filesystem modification time at read-time.
public struct PersonaDoc: Sendable, Equatable, Codable {
    public let id: String
    public let content: String
    public let sizeBytes: Int
    public let mtime: Date

    public init(id: String, content: String, sizeBytes: Int, mtime: Date) {
        self.id = id
        self.content = content
        self.sizeBytes = sizeBytes
        self.mtime = mtime
    }
}

// MARK: - Persona-root resolver
//
// Mirrors the retired daemon `_resolve_persona_root()` in
// priority order:
//   1. NATIVE_AGENT_PERSONA_ROOT env var (LITERAL — no `~` expansion).
//   2. <stamped_repo>/persona/ if Resources/REPO_PATH is stamped (installed
//      bundle path), provided the dir exists.
//   3. <repo_root>/persona/ if it exists AND is NOT inside a `.app` bundle
//      (Python: `_path_inside_app_bundle` guard — prevents the first-run
//      onboarding break where SOUL.md silently auto-creates inside the
//      read-only signed bundle).
//   4. <data_root>/memory/ legacy fallback.
//
// LITERAL-TILDE GOTCHA (production bug already paid for in
// `PersistenceCore.defaultDataRoot`): every
// `URL(fileURLWithPath:)` / `URL(fileURLWithFileSystemRepresentation:)`
// variant silently expands a leading `~`. Python's `Path(env)` does NOT.
// The only Foundation constructor that preserves the literal tilde is
// `URLComponents(scheme: "file", path: raw)` — that path bypasses the
// implicit tilde expansion entirely. The env-var branch below MUST use
// the URLComponents path; this is pinned by
// `resolvePersonaRoot_envVar_preserves_literal_tilde`.

public enum PersonaRootResolver {
    /// Resolve persona strictly inside an injected data root.
    ///
    /// Secondary runtimes and hermetic tests must not fall through to the
    /// process environment, a stamped repository, or the developer checkout:
    /// those are production seed sources and can expose the personal persona
    /// to an otherwise isolated body. A valid identity subdirectory still
    /// requires SOUL.md; otherwise the isolated parent is returned.
    public static func resolveIsolated(
        dataRoot: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let parent = dataRoot.standardizedFileURL
            .appendingPathComponent("persona", isDirectory: true)
        return firstPersonaSubdirWithSoul(in: parent, fileManager: fileManager) ?? parent
    }

    /// Resolve the persona root using the 4-step priority chain. `fileManager`
    /// + `environment` are injectable so tests can pin behavior without
    /// touching ProcessInfo / the real filesystem.
    public static func resolve(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        repoRoot: URL? = nil,
        bundleBases: [URL]? = nil,
        dataRootProvider: () -> URL = { PersistenceCore.defaultDataRoot() }
    ) -> URL {
        let dataRoot = dataRootProvider()

        // Step 1 — optional installed-app identity subdir:
        // <dataRoot>/persona/<identity>/. Wins only when SOUL.md exists there —
        // SOUL.md is the identity-doc marker.
        //
        // HOTFIX 2026-06-03, kept after the 2026-06-18 USER.md cleanup:
        // this previously matched on ANY marker, including a lone USER.md.
        // USER.md is a generated memory projection, not an identity-root
        // marker. SOUL.md is the identity doc, so requiring it here prevents
        // a partial persona dir from silently winning over the real root.
        let canonicalParent = dataRoot.appendingPathComponent("persona", isDirectory: true)
        if let canonicalDir = firstPersonaSubdirWithSoul(in: canonicalParent, fileManager: fileManager) {
            return canonicalDir
        }
        if fileManager.fileExists(
            atPath: canonicalParent.appendingPathComponent("SOUL.md").path
        ) {
            return canonicalParent
        }

        // Step 2 — env var override (dev / CI). Accepted as LITERAL path;
        // no `~` expansion (see tilde gotcha note at top of file).
        if let raw = environment["NATIVE_AGENT_PERSONA_ROOT"], !raw.isEmpty {
            var components = URLComponents()
            components.scheme = "file"
            components.path = raw
            if let url = components.url {
                return url
            }
            // Defensive fallback — accepts the tilde-expansion divergence
            // rather than crashing on a malformed path.
            return URL(fileURLWithPath: raw)
        }

        // Step 3 — stamped REPO_PATH from the running bundle: seed source
        // when the canonical dataRoot dir is empty (first install). Prefer
        // <stamped_repo>/persona/<identity>/ only when it has SOUL.md; some legacy
        // checkouts have identity subdirs as notes-only storage, and accepting
        // that empty identity dir makes first-run onboarding reopen even though
        // the real Agent docs live at <stamped_repo>/persona/.
        if let stamped = stampedRepoFromBundle(fileManager: fileManager, bundleBases: bundleBases) {
            let personaParent = stamped.appendingPathComponent("persona", isDirectory: true)
            if let personaDir = firstPersonaSubdirWithSoul(in: personaParent, fileManager: fileManager) {
                return personaDir
            }
            // Fallback to stamped/persona/ (without Agent subdir) for legacy layouts.
            let personaDirLegacy = personaParent
            if fileManager.fileExists(atPath: personaDirLegacy.path) {
                return personaDirLegacy
            }
        }

        // Step 4 — repo_root/persona/, IF it exists AND is NOT inside a `.app`
        // bundle. `repoRoot` is injectable for tests.
        let resolvedRepo = repoRoot ?? findRepoRoot(fileManager: fileManager)
        if let repo = resolvedRepo {
            let personaDir = repo.appendingPathComponent("persona", isDirectory: true)
            if fileManager.fileExists(atPath: personaDir.path)
                && !pathInsideAppBundle(personaDir) {
                return personaDir
            }
        }

        // Final fallback: return the canonical location even if empty.
        // Callers handle an empty/missing directory gracefully.
        return canonicalParent
    }

    // MARK: - helpers

    /// `<App>.app/Contents/...` detector — matches the retired
    /// `_path_inside_app_bundle` at the retired daemon.
    /// Public for test access; not part of the migration API.
    public static func pathInsideAppBundle(_ candidate: URL) -> Bool {
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

    private static func firstPersonaSubdirWithSoul(in parent: URL, fileManager: FileManager) -> URL? {
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

    /// Walk up from CWD looking for a directory containing `Package.swift`.
    /// Returns nil if no match is found. Used as a dev fallback when no
    /// explicit `repoRoot` is injected.
    ///
    /// DAEMON KILLED 2026-06-02: was an `&& exists`
    /// check; that file is gone. Package.swift alone is the dev-repo marker
    /// now, mirroring NativeAgentPaths.isValidRepoStamp and the matching fix
    /// in PersistenceCore (commit 8c10fcc8). Without this fix the persona
    /// root resolver silently falls through to `<dataRoot>/memory`.
    private static func findRepoRoot(fileManager: FileManager) -> URL? {
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        var dir = cwd
        for _ in 0..<8 {
            let pkg = dir.appendingPathComponent("Package.swift")
            if fileManager.fileExists(atPath: pkg.path) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    /// Marker files that prove a stamped REPO_PATH target is a real
    /// NativeAgent source repo. MUST stay in sync with:
    ///   - the retired daemon::REPO_MARKER_FILES
    ///   - PersistenceCore's private `repoMarkerFiles`
    ///   - Sources/NativeAgentApp/NativeAgentPaths.swift::isValidRepoStamp
    /// Without this validation, a stale/tampered stamp pointing at any
    /// directory that happens to have a `persona/` subdir would be
    /// silently accepted — Python rejects via `_validate_stamped_repo_path`
    /// and falls through to step 3.
    private static let repoMarkerFiles: [String] = [
        "persona/SOUL.template.md",
        "script/init_persona.sh",
        // DAEMON KILLED 2026-06-02: was "the retired daemon". Replaced
        // with Package.swift so bundle-stamp validation still passes after
        // the daemon was deleted (matches PersistenceCore commit 8c10fcc8).
        // Without this, _stampedRepoFromBundle returns nil → persona root
        // falls through to legacy `<dataRoot>/memory`.
        "Package.swift",
    ]

    /// Mirrors PersistenceCore's `_stampedRepoFromBundle` — reads a `REPO_PATH`
    /// stamp file inside Bundle.main's Resources hierarchy and returns the
    /// canonicalized target IFF all `repoMarkerFiles` are present (matches
    /// Python's `_validate_stamped_repo_path`). Returns nil outside a
    /// stamped bundle (dev, `swift test` runner) OR when the stamp target
    /// fails marker validation.
    private static func stampedRepoFromBundle(
        fileManager: FileManager,
        bundleBases: [URL]? = nil
    ) -> URL? {
        let bases: [URL]
        if let injected = bundleBases {
            bases = injected
        } else {
            let main = Bundle.main
            var defaults: [URL] = []
            if let res = main.resourceURL { defaults.append(res) }
            defaults.append(main.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true))
            defaults.append(main.bundleURL)
            bases = defaults
        }
        for base in bases {
            let stamp = base.appendingPathComponent("REPO_PATH")
            guard fileManager.fileExists(atPath: stamp.path) else { continue }
            guard let data = try? Data(contentsOf: stamp) else { continue }
            guard let text = String(data: data, encoding: .utf8) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let canonical = URL(fileURLWithPath: trimmed).resolvingSymlinksInPath()
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
}

// MARK: - Protocol

public protocol PersonaEngineProtocol: Sendable {
    /// All persona docs in the root, sorted by id ASC for determinism.
    func listPersonaDocs() async throws -> [PersonaDoc]
    /// Convenience accessor by id (filename without `.md`).
    func getPersonaDoc(id: String) async throws -> PersonaDoc?
}

// MARK: - WRITE protocol (wave 33 W06)
//
// The native write impls landed wave-32 W19 on `SwiftNativePersonaEngine`
// (PersonaEngine+Writes.swift) but were NOT on any protocol, so
// `makePersonaEngine(runtime:)` callers could not reach them through the
// factory — NativeClient had to either instantiate the concrete actor directly
// (asymmetric with every other gated subsystem) or stay HTTP-only.
//
// The write methods are deliberately a SEPARATE protocol, not added to
// `PersonaEngineProtocol`. The base read protocol is consumed by
// ChatOrchestration's TurnEngine (`persona: any PersonaEngineProtocol`) purely
// to compile the persona into a chat turn — a READ-ONLY consumer. Polluting
// that contract with write methods would force every read-only consumer (and
// every chat-path test stub) to implement persona WRITES it never calls. The
// factory therefore returns a type that conforms to BOTH protocols, and the
// NativeClient write gate refines to `PersonaEngineWriting` via the dedicated
// `makePersonaEngineWriter(runtime:)` factory.
public protocol PersonaEngineWriting: Sendable {
    /// POST /v1/personality — merge `body` over the current profile, normalize,
    /// atomically write `<dataRoot>/memory/profile.json` under a cross-process
    /// flock. Returns the fully-normalized persisted profile. Mirrors the
    /// daemon `save_personality`.
    func savePersonality(body: [String: JSONValue]) async throws -> CompiledPersonalityProfile

    /// POST /v1/personality/docs — onboarding-gated atomic write of a fixed
    /// persona doc (SOUL/VOICE/GROWTH/AGENTS) under a cross-process flock.
    /// USER.md is read-only here because MemoryV2 owns that projection. Returns
    /// the `{**spec, path, content, updatedAt}` wire shape. Throws
    /// `PersonaWriteError.onboardingRequired` pre-onboarding, `.unknownDocument`
    /// for an id outside the fixed set, and `.invalidInput` for USER.
    func savePersonalityDoc(id: String, content: String) async throws -> PersonaDocSpec

    /// Mirror of the daemon's `personality_doc_contents(create_missing=True)`
    /// PERSISTENCE behaviour: once SOUL.md
    /// exists (the "persona is initialized" sentinel), any MISSING mutable fixed
    /// doc (VOICE/GROWTH/AGENTS) is atomically WRITTEN to disk with its
    /// `default_personality_doc_content` body, parameterized by the user's
    /// profile.json. USER is skipped because MemoryV2 regenerates USER.md from
    /// SQLite; persona scaffolding must not create a second source of truth.
    /// The READ path (`listPersonaDocSpecs`) only renders these
    /// defaults in-memory (updatedAt nil); this method actually persists them,
    /// closing the wave-33 W19 "missing-doc default value persistence" gap —
    /// without it, a flipped write subsystem would surface defaults forever but
    /// never durably create the files (so a later daemon read would re-scaffold,
    /// reintroducing the split-writer race). Pre-onboarding (SOUL.md absent) it
    /// is a NO-OP so the first-run wizard still renders. Each write is held
    /// under the same per-doc `<path>.lock` cross-process flock the route write
    /// uses. Returns the ids that were newly persisted (empty if none).
    @discardableResult
    func scaffoldMissingDocs() async throws -> [String]

    // MARK: - Growth + Voice MUTATION writers (wave 35 W13)
    //
    // Native twins of the three persona-MUTATION writers wave-34 W02 flocked on
    // the Python side. They are the GROWTH-append + voice/section doc-mutation
    // surfaces that, until now, had ONLY a Python impl -- the wave-32 W19
    // savePersonality/savePersonalityDoc ports covered the two HTTP routes but
    // NOT the agent-tool persona_write/persona_append_section nor the structured
    // append_personality_growth journal append. With all three now flock-symmetric
    // on disk (<path>.lock), the native side closes the coverage gap so
    // .personaEngineWrites has a native impl for every persona-file writer the
    // daemon exposes. DORMANT: no NativeClient seam routes through these yet.

    /// Mirror of `Runtime.append_personality_growth(kind, text, source_run_id)`
    ///: append one structured journal line to
    /// GROWTH.md. Word-collapses + caps `text` at 1000 CODE POINTS, NO-OPs on
    /// empty cleaned text, enforces the SOUL.md onboarding gate (pre-onboarding
    /// -> silent NO-OP), scaffolds a missing GROWTH.md from
    /// `default_personality_doc_content` BEFORE the append, and holds the whole
    /// read-scaffold-append under a cross-process flock on GROWTH.md. Returns
    /// `true` if a line was appended, `false` on the NO-OP paths.
    @discardableResult
    func appendPersonalityGrowth(kind: String, text: String, sourceRunId: String?) async throws -> Bool

    /// Mirror of the agent tool `_exec_persona_write` (builtin_tools.py
    /// L3613-3703): full-doc REPLACE of a persona file with a timestamped
    /// `.pre-<ts>-<uid>.bak` backup of the prior content, atomic temp+rename,
    /// held under a cross-process flock on the target. `kind` is canonicalized
    /// NFKC+strip+lower and must be in {soul,skill,voice,growth,agents};
    /// USER.md is rejected because MemoryV2 owns that projection;
    /// `skillName` is required + validated when kind=skill.
    @discardableResult
    func personaWrite(kind: String, content: String, skillName: String?) async throws -> PersonaToolWriteResult

    /// Mirror of the agent tool `_exec_persona_append_section` (builtin_tools.py
    /// L3948-4038): append `\n\n## <title>\n<content>` to a persona file
    /// (after `existing.rstrip()`), with a timestamped backup, atomic temp+rename,
    /// held under a cross-process flock. `kind` must be in
    /// {soul,voice,growth,agents} (NO skill, no USER); `title` non-empty after strip.
    @discardableResult
    func personaAppendSection(kind: String, title: String, content: String) async throws -> PersonaToolWriteResult
}

/// Result of a `personaWrite` / `personaAppendSection` mutation, mirroring the
/// daemon tool's `{ok, kind, path, backup_path, bytes_*}` dict. `bytesWritten`
/// carries the full-file byte count for a replace; `bytesAppended` the appended
/// section byte count for an append (the other is `nil`).
public struct PersonaToolWriteResult: Sendable, Equatable {
    public let kind: String
    public let path: String
    public let backupPath: String?
    public let bytesWritten: Int?
    public let bytesAppended: Int?

    public init(kind: String, path: String, backupPath: String?, bytesWritten: Int?, bytesAppended: Int?) {
        self.kind = kind
        self.path = path
        self.backupPath = backupPath
        self.bytesWritten = bytesWritten
        self.bytesAppended = bytesAppended
    }
}

// MARK: - SwiftNative impl

/// Read-only persona doc loader.
///
/// HARD SCOPE CARVE-OUT — Swift impl deliberately does NOT do:
///   - any write/mutation (USER.md cap eviction, GROWTH.md size cap,
///     REM-cycle writes, memory consolidation) — those stay with the
///     daemon and migrate as part of subsystems #10 (DreamREMCycle) and
///     #11 (SelfImprovement).
///   - hot-reload watching. Instantiating a new engine re-reads the dir;
///     long-lived engines see a snapshot from first read. Deferred to a
///     future phase if cache-invalidation pressure surfaces.
///   - REM-pin retrieval / pinned-doc subset selection — that belongs to
///     subsystem #10.
///
/// `actor` isolation makes the lazy-resolver-cache field safe across
/// concurrent calls. File IO inside actor methods does block the actor
/// thread briefly, but persona dirs are small (single-digit MB at most)
/// so it isn't worth detaching.
public actor SwiftNativePersonaEngine: PersonaEngineProtocol, PersonaEngineWriting {
    private let root: URL
    private let fileManager: FileManager
    /// Data root used to resolve `<dataRoot>/memory/profile.json` when
    /// rendering personality-doc defaults. Defaults to the same path the
    /// daemon uses; tests pass a temp dir to seed a custom profile.
    private let dataRoot: URL

    public init(
        root: URL = PersonaRootResolver.resolve(),
        fileManager: FileManager = .default,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) {
        self.root = root
        self.fileManager = fileManager
        self.dataRoot = dataRoot
    }

    /// Persona engine for an injected/secondary body. Unlike the default
    /// initializer this cannot consult environment, bundle, or checkout seed
    /// roots when the injected persona is absent.
    public static func isolated(dataRoot: URL) -> SwiftNativePersonaEngine {
        SwiftNativePersonaEngine(
            root: PersonaRootResolver.resolveIsolated(dataRoot: dataRoot),
            dataRoot: dataRoot
        )
    }

    public var personaRoot: URL { root }

    /// Data root used to resolve `<dataRoot>/memory/profile.json` for the
    /// write-side `savePersonality` path (PersonaEngine+Writes.swift). Exposed
    /// so the write extension can locate the profile file the daemon's
    /// `personality_path()` points at.
    public var dataRootURL: URL { dataRoot }

    public func listPersonaDocs() async throws -> [PersonaDoc] {
        // Missing root → empty list (matches Python's behavior when the
        // resolver lands on a nonexistent legacy fallback).
        guard fileManager.fileExists(atPath: root.path) else { return [] }

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
        } catch {
            throw PersonaEngineError.rootUnreadable(reason: error.localizedDescription)
        }

        var docs: [PersonaDoc] = []
        for entry in entries {
            let name = entry.lastPathComponent
            // Filter rules — mirror the daemon's "persona doc" intent:
            //   - must end with `.md` (case-sensitive — matches Python's
            //     `glob("*.md")` behavior on case-sensitive FS, and the
            //     daemon's `Path.suffix == ".md"` check).
            //   - skip `.bak` backup files. `USER.md.bak`, `SOUL.md.pre-...bak`
            //     etc. are the rollback backups the daemon writes pre-cap.
            //   - skip dotfiles (.DS_Store etc.) — also caught by
            //     skipsHiddenFiles but defended here too.
            //   - skip anything inside subdirs (skipsSubdirectoryDescendants
            //     handles this above).
            //   - template.md files (SOUL.template.md) ARE included — the
            //     daemon treats them as part of the persona surface for
            //     first-run onboarding.
            guard name.hasSuffix(".md") else { continue }
            if name.hasPrefix(".") { continue }
            if name.contains(".bak") { continue }
            // Resource values for size + mtime.
            guard let values = try? entry.resourceValues(
                forKeys: [.isRegularFileKey, .contentModificationDateKey]
            ),
                  values.isRegularFile == true else { continue }

            let content: String
            do {
                content = try String(contentsOf: entry, encoding: .utf8)
            } catch {
                // Unreadable file (perms / encoding) — skip silently rather
                // than fail the whole listing. The daemon does the same.
                continue
            }
            let mtime = values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            let bytes = content.utf8.count
            let id = String(name.dropLast(3)) // strip ".md"
            docs.append(PersonaDoc(
                id: id,
                content: content,
                sizeBytes: bytes,
                mtime: mtime
            ))
        }

        docs.sort { $0.id < $1.id }
        return docs
    }

    public func getPersonaDoc(id: String) async throws -> PersonaDoc? {
        let all = try await listPersonaDocs()
        return all.first { $0.id == id }
    }

    // MARK: - Wire-shape adapter for /v1/personality/docs
    //
    // Daemon parity:
    // ALWAYS returns one entry per fixed spec id (SOUL/VOICE/GROWTH/USER/
    // AGENTS) — never a dir-scan. Missing files surface as `content: ""` and
    // `updatedAt: null`, matching `path.exists() ? iso(stat.st_mtime) : None`.
    // Top-level `updatedAt` is the response timestamp (`now_iso()`).
    //
    // The previous implementation delegated to `listPersonaDocs()` (a dir
    // scan), which (a) returned zero rows when the persona dir was empty,
    // (b) returned arbitrary `*.md` rows when extras existed, and (c)
    // computed top-level updatedAt as max(mtime) instead of "now". All
    // three diverged from the daemon contract; the daemon's contract is
    // the source of truth across surfaces.
    public func listPersonaDocSpecs() async throws -> PersonaDocListing {
        // Local helper avoids capturing a non-Sendable ISO8601DateFormatter
        // in the loop body (Swift 6 strict-concurrency would flag sending
        // a class instance into an actor-isolated closure body).
        func isoString(_ d: Date) -> String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return iso.string(from: d)
        }
        // Fixed spec list — matches the retired daemon
        // `personality_doc_specs`. Order is load-bearing (AGENTS last so it
        // lands freshest in the persona prompt).
        let specsFixed: [(id: String, title: String, filename: String)] = [
            ("SOUL",   "Soul",             "SOUL.md"),
            ("VOICE",  "Voice",            "VOICE.md"),
            ("GROWTH", "Growth",           "GROWTH.md"),
            ("USER",   "User",             "USER.md"),
            ("AGENTS", "Operating Manual", "AGENTS.md"),
        ]

        // Once SOUL.md exists (the canonical "persona is initialized"
        // sentinel), missing mutable persona docs return their default content.
        // USER.md is different: it is a MemoryV2 projection. If it is missing,
        // leave it empty until MemoryV2 regenerates it from SQLite.
        let soulURL = root.appendingPathComponent("SOUL.md")
        let soulInitialized = fileManager.fileExists(atPath: soulURL.path)

        var docs: [PersonaDocSpec] = []
        for spec in specsFixed {
            let url = root.appendingPathComponent(spec.filename)
            let exists = fileManager.fileExists(atPath: url.path)
            var content: String = ""
            var updatedAt: String? = nil
            if exists {
                if let body = try? String(contentsOf: url, encoding: .utf8) {
                    content = body
                }
                if let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ),
                   let mtime = values.contentModificationDate {
                    updatedAt = isoString(mtime)
                }
            } else if soulInitialized && spec.id != "SOUL" && spec.id != "USER" {
                // Persona is initialized but this mutable doc is missing.
                // Surface the default content but leave updatedAt nil to signal
                // "this is the default, not a persisted write". USER is skipped
                // because MemoryV2 owns that file.
                content = Self.defaultPersonalityDocContent(
                    id: spec.id,
                    profile: PersonaCompiler.loadProfile(dataRoot: dataRoot)
                )
            }
            docs.append(PersonaDocSpec(
                id: spec.id,
                title: spec.title,
                filename: spec.filename,
                path: url.path,
                content: content,
                updatedAt: updatedAt
            ))
        }
        // Top-level updatedAt: daemon uses `now_iso()` — mirror that exactly.
        return PersonaDocListing(docs: docs, updatedAt: isoString(Date()))
    }

    // MARK: - Bug 4 fix: daemon-default personality doc content
    //
    // Mirrors `default_personality_doc_content(doc_id)` at
    // the retired daemon. The daemon parameterizes the
    // body with the user's loaded personality profile (name, personaKind,
    // essence, voice, examples, forbiddenPatterns). Swift's
    // listPersonaDocSpecs is READ-ONLY and does not load profile.json,
    // so we render with the daemon's `default_personality()` defaults
    // (name="NativeAgent", personaKind="AI", essence/voice/examples from
    // L34989-35033). Tests pin exact-bytes equality between the daemon
    // and Swift forms.
    nonisolated static func defaultPersonalityDocContent(
        id: String,
        profile: CompiledPersonalityProfile = .defaults,
        now: Date = Date()
    ) -> String {
        let name = profile.name
        let personaKind = profile.personaKind
        let essence = profile.essence
        let voice = profile.voice
        // Bug D fix (2026-05-31, 4th-round review): when profile fields
        // are empty, mirror the daemon's exact fallback strings (see
        // the retired daemon in `default_personality_doc_content`):
        // `"- Lead with the useful answer."` for examples and
        // `"- Generic assistant filler."` for forbiddenPatterns.
        // The prior version reached for CompiledPersonalityProfile.defaults
        // which has DIFFERENT multi-line text — drift relative to Python.
        let examplesBody: String
        if profile.examples.isEmpty {
            examplesBody = "- Lead with the useful answer."
        } else {
            examplesBody = profile.examples.map { "- \($0)" }.joined(separator: "\n")
        }
        let forbiddenBody: String
        if profile.forbiddenPatterns.isEmpty {
            forbiddenBody = "- Generic assistant filler."
        } else {
            forbiddenBody = profile.forbiddenPatterns.map { "- \($0)" }.joined(separator: "\n")
        }
        switch id {
        case "SOUL":
            return """
            # \(name) Soul

            ## North Star
            \(essence)

            ## Identity Stance
            - Active mode: \(personaKind).
            - Feel human-presenting when that mode is selected, but stay truthful if directly asked whether you are AI.
            - Do not perform a stereotype. Let identity show through judgment, cadence, continuity, emotional intelligence, and initiative.
            - Be helpful and proactive by default: notice what matters, make the clean call, and move the work forward.

            ## Operating Instincts
            - Prefer useful action over long setup.
            - Keep the user oriented without burying them in process.
            - Absorb pressure calmly when something is broken or confusing.
            - Protect trust: do not claim tool use, file edits, memories, or checks that did not happen.

            """
        case "VOICE":
            return """
            # \(name) Voice

            ## Voice Target
            \(voice)

            ## Cadence
            - Use contractions and natural phrasing where they fit.
            - Vary sentence length so replies do not read like a template.
            - Lead with the real read of the situation, then the next useful action.
            - Keep warmth grounded. No customer-service syrup.

            ## Style Anchors
            \(examplesBody)

            ## Avoid
            \(forbiddenBody)

            """
        case "GROWTH":
            // Bug D fix (2026-05-31, 4th-round review): mirror Python's
            // `now_iso()` stamp in the baseline entry (daemon L34424).
            // Tests tolerate the timestamp via regex match. Uses the
            // same formatter shape as `listPersonaDocSpecs.isoString`.
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let stamp = iso.string(from: now)
            return """
            # \(name) Growth

            This is the living journal for personality corrections, drift notes, and voice improvements.

            ## Entries
            - \(stamp) · baseline · Soul layer initialized for \(personaKind) mode.

            """
        case "USER":
            return """
            # User

            ## Working Relationship
            - The user wants a capable native macOS agent that is simple to use, proactive, safe, and powerful.
            - They value directness, follow-through, autonomy, and real verification over generic reassurance.
            - When they say something feels off, treat it as signal. Diagnose the layer, fix it, and test the result.

            """
        case "AGENTS":
            return """
            # \(name) Operating Manual

            ## Runtime
            - Know the app's available tools, skills, memory layers, provider controls, approvals, and Mac/iOS/Telegram surfaces.
            - Load detailed skill or tool instructions only when the current task needs them.
            - Keep context lean: prefer routed summaries, then look up deeper context on demand.

            ## Capability inventory (this build)
            - Chat surfaces: Mac app, iOS companion (after pairing), Telegram bot (after token wiring).
            - Memory: durable USER.md facts, GROWTH journal, knowledge graph, hybrid BM25 recall.
            - Mac integrations behind Trust: Messages, Notes, Contacts, Calendar, Files, Shortcuts, Spotlight, shell.
            - Connectors (optional, user-configured): chat model providers, embeddings, Telegram, GitHub, email, calendar feeds.
            - Self-improvement: harness checks, evals, capability foundry, gated promotions, incident receipts.
            - Approvals: pending actions surface to the user before destructive or sensitive operations execute.

            ## Helping the user set up
            - On first chat after onboarding, take stock: ask the user what they want to use first (chat-only, Mac actions, Telegram, mobile pairing) instead of dumping the whole menu.
            - For each capability the user wants, look up the live status (use /v1/capabilities, /v1/connectors, /v1/providers, Trust policy) before claiming it's ready.
            - If a capability requires a token, key, or permission grant, name the exact tab/screen where the user enters it — don't hand-wave.
            - When the user grants a new permission or pastes a key, verify it actually works (read-back, status endpoint, or a small probe call) before saying "you're set."

            ## Autonomy
            - Improve the NativeAgent project only inside the approved repo/worktree scope.
            - Treat generated tools and skills as drafts until validation, tests, and trust gates pass.
            - Never touch credentials, pairing tokens, provider secrets, or unrelated user files during autonomous improvement.

            """
        default:
            return ""
        }
    }
}

// MARK: - PersonaDocSpec / PersonaDocListing

/// Wire-shape DTO mirroring the daemon's `/v1/personality/docs` entry
/// shape. Kept in Core (not NativeAgentShared) so PersonaEngineTests can
/// verify the adapter end-to-end without crossing module boundaries; the
/// app-side `NativeAgentShared.PersonalityDoc` is a field-for-field copy
/// that NativeClient maps to.
public struct PersonaDocSpec: Sendable, Equatable, Codable {
    public let id: String
    public let title: String
    public let filename: String
    public let path: String
    public let content: String
    public let updatedAt: String?

    public init(id: String, title: String, filename: String, path: String, content: String, updatedAt: String?) {
        self.id = id
        self.title = title
        self.filename = filename
        self.path = path
        self.content = content
        self.updatedAt = updatedAt
    }
}

public struct PersonaDocListing: Sendable, Equatable, Codable {
    public let docs: [PersonaDocSpec]
    public let updatedAt: String?

    public init(docs: [PersonaDocSpec], updatedAt: String?) {
        self.docs = docs
        self.updatedAt = updatedAt
    }
}

// MARK: - Factory

public func makePersonaEngine() -> any PersonaEngineProtocol {
    return SwiftNativePersonaEngine()
}

/// Write-capable persona engine for the NativeClient persona WRITE gate
/// (wave 33 W06). Typed as `any PersonaEngineWriting` so the write-gate call
/// sites get the write methods without the read-only ChatOrchestration
/// consumers being dragged onto the write contract.
///
/// CALLER CONTRACT: this factory always vends a writer that writes to the local
/// on-disk persona path. There is no dormant daemon branch here; call sites must
/// gate writes before reaching this factory when policy requires it.
public func makePersonaEngineWriter() -> any PersonaEngineWriting {
    return SwiftNativePersonaEngine()
}
