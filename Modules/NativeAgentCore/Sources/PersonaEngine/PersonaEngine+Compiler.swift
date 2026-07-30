import Foundation
import CryptoKit
import PersistenceCore

// MARK: - PersonalityPacket
//
// Mirrors the retired daemon `compiled_personality_packet(surface)`
// (~L35364-35550). Phase-B+ scope: load canonical persona docs, apply
// custom-persona dir overrides, append surface guidance, concatenate in
// canonical order, derive a stable fingerprint, surface trait metadata
// parsed from GROWTH.md frontmatter. Deliberately simplified vs. daemon:
//   - no REM-pin retrieval (subsystem #10).
//   - no chat-turn-time slotting (`compiled_personality_packet_for_turn`
//     additions like KG snippets) — that's the next layer.
//   - no live-tone augmentation, no prompt-cache key derivation.

public struct PersonalityPacket: Sendable, Codable, Equatable {
    public let surface: String
    public let personaKind: String       // "Custom" | "Default"
    public let personaId: String
    public let fingerprint: String       // SHA-256 hex prefix (16 chars)
    public let compiledSystemPrompt: String
    public let activeDocs: [String: String]
    public let traits: [String: JSONValue]
    public let extras: JSONValue?

    public init(
        surface: String,
        personaKind: String,
        personaId: String,
        fingerprint: String,
        compiledSystemPrompt: String,
        activeDocs: [String: String],
        traits: [String: JSONValue],
        extras: JSONValue? = nil
    ) {
        self.surface = surface
        self.personaKind = personaKind
        self.personaId = personaId
        self.fingerprint = fingerprint
        self.compiledSystemPrompt = compiledSystemPrompt
        self.activeDocs = activeDocs
        self.traits = traits
        self.extras = extras
    }
}

public struct PersonaContextDocumentSource: Sendable, Equatable {
    public let id: String
    public let fileURL: URL
    public let content: String
    public let canonicalOrder: Int
    public let optional: Bool
    public let surfaceOverride: Bool

    public init(
        id: String,
        fileURL: URL,
        content: String,
        canonicalOrder: Int,
        optional: Bool,
        surfaceOverride: Bool
    ) {
        self.id = id
        self.fileURL = fileURL
        self.content = content
        self.canonicalOrder = canonicalOrder
        self.optional = optional
        self.surfaceOverride = surfaceOverride
    }
}

public struct PersonaContextSourceSnapshot: Sendable, Equatable {
    public let packet: PersonalityPacket
    public let personaRoot: URL
    public let activePersonaDirectory: URL?
    public let documents: [PersonaContextDocumentSource]
    public let watchedDirectories: [URL]

    public init(
        packet: PersonalityPacket,
        personaRoot: URL,
        activePersonaDirectory: URL?,
        documents: [PersonaContextDocumentSource],
        watchedDirectories: [URL]
    ) {
        self.packet = packet
        self.personaRoot = personaRoot
        self.activePersonaDirectory = activePersonaDirectory
        self.documents = documents
        self.watchedDirectories = watchedDirectories
    }
}

// MARK: - CompiledPersonalityProfile
//
// Mirrors the retired daemon `personality()` (L35081-35084) which reads
// `<dataRoot>/memory/profile.json`, normalizes it via `normalize_personality`
// (L35035-35079) seeded with `default_personality()` (L34989-35033), and
// returns the typed profile. Shape matches the Mac-side `PersonalityProfile`
// in NativeAgentShared/SharedModels.swift so the NativeClient adapter can
// map field-for-field. Core-side type — PersonaEngine doesn't import
// NativeAgentShared.

public struct CompiledPersonalityTraits: Sendable, Codable, Equatable {
    public let warmth: Double
    public let directness: Double
    public let humor: Double
    public let proactivity: Double
    public let rigor: Double
    public let autonomy: Double
    public let creativity: Double
    public let brevity: Double

    public init(warmth: Double, directness: Double, humor: Double, proactivity: Double,
                rigor: Double, autonomy: Double, creativity: Double, brevity: Double) {
        self.warmth = warmth
        self.directness = directness
        self.humor = humor
        self.proactivity = proactivity
        self.rigor = rigor
        self.autonomy = autonomy
        self.creativity = creativity
        self.brevity = brevity
    }
}

public struct CompiledPersonalityProfile: Sendable, Codable, Equatable {
    public let schemaVersion: Int
    public let personaEngineVersion: String
    public let name: String
    public let personaKind: String
    public let essence: String
    public let voice: String
    public let customDirective: String
    public let traits: CompiledPersonalityTraits
    public let examples: [String]
    public let forbiddenPatterns: [String]
    public let instincts: [String]
    public let boundaries: [String]
    public let surfaceOverrides: [String: String]
    public let updatedAt: String

