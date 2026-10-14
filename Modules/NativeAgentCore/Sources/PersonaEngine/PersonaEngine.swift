import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore

/// One installation-wide persona selection for every conversation door.
/// Retains the existing preference key so the Mac's saved pick survives upgrades.
public enum PersonaSelection {
    public static func current(defaults: UserDefaults = .standard) -> String? {
        let name = defaults.string(forKey: "chatPersona")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }

    public static func select(_ name: String, defaults: UserDefaults = .standard) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { defaults.removeObject(forKey: "chatPersona") }
        else { defaults.set(clean, forKey: "chatPersona") }
    }
}

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
public actor SwiftNativePersonaEngine {
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
        // Scaffold first so content and updatedAt describe persisted defaults
        // (SOUL.md gates, USER.md skipped, each write locked; failures propagate).
        _ = try await scaffoldMissingDocs()
        // Local helper avoids capturing a non-Sendable ISO8601DateFormatter
        // in the loop body (Swift 6 strict-concurrency would flag sending
        // a class instance into an actor-isolated closure body).
        func isoString(_ d: Date) -> String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return iso.string(from: d)
        }
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
        for spec in Self.personalityDocSpecsFixed {
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
            - Run a matching skill routine through skill.run; request its source only for authoring or review.
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

/// One persona document as the Personality tab reads and saves it.
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

extension SwiftNativePersonaEngine {
    /// The saved profile, read and parsed off the main actor.
    public nonisolated static func readPersonality(dataRoot: URL) async throws -> PersonalityProfile {
        try await Task.detached { try PersonaCompiler.compileProfile(dataRoot: dataRoot).sharedProfile }.value
    }
}
