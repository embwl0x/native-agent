import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - PersonaRoot resolution contract
//
// One rule, owned by `PersistenceCore.defaultPersonaRoot`: a checkout's
// `data/` (every dev install) keeps its persona at `<repo>/persona`; any other
// data root holds it at `<dataRoot>/persona`.

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

public enum PersonaRootResolver {
    /// Resolve persona strictly inside an injected data root.
    ///
    /// Secondary runtimes and hermetic tests must not fall through to the
    /// process environment, a stamped repository, or the developer checkout:
    /// those are production seed sources and can expose the personal persona
    /// to an otherwise isolated body. Always `<dataRoot>/persona`.
    public static func resolveIsolated(dataRoot: URL) -> URL {
        dataRoot.standardizedFileURL.appendingPathComponent("persona", isDirectory: true)
    }

    /// The persona root this process runs: `PersistenceCore.defaultPersonaRoot`
    /// for the given data root.
    public static func resolve(
        fileManager: FileManager = .default,
        dataRootProvider: () -> URL = { PersistenceCore.defaultDataRoot() }
    ) -> URL {
        PersistenceCore.defaultPersonaRoot(dataRoot: dataRootProvider(), fileManager: fileManager)
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

/// Native persona document reader and write owner. Each read loads current
/// disk contents; document snapshots are not cached. Write extensions own
/// locked persona mutations, while MemoryV2 owns the USER.md projection.
/// Actor isolation serializes access to this engine's state.
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
                content = try Self.readPersonaDocument(at: entry)
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

    /// Every persona reader excludes legacy episodic logs from GROWTH context.
    static func readPersonaDocument(at url: URL) throws -> String {
        let body = try String(contentsOf: url, encoding: .utf8)
        guard url.lastPathComponent == "GROWTH.md" else { return body }
        return filterEpisodicGrowthLines(body)
    }

    public static func filterEpisodicGrowthLines(_ body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                line.range(of: #"^- \S+\s+·\s+(feedback|dream_candidate)\s+·"#, options: .regularExpression) == nil
            }
            .joined(separator: "\n")
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

        // A missing root is the legitimate first-run state and therefore
        // produces the fixed, empty document specs below. A root *file* is
        // different: it cannot contain a persona and must not be rendered as
        // a fresh account, because doing so would offer onboarding over a
        // corrupted existing path. Surface that distinction to the mounted
        // loader so it can retain a known-good document set or show an
        // unavailable state instead of a false Create card.
        var rootIsDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: root.path, isDirectory: &rootIsDirectory),
           !rootIsDirectory.boolValue {
            throw PersonaEngineError.rootUnreadable(reason: "persona root is not a directory")
        }

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
                content = try Self.readPersonaDocument(at: url)
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

            ## Capability reference (look up details when needed)
            - Chat surfaces: Mac app, iOS companion (after pairing), Telegram bot (after token wiring).
            - Memory: remembering useful facts and finding relevant past conversations.
            - Mac integrations behind Trust: Messages, Notes, Contacts, Calendar, Files, Shortcuts, Spotlight, shell.
            - Connectors (optional, user-configured): chat model providers, embeddings, Telegram, GitHub, email, calendar feeds.
            - Skills: building and checking reusable ways to help, with approval where required.
            - Approvals: pending actions surface to the user before destructive or sensitive operations execute.

            ## Helping the user set up
            - For each capability the user wants, look up the live status before claiming it's ready.
            - Set the capability up yourself: open the page (app {page}), change what you can (its actions, such as setting.set), and fill in every field you already have. Ask the user only for a token or a grant you cannot obtain on your own, and verify it works before saying it is set up.
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