    /// Lossless carry-over of profile.json keys OUTSIDE the fixed field set —
    /// the Swift mirror of Python `normalize_personality`'s
    /// `{**default, **{k:v for k,v in raw.items() if k not in {"traits","gender"}}, ...}`
    /// splat. The fixed struct above models the
    /// KNOWN keys; this dictionary preserves any UNKNOWN key a caller (or a
    /// future schema rev / a hand-edited profile.json) put on disk, so a
    /// native `savePersonality` round-trip does NOT silently drop it the way a
    /// plain fixed-struct re-serialize would (the §6.76 W19 item-B.2 gap that
    /// kept the write path PARTIAL). Keys here are guaranteed disjoint from the
    /// known field set + `{traits, gender}` (see `PersonaCompiler.normalize`).
    /// Default empty so every existing positional constructor keeps compiling
    /// and a profile with no extras compares equal to the pre-extras shape.
    public let extras: [String: JSONValue]

    public init(
        schemaVersion: Int,
        personaEngineVersion: String,
        name: String,
        personaKind: String,
        essence: String,
        voice: String,
        customDirective: String,
        traits: CompiledPersonalityTraits,
        examples: [String],
        forbiddenPatterns: [String],
        instincts: [String],
        boundaries: [String],
        surfaceOverrides: [String: String],
        updatedAt: String,
        extras: [String: JSONValue] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.personaEngineVersion = personaEngineVersion
        self.name = name
        self.personaKind = personaKind
        self.essence = essence
        self.voice = voice
        self.customDirective = customDirective
        self.traits = traits
        self.examples = examples
        self.forbiddenPatterns = forbiddenPatterns
        self.instincts = instincts
        self.boundaries = boundaries
        self.surfaceOverrides = surfaceOverrides
        self.updatedAt = updatedAt
        self.extras = extras
    }

