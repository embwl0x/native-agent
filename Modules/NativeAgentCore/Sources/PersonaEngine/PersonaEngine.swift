import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `PersonaEngine.swift` | `SwiftNativePersonaEngine`: shared persona-document reads and GROWTH episodic-log filtering; `PersonaSelection`: installation-wide selection for every door |

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

// MARK: - Persona-root resolver

public enum PersonaRootResolver {
    /// Resolve persona strictly inside an injected data root.
    ///
    /// Isolated bodies never use checkout persona seeds: always `<dataRoot>/persona`.
    public static func resolveIsolated(dataRoot: URL) -> URL {
        dataRoot.standardizedFileURL.appendingPathComponent("persona", isDirectory: true)
    }
}

/// Mutation receipt: `bytesWritten` counts a full replacement; `bytesAppended`
/// counts the appended section. The unused count is `nil`.
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
    /// Data root for profile-backed personality-document defaults.
    private let dataRoot: URL

    public init(
        root: URL = PersistenceCore.defaultPersonaRoot(),
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

    /// Shared data root for profile reads and writes.
    public var dataRootURL: URL { dataRoot }

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

    // MARK: - Persona document listing

    /// Scaffold profile-backed defaults, then list fixed specs with file mtimes; the listing timestamp is now.
    public func listPersonaDocSpecs() async throws -> PersonaDocListing {
        _ = try await scaffoldMissingDocs()
        // A missing root permits first-run specs; a root file is an error, never an onboarding state.
        var rootIsDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: root.path, isDirectory: &rootIsDirectory),
           !rootIsDirectory.boolValue {
            throw PersonaEngineError.rootUnreadable(reason: "persona root is not a directory")
        }

        // SOUL.md gates defaults; missing USER.md stays empty until MemoryV2 regenerates it.
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
                    updatedAt = NativeTimestampFormat.fractionalZulu(mtime)
                }
            } else if soulInitialized && spec.id != "SOUL" && spec.id != "USER" {
                // Unpersisted defaults retain a nil updatedAt.
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
        return PersonaDocListing(docs: docs, updatedAt: NativeTimestampFormat.fractionalZulu(Date()))
    }

    // MARK: - Profile-backed document defaults
    nonisolated static func defaultPersonalityDocContent(
        id: String,
        profile: CompiledPersonalityProfile = .defaults,
        now: Date = Date()
    ) -> String {
        let name = profile.name
        let personaKind = profile.personaKind
        let essence = profile.essence
        let voice = profile.voice
        // Empty style lists use document-specific placeholders, distinct from profile defaults.
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
            let stamp = NativeTimestampFormat.fractionalZulu(now)
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
            - Know the app's abilities, built-in guidance, memory layers, provider controls, approvals, and Mac/iOS/Telegram surfaces.
            - Run a matching ability of yours as authored.<id>; read its code with ability.read only for authoring or review.
            - Keep context lean: prefer routed summaries, then look up deeper context on demand.

            ## Capability reference (look up details when needed)
            - Chat surfaces: Mac app, iOS companion (after pairing), Telegram bot (after token wiring).
            - Memory: remembering useful facts and finding relevant past conversations.
            - Mac integrations behind Trust: Messages, Notes, Contacts, Calendar, Files, Shortcuts, Spotlight, shell.
            - Connections: model providers, embeddings, Telegram and Slack; grow other service connections as abilities.
            - Abilities: grow reusable code with ability.save; built-in guidance is read-only and followed with existing actions.
            - Approvals: pending actions surface to the user before destructive or sensitive operations execute.

            ## Helping the user set up
            - For each capability the user wants, look up the live status before claiming it's ready.
            - Set the capability up yourself: open the page (app {page}), change what you can (its actions, such as setting.set), and fill in every field you already have. Ask the user only for a grant you cannot obtain on your own.
            - Ask for service secrets with card.request {kind:"api_key", target:"secret:<name>", hosts:[...], programs:[...]}; add sign_in for a sign-in flow. Use {{secret:<name>}} in code; NativeAgent holds the value. Never ask for a secret in chat.
            - After a permission or secret is granted, verify it works with a read-back, status endpoint, or small probe before saying "you're set."

            ## Autonomy
            - Improve the NativeAgent project only inside the approved repo/worktree scope.
            - Under Full Mac, your own ability.save is kept and on; its first real run is its proof. Otherwise it waits as a draft: ability.validate rehearses it and ability.enable asks the owner to keep it. Every action still passes Trust.
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
