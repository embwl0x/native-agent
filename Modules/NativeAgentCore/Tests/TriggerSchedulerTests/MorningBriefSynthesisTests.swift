import Testing
import Foundation
@testable import TriggerScheduler
import NativeAgentCore
import PersistenceCore

// L5 G3 + G1 — the merged brief.
//
// The contract under test has two halves and BOTH matter:
//   1. With a synthesizer, the brief LEADS with her read and keeps the
//      deterministic counts below it as the evidence layer.
//   2. Without one — or when the turn fails, returns nothing, or returns
//      whitespace — the brief is byte-identical to the deterministic brief
//      that shipped before this seam existed. The fail-open contract is the
//      reason the scheduler tick may call an LLM at all.

private func tempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("MorningBriefSynthesisTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func localDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone.current
    var dc = DateComponents()
    dc.year = y; dc.month = mo; dc.day = d; dc.hour = h; dc.minute = mi; dc.second = 0
    return cal.date(from: dc)!
}

private func builder(root: URL, now: Date) -> TriggerContentBuilder {
    TriggerContentBuilder(
        root: root,
        persistence: SwiftNativePersistenceCore(),
        now: { now },
        // Never read User's real ~/.claude worklog from a test.
        worklogPath: root.appendingPathComponent("no-such-worklog.jsonl")
    )
}

/// Seeds enough real state that the deterministic brief has both a summary
/// with counts and a markdown detail body — otherwise "the evidence layer
/// survived" would be vacuously true.
private func seedDesk(root: URL) async throws {
    let desk = SwiftNativeDeskStore(dataRoot: root)
    let item = try await desk.createItem(kind: .plan, project: "na", title: "wake the triggers")
    _ = try await desk.setStatus(item.handle, status: .now)
}

@Suite("Morning brief: synthesized lead over deterministic evidence")
struct MorningBriefSynthesisSuite {

    @Test func nilSynthesizerIsByteIdenticalToTheDeterministicBrief() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = localDate(2026, 3, 5, 9, 0)
        try await seedDesk(root: root)

        let deterministic = await builder(root: root, now: now).morningBrief()
        let viaSeam = await builder(root: root, now: now).morningBrief(synthesizer: nil)