    /// Explicit `CodingKeys` that OMIT `extras` so the synthesized
    /// `Codable` wire shape of this struct stays byte-identical to the
    /// pre-extras layout. Nothing in the codebase Codable-encodes this
    /// struct directly (the `/v1/personality/compiled` packet builds its
    /// `profile` value explicitly in `PersonaEngine+CompiledPacket.swift`,
    /// and the on-disk profile.json write is built explicitly in
    /// `PersonaEngine+Writes.swift`), but pinning the keys keeps any future
    /// incidental `JSONEncoder().encode(profile)` from leaking an
    /// unsorted/duplicated `extras` blob. The lossless extras carry-over is
    /// done EXPLICITLY at the two write boundaries, not via this `Codable`.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, personaEngineVersion, name, personaKind, essence
        case voice, customDirective, traits, examples, forbiddenPatterns
        case instincts, boundaries, surfaceOverrides, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        self.personaEngineVersion = try c.decode(String.self, forKey: .personaEngineVersion)
        self.name = try c.decode(String.self, forKey: .name)
        self.personaKind = try c.decode(String.self, forKey: .personaKind)
        self.essence = try c.decode(String.self, forKey: .essence)
        self.voice = try c.decode(String.self, forKey: .voice)
        self.customDirective = try c.decode(String.self, forKey: .customDirective)
        self.traits = try c.decode(CompiledPersonalityTraits.self, forKey: .traits)
        self.examples = try c.decode([String].self, forKey: .examples)
        self.forbiddenPatterns = try c.decode([String].self, forKey: .forbiddenPatterns)
        self.instincts = try c.decode([String].self, forKey: .instincts)
        self.boundaries = try c.decode([String].self, forKey: .boundaries)
        self.surfaceOverrides = try c.decode([String: String].self, forKey: .surfaceOverrides)
        self.updatedAt = try c.decode(String.self, forKey: .updatedAt)
        self.extras = [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(personaEngineVersion, forKey: .personaEngineVersion)
        try c.encode(name, forKey: .name)
        try c.encode(personaKind, forKey: .personaKind)
        try c.encode(essence, forKey: .essence)
        try c.encode(voice, forKey: .voice)
        try c.encode(customDirective, forKey: .customDirective)
        try c.encode(traits, forKey: .traits)
        try c.encode(examples, forKey: .examples)
        try c.encode(forbiddenPatterns, forKey: .forbiddenPatterns)
        try c.encode(instincts, forKey: .instincts)
        try c.encode(boundaries, forKey: .boundaries)
        try c.encode(surfaceOverrides, forKey: .surfaceOverrides)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    /// Defaults matching Python `default_personality()` at
    /// the retired daemon. Used as the seed any time
    /// profile.json is missing or a field is absent / malformed.
    public static let defaults: CompiledPersonalityProfile = CompiledPersonalityProfile(
        schemaVersion: 2,
        personaEngineVersion: "2.0",
        name: "NativeAgent",
        personaKind: "AI",
        essence: "A calm, sharp, practical native macOS agent that improves itself inside its own sandbox and helps the user get real work done.",
        voice: "Direct, grounded, specific, with no corporate fluff.",
        customDirective: "",
        traits: CompiledPersonalityTraits(
            warmth: 0.45, directness: 0.82, humor: 0.12, proactivity: 0.78,
            rigor: 0.86, autonomy: 0.82, creativity: 0.58, brevity: 0.74
        ),
        examples: [
            "Lead with the useful answer, then show only the context needed to act.",
            "When tools are involved, be explicit about what was actually done.",
        ],
        forbiddenPatterns: [
            "Corporate filler.",
            "Claiming tool or file actions that did not happen.",
            "Over-explaining simple outcomes.",
        ],
        instincts: [
            "Prefer action over prolonged discussion when the task is executable.",
            "State uncertainty plainly and then check it.",
            "Keep self-improvement autonomous but contained to app-owned paths.",
        ],
        boundaries: [
            "Do not invent tool results.",
            "Do not claim files were changed unless they were.",
            "Do not autonomously modify unrelated computer files while improving yourself.",
        ],
        surfaceOverrides: [
            "chat": "",
            "telegram": "Keep Telegram replies shorter and preserve the same persona without long setup context.",
            "dream": "Reflect like an internal agent maintenance pass: specific lessons, memory candidates, eval ideas, and improvement targets.",
            "autonomy": "Operate as a careful self-improvement engineer inside the app-owned worktree.",
        ],
        updatedAt: ""
    )
}

// MARK: - PersonaCompiler

/// Compiles the personality packet for a surface. Reads from the same
/// persona root the SwiftNativePersonaEngine sees (so the resolver chain
/// from PersonaEngine.swift is honored — env var, stamped repo, dev repo,
/// legacy fallback).
public actor PersonaCompiler {
    /// Internal so `PersonaEngine+CompiledPacket.swift` (same module,
    /// separate file) can reach the engine's personaRoot + dataRoot when
    /// building the daemon-equivalent `/v1/personality/compiled` packet.
    internal let engine: SwiftNativePersonaEngine
    private let fileManager: FileManager

    /// Canonical docs in the order they get concatenated into the system
    /// prompt. Carve order (fix 5):
    ///   SOUL → VOICE → USER → GROWTH → MEMORY (if present) → AGENTS
    /// MEMORY.md is injected after GROWTH and before AGENTS when the file
    /// exists on disk. It carries REM-distilled durable memory facts that
    /// the agent should treat as higher-priority than recall hits. The file
    /// is optional — missing MEMORY.md is silently omitted (no effect on
    /// fingerprint or any other doc). AGENTS is always last so operating-
    /// manual instructions land freshest in the context window.
    /// The surface guidance is appended after AGENTS.
    private static let canonicalDocOrder: [String] = [
        "SOUL", "VOICE", "USER", "GROWTH", "MEMORY", "AGENTS",
    ]

    public init(
        engine: SwiftNativePersonaEngine = SwiftNativePersonaEngine(),
        fileManager: FileManager = .default
    ) {
        self.engine = engine
        self.fileManager = fileManager
    }

    // MARK: Public API

    public func compile(surface: String) async throws -> PersonalityPacket {
        return try await compile(surface: surface, personaOverride: nil)
    }

    /// Same as `compile(surface:)` but honours a per-turn persona override
    /// (Mac UI's `UserDefaults["chatPersona"]`). When `personaOverride` names
    /// a subdir under the persona root that contains at least one marker doc,
    /// that subdir wins over the on-disk `active.json` / scan resolution.
    /// Override resolution failures fall through to the normal resolver — a
    /// typo can't blank the persona.
    public func compile(surface: String, personaOverride: String?) async throws -> PersonalityPacket {
        let root = await engine.personaRoot

        let (personaKind, personaId, personaSubdir) = resolveActivePersona(
            root: root, personaOverride: personaOverride
        )

        // Load canonical docs + apply per-doc overrides from the custom
        // persona subdir.
        var activeDocs: [String: String] = [:]
        for id in Self.canonicalDocOrder {
            if let override = personaSubdir.flatMap({ readDoc(root: $0, id: id) }) {
                activeDocs[id] = override
            } else if let canonical = readDoc(root: root, id: id) {
                activeDocs[id] = canonical
            }
            // missing → omitted from activeDocs and from the prompt body.
        }

        // Build the system prompt in canonical order.
        var sections: [String] = []
        for id in Self.canonicalDocOrder {
            if let body = activeDocs[id], !body.isEmpty {
                sections.append("# \(id)\n\(body)")
            }
        }
        if let surfaceBody = readSurfaceOverride(root: root, surface: surface) {
            sections.append("Surface guidance for \(surface):\n\(surfaceBody)")
            activeDocs["surface:\(surface)"] = surfaceBody
        }
        let compiledSystemPrompt = sections.joined(separator: "\n\n")

        // Traits — parsed from GROWTH.md (frontmatter or `TRAIT:` headers).
        let traits = extractTraits(growth: activeDocs["GROWTH"] ?? "")

        // Fingerprint — SHA-256 over (sorted ids + their contents + surface).
        let fingerprint = computeFingerprint(activeDocs: activeDocs, surface: surface)

        return PersonalityPacket(
            surface: surface,
            personaKind: personaKind,
            personaId: personaId,
            fingerprint: fingerprint,
            compiledSystemPrompt: compiledSystemPrompt,
            activeDocs: activeDocs,
            traits: traits,
            extras: nil
        )
    }

    public func fingerprint(surface: String) async throws -> String {
        try await compile(surface: surface).fingerprint
    }

    /// ContextFlow source discovery using the exact same active/custom/surface
    /// decisions as the live compiler. The derived index must not maintain a
    /// second persona-root or active-persona resolver.
    public func contextSourceSnapshot(
        surface: String,
        personaOverride: String? = nil
    ) async throws -> PersonaContextSourceSnapshot {
        let packet = try await compile(surface: surface, personaOverride: personaOverride)
        let root = await engine.personaRoot
        let (_, _, activeDirectory) = resolveActivePersona(
            root: root,
            personaOverride: personaOverride
        )
        var documents: [PersonaContextDocumentSource] = []
        for (order, id) in Self.canonicalDocOrder.enumerated() {
            guard let content = packet.activeDocs[id] else { continue }
            let overrideURL = activeDirectory?.appendingPathComponent("\(id).md")
            let selectedURL: URL
            if let overrideURL, fileManager.fileExists(atPath: overrideURL.path) {
                selectedURL = overrideURL
            } else {
                selectedURL = root.appendingPathComponent("\(id).md")
            }
            documents.append(PersonaContextDocumentSource(
                id: id,
                fileURL: selectedURL,
                content: content,
                canonicalOrder: order,
                optional: id == "MEMORY",
                surfaceOverride: false
            ))
        }
        if let surfaceContent = packet.activeDocs["surface:\(surface)"] {
            documents.append(PersonaContextDocumentSource(
                id: "surface:\(surface)",
                fileURL: root
                    .appendingPathComponent("surfaces", isDirectory: true)
                    .appendingPathComponent("\(surface).md"),
                content: surfaceContent,
                canonicalOrder: Self.canonicalDocOrder.count,
                optional: true,
                surfaceOverride: true
            ))
        }

        var watched = Set<URL>([
            root,
            root.deletingLastPathComponent(),
            root.appendingPathComponent("surfaces", isDirectory: true),
        ])
        if let activeDirectory { watched.insert(activeDirectory) }
        return PersonaContextSourceSnapshot(
            packet: packet,
            personaRoot: root,
            activePersonaDirectory: activeDirectory,
            documents: documents,
            watchedDirectories: watched.sorted { $0.path < $1.path }
        )
    }

    /// Returns the structured personality profile that the daemon's
    /// `/v1/personality` endpoint serves. Mirrors Python `personality()` at
    /// the retired daemon: read `<dataRoot>/memory/profile.json`,
    /// normalize via `normalize_personality` (L35035-35079) seeded with
    /// `default_personality()` (L34989-35033). Missing file → defaults.
    /// Malformed JSON → defaults. Missing fields → defaults per field.
    ///
    /// Custom-persona override semantics: `personaKind` outside
    /// {male, female, ai, custom} falls back to default; "ai" canonicalises
    /// to "AI", others Title-cased.
    public func compileProfile(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> CompiledPersonalityProfile {
        return Self.loadProfile(dataRoot: dataRoot)
    }

    /// Non-isolated load path so callers that already serialize themselves
    /// (e.g. SwiftNativePersonaEngine.listPersonaDocSpecs) can read the
    /// profile without spinning up a PersonaCompiler actor + crossing the
    /// boundary. Identical semantics to `compileProfile`.
    public nonisolated static func loadProfile(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> CompiledPersonalityProfile {
        let profileURL = dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("profile.json")
        let raw: [String: Any]
        if let data = try? Data(contentsOf: profileURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            raw = obj
        } else {
            raw = [:]
        }
        return normalize(raw: raw, defaults: .defaults)
    }

    // MARK: - agent_display_name() mirror
    //
    // Subsystem #17 wave 10 prereq #2: mirror Python `agent_display_name()`
    // at the retired daemon. The daemon normalizes
    // profile.name: when it's empty, whitespace, or one of the generic
    // labels {"agent", "custom", "ai", "male", "female"} (case-insensitive),
    // the daemon falls back to APP ("NativeAgent"). Real custom names
    // pass through, truncated to 80 chars. CommandPalette's
    // makeCommandPaletteContext factory MUST call this instead of the raw
    // `loadProfile().name` so the chat-subtitle and operating-map-title
    // surfaces match the daemon for default-named personas.

    /// Generic labels the daemon treats as "no real name set" — see
    /// the retired daemon. Case-insensitive comparison; keep this set
    /// in sync with the Python literal.
    nonisolated static let agentDisplayGenericNames: Set<String> = [
        "agent", "custom", "ai", "male", "female",
    ]

    /// The daemon's APP constant (the literal string "NativeAgent"). The
    /// Python source defines `APP = "NativeAgent"` near the top of
    /// the retired daemon and `agent_display_name()` returns it whenever the
    /// profile name is empty/whitespace OR one of the generic labels above.
    nonisolated static let agentDisplayAppFallback: String = "NativeAgent"

    /// Pure normalization of a profile's display name. Mirrors Python
    /// `agent_display_name()` at the retired daemon.
    /// Empty/whitespace OR a generic label → "NativeAgent". Otherwise the
    /// trimmed name truncated to 80 UTF-8-character cap (matches Python's
    /// `name[:80]` slice which counts code points).
    public nonisolated static func agentDisplayName(
        profile: CompiledPersonalityProfile
    ) -> String {
        // Python: `name = str(profile.get("name") or "").strip()`
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return agentDisplayAppFallback }
        if agentDisplayGenericNames.contains(name.lowercased()) {
            return agentDisplayAppFallback
        }
        // Python: `return name[:80]` — slice by code points (Unicode scalars).
        // Swift String.count + .prefix(N) operate on extended grapheme clusters,
        // which would diverge for grapheme-cluster-rich names (compound emoji,
        // etc.). Use unicodeScalars to mirror Python's CODE POINT slice exactly.
        let scalars = name.unicodeScalars
        if scalars.count <= 80 { return name }
        return String(String.UnicodeScalarView(scalars.prefix(80)))
    }

    /// Convenience wrapper: load the profile from disk and return its
    /// daemon-equivalent display name. Use this from non-actor callers
    /// (e.g. NativeClient.makeCommandPaletteContext) that previously read
    /// `loadProfile(dataRoot:).name` raw — that path skipped the
    /// generic-label fallback. Matches daemon `agent_display_name()` 1:1.
    public nonisolated static func agentDisplayName(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> String {
        return agentDisplayName(profile: loadProfile(dataRoot: dataRoot))
    }

    // MARK: - normalize_personality mirror

    /// Mirrors Python `normalize_personality(raw)` at L35035-35079.
    public static func normalize(
        raw: [String: Any],
        defaults: CompiledPersonalityProfile
    ) -> CompiledPersonalityProfile {
        // personaKind canonicalisation (L35042-35051).
        var personaKind = stringOr(raw["personaKind"], or: nil)
            ?? stringOr(raw["gender"], or: nil)
            ?? defaults.personaKind
        personaKind = personaKind.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed: Set<String> = ["male", "female", "ai", "custom"]
        if !allowed.contains(personaKind.lowercased()) {
            personaKind = defaults.personaKind
        }
        let personaCanonical: String =
            (personaKind.lowercased() == "ai") ? "AI" : personaKind.capitalized

        // Traits (L35038-35041): clamp_float on every defaults key; ignore
        // raw extras.
        let rawTraits = raw["traits"] as? [String: Any] ?? [:]
        let traits = CompiledPersonalityTraits(
            warmth: clampFloat(rawTraits["warmth"], fallback: defaults.traits.warmth),
            directness: clampFloat(rawTraits["directness"], fallback: defaults.traits.directness),
            humor: clampFloat(rawTraits["humor"], fallback: defaults.traits.humor),
            proactivity: clampFloat(rawTraits["proactivity"], fallback: defaults.traits.proactivity),
            rigor: clampFloat(rawTraits["rigor"], fallback: defaults.traits.rigor),
            autonomy: clampFloat(rawTraits["autonomy"], fallback: defaults.traits.autonomy),
            creativity: clampFloat(rawTraits["creativity"], fallback: defaults.traits.creativity),
            brevity: clampFloat(rawTraits["brevity"], fallback: defaults.traits.brevity)
        )

        // Scalar strings with caps + trim (L35057-35061).
        let name = capString(raw["name"], fallback: defaults.name, cap: 80)
        let essence = capString(raw["essence"], fallback: defaults.essence, cap: 1000)
        let voice = capString(raw["voice"], fallback: defaults.voice, cap: 1000)
        let customDirective = capString(raw["customDirective"], fallback: "", cap: 2000)

        // List fields: list-typed-or-default, then per-item trim/cap/limit
        // (L35063-35073).
        let examples = trimList(
            raw["examples"] as? [Any] ?? defaults.examples.map { $0 as Any },
            itemCap: 500, listCap: 12
        )
        let forbiddenPatterns = trimList(
            raw["forbiddenPatterns"] as? [Any] ?? defaults.forbiddenPatterns.map { $0 as Any },
            itemCap: 300, listCap: 16
        )
        let instincts = trimList(
            raw["instincts"] as? [Any] ?? defaults.instincts.map { $0 as Any },
            itemCap: 500, listCap: 16
        )
        let boundaries = trimList(
            raw["boundaries"] as? [Any] ?? defaults.boundaries.map { $0 as Any },
            itemCap: 500, listCap: 16
        )

        // surfaceOverrides: dict-typed-or-default, then per-pair sanitize
        // (L35067, L35074-35078).
        let rawOverrides = (raw["surfaceOverrides"] as? [String: Any])
            ?? defaults.surfaceOverrides.mapValues { $0 as Any }
        var surfaceOverrides: [String: String] = [:]
        for (key, value) in rawOverrides {
            let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { continue }
            let kCapped = String(k.prefix(40))
            let v: String
            if let s = value as? String {
                v = s
            } else if let n = value as? NSNumber {
                v = n.stringValue
            } else if let b = value as? Bool {
                v = b ? "true" : "false"
            } else {
                continue
            }
            let vTrim = v.trimmingCharacters(in: .whitespacesAndNewlines)
            surfaceOverrides[kCapped] = String(vTrim.prefix(1000))
        }

        // updatedAt: raw value if present, else now ISO8601.
        let updatedAt = stringOr(raw["updatedAt"], or: nil) ?? Self.nowISO()

        // Lossless extras (Python `{**raw items if k not in {"traits","gender"}}`,
        // L35259). Every KNOWN key the normalize sets above is re-stamped from
        // the explicit fields, so the only `raw` keys that survive the splat are
        // those OUTSIDE the fixed set. We compute that set here: any raw key not
        // in `normalizedKeys` AND not in `{traits, gender}` is carried verbatim
        // as a JSONValue. (`gender` is folded into personaKind; `traits` is
        // rebuilt — both are excluded by Python and here.)
        var extras: [String: JSONValue] = [:]
        for (key, value) in raw {
            if Self.normalizedKeys.contains(key) { continue }
            if key == "traits" || key == "gender" { continue }
            extras[key] = JSONValue(fromFoundation: value)
        }

        return CompiledPersonalityProfile(
            schemaVersion: 2,
            personaEngineVersion: "2.0",
            name: name,
            personaKind: personaCanonical,
            essence: essence,
            voice: voice,
            customDirective: customDirective,
            traits: traits,
            examples: examples,
            forbiddenPatterns: forbiddenPatterns,
            instincts: instincts,
            boundaries: boundaries,
            surfaceOverrides: surfaceOverrides,
            updatedAt: updatedAt,
            extras: extras
        )
    }

    /// The KNOWN profile keys `normalize_personality` re-stamps explicitly
    ///. Any raw key NOT in this set (and not
    /// `traits`/`gender`, which are consumed) is an "extra" preserved verbatim
    /// per Python's `{**raw}` splat. Keep in lockstep with the explicit fields.
    static let normalizedKeys: Set<String> = [
        "schemaVersion", "personaEngineVersion", "name", "personaKind",
        "essence", "voice", "customDirective", "traits", "examples",
        "forbiddenPatterns", "instincts", "boundaries", "surfaceOverrides",
        "updatedAt",
    ]

    private static func stringOr(_ value: Any?, or fallback: String?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        return fallback
    }

    private static func capString(_ value: Any?, fallback: String, cap: Int) -> String {
        let s = (value as? String) ?? fallback
        let trimmed = (s.isEmpty ? fallback : s).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(cap))
    }

    /// Mirrors Python `clamp_float(value, fallback)` — accept ints, floats,
    /// numeric strings, clamp to [0, 1], else fallback.
    private static func clampFloat(_ value: Any?, fallback: Double) -> Double {
        let candidate: Double?
        if let d = value as? Double { candidate = d }
        else if let i = value as? Int { candidate = Double(i) }
        else if let n = value as? NSNumber { candidate = n.doubleValue }
        else if let s = value as? String, let d = Double(s) { candidate = d }
        else { candidate = nil }
        guard let v = candidate, v.isFinite else { return fallback }
        return min(1.0, max(0.0, v))
    }

    private static func trimList(_ raw: [Any], itemCap: Int, listCap: Int) -> [String] {
        var out: [String] = []
        for item in raw {
            let s: String
            if let str = item as? String { s = str } else { continue }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            out.append(String(trimmed.prefix(itemCap)))
            if out.count >= listCap { break }
        }
        return out
    }

    private static func nowISO() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    // MARK: - Internals

    /// Persona-doc filenames that, when present in a subdir, mark that
    /// subdir as a custom persona. Notes/jsonl files alone do NOT count —
    /// the daemon treats a custom persona as one that actually overrides
    /// at least one canonical doc.
    private static let personaMarkerDocs: Set<String> = ["SOUL", "VOICE", "GROWTH", "USER", "AGENTS"]

    /// Returns (kind, id, customSubdirURL?). Selection order:
    ///   1. `<root>/active.json` { "persona": "<Name>" } if present + dir
    ///      exists + dir has at least one marker doc → Custom.
    ///   2. Otherwise scan immediate subdirs; pick the first (sorted)
    ///      that contains a marker doc → Custom.
    ///   3. None found → Default / "canonical".
    private func resolveActivePersona(root: URL) -> (kind: String, id: String, subdir: URL?) {
        return resolveActivePersona(root: root, personaOverride: nil)
    }

    private func resolveActivePersona(
        root: URL,
        personaOverride: String?
    ) -> (kind: String, id: String, subdir: URL?) {
        // 0. Per-turn override (Mac UI chatPersona pick). Trim, then look
        //    for a subdir with at least one marker doc. Misses fall through
        //    to the normal resolver so a typo can't blank the persona.
        if let raw = personaOverride {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                let candidate = root.appendingPathComponent(name, isDirectory: true)
                if subdirHasMarker(candidate) {
                    return ("Custom", name, candidate)
                }
                // Override naming the canonical persona by display name (e.g.
                // the configured name when SOUL.md lives at the root) —
                // fall through to the scan + default. The chosen-persona name
                // is preserved on `metadata.persona` upstream regardless.
            }
        }
        // 1. active.json
        let activeFile = root.appendingPathComponent("active.json")
        if let data = try? Data(contentsOf: activeFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = obj["persona"] as? String, !name.isEmpty {
            let candidate = root.appendingPathComponent(name, isDirectory: true)
            if subdirHasMarker(candidate) {
                return ("Custom", name, candidate)
            }
        }
        // 2. Scan immediate subdirs.
        let entries = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        let dirs = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in dirs where subdirHasMarker(dir) {
            return ("Custom", dir.lastPathComponent, dir)
        }
        // 3. Default
        return ("Default", "canonical", nil)
    }

    private func subdirHasMarker(_ dir: URL) -> Bool {
        guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return false
        }
        for id in Self.personaMarkerDocs {
            let f = dir.appendingPathComponent("\(id).md")
            if fileManager.fileExists(atPath: f.path) { return true }
        }
        return false
    }

    private func readDoc(root: URL, id: String) -> String? {
        let url = root.appendingPathComponent("\(id).md")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func readSurfaceOverride(root: URL, surface: String) -> String? {
        let url = root
            .appendingPathComponent("surfaces", isDirectory: true)
            .appendingPathComponent("\(surface).md")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Trait parser. Two supported shapes:
    ///   1. YAML-ish frontmatter at the top of GROWTH.md:
    ///        ---
    ///        traits:
    ///          curiosity: 0.7
    ///          warmth: high
    ///        ---
    ///   2. Inline `TRAIT: <name> = <value>` lines anywhere in the body.
    /// Anything that fails to parse → empty dict. Daemon parses additional
    /// shapes (LLM-distilled KG entries); those are deferred to Phase C
    /// (DreamREMCycle owns the rich GROWTH.md schema).
    private func extractTraits(growth: String) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        guard !growth.isEmpty else { return out }

        // 1. Frontmatter.
        if growth.hasPrefix("---\n") {
            let rest = growth.dropFirst(4)
            if let endRange = rest.range(of: "\n---") {
                let block = String(rest[..<endRange.lowerBound])
                parseYamlishTraits(block: block, into: &out)
            }
        }

        // 2. Inline TRAIT lines.
        for raw in growth.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("TRAIT:") else { continue }
            let body = line.dropFirst("TRAIT:".count).trimmingCharacters(in: .whitespaces)
            guard let eq = body.firstIndex(of: "=") else { continue }
            let key = body[..<eq].trimmingCharacters(in: .whitespaces)
            let valueRaw = body[body.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                out[key] = parseScalar(valueRaw)
            }
        }

        return out
    }

    private func parseYamlishTraits(block: String, into out: inout [String: JSONValue]) {
        // Only inspect the `traits:` sub-section. Indented `key: value`
        // pairs underneath are read until a non-indented line.
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var inTraits = false
        for raw in lines {
            if raw.trimmingCharacters(in: .whitespaces) == "traits:" {
                inTraits = true
                continue
            }
            if inTraits {
                // End of section when we hit an unindented non-empty line.
                if !raw.isEmpty && !raw.hasPrefix(" ") && !raw.hasPrefix("\t") {
                    break
                }
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                guard let colon = trimmed.firstIndex(of: ":") else { continue }
                let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
                let valueRaw = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty {
                    out[String(key)] = parseScalar(valueRaw)
                }
            }
        }
    }

    private func parseScalar(_ s: String) -> JSONValue {
        if s.isEmpty { return .string("") }
        if s == "true" { return .bool(true) }
        if s == "false" { return .bool(false) }
        if s == "null" || s == "~" { return .null }
        if let i = Int64(s) { return .int(i) }
        if let d = Double(s) { return .double(d) }
        // Strip surrounding quotes if present.
        if s.count >= 2,
           (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            return .string(String(s.dropFirst().dropLast()))
        }
        return .string(s)
    }

    private func computeFingerprint(activeDocs: [String: String], surface: String) -> String {
        var hasher = SHA256()
        let ids = activeDocs.keys.sorted()
        for id in ids {
            hasher.update(data: Data(id.utf8))
            hasher.update(data: Data([0x1F])) // unit separator
            hasher.update(data: Data((activeDocs[id] ?? "").utf8))
            hasher.update(data: Data([0x1E])) // record separator
        }
        hasher.update(data: Data("surface=".utf8))
        hasher.update(data: Data(surface.utf8))
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }
}

// MARK: - CompiledGrowthSummary
//
// Mirrors the retired daemon `personality_growth_summary()` (~L16456).
// `feedbackMemories` is supplied by the caller via `feedbackMemoryProvider`
// so this module stays free of a MemoryV2 dependency — NativeClient wires
// the count in by listing memories tagged `persona-feedback`.

public struct CompiledGrowthSummary: Sendable, Codable, Equatable {
    public let engineVersion: String
    public let activeKind: String?
    public let fingerprint: String?
    public let growthEntries: Int
    public let feedbackMemories: Int
    public let nextActions: [String]
    public let createdAt: String

