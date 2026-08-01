import Testing
@testable import NativeAgentApp

// Pins the public-era plain-English copy helpers (UI-2 / UI-5 / detached chat
// error copy, 2026-08-01). These are the pure surfaces behind the honesty
// restructure: the views only decide placement, these decide wording.
//
// The point of these tests is the HONESTY property, not the exact prose: a
// user-facing headline must never carry a raw identifier, a file path, or a
// backend product name.

@Suite("Doctor plain-English copy")
struct DoctorPlainCopyTests {

    private func check(_ id: String, _ status: String) -> DoctorCheck {
        DoctorCheck(id: id, title: id, status: status, detail: "", repair: nil)
    }

    @Test("buckets raw statuses into the three words a person can act on")
    func bucketing() {
        #expect(DoctorPlainCopy.bucket(for: "ok") == "healthy")
        #expect(DoctorPlainCopy.bucket(for: "PASSED") == "healthy")
        #expect(DoctorPlainCopy.bucket(for: "warn") == "warning")
        #expect(DoctorPlainCopy.bucket(for: "needs_setup") == "warning")
        #expect(DoctorPlainCopy.bucket(for: "failed") == "failing")
        #expect(DoctorPlainCopy.bucket(for: "timeout") == "failing")
        #expect(DoctorPlainCopy.bucket(for: "who-knows") == "unclear")
    }

    @Test("summary counts every check exactly once")
    func summaryCounts() {
        let summary = DoctorPlainCopy.summarize([
            check("llm", "ok"),
            check("tools", "ok"),
            check("telegram", "warn"),
            check("searxng", "failed"),
            check("mystery", "banana"),
        ])
        #expect(summary.healthy == 2)
        #expect(summary.warning == 1)
        #expect(summary.failing == 1)
        #expect(summary.unclear == 1)
        #expect(summary.total == 5)
    }

    @Test("headline escalates worst-first and stays plain")
    func headlineEscalation() {
        var summary = DoctorPlainCopy.Summary()
        #expect(DoctorPlainCopy.headline(for: summary) == "No checks have run yet.")

        summary = DoctorPlainCopy.Summary(healthy: 3)
        #expect(DoctorPlainCopy.headline(for: summary) == "Everything looks healthy.")

        summary = DoctorPlainCopy.Summary(healthy: 3, warning: 1)
        #expect(DoctorPlainCopy.headline(for: summary).contains("need attention"))

        // Failing outranks warning even when both are present.
        summary = DoctorPlainCopy.Summary(healthy: 3, warning: 1, failing: 1)
        #expect(DoctorPlainCopy.headline(for: summary) == "Some parts of the app are not working.")
    }

    @Test("status dot never disagrees with the headline")
    func statusTextMatchesHeadline() {
        #expect(DoctorPlainCopy.Summary().statusText == "unknown")
        #expect(DoctorPlainCopy.Summary(healthy: 2).statusText == "ok")
        #expect(DoctorPlainCopy.Summary(healthy: 2, warning: 1).statusText == "warn")
        #expect(DoctorPlainCopy.Summary(healthy: 2, warning: 1, failing: 1).statusText == "failed")
    }

    @Test("detail names counts in words and drops empty buckets")
    func detailCopy() {
        #expect(DoctorPlainCopy.detail(for: DoctorPlainCopy.Summary())
            == "Press Run Doctor to check how the app is doing.")

        let clean = DoctorPlainCopy.detail(for: DoctorPlainCopy.Summary(healthy: 4))
        #expect(clean == "4 areas checked: 4 working.")
        #expect(!clean.contains("need attention"))
        #expect(!clean.contains("unclear"))

        let mixed = DoctorPlainCopy.detail(for: DoctorPlainCopy.Summary(healthy: 4, warning: 2, failing: 1))
        #expect(mixed.contains("7 areas checked"))
        #expect(mixed.contains("2 need attention"))
        #expect(mixed.contains("1 not working"))

