// U3 wave-2 item 7 (2026-06-10): the known-answer PROBE SET that gates
// every consolidation.
//
// A probe is a natural recall question plus what a correct recall must
// surface — an expected memory id and/or one of several expected content
// substrings. The probe runner (MemoryV2+ProbeRunner.swift) embeds each
// question, runs MemoryStorage.recall, and counts a hit when the top-K
// contains the expected row. The consolidation gate
// (MemoryV2+ConsolidationGate.swift) scores BOTH the live store and the
// consolidation candidate with the same probe vectors and refuses to stage
// any candidate that scores below live.
//
// DERIVATION (reproducible): the 50 built-in probes below were hand-derived
// on 2026-06-10 from the 32 ACTIVE rows of the live store
// (data/memory/memory.sqlite, read-only:
//   sqlite3 "file:data/memory/memory.sqlite?mode=ro" \
//     "SELECT id, content FROM memories WHERE status='active' ORDER BY created_at;"
// ). Every row carries at least one probe; the richer rows carry two.
// Expected substrings are verbatim slices of the row's content, chosen to
// (a) be distinctive enough not to over-match other rows and (b) SURVIVE
// the pending wave-1 `memory.repair` cards — for the 5 daemon-era truncated
// rows the substring lives in the prefix that the LLM-suggested completion
// keeps (see MemoryRepairOneShot.truncatedRowSuggestedCompletions).
//
// OVERRIDE: <dataRoot>/memory/probes/probe_set.json replaces the built-ins
// when present and valid, so the user/Agent can evolve the probe set without a
// rebuild. Shape:
//   { "version": 1, "top_k": 5,
//     "probes": [ { "id": "p01", "question": "...",
//                   "expect_memory_id": "...",            // optional
//                   "expect_any_substring": ["...", ...]  // optional
//                 }, ... ] }
// A probe with NEITHER expectation is invalid; an override file that parses
// to zero valid probes is rejected (built-ins win) — and the gate itself
// fails closed on an empty effective set.

import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - MemoryProbe

public struct MemoryProbe: Sendable, Equatable {
    /// Stable id for per-miss reporting.
    public let id: String
    /// The recall question, embedded verbatim by the probe runner.
    public let question: String
    /// Hit when the top-K contains this memory id…
    public let expectMemoryId: String?
    /// …or any top-K content contains ANY of these substrings
    /// (case-insensitive). Either expectation satisfies the probe.
    public let expectAnySubstring: [String]

    public init(
        id: String,
        question: String,
        expectMemoryId: String? = nil,
        expectAnySubstring: [String] = []
    ) {
        self.id = id
        self.question = question
        self.expectMemoryId = expectMemoryId
        self.expectAnySubstring = expectAnySubstring
    }

    /// A probe with no expectation can never be evaluated — treat as invalid.
    public var isValid: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (expectMemoryId != nil || expectAnySubstring.contains { !$0.isEmpty })
    }
}

// MARK: - MemoryProbeSet

public struct MemoryProbeSet: Sendable, Equatable {
    public let version: Int
    /// Top-K recall window a probe must land in to count as a hit.
    public let topK: Int
    public let probes: [MemoryProbe]

    public init(version: Int = 1, topK: Int = 5, probes: [MemoryProbe]) {
        self.version = version
        self.topK = max(1, topK)
        self.probes = probes
    }

    /// Effective probe set for a data root: the on-disk override when it
    /// parses to at least one valid probe, the built-ins otherwise.
    public static func load(dataRoot: URL) -> MemoryProbeSet {
        let overridePath = overridePath(dataRoot: dataRoot)
        if let data = try? Data(contentsOf: overridePath),
           let parsed = parse(data: data),
           !parsed.probes.isEmpty {
            return parsed
        }
        return .builtin
    }

    public static func overridePath(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("probes", isDirectory: true)
            .appendingPathComponent("probe_set.json")
    }

    /// Parse the JSON shape documented in the header. Returns nil when the
    /// document is structurally wrong; silently drops individual invalid
    /// probes (a typo in one row must not nuke the whole override).
    public static func parse(data: Data) -> MemoryProbeSet? {
        guard let parsed = try? JSONValue.parse(data),
              case .object(let obj) = parsed,
              case .array(let rawProbes)? = obj["probes"] else { return nil }
        let version: Int = {
            if case .int(let v)? = obj["version"] { return Int(v) }
            return 1
        }()
        let topK: Int = {
            if case .int(let k)? = obj["top_k"] { return Int(k) }
            return 5
        }()
        let probes: [MemoryProbe] = rawProbes.compactMap { raw in
            guard case .object(let p) = raw,
                  case .string(let id)? = p["id"], !id.isEmpty,
                  case .string(let question)? = p["question"] else { return nil }
            let expectId: String? = {
                if case .string(let s)? = p["expect_memory_id"], !s.isEmpty { return s }
                return nil
            }()
            let substrings: [String] = {
                guard case .array(let items)? = p["expect_any_substring"] else { return [] }
                return items.compactMap {
                    if case .string(let s) = $0, !s.isEmpty { return s }
                    return nil
                }
            }()
            let probe = MemoryProbe(
                id: id, question: question,
                expectMemoryId: expectId, expectAnySubstring: substrings
            )
            return probe.isValid ? probe : nil
        }
        return MemoryProbeSet(version: version, topK: topK, probes: probes)
    }