        #expect(viaSeam == deterministic)
    }

    @Test func synthesizedLeadBecomesTheSummaryAndTopsTheDetail() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = localDate(2026, 3, 5, 9, 0)
        try await seedDesk(root: root)

        let deterministic = await builder(root: root, now: now).morningBrief()
        guard case .string(let deterministicDetail) = deterministic.detail else {
            Issue.record("fixture must produce a markdown detail body"); return
        }

        let lead = "Start with waking the triggers — it's the only thing in `now` and it blocks the rest."
        let content = await builder(root: root, now: now).morningBrief(synthesizer: { _ in lead })

        // Title is pinned by the UI and by the existing brief tests; the seam
        // must not move it.
        #expect(content.title == deterministic.title)
        #expect(content.summary == lead)
        guard case .string(let detail) = content.detail else {
            Issue.record("expected a markdown detail body"); return
        }
        #expect(detail.hasPrefix(lead))
        // The evidence layer survives BELOW the lead, unmodified.
        #expect(detail.hasSuffix(deterministicDetail))
        #expect(detail.contains("## Desk"))
        let leadIndex = try #require(detail.range(of: lead))
        let deskIndex = try #require(detail.range(of: "## Desk"))
        #expect(leadIndex.lowerBound < deskIndex.lowerBound)
    }

    @Test func synthesizerSeesTheDeterministicBriefItIsLeading() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = localDate(2026, 3, 5, 9, 0)
        try await seedDesk(root: root)

        // The point of passing the resolved brief in: the turn writes a read
        // ON the evidence rather than re-deriving it and disagreeing.
        actor Captured { var value: MorningBriefSynthesisRequest?
            func set(_ v: MorningBriefSynthesisRequest) { value = v } }
        let captured = Captured()
        _ = await builder(root: root, now: now).morningBrief(synthesizer: { request in
            await captured.set(request)
            return "lead"
        })

        let request = try #require(await captured.value)
        #expect(request.dayLabel == "Thursday, March 5")
        #expect(request.deterministicSummary.contains("1 open desk item"))
        #expect(request.deterministicDetail?.contains("## Desk") == true)
    }

    @Test func failedTurnFallsBackToTheDeterministicBrief() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = localDate(2026, 3, 5, 9, 0)
        try await seedDesk(root: root)

        let deterministic = await builder(root: root, now: now).morningBrief()
        // nil is how the app-layer synthesizer reports "provider down / tools
        // denied / turn threw / timed out".
        let content = await builder(root: root, now: now).morningBrief(synthesizer: { _ in nil })
        #expect(content == deterministic)
    }

    @Test func blankLeadIsTreatedAsNoLead() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = localDate(2026, 3, 5, 9, 0)
        try await seedDesk(root: root)

        let deterministic = await builder(root: root, now: now).morningBrief()
        // A model that returns "" or "\n\n  " must not blank out the summary —
        // that would be a worse brief than the counts, delivered as if it were
        // better.
        for blank in ["", "   ", "\n\n \t"] {
            let content = await builder(root: root, now: now).morningBrief(synthesizer: { _ in blank })
            #expect(content == deterministic)
        }
    }

    @Test func longLeadIsCappedInTheSummaryButWholeInTheDetail() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = localDate(2026, 3, 5, 9, 0)
        try await seedDesk(root: root)

        let cap = TriggerContentBuilder.synthesizedLeadSummaryCap
        let lead = String(repeating: "x", count: cap + 50)
        let content = await builder(root: root, now: now).morningBrief(synthesizer: { _ in lead })

        #expect(content.summary.count == cap + 1)      // cap + the ellipsis
        #expect(content.summary.hasSuffix("…"))
        guard case .string(let detail) = content.detail else {
            Issue.record("expected a markdown detail body"); return
        }
        #expect(detail.contains(lead))                  // uncut where there's room
    }

    @Test func leadStandsAloneWhenNoDeterministicSectionResolved() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = localDate(2026, 3, 5, 9, 0)
        // No desk, no worklog, no executions: the deterministic detail is .null.

        let deterministic = await builder(root: root, now: now).morningBrief()
        #expect(deterministic.detail == .null)

        let content = await builder(root: root, now: now).morningBrief(synthesizer: { _ in "quiet morning" })
        // No stray separator with nothing under it.
        #expect(content.detail == .string("quiet morning"))
        #expect(content.summary == "quiet morning")
    }
}

@Suite("Morning brief: the trigger fire path carries the seam")
struct MorningBriefFirePathSuite {

    @Test func firedTimeTriggerCarriesTheSynthesizedLead() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await seedDesk(root: root)

        let client = SwiftNativeTriggerScheduler(
            root: root,
            now: { localDate(2026, 3, 5, 9, 0) },
            worklogPath: root.appendingPathComponent("no-such-worklog.jsonl"),
            morningBriefSynthesizer: { _ in "Waking the triggers is the thing." }
        )
        let result = try await client.fireInboxTrigger(name: "morning_brief", isStub: true)
        #expect(result.stub == false)
        #expect(Self.summary(of: result) == "Waking the triggers is the thing.")
    }

    /// The card the fire built, as the inbox will store it. Reading the summary
    /// off the ITEM rather than off a convenience field is deliberate: this is
    /// the exact bytes User's inbox row renders.
    static func summary(of result: TriggerFireResult) -> String? {
        guard case .object(let item)? = result.item,
              case .string(let summary)? = item["summary"] else { return nil }
        return summary
    }

    @Test func firedTimeTriggerWithoutASynthesizerKeepsTheCountsBrief() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await seedDesk(root: root)

        let client = SwiftNativeTriggerScheduler(
            root: root,
            now: { localDate(2026, 3, 5, 9, 0) },
            worklogPath: root.appendingPathComponent("no-such-worklog.jsonl")
        )
        let result = try await client.fireInboxTrigger(name: "morning_brief", isStub: true)
        #expect(result.stub == false)
        #expect(Self.summary(of: result)?.contains("1 open desk item") == true)
    }
}