        #expect(DoctorPlainCopy.detail(for: DoctorPlainCopy.Summary(healthy: 1)).contains("1 area checked"))
    }

    @Test("section titles translate every code-word group key")
    func sectionTitles() {
        let groups = ["Provider", "Runtime", "Connectors", "Data", "Tools", "Autonomy", "Release"]
        for group in groups {
            let title = DoctorPlainCopy.sectionTitle(for: group)
            #expect(!title.isEmpty)
        }
        #expect(DoctorPlainCopy.sectionTitle(for: "Provider") == "AI provider")
        #expect(DoctorPlainCopy.sectionTitle(for: "Connectors") == "Connected services")
        #expect(DoctorPlainCopy.sectionTitle(for: "Autonomy") == "Actions the agent takes on its own")
        // Unknown keys pass through rather than rendering blank.
        #expect(DoctorPlainCopy.sectionTitle(for: "Wombat") == "Wombat")
    }

    @Test("loop identifiers render as readable names, never as raw ids")
    func friendlyLoopNames() {
        #expect(DoctorPlainCopy.friendlyLoopName("github_tracking") == "Github tracking")
        #expect(DoctorPlainCopy.friendlyLoopName("slack-socket-mode") == "Slack socket mode")
        #expect(DoctorPlainCopy.friendlyLoopName("memory.hygiene") == "Memory hygiene")
        // Degenerate input must not produce an empty label.
        #expect(DoctorPlainCopy.friendlyLoopName("") == "")
        #expect(DoctorPlainCopy.friendlyLoopName("x") == "X")
        // Honesty property: no separator characters survive into the headline.
        let rendered = DoctorPlainCopy.friendlyLoopName("a_b-c.d")
        #expect(!rendered.contains("_"))
        #expect(!rendered.contains("-"))
        #expect(!rendered.contains("."))
    }

    @Test("loop count sentences are singular-safe")
    func loopCountCopy() {
        #expect(DoctorPlainCopy.allLoopsHealthyText(count: 1) == "1 background task is running normally.")
        #expect(DoctorPlainCopy.allLoopsHealthyText(count: 4).contains("All 4 background tasks"))
        #expect(DoctorPlainCopy.otherLoopsHealthyText(count: 1).hasPrefix("1 other background task is"))
        #expect(DoctorPlainCopy.otherLoopsHealthyText(count: 3).hasPrefix("3 other background tasks are"))
    }

    @Test("no user-facing Doctor string leaks jargon or exclamation marks")
    func noJargonInHeadlines() {
        let summaries = [
            DoctorPlainCopy.Summary(),
            DoctorPlainCopy.Summary(healthy: 5),
            DoctorPlainCopy.Summary(healthy: 5, warning: 2),
            DoctorPlainCopy.Summary(healthy: 5, warning: 2, failing: 1),
            DoctorPlainCopy.Summary(healthy: 5, unclear: 2),
        ]
        let jargon = ["CODEX_HOME", "loop", "endpoint", "sqlite", "/Users/", "!"]
        for summary in summaries {
            for text in [DoctorPlainCopy.headline(for: summary), DoctorPlainCopy.detail(for: summary)] {
                for term in jargon {
                    #expect(!text.lowercased().contains(term.lowercased()), "\(text) leaked \(term)")
                }
            }
        }
    }
}

@Suite("Memory status plain-English copy")
struct MemoryStatusPlainCopyTests {

    @Test("saved count prefers live status counts, falls back to the disk probe")
    func savedCountFallback() {
        #expect(MemoryStatusPlainCopy.savedCount(active: 12, sqliteRecordCount: 9) == 12)
        // Fresh install: status has not loaded, so the SQLite probe carries it.
        #expect(MemoryStatusPlainCopy.savedCount(active: nil, sqliteRecordCount: 9) == 9)
        #expect(MemoryStatusPlainCopy.savedCount(active: 0, sqliteRecordCount: 9) == 9)
        #expect(MemoryStatusPlainCopy.savedCount(active: nil, sqliteRecordCount: 0) == 0)
    }

