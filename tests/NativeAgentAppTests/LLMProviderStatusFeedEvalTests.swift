import Foundation
import Testing
@testable import NativeAgentApp

// ─────────────────────────────────────────────────────────────────────────────
// EVAL FENCE: core.providers
// Ledger row: providers.feed.llmProviderStatus
//
// This is an actual disk round-trip through the production feed writer and
// reader. It does not plant the old instrument-only fixture: the same writer
// called by NativeClient.testProvider is what creates each record here.
// ─────────────────────────────────────────────────────────────────────────────

@Suite("LLM provider status feed", .serialized)
struct LLMProviderStatusFeedEvalTests {
    private func root(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-provider-status-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("canonical writer round-trips a successful native probe through the reader")
    func writerAndReaderRoundTrip() async throws {
        let dataRoot = try root("roundtrip")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let checkedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let probe = ProviderTestResult(
            provider_id: "kimi-code",
            status: "ok",
            tested: true,
            response: nil,
            model_used: "kimi-for-coding",
            detail: "latency=24ms",
            error: nil
        )

        try await LLMProviderStatusFeed.write(probe, dataRoot: dataRoot, checkedAt: checkedAt)

        guard case .current(let record) = LLMProviderStatusFeed.read(dataRoot: dataRoot, now: checkedAt.addingTimeInterval(5)) else {
            Issue.record("a writer-produced successful probe must be current")
            return
        }
        #expect(record.status == .ok)
        #expect(record.providerID == "kimi-code")
        #expect(record.model == "kimi-for-coding")
        #expect(record.tested)
        #expect(record.detail == "latency=24ms")

        let raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: LLMProviderStatusFeed.path(in: dataRoot))) as? [String: Any])
        #expect(raw["schema"] as? String == "llm.provider_status.v2")
        #expect(raw["status"] as? String == "ok")
        #expect(raw["providerId"] as? String == "kimi-code")
    }

    @Test("an isolated NativeClient writes its own canonical feed after an unsupported probe")
    func isolatedClientOwnsProviderStatusFeed() async throws {
        let dataRoot = try root("isolated-client")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let client = NativeClient(baseURL: "", dataRootOverride: dataRoot)

        let result = try await client.testProvider("unsupported-provider-eval")

        #expect(result.status == "unknown")
        #expect(result.tested == false)
        #expect(FileManager.default.fileExists(atPath: LLMProviderStatusFeed.path(in: dataRoot).path))
        guard case .unavailable(let detail) = LLMProviderStatusFeed.read(dataRoot: dataRoot) else {
            Issue.record("the isolated client must write its unavailable probe result to its own feed")
            return
        }
        #expect(detail.contains("no native probe"))
    }

    @Test("reader keeps unavailable failed stale and write-failure states distinct")
    func adverseStatesAreHonest() async throws {
        let dataRoot = try root("adverse")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        guard case .unavailable = LLMProviderStatusFeed.read(dataRoot: dataRoot, now: now) else {
            Issue.record("a missing feed must not read as healthy")
            return
        }

        let unsupportedProbe = ProviderTestResult(
            provider_id: "anthropic",
            status: "ok",
            tested: false,
            response: nil,
            model_used: nil,
            detail: "probe skipped",
            error: nil
        )
        try await LLMProviderStatusFeed.write(unsupportedProbe, dataRoot: dataRoot, checkedAt: now)
        guard case .unavailable(let detail) = LLMProviderStatusFeed.read(dataRoot: dataRoot, now: now) else {
            Issue.record("an untestable provider must not be reported as checked")
            return
        }
        #expect(detail == "probe skipped")

        let failedProbe = ProviderTestResult(
            provider_id: "openai",
            status: "error",
            tested: true,
            response: nil,
            model_used: nil,
            detail: "latency=12ms",
            error: "HTTP 401"
        )
        try await LLMProviderStatusFeed.write(failedProbe, dataRoot: dataRoot, checkedAt: now)
        guard case .failed(let failure) = LLMProviderStatusFeed.read(dataRoot: dataRoot, now: now) else {
            Issue.record("a failed provider probe must replace a prior non-failure row")
            return
        }
        #expect(failure == "HTTP 401")

        let staleRecord = LLMProviderStatusFeed.Record(
            status: .ok,
            checkedAt: now.addingTimeInterval(-LLMProviderStatusFeed.staleAfter - 1),
            detail: "old success",
            providerID: "openai",
            model: nil,
            tested: true
        )
        try await LLMProviderStatusFeed.write(staleRecord, to: LLMProviderStatusFeed.path(in: dataRoot))
        guard case .stale(let stale) = LLMProviderStatusFeed.read(dataRoot: dataRoot, now: now) else {
            Issue.record("a dated success older than the feed horizon must be stale")
            return
        }
        #expect(stale.detail == "old success")

        let withinSkew = LLMProviderStatusFeed.Record(
            status: .ok,
            checkedAt: now.addingTimeInterval(LLMProviderStatusFeed.allowedClockSkew),
            detail: "clock is within tolerance",
            providerID: "openai",
            model: nil,
            tested: true
        )
        try await LLMProviderStatusFeed.write(withinSkew, to: LLMProviderStatusFeed.path(in: dataRoot))
        guard case .current = LLMProviderStatusFeed.read(dataRoot: dataRoot, now: now) else {
            Issue.record("bounded clock skew must remain readable as current")
            return
        }

        let beyondSkew = LLMProviderStatusFeed.Record(
            status: .ok,
            checkedAt: now.addingTimeInterval(LLMProviderStatusFeed.allowedClockSkew + 1),
            detail: "future result",
            providerID: "openai",
            model: nil,
            tested: true
        )
        try await LLMProviderStatusFeed.write(beyondSkew, to: LLMProviderStatusFeed.path(in: dataRoot))
        let futureWire = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: LLMProviderStatusFeed.path(in: dataRoot))) as? [String: Any]
        )
        #expect(futureWire["checkedAt"] as? String != nil)
        guard case .failed(let futureFailure) = LLMProviderStatusFeed.read(dataRoot: dataRoot, now: now) else {
            Issue.record("a future-dated wire record beyond allowed skew must not read as current")
            return
        }
        #expect(futureFailure.contains("too far in the future"))

        let blockedRoot = try root("write-failure")
        defer { try? FileManager.default.removeItem(at: blockedRoot) }
        try FileManager.default.createDirectory(
            at: LLMProviderStatusFeed.path(in: blockedRoot),
            withIntermediateDirectories: true
        )
        await #expect(throws: (any Error).self) {
            try await LLMProviderStatusFeed.write(staleRecord, to: LLMProviderStatusFeed.path(in: blockedRoot))
        }
        guard case .failed = LLMProviderStatusFeed.read(dataRoot: blockedRoot, now: now) else {
            Issue.record("a real writer failure must not leave a healthy-looking record")
            return
        }
    }

    @Test("fresh organism provider health supersedes an old manual probe")
    func runtimeHealthReadsCanonicalOrganismState() async throws {
        let dataRoot = try root("runtime-health")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cognition = dataRoot.appendingPathComponent("cognition", isDirectory: true)
        try FileManager.default.createDirectory(at: cognition, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        let object: [String: Any] = [
            "savedAt": iso.string(from: now),
            "bodySchema": ["providersAvailable": true, "providersHealthy": true],
        ]
        try JSONSerialization.data(withJSONObject: object)
            .write(to: cognition.appendingPathComponent("organism_state.json"))

        guard case .healthy(let savedAt) = ProviderRuntimeHealthFeed.read(dataRoot: dataRoot, now: now) else {
            Issue.record("fresh organism health must be usable as provider evidence")
            return
        }
        #expect(savedAt == now)

        let staleProbe = LLMProviderStatusFeed.Record(
            status: .ok,
            checkedAt: now.addingTimeInterval(-LLMProviderStatusFeed.staleAfter - 1),
            detail: "old manual probe",
            providerID: "anthropic",
            model: "old-model",
            tested: true
        )
        try await LLMProviderStatusFeed.write(staleProbe, to: LLMProviderStatusFeed.path(in: dataRoot))
        guard case .stale = LLMProviderStatusFeed.read(dataRoot: dataRoot, now: now) else {
            Issue.record("manual probe fixture must remain stale")
            return
        }

        let staleRuntime = ProviderRuntimeHealthFeed.read(
            dataRoot: dataRoot,
            now: now.addingTimeInterval(ProviderRuntimeHealthFeed.staleAfter + 1)
        )
        guard case .unavailable(let detail) = staleRuntime else {
            Issue.record("stale organism state must not masquerade as current provider health")
            return
        }
        #expect(detail.contains("stale"))
    }

    @Test("native provider probes own the production writer and the instrument names adverse states")
    func productionWiringAndReaderSemantics() throws {
        let doctorSource = try AppSourceScraping.appSource("NativeClient+SystemOpsActions.swift")
        let doctorProvider = try AppSourceScraping.functionBody(named: "providerDoctorCoverageCheck", in: doctorSource)
        #expect(doctorProvider.contains("let dataRoot = dataRootOverride ?? PersistenceCore.defaultDataRoot()"))
        #expect(doctorProvider.contains("LLMProviderStatusFeed.read(dataRoot: dataRoot)"))
        #expect(doctorProvider.contains("case .stale"))
        #expect(doctorProvider.contains("case .unavailable"))
        #expect(doctorProvider.contains("case .failed"))

        let root = try AppSourceScraping.repositoryRoot()
        let instrument = try String(contentsOf: root.appendingPathComponent("script/agent_instrument.swift"), encoding: .utf8)
        #expect(instrument.contains("case \"error\", \"failed\":"))
        #expect(instrument.contains("case \"unavailable\", \"unknown\":"))
        #expect(instrument.contains("providerStatusCheckedAt, c.timeIntervalSinceNow > 5 * 60"))
        #expect(instrument.contains("provider status last checked"))
    }
}
