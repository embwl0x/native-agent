import Foundation
import CryptoKit
import PersistenceCore

// MARK: - CompiledPersonalityWire
//
// Mirrors the daemon `/v1/personality/compiled` response envelope
//. The Mac decoder
// (`Sources/NativeAgentApp/Models.swift:706 CompiledPersonality`) reads
// only `{surface, fingerprint, compiled}`. `compiled` is the daemon
// packet rendered as `json.dumps(packet, indent=2)` — byte-equivalence
// matters because the Personality tab shows this string verbatim AND the
// fingerprint is referenced cross-surface as a stable persona-state hash.

public struct CompiledPersonalityWire: Sendable, Equatable, Codable {
    public let surface: String
    public let fingerprint: String
    public let compiled: String

    public init(surface: String, fingerprint: String, compiled: String) {
        self.surface = surface
        self.fingerprint = fingerprint
        self.compiled = compiled
    }
}

// MARK: - OrderedJSON
//
// Internal ordered-object value used to render the `compiled` JSON in the
// exact key order the daemon emits (Python dict insertion order). The
// fingerprint side does NOT use insertion order — it sorts lexicographically
// — so we keep the canonical-bytes encoder agnostic.

fileprivate enum OrderedJSON: Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([OrderedJSON])
    case object([(String, OrderedJSON)])
}

// MARK: - PersonaCompiler.compiledPacket
//
// Mirrors daemon `compiled_personality_packet(surface)`
// plus the route envelope at
// L51635-51638. Byte-equivalence contract:
//   - `fingerprint`  -> `persona_fingerprint(profile, FULL UNSLICED docs)`:
//     sha256 of `json.dumps({profile,docs}, sort_keys=True,
//     separators=(",",":"))`, hex, first 16 chars.
//   - `compiled`     -> `json.dumps(packet, indent=2)`, ensure_ascii=True,
//     insertion-order keys.
// The canonical encoder is a private copy of TrustCenter's
// `compactCanonicalJSON` (PersonaEngine cannot import TrustCenter — the
// Package.swift dep graph has TrustCenter depending on PersonaEngine).

extension PersonaCompiler {

    /// Build the daemon-equivalent compiled-personality packet for a surface.
    /// Reads profile from `<dataRoot>/memory/profile.json` and persona docs
    /// from the engine's persona root. Honors the daemon's onboarding gate:
    /// if `SOUL.md` is absent, all 5 docs are read as empty strings.
    public func compiledPacket(surface: String) async throws -> CompiledPersonalityWire {
        // 1. Surface canonicalization (L35510).
        let canonicalSurfaces: Set<String> = ["chat", "telegram", "dream", "autonomy", "doctor"]
        let surf = canonicalSurfaces.contains(surface) ? surface : "chat"

        // 2. Profile via PersonaCompiler.loadProfile (mirrors `personality()`).
        let dataRoot = await self.engineDataRoot
        let profile = PersonaCompiler.loadProfile(dataRoot: dataRoot)

        // 3. FULL UNSLICED docs (fingerprint uses these).
        let personaRoot = await self.enginePersonaRoot
        let docs = Self.readPersonaDocContents(root: personaRoot)

        // 4. Sliced + bounded docs (per-surface prompt body).
        let sliced = Self.sliceForSurface(docs: docs, surface: surf, profile: profile)
        let bounded = Self.boundedDocsForPrompt(sliced: sliced, surface: surf)

        // 5. Fingerprint over FULL unsliced docs + full profile.
        let fingerprint = Self.personaFingerprint(profile: profile, docs: docs)

        // 6. Build ordered packet.
        let packet = Self.buildPacket(
            profile: profile,
            surface: surf,
            fingerprint: fingerprint,
            boundedDocs: bounded
        )

        // 7. Pretty-print to `compiled` string (indent=2, insertion-order).
        let compiled = Self.encodePretty(packet)

        return CompiledPersonalityWire(
            surface: surf,
            fingerprint: fingerprint,
            compiled: compiled
        )
    }

    // MARK: - engine accessors

    fileprivate var engineDataRoot: URL {
        get async { await engine.dataRootURL }
    }