    @Test("status dot tracks embedder health")
    func statusText() {
        #expect(MemoryStatusPlainCopy.statusText(health: .working(loadCount: 2)) == "ok")
        #expect(MemoryStatusPlainCopy.statusText(health: .ready) == "warn")
        #expect(MemoryStatusPlainCopy.statusText(health: .broken(reason: "boom")) == "failed")
        #expect(MemoryStatusPlainCopy.statusText(health: .missing) == "failed")
    }

    @Test("headline leads with what the user has, not with the backend")
    func headline() {
        #expect(MemoryStatusPlainCopy.headline(savedCount: 0, health: .working(loadCount: 1))
            == "No memories saved yet.")
        #expect(MemoryStatusPlainCopy.headline(savedCount: 20, health: .working(loadCount: 1))
            == "Memory is working.")
        // A broken embedder outranks the count: the user needs to know search degraded.
        #expect(MemoryStatusPlainCopy.headline(savedCount: 20, health: .broken(reason: "no model"))
            .contains("smart search is not working"))
        #expect(MemoryStatusPlainCopy.headline(savedCount: 20, health: .missing)
            .contains("smart search is not working"))
    }

    @Test("headline never leaks the reason string or a backend name")
    func headlineHidesTechnicalReason() {
        let text = MemoryStatusPlainCopy.headline(
            savedCount: 3,
            health: .broken(reason: "MLModel compile failed at /Users/x/minilm.mlpackage")
        )
        for term in ["mlmodel", "/users/", "mlpackage", "sqlite", "coreml", "cloudkit", "user.md"] {
            #expect(!text.lowercased().contains(term), "\(text) leaked \(term)")
        }
    }

    @Test("counts line is singular-safe and drops empty buckets")
    func countsLine() {
        #expect(MemoryStatusPlainCopy.countsLine(savedCount: 0, pinned: 0, pendingProposals: 0)
            == "Memories appear here as the agent learns from your conversations.")

        let one = MemoryStatusPlainCopy.countsLine(savedCount: 1, pinned: 0, pendingProposals: 0)
        #expect(one == "1 memory saved.")
        #expect(!one.contains("pinned"))

        let many = MemoryStatusPlainCopy.countsLine(savedCount: 14, pinned: 3, pendingProposals: 2)
        #expect(many.contains("14 memories saved"))
        #expect(many.contains("3 pinned"))
        #expect(many.contains("2 waiting for your approval"))

        #expect(MemoryStatusPlainCopy.countsLine(savedCount: 5, pinned: 0, pendingProposals: 1)
            .contains("1 waiting for your approval"))
    }

    @Test("attention detail appears only when something is off")
    func attentionDetail() {
        #expect(MemoryStatusPlainCopy.attentionDetail(health: .working(loadCount: 3)) == nil)
        #expect(MemoryStatusPlainCopy.attentionDetail(health: .ready)?.isEmpty == false)
        #expect(MemoryStatusPlainCopy.attentionDetail(health: .missing)?
            .contains("matching words") == true)
        // The raw reason stays in Advanced Diagnostics; the copy only points there.
        let broken = MemoryStatusPlainCopy.attentionDetail(health: .broken(reason: "dyld: symbol not found"))
        #expect(broken?.contains("Advanced Diagnostics") == true)
        #expect(broken?.contains("dyld") == false)
    }

    @Test("search quality line explains both modes without naming the model")
    func searchQualityLine() {
        let on = MemoryStatusPlainCopy.searchQualityLine(realSemanticAvailable: true)
        let off = MemoryStatusPlainCopy.searchQualityLine(realSemanticAvailable: false)
        #expect(on != off)
        for text in [on, off] {
            for term in ["minilm", "coreml", "embedding", "vector", "!"] {
                #expect(!text.lowercased().contains(term), "\(text) leaked \(term)")
            }
        }
    }
}