    public init(
        engineVersion: String,
        activeKind: String?,
        fingerprint: String?,
        growthEntries: Int,
        feedbackMemories: Int,
        nextActions: [String],
        createdAt: String
    ) {
        self.engineVersion = engineVersion
        self.activeKind = activeKind
        self.fingerprint = fingerprint
        self.growthEntries = growthEntries
        self.feedbackMemories = feedbackMemories
        self.nextActions = nextActions
        self.createdAt = createdAt
    }
}

extension PersonaCompiler {
    /// Daemon-equivalent fixed next-actions copy. Matches L16469-16473 verbatim.
    public static let growthNextActions: [String] = [
        "Use direct chat feedback as growth material.",
        "Keep persona docs small enough to compile fast.",
        "Run chat calibration after major voice edits.",
    ]

    /// Builds a `CompiledGrowthSummary` by compiling the chat-surface packet
    /// (for fingerprint), reading the profile.json persona kind (for
    /// activeKind), counting non-empty lines in GROWTH.md, and asking the
    /// caller for the persona-feedback memory count.
    ///
    /// W39 W05 / §6.200 #5 parity fix: `activeKind` MUST mirror the daemon's
    /// `personality_growth_summary`, which sets
    /// `"activeKind": self.personality().get("personaKind")` — the
    /// PROFILE.JSON `personaKind` field (default "AI", allowlist
    /// {male,female,ai,custom}), NOT the compiled packet's filesystem-derived
    /// `personaKind` (which defaults to "Default"/"Custom" via
    /// resolveActivePersona). Using `packet.personaKind` here produced
    /// `activeKind == "Default"` for the common no-custom-persona-dir profile
    /// while the daemon returned "AI" — a live `.personaEngine` parity bug.
    /// `loadProfile().personaKind` is the exact mirror of `personality()`.
    /// Builds a `CompiledGrowthSummary` mirroring the daemon's
    /// `personality_growth_summary()` field-for-field:
    ///
    ///   * `activeKind`  = `self.personality().get("personaKind")` — i.e. the
    ///     NORMALIZED profile's persona kind (default `"AI"` when profile.json is
    ///     absent), NOT the prompt-builder's active-persona resolution. The
    ///     `compile(surface:)` packet's `personaKind` comes from
    ///     `resolveActivePersona` which returns `"Default"` for a canonical
    ///     (non-custom-subdir) persona — a value the daemon NEVER emits here
    ///     (§6.200 #5). Sourced from `loadProfile().personaKind` instead.
    ///   * `fingerprint` = `self.compiled_personality_packet("chat").fingerprint`
    ///     — the SURFACE-INDEPENDENT byte-equivalent `persona_fingerprint`
    ///     (`compiledPacket`), NOT the `compile(surface:)` packet's
    ///     surface-SCOPED `computeFingerprint` (which would disagree with the
    ///     chat-orchestration fingerprint — the same divergence §6.97 documents).
    ///   * `growthEntries` = non-empty line count of the FULL (unsliced,
    ///     unbounded) GROWTH.md, matching the daemon reading GROWTH from
    ///     `personality_docs()` (not the surface-sliced packet body).
    ///   * `feedbackMemories` supplied by the caller via `feedbackMemoryProvider`.
    public func growthSummary(
        feedbackMemoryProvider: (@Sendable () async throws -> Int)? = nil,
        now: () -> Date = Date.init
    ) async throws -> CompiledGrowthSummary {
        // activeKind: normalized profile persona kind (default "AI"), mirroring
        // the daemon's `self.personality().get("personaKind")` — surface-/
        // prompt-builder-independent.
        let dataRoot = await engine.dataRootURL
        let activeKind = PersonaCompiler.loadProfile(dataRoot: dataRoot).personaKind

        // fingerprint: the byte-equivalent SURFACE-INDEPENDENT daemon packet
        // fingerprint, matching `compiled_personality_packet("chat")`.
        let wire = try await compiledPacket(surface: "chat")

        // growthEntries: non-empty line count of the FULL raw GROWTH.md (the
        // `compile()` packet reads docs unsliced/unbounded, matching the daemon's
        // `personality_docs()` source). W14's 5 characterization tests pin this.
        let packet = try await compile(surface: "chat")
        let growthBody = packet.activeDocs["GROWTH"] ?? ""
        let growthEntries = growthBody
            .split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + ($1.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : 1) }
        let feedbackCount: Int
        if let provider = feedbackMemoryProvider {
            feedbackCount = (try? await provider()) ?? 0
        } else {
            feedbackCount = 0
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return CompiledGrowthSummary(
            engineVersion: "2.0",
            activeKind: activeKind,
            fingerprint: wire.fingerprint,
            growthEntries: growthEntries,
            feedbackMemories: feedbackCount,
            nextActions: Self.growthNextActions,
            createdAt: formatter.string(from: now())
        )
    }
}