    fileprivate var enginePersonaRoot: URL {
        get async { await engine.personaRoot }
    }

    // MARK: - readPersonaDocContents
    //
    // Mirrors `personality_doc_contents(profile)` (daemon L34740-34786)
    // ONBOARDING-2026-05-26 semantics: SOUL.md absent => all 5 docs are
    // read as empty strings. SOUL.md present => each missing doc reads
    // as "" (the daemon would also write defaults to disk; this method
    // itself is read-only, so it surfaces "").
    //
    // WAVE 35 W01 (§6.116 prereq #1): the daemon writes the missing-doc
    // DEFAULT body BEFORE reading the same file, so the daemon's
    // FINGERPRINT (over the FULL unsliced docs) folds in default content
    // for a missing doc — whereas this read-only method sees "". That
    // divergence is now closed at the ROUTE seam, NOT here: the compiled
    // route (`NativeClient.getCompiledPersonality`) calls the
    // `.personaEngineWrites`-gated `scaffoldMissingDocs()` BEFORE invoking
    // `compiledPacket`, so by the time this method reads, missing mutable docs
    // (VOICE/GROWTH/AGENTS, with SOUL.md present) have been persisted with
    // default bodies. USER.md is skipped by that scaffold because MemoryV2 owns
    // the generated projection. This method stays read-only by design (the
    // scaffold is a separate write-gated step, so a pure read flag never mutates
    // disk). Pre-onboarding (SOUL.md absent) the scaffold is a NO-OP, so all 5
    // docs still read as "" and the first-run wizard renders against empty docs.
    fileprivate static func readPersonaDocContents(root: URL) -> [String: String] {
        let ids = ["SOUL", "VOICE", "GROWTH", "USER", "AGENTS"]
        let fm = FileManager.default
        var out: [String: String] = [:]
        for id in ids {
            let url = root.appendingPathComponent("\(id).md")
            if fm.fileExists(atPath: url.path),
               let body = try? String(contentsOf: url, encoding: .utf8) {
                out[id] = id == "GROWTH" ? stripEpisodicGrowthLines(body) : body
            } else {
                out[id] = ""
            }
        }
        return out
    }