@Suite("Detached chat load-failure copy")
struct DetachedChatLoadFailureCopyTests {

    @Test("the user-facing message says what happened and what to try")
    func message() {
        let text = DetachedChatLoadFailureCopy.message
        #expect(text.contains("safe"))
        #expect(text.contains("connection"))
        #expect(!text.contains("!"))
    }

    @Test("the headline message names no internal endpoint")
    func messageHidesEndpoints() {
        let text = DetachedChatLoadFailureCopy.message.lowercased()
        for term in ["endpoint", "health", "providers", "chat messages", "http", "api"] {
            #expect(!text.contains(term), "\(text) leaked \(term)")
        }
    }

    @Test("endpoint names survive in the secondary technical line")
    func technicalDetailPreservesEndpoints() {
        let detail = DetachedChatLoadFailureCopy.technicalDetail(
            failedEndpoints: ["health", "chat messages"]
        )
        #expect(detail == "Did not respond: health, chat messages")
    }

    @Test("technical line is absent when there is nothing specific to name")
    func technicalDetailAbsent() {
        #expect(DetachedChatLoadFailureCopy.technicalDetail(failedEndpoints: []) == nil)
        // Blank entries would render as a dangling comma; they are dropped.
        #expect(DetachedChatLoadFailureCopy.technicalDetail(failedEndpoints: ["", "  "]) == nil)
        #expect(DetachedChatLoadFailureCopy.technicalDetail(failedEndpoints: ["", "health"])
            == "Did not respond: health")
    }
}

// UI-6 (2026-08-01): the second half of the public-honesty sweep — the memory
// policy tooltips, the read-only persona document tooltip, and every sentence
// the app says about the semantic search model. Same honesty property as
// above: a headline carries no filename, no backend name, no env var.

@Suite("Memory policy help copy")
struct MemoryPolicyHelpCopyTests {

    private var allHelpStrings: [String] {
        [
            MemoryPolicyHelpCopy.nightlyConsolidation,
            MemoryPolicyHelpCopy.autoPromoteConsolidated,
        ]
    }

    @Test("tooltips name the long-term memory profile, never the file on disk")
    func noFilenames() {
        for text in allHelpStrings {
            #expect(text.contains("long-term memory profile"), "\(text) lost the plain noun")
            for term in ["user.md", "soul.md", ".md", "memoryv2", "promotion engine", "!"] {
                #expect(!text.lowercased().contains(term), "\(text) leaked \(term)")
            }
        }
    }

    @Test("each tooltip says what the toggle actually does for the user")
    func saysWhatItDoes() {
        #expect(MemoryPolicyHelpCopy.nightlyConsolidation.contains("night"))
        #expect(MemoryPolicyHelpCopy.nightlyConsolidation.contains("suggests"))
        // The auto-promote one must make the no-approval consequence explicit.
        #expect(MemoryPolicyHelpCopy.autoPromoteConsolidated.contains("automatically"))
        #expect(MemoryPolicyHelpCopy.autoPromoteConsolidated.contains("approve"))
    }
}

@Suite("Personality document help copy")
struct PersonalityDocHelpCopyTests {

    @Test("explains why the editor is read-only without naming file or backend")
    func readOnlyExplanation() {
        let text = PersonalityDocHelpCopy.memoryOwnedDocument
        #expect(text.contains("cannot be edited here"))
        #expect(text.contains("Memory page"))
        for term in ["user.md", ".md", "memoryv2", "generated from", "!"] {
            #expect(!text.lowercased().contains(term), "\(text) leaked \(term)")
        }
    }
}

@Suite("Semantic search plain-English copy")
struct EmbeddingPlainCopyTests {

    private let allStates: [EmbeddingPlainCopy.SearchState] =
        [.byMeaning, .turnedOff, .testVectors, .modelMissing, .modelFailed]