    // MARK: - Built-in set

    public static let builtin = MemoryProbeSet(version: 1, topK: 5, probes: [
        MemoryProbe(id: "p01", question: "What is the status of X OAuth setup for NativeAgent?",
                    expectAnySubstring: ["X OAuth authentication for NativeAgent"]),
        MemoryProbe(id: "p02", question: "How should the assistant infer the user's gender references?",
                    expectAnySubstring: ["natural gender inference from context"]),
        MemoryProbe(id: "p03", question: "Should gender be explicitly documented in user.md?",
                    expectAnySubstring: ["explicit documentation in user.md"]),
        MemoryProbe(id: "p04", question: "How many workers can be allocated per task?",
                    expectAnySubstring: ["worker allocation (1-20 range)"]),
        MemoryProbe(id: "p05", question: "What does the phrase Directive holding refer to?",
                    expectAnySubstring: ["Directive holding"]),
        MemoryProbe(id: "p06", question: "What kind of notifications should the assistant send?",
                    expectAnySubstring: ["meaningful, intentional notifications"]),
        MemoryProbe(id: "p07", question: "Should the assistant send engagement-focused notification spam?",
                    expectAnySubstring: ["engagement-focused spam"]),
        MemoryProbe(id: "p08", question: "What makes a good commit message?",
                    expectAnySubstring: ["name the actual failure mode"]),
        MemoryProbe(id: "p09", question: "What is NativeAgent?",
                    expectAnySubstring: ["native macOS agent system"]),
        MemoryProbe(id: "p10", question: "What capabilities does NativeAgent provide?",
                    expectAnySubstring: ["autonomous tools, and trait tuning"]),
        MemoryProbe(id: "p11", question: "How many P1 bugs did the swarm debugging session find?",
                    expectAnySubstring: ["4 P1 bugs"]),
        MemoryProbe(id: "p12", question: "Can sub-agents spin up across multiple providers?",
                    expectAnySubstring: ["Claude, GPT, Codex"]),
        MemoryProbe(id: "p13", question: "What is the status of swarm synthesis testing?",
                    expectAnySubstring: ["synthesis functioning end-to-end"]),
        MemoryProbe(id: "p14", question: "What is the next step for swarm-presets-2?",
                    expectAnySubstring: ["context_recipe resolution"]),
        MemoryProbe(id: "p15", question: "Is the context_recipe resolution built yet?",
                    expectAnySubstring: ["currently unbuilt"]),
        MemoryProbe(id: "p16", question: "How should messages be formatted and segmented?",
                    expectAnySubstring: ["one distinct signal per message"]),
        MemoryProbe(id: "p17", question: "Are consolidated walls of text preferred?",
                    expectAnySubstring: ["walls of text"]),
        MemoryProbe(id: "p18", question: "How is trust built in this system?",
                    expectAnySubstring: ["trusts by stress-testing"]),
        MemoryProbe(id: "p19", question: "When does the user relax about a system's reliability?",
                    expectAnySubstring: ["respond cleanly without defensiveness"]),
        MemoryProbe(id: "p20", question: "How should the system treat stress-testing?",
                    expectAnySubstring: ["rather than as criticism"]),
        MemoryProbe(id: "p21", question: "Is being stress-tested criticism?",
                    expectAnySubstring: ["verify robustness"]),
        MemoryProbe(id: "p22", question: "How should the assistant respond to jokes?",
                    expectAnySubstring: ["catches jokes without over-interpreting"]),
        MemoryProbe(id: "p23", question: "What data exists for building evaluation harnesses?",
                    expectAnySubstring: ["real long-session conversation history"]),
        MemoryProbe(id: "p24", question: "Should search activity be narrated verbosely?",
                    expectAnySubstring: ["without verbose search activity narration"]),
        MemoryProbe(id: "p25", question: "Is confident wrongness preferred over honest self-correction?",
                    expectAnySubstring: ["honest self-correction and vulnerability"]),
    ])
}