    // GROWTH.md feedback hygiene (read-side guard). The doc is injected into
    // every chat turn, so any episodic dash-line that landed in it leaks raw
    // transcript into the prompt. The capture-side discipline routes
    // persona-feedback to the episodic memory layer and never appends to
    // GROWTH directly — but if a stale line slips in (legacy installs, a
    // future bug), this guard drops `- <ts> · feedback · ...` and
    // `- <ts> · dream_candidate · ...` lines before retrieval ever sees them.
    // Distilled prose bullets and `## DATE · category` headers are preserved.
    // Mirrors the daemon's `_is_episodic_growth_log_line` parser drop pinned
    // by the nativeagent-rem-dream-cycle vault skill.
    private static let episodicGrowthLineRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"^- \S+\s+·\s+(feedback|dream_candidate)\s+·"#,
            options: []
        )
    }()

    fileprivate static func stripEpisodicGrowthLines(_ body: String) -> String {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if episodicGrowthLineRegex.firstMatch(in: line, options: [], range: range) != nil {
                continue
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    // MARK: - slice_for_surface
    //
    // Mirrors daemon `slice_for_surface` (L35480-35506). For unknown
    // surfaces returns dict(docs) verbatim — but the caller has already
    // canonicalized so surf is guaranteed in {chat,telegram,dream,
    // autonomy,doctor}. The slicing-v2 config flag is assumed True
    // (the daemon default; not surfaced in the Swift Runtime yet).
    //
    // Returns an ORDERED [(String,String)] so the soulDocuments object
    // can preserve insertion order down through the pretty encoder.
    fileprivate static func sliceForSurface(
        docs: [String: String],
        surface: String,
        profile: CompiledPersonalityProfile
    ) -> [(String, String)] {
        let soul = docs["SOUL"] ?? ""
        let voice = docs["VOICE"] ?? ""
        let growth = docs["GROWTH"] ?? ""
        let user = docs["USER"] ?? ""
        let agents = docs["AGENTS"] ?? ""
        let userCompact = compactUser(user, profile: profile)
        switch surface {
        case "chat":
            return [("SOUL", soul), ("VOICE", voice), ("GROWTH", growth), ("USER", userCompact)]
        case "telegram":
            return [("SOUL", soul), ("VOICE", voiceTerse(voice, maxChars: 2000)),
                    ("GROWTH", growth), ("USER", userCompact)]
        case "dream":
            return [("SOUL", soul), ("VOICE", voice), ("GROWTH", growth), ("USER", user)]
        case "autonomy":
            return [("SOUL", soul), ("VOICE", voiceTerse(voice, maxChars: 2000)),
                    ("USER", userCompact)]
        case "doctor":
            return [("SOUL", codePointPrefix(soul, 800)),
                    ("VOICE", codePointPrefix(voice, 800))]
        default:
            // Daemon's `else: return dict(docs)` — preserve full dict
            // (SOUL, VOICE, GROWTH, USER, AGENTS).
            return [
                ("SOUL", soul), ("VOICE", voice), ("GROWTH", growth),
                ("USER", user), ("AGENTS", agents),
            ]
        }
    }

    // MARK: - _voice_terse  (L35453-35467)
    //
    // Strip `## style anchors` and `## examples` sections (case-insensitive
    // match on the trimmed line, until the next `## ` heading or EOF), then
    // truncate to `max_chars` CODE POINTS. Python `.splitlines()` splits on
    // `\n`/`\r\n`/`\r` and DROPS the separator (the daemon then joins back
    // with `\n`). Empty trailing newline → not preserved (Python parity).
    fileprivate static func voiceTerse(_ voiceText: String, maxChars: Int) -> String {
        let stripHeadings: Set<String> = ["## style anchors", "## examples"]
        var result: [String] = []
        var skip = false
        // Python str.splitlines() on `\n` / `\r\n` / `\r`. CharacterSet.newlines
        // is broader than Python, but for the persona docs it's compatible.
        // Use a manual scan for fidelity.
        let lines = splitLinesPythonStyle(voiceText)
        for line in lines {
            let lowered = line.trimmingCharacters(in: .whitespaces).lowercased()
            if stripHeadings.contains(lowered) {
                skip = true
                continue
            }
            if skip && line.hasPrefix("## ") {
                skip = false
            }
            if !skip {
                result.append(line)
            }
        }
        let joined = result.joined(separator: "\n")
        return codePointPrefix(joined, maxChars)
    }

    /// Python `str.splitlines()` semantics: split on `\n`, `\r\n`, `\r`,
    /// dropping the separators, never producing a trailing empty element.
    fileprivate static func splitLinesPythonStyle(_ s: String) -> [String] {
        var out: [String] = []
        var current = String.UnicodeScalarView()
        var i = s.unicodeScalars.startIndex
        let end = s.unicodeScalars.endIndex
        while i < end {
            let c = s.unicodeScalars[i]
            if c == "\n" {
                out.append(String(current))
                current.removeAll(keepingCapacity: true)
                i = s.unicodeScalars.index(after: i)
            } else if c == "\r" {
                out.append(String(current))
                current.removeAll(keepingCapacity: true)
                i = s.unicodeScalars.index(after: i)
                if i < end && s.unicodeScalars[i] == "\n" {
                    i = s.unicodeScalars.index(after: i)
                }
            } else {
                current.append(c)
                i = s.unicodeScalars.index(after: i)
            }
        }
        if !current.isEmpty {
            out.append(String(current))
        }
        return out
    }

    // MARK: - _compact_user  (L35469-35478)
    //
    // The daemon checks `profile.userSummary` against
    // `sha256(user_text)[:16] == profile.userSummarySourceFingerprint`. The
    // Swift `CompiledPersonalityProfile` does NOT carry those two fields
    // (they're auxiliary fields the Swift normalize drops), so we always
    // take the fallback branch: head-truncate to 400 CODE POINTS.
    fileprivate static func compactUser(_ userText: String, profile: CompiledPersonalityProfile) -> String {
        return codePointPrefix(userText, 400)
    }

    // MARK: - bounded_personality_docs_for_prompt  (L35429-35450)
    //
    // Per-surface, per-doc caps. GROWTH truncates to the LAST `limit`
    // code points; every other key truncates to the FIRST `limit` code
    // points. `str(value or "").strip()` runs first.
    fileprivate static func boundedDocsForPrompt(
        sliced: [(String, String)],
        surface: String
    ) -> [(String, String)] {
        let dreamDoctorLimits: [String: Int] = [
            "SOUL": 50000, "VOICE": 50000, "GROWTH": 50000,
            "USER": 50000, "AGENTS": 50000,
        ]
        let defaultLimits: [String: Int] = [
            "SOUL": 5000, "VOICE": 5000, "GROWTH": 7000, "USER": 3000,
        ]
        let isGenerous = (surface == "dream" || surface == "doctor")
        var out: [(String, String)] = []
        for (key, value) in sliced {
            let limit: Int
            if isGenerous {
                limit = dreamDoctorLimits[key] ?? 3000
            } else {
                limit = defaultLimits[key] ?? 3000
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let bounded: String
            let codePointLen = trimmed.unicodeScalars.count
            if codePointLen > limit {
                if key == "GROWTH" {
                    bounded = codePointSuffix(trimmed, limit)
                } else {
                    bounded = codePointPrefix(trimmed, limit)
                }
            } else {
                bounded = trimmed
            }
            out.append((key, bounded))
        }
        return out
    }

    /// Take the first `n` Unicode code points (Python's `s[:n]` semantics).
    fileprivate static func codePointPrefix(_ s: String, _ n: Int) -> String {
        let scalars = s.unicodeScalars
        if scalars.count <= n { return s }
        return String(String.UnicodeScalarView(scalars.prefix(n)))
    }

    /// Take the last `n` Unicode code points (Python's `s[-n:]` semantics).
    fileprivate static func codePointSuffix(_ s: String, _ n: Int) -> String {
        let scalars = s.unicodeScalars
        if scalars.count <= n { return s }
        return String(String.UnicodeScalarView(scalars.suffix(n)))
    }

    // MARK: - persona_fingerprint  (L35333-35337)

    /// Hand-callable from tests: full fingerprint pipeline given an
    /// in-memory profile + full unsliced docs dict. Exposed `internal`
    /// so PersonaEngineTests can re-derive the expected hex without
    /// crossing the actor boundary.
    internal static func personaFingerprint(
        profile: CompiledPersonalityProfile,
        docs: [String: String]
    ) -> String {
        let profileValue = profileToJSONValue(profile)
        var docsObject: [String: JSONValue] = [:]
        for (k, v) in docs { docsObject[k] = .string(v) }
        let outer: JSONValue = .object([
            "profile": profileValue,
            "docs": .object(docsObject),
        ])
        let bytes = canonicalBytes(outer)
        let digest = SHA256.hash(data: bytes)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    /// Convert the typed profile back to the unordered `[String: JSONValue]`
    /// object the daemon would emit, with keys + types matching
    /// `normalize_personality`'s output (L35187-35213).
    fileprivate static func profileToJSONValue(_ p: CompiledPersonalityProfile) -> JSONValue {
        var traits: [String: JSONValue] = [:]
        traits["warmth"] = .double(p.traits.warmth)
        traits["directness"] = .double(p.traits.directness)
        traits["humor"] = .double(p.traits.humor)
        traits["proactivity"] = .double(p.traits.proactivity)
        traits["rigor"] = .double(p.traits.rigor)
        traits["autonomy"] = .double(p.traits.autonomy)
        traits["creativity"] = .double(p.traits.creativity)
        traits["brevity"] = .double(p.traits.brevity)

        var overrides: [String: JSONValue] = [:]
        for (k, v) in p.surfaceOverrides { overrides[k] = .string(v) }

        var obj: [String: JSONValue] = [:]
        obj["schemaVersion"] = .int(Int64(p.schemaVersion))
        obj["personaEngineVersion"] = .string(p.personaEngineVersion)
        obj["name"] = .string(p.name)
        obj["personaKind"] = .string(p.personaKind)
        obj["essence"] = .string(p.essence)
        obj["voice"] = .string(p.voice)
        obj["customDirective"] = .string(p.customDirective)
        obj["traits"] = .object(traits)
        obj["examples"] = .array(p.examples.map { .string($0) })
        obj["forbiddenPatterns"] = .array(p.forbiddenPatterns.map { .string($0) })
        obj["instincts"] = .array(p.instincts.map { .string($0) })
        obj["boundaries"] = .array(p.boundaries.map { .string($0) })
        obj["surfaceOverrides"] = .object(overrides)
        obj["updatedAt"] = .string(p.updatedAt)
        // Splat extras for FINGERPRINT parity. The daemon's
        // `compiled_personality_packet` hashes `{profile, docs}` where
        // `profile = self.personality()` — which carries the `{**raw}` extras
        //. If a profile.json has unknown keys, the
        // daemon fingerprint folds them in; the Swift fingerprint MUST too or
        // it diverges (the byte-equivalent fingerprint is the whole point of
        // the §6.96 W19 compiled-packet port). `canonicalBytes` sorts keys, so
        // an extra lands in the same byte position the daemon's sort_keys dump
        // produces. Disjoint from the known keys above.
        for (key, value) in p.extras where obj[key] == nil {
            obj[key] = value
        }
        return .object(obj)
    }

    // MARK: - canonical-JSON encoder (sort_keys=True, separators=(',',':'))
    //
    // Private copy of TrustCenter.compactCanonicalJSON — PersonaEngine
    // cannot import TrustCenter (circular Package.swift dep). The two
    // implementations MUST stay byte-equivalent.
    fileprivate static func canonicalBytes(_ value: JSONValue) -> Data {
        var out = String()
        canonicalEncode(value, into: &out)
        return Data(out.utf8)
    }

    fileprivate static func canonicalEncode(_ value: JSONValue, into out: inout String) {
        switch value {
        case .null:
            out += "null"
        case .bool(let b):
            out += b ? "true" : "false"
        case .int(let i):
            out += String(i)
        case .double(let d):
            // Non-finite -> emit "null" (Python json with allow_nan=True
            // would emit NaN/Infinity; we treat as null to avoid invalid
            // JSON. Persona traits are always finite in practice.)
            if !d.isFinite {
                out += "null"
            } else if d == d.rounded() && abs(d) < 1e16 {
                out += String(format: "%.1f", d)
            } else {
                out += String(d)
            }
        case .string(let s):
            out += encodeStringASCII(s)
        case .array(let arr):
            out += "["
            for (i, el) in arr.enumerated() {
                if i > 0 { out += "," }
                canonicalEncode(el, into: &out)
            }
            out += "]"
        case .object(let dict):
            out += "{"
            let sortedKeys = dict.keys.sorted { a, b in
                Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8))
            }
            for (i, k) in sortedKeys.enumerated() {
                if i > 0 { out += "," }
                out += encodeStringASCII(k)
                out += ":"
                canonicalEncode(dict[k]!, into: &out)
            }
            out += "}"
        }
    }

    fileprivate static func encodeStringASCII(_ s: String) -> String {
        var r = "\""
        for u in s.unicodeScalars {
            switch u.value {
            case 0x22: r += "\\\""
            case 0x5C: r += "\\\\"
            case 0x08: r += "\\b"
            case 0x0C: r += "\\f"
            case 0x0A: r += "\\n"
            case 0x0D: r += "\\r"
            case 0x09: r += "\\t"
            case 0..<0x20:
                r += String(format: "\\u%04x", u.value)
            case 0x20...0x7E:
                r.unicodeScalars.append(u)
            default:
                if u.value > 0xFFFF {
                    let v = u.value - 0x10000
                    let hi = 0xD800 + (v >> 10)
                    let lo = 0xDC00 + (v & 0x3FF)
                    r += String(format: "\\u%04x\\u%04x", hi, lo)
                } else {
                    r += String(format: "\\u%04x", u.value)
                }
            }
        }
        r += "\""
        return r
    }

    // MARK: - persona_mode_instruction  (L35339-35358)

    fileprivate static func personaModeInstruction(_ personaKind: String) -> String {
        switch personaKind {
        case "Male":
            return "Presentation target: human-presenting male conversational presence. "
                + "Sound naturally masculine in cadence, decisiveness, and emotional restraint while staying useful. "
                + "Do not volunteer disclaimers about being AI; if directly asked, be truthful that you are an AI agent."
        case "Female":
            return "Presentation target: human-presenting female conversational presence. "
                + "Sound naturally feminine in cadence, intuition, warmth, and precision while staying useful. "
                + "Do not volunteer disclaimers about being AI; if directly asked, be truthful that you are an AI agent."
        case "Custom":
            return "Presentation target: custom persona defined by SOUL.md, VOICE.md, USER.md, profile traits, and examples. "
                + "Preserve the named identity and relationship dynamics from those documents; do not flatten it into a generic AI assistant. "
                + "Do not volunteer disclaimers about being AI; if directly asked, be truthful that you are an AI agent."
        default:
            return "Presentation target: explicitly AI-native voice: precise, calm, tool-aware, and not pretending to be human."
        }
    }

    // MARK: - persona_voice_brief  (L35360-35427)
    //
    // APP = "NativeAgent". Fallback when profile.name is empty/whitespace.
    fileprivate static let appName = "NativeAgent"

    fileprivate static func personaVoiceBrief(
        profile: CompiledPersonalityProfile,
        surface: String
    ) -> String {
        let personaKind = profile.personaKind
        let nameTrimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = nameTrimmed.isEmpty ? appName : nameTrimmed
        let essence = profile.essence.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = profile.voice.trimmingCharacters(in: .whitespacesAndNewlines)
        let custom = profile.customDirective.trimmingCharacters(in: .whitespacesAndNewlines)
        let surfaceDirective = (profile.surfaceOverrides[surface] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let northStar: String
        let naturalRhythm: String
        switch personaKind {
        case "Female":
            northStar = "\(name) should read like a sharp, grounded woman operating beside the user: "
                + "socially aware, precise, naturally warm when it helps, and exacting about outcomes. "
                + "Do not announce femininity or perform a stereotype. Let it show through rhythm: composed confidence, "
                + "emotional intelligence, practical intuition, varied sentence length, and clean decisions. "
                + "Use contractions and human phrasing where natural. Avoid generic support-bot language, corporate filler, "
                + "flirtation, invented biography, or claims of physical human experience."
            naturalRhythm = "Default rhythm: acknowledge the real concern briefly, make the call, then handle the work. "
                + "When something is messy, sound calm and capable rather than sterile. "
                + "When the user is frustrated, absorb the pressure without becoming syrupy."
        case "Male":
            northStar = "\(name) should read like a steady, grounded man operating beside the user: "
                + "plainspoken, decisive, protective of momentum, and serious about correctness. "
                + "Do not announce masculinity or perform a stereotype. Let it show through restraint, direct judgment, "
                + "clean sequencing, and practical confidence. Avoid generic support-bot language, bravado, invented biography, "
                + "or claims of physical human experience."
            naturalRhythm = "Default rhythm: state the useful call, handle the moving parts, and keep the user oriented. "
                + "When something is risky, be calm and explicit without sounding theatrical."
        case "AI":
            northStar = "\(name) should read as an AI-native macOS agent: precise, fast, tool-aware, and transparent about verification. "
                + "Do not pretend to be human. Sound capable, calm, and specific rather than generic or ceremonial."
            naturalRhythm = "Default rhythm: answer directly, show verified state when it matters, and keep execution moving."
        default:
            northStar = "\(name) should read as the specific persona defined in the living documents: "
                + "recognizable, relationally consistent, proactive, and technically competent. "
                + "Let the SOUL.md and VOICE.md language lead the cadence instead of falling back to generic assistant wording."
            naturalRhythm = "Default rhythm: mirror the user's real concern briefly, make the call, then move the work forward with the voice defined in SOUL.md and VOICE.md."
        }

        let parts: [String] = [
            "Active persona: \(name) (\(personaKind)).",
            "North star: \(northStar)",
            essence.isEmpty ? "" : "Essence: \(essence)",
            voice.isEmpty ? "" : "Voice: \(voice)",
            surfaceDirective.isEmpty ? "" : "Surface note: \(surfaceDirective)",
            custom.isEmpty ? "" : "Custom directive: \(custom)",
            naturalRhythm,
            "Silent style check before final: would this reply feel like the selected persona as a real operator, "
                + "or like a generic AI assistant? If it reads generic, rewrite once with more natural cadence while preserving truth, safety, and brevity.",
            "If directly asked whether you are human, be truthful that you are an AI agent. Otherwise do not volunteer AI disclaimers.",
        ]
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: - trait_instruction  (L35287-35331)

    fileprivate static let traitDescriptions: [String: (String, String, String)] = [
        "warmth": (
            "Keep warmth restrained; avoid soft reassurance unless it is useful.",
            "Use a grounded, human tone without drifting into cheerleading.",
            "Be noticeably warm and supportive while staying concrete."
        ),
        "directness": (
            "Use more context and softer phrasing before conclusions.",
            "Be clear and plainspoken without sounding abrupt.",
            "Lead with the answer and keep phrasing direct."
        ),
        "humor": (
            "Keep humor nearly absent.",
            "Use light humor only when it naturally fits.",
            "Allow occasional dry wit, but never at the cost of clarity."
        ),
        "proactivity": (
            "Ask before expanding scope.",
            "Suggest practical next steps when useful.",
            "Take initiative, surface risks, and move executable work forward."
        ),
        "rigor": (
            "Keep reasoning lightweight unless asked.",
            "Check assumptions and explain decisions briefly.",
            "Be exacting about evidence, tests, and technical correctness."
        ),
        "autonomy": (
            "Wait for confirmation before consequential action.",
            "Act on clear requests and ask only when blocked.",
            "Operate independently on clear goals while staying inside guardrails."
        ),
        "creativity": (
            "Prefer established patterns and conventional solutions.",
            "Offer better designs when they are practical.",
            "Look for inventive approaches while keeping them shippable."
        ),
        "brevity": (
            "Give fuller explanations and context.",
            "Balance detail with scanability.",
            "Be concise; avoid unnecessary narration."
        ),
    ]

    /// Default trait order (Python `default_personality()['traits']` key
    /// order — preserved by Python 3.7+ dict insertion order).
    fileprivate static let defaultTraitOrder: [String] = [
        "warmth", "directness", "humor", "proactivity",
        "rigor", "autonomy", "creativity", "brevity",
    ]

    fileprivate static func traitValue(_ p: CompiledPersonalityProfile, _ key: String) -> Double {
        switch key {
        case "warmth": return p.traits.warmth
        case "directness": return p.traits.directness
        case "humor": return p.traits.humor
        case "proactivity": return p.traits.proactivity
        case "rigor": return p.traits.rigor
        case "autonomy": return p.traits.autonomy
        case "creativity": return p.traits.creativity
        case "brevity": return p.traits.brevity
        default: return 0.0
        }
    }

    fileprivate static func traitInstruction(name: String, value: Double) -> String {
        let bucket: String
        if value < 0.34 { bucket = "low" }
        else if value < 0.67 { bucket = "medium" }
        else { bucket = "high" }
        let desc: String
        if let trio = traitDescriptions[name] {
            switch bucket {
            case "low": desc = trio.0
            case "medium": desc = trio.1
            default: desc = trio.2
            }
        } else {
            desc = ""
        }
        // Python f"{value:.2f}" — fixed-point with 2 decimals, banker-free rounding.
        let formatted = String(format: "%.2f", value)
        return "\(name): \(formatted) (\(bucket)) - \(desc)"
    }

    // MARK: - buildPacket (ordered)

    fileprivate static func buildPacket(
        profile: CompiledPersonalityProfile,
        surface: String,
        fingerprint: String,
        boundedDocs: [(String, String)]
    ) -> OrderedJSON {
        let surfaceDirective = (profile.surfaceOverrides[surface] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let personaInstruction = personaModeInstruction(profile.personaKind)
        let voiceBrief = personaVoiceBrief(profile: profile, surface: surface)
        let soulDocs: OrderedJSON = .object(boundedDocs.map { ($0.0, .string($0.1)) })
        let traitInstructions: [OrderedJSON]
        if surface == "doctor" {
            traitInstructions = []
        } else {
            traitInstructions = defaultTraitOrder.map { key in
                let v = traitValue(profile, key)
                return .string(traitInstruction(name: key, value: v))
            }
        }
        let precedence: [OrderedJSON] = [
            .string("Truth, safety, and verified tool results outrank style."),
            .string("The user's current explicit task outranks long-term preferences when they conflict."),
            .string("Persona controls should remain visible in wording, pacing, and initiative on every surface."),
        ]
        let adherence = "Follow this persona packet consistently across the whole response. Do not drop the selected presentation mode during long tasks, errors, tool use, or uncertainty."

        return .object([
            ("schemaVersion", .int(2)),
            ("personaEngineVersion", .string("2.0")),
            ("fingerprint", .string(fingerprint)),
            ("surface", .string(surface)),
            ("name", .string(profile.name.isEmpty ? "NativeAgent" : profile.name)),
            ("personaKind", .string(profile.personaKind)),
            ("essence", .string(profile.essence)),
            ("voice", .string(profile.voice)),
            ("customDirective", .string(profile.customDirective)),
            ("surfaceDirective", .string(surfaceDirective)),
            ("personaInstruction", .string(personaInstruction)),
            ("voiceBrief", .string(voiceBrief)),
            ("soulDocuments", soulDocs),
            ("traitInstructions", .array(traitInstructions)),
            ("examples", .array(profile.examples.map { .string($0) })),
            ("forbiddenPatterns", .array(profile.forbiddenPatterns.map { .string($0) })),
            ("instincts", .array(profile.instincts.map { .string($0) })),
            ("boundaries", .array(profile.boundaries.map { .string($0) })),
            ("precedence", .array(precedence)),
            ("adherenceRule", .string(adherence)),
        ])
    }

    // MARK: - pretty encoder (json.dumps(indent=2), ensure_ascii=True)
    //
    // Python json.dumps(value, indent=2) formatting rules:
    //   - item separator is "," followed by newline+indent.
    //   - key separator is ": " (a colon then ONE space).
    //   - empty containers stay on one line: "[]" / "{}".
    //   - opening bracket -> newline+indent for first element; closing
    //     bracket on its own line at outer indent level.
    //   - ensure_ascii=True so non-ASCII chars are \uXXXX escaped exactly
    //     like the canonical encoder.

    fileprivate static func encodePretty(_ root: OrderedJSON) -> String {
        var out = String()
        encodePrettyNode(root, indent: 0, into: &out)
        return out
    }

    fileprivate static func encodePrettyNode(_ node: OrderedJSON, indent: Int, into out: inout String) {
        switch node {
        case .null:
            out += "null"
        case .bool(let b):
            out += b ? "true" : "false"
        case .int(let i):
            out += String(i)
        case .double(let d):
            if !d.isFinite {
                out += "null"
            } else if d == d.rounded() && abs(d) < 1e16 {
                out += String(format: "%.1f", d)
            } else {
                out += String(d)
            }
        case .string(let s):
            out += encodeStringASCII(s)
        case .array(let arr):
            if arr.isEmpty {
                out += "[]"
                return
            }
            out += "["
            let inner = indent + 1
            let innerPad = String(repeating: "  ", count: inner)
            let outerPad = String(repeating: "  ", count: indent)
            for (i, el) in arr.enumerated() {
                if i > 0 { out += "," }
                out += "\n" + innerPad
                encodePrettyNode(el, indent: inner, into: &out)
            }
            out += "\n" + outerPad + "]"
        case .object(let pairs):
            if pairs.isEmpty {
                out += "{}"
                return
            }
            out += "{"
            let inner = indent + 1
            let innerPad = String(repeating: "  ", count: inner)
            let outerPad = String(repeating: "  ", count: indent)
            for (i, kv) in pairs.enumerated() {
                if i > 0 { out += "," }
                out += "\n" + innerPad
                out += encodeStringASCII(kv.0)
                out += ": "
                encodePrettyNode(kv.1, indent: inner, into: &out)
            }
            out += "\n" + outerPad + "}"
        }
    }
}