    @Test("no headline carries a backend name, a filename, or an env var")
    func headlinesAreJargonFree() {
        let jargon = [
            "coreml", "core ml", "minilm", "fail-closed", "fail closed",
            "embedding", "vector", "semantic recall", "backend", "mlmodel",
            "native_agent_embedding_mock", "embed()", "!",
        ]
        for state in allStates {
            let text = EmbeddingPlainCopy.headline(state)
            #expect(!text.isEmpty)
            for term in jargon {
                #expect(!text.lowercased().contains(term), "headline(\(state)) leaked \(term)")
            }
        }
    }

    @Test("every degraded state tells the user search fell back to words")
    func degradedStatesNameTheFallback() {
        for state in [EmbeddingPlainCopy.SearchState.turnedOff, .modelMissing, .modelFailed] {
            #expect(EmbeddingPlainCopy.headline(state).contains("match words"),
                    "headline(\(state)) does not say what search does instead")
        }
        // Test vectors are a different failure: results exist but are meaningless.
        #expect(EmbeddingPlainCopy.headline(.testVectors).contains("test data"))
        // The healthy state is the only one that promises meaning-based search.
        #expect(EmbeddingPlainCopy.headline(.byMeaning).contains("by meaning"))
    }

    @Test("each state reads differently — no two collapse into one message")
    func headlinesAreDistinct() {
        let headlines = allStates.map { EmbeddingPlainCopy.headline($0) }
        #expect(Set(headlines).count == headlines.count)
    }

    @Test("the technical identifiers survive in the secondary line")
    func technicalDetailKeepsIdentifiers() {
        // Deleting the information was never the goal — demoting it was.
        #expect(EmbeddingPlainCopy.technicalDetail(.modelMissing)?.contains("MiniLM") == true)
        #expect(EmbeddingPlainCopy.technicalDetail(.modelFailed)?.contains("MiniLM") == true)
        #expect(EmbeddingPlainCopy.technicalDetail(.testVectors)?
            .contains("NATIVE_AGENT_EMBEDDING_MOCK") == true)
        #expect(EmbeddingPlainCopy.technicalDetail(.turnedOff)?.contains("MiniLM") == true)
        // A working model has nothing to explain.
        #expect(EmbeddingPlainCopy.technicalDetail(.byMeaning) == nil)
    }

    @Test("a load error is carried through, and a blank one does not dangle")
    func technicalDetailCarriesError() {
        let withError = EmbeddingPlainCopy.technicalDetail(
            .modelFailed,
            error: "MLModel compile failed (code 3)"
        )
        #expect(withError?.contains("MLModel compile failed (code 3)") == true)

        // Blank / whitespace-only errors must not render "Load failed: ".
        for blank in [nil, "", "   ", "\n"] {
            let text = EmbeddingPlainCopy.technicalDetail(.modelFailed, error: blank)
            #expect(text == "Search model: Core ML MiniLM. Load failed.")
        }
    }

    @Test("mode lines describe what the user feels, not which model unloads")
    func modeLinesArePlain() {
        let lines = ["performance", "low_memory", "balanced", "who-knows"]
            .map { EmbeddingPlainCopy.modeLine(mode: $0) }
        // Unknown modes fall back to the balanced sentence rather than blank.
        #expect(lines[2] == lines[3])
        #expect(Set(lines).count == 3)
        for text in lines {
            #expect(!text.isEmpty)
            for term in ["coreml", "core ml", "minilm", "embedding", "recall", "lazy-load", "!"] {
                #expect(!text.lowercased().contains(term), "\(text) leaked \(term)")
            }
        }
    }

    @Test("the not-loaded-yet line reassures instead of alarming")
    func notLoadedYetLine() {
        let text = EmbeddingPlainCopy.notLoadedYetLine
        #expect(text.contains("next search"))
        for term in ["coreml", "minilm", "resident", "!"] {
            #expect(!text.lowercased().contains(term), "\(text) leaked \(term)")
        }
    }
}
