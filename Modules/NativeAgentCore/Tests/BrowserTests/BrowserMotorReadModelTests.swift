import Foundation
import Testing
@testable import Browser
import PersistenceCore

@Suite("Browser shared motor read model")
struct BrowserMotorReadModelTests {
    private struct Fixture {
        let root: URL
        let client: SwiftNativeBrowserClient

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("browser-motor-\(UUID().uuidString)", isDirectory: true)
            let browser = root.appendingPathComponent("native_power/browser", isDirectory: true)
            try FileManager.default.createDirectory(at: browser, withIntermediateDirectories: true)
            client = SwiftNativeBrowserClient(
                runsPath: browser.appendingPathComponent("runs.json"),
                receiptsPath: browser.appendingPathComponent("receipts.jsonl"),
                profileDir: browser.appendingPathComponent("profile", isDirectory: true),
                sourcesDir: browser.appendingPathComponent("sources", isDirectory: true),
                screenshotsDir: browser.appendingPathComponent("screenshots", isDirectory: true),
                trustPolicyPath: root.appendingPathComponent("trust/policy.json")
            )
        }

        func writeRuns(_ rows: [[String: Any]]) throws {
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
            try data.write(to: client.runsPath, options: .atomic)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("active navigation exposes exact opaque cancellation identity without payload")
    func runningProjectionIsPayloadFree() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeRuns([[
            "id": "browser-run-1",
            "status": "running",
            "url": "https://private.example/secret",
            "domain": "private.example",
            "requestDigest": "private-request-digest",
            "createdAt": "2026-07-12T01:00:00.000000+00:00",
            "deadlineSeconds": 30,
        ]])

        let model = try #require(try await fixture.client.motorActionReadModel(actionId: "browser-run-1"))
        let opaque = CausalTransitionEvidence.opaqueIdentity("browser-run-1")
        #expect(model.domain == "browser")
        #expect(model.actionIdentity == opaque)
        #expect(model.cancellationIdentity == opaque)
        #expect(model.phase == .running)
        #expect(model.verification == .pending)
        #expect(model.expectedNextEvidence == "browser_navigation_terminal")
        #expect(model.updatedAt == "2026-07-12T01:00:00.000000+00:00")
        #expect(model.deadline == MotorActionDeadlineReadModel(scope: .operation, timeoutSeconds: 30))

        let encoded = try JSONEncoder().encode(model)
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(!text.contains("private.example"))
        #expect(!text.contains("browser-run-1"))
        #expect(!text.contains("private-request-digest"))
    }

    @Test("canonical run defeats stale derived terminal receipt")
    func staleReceiptCannotManufactureTerminality() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeRuns([[
            "id": "live-run",
            "status": "running",
            "createdAt": "2026-07-12T02:00:00.000000+00:00",
        ]])
        let stale = "{\"id\":\"live-run\",\"status\":\"succeeded\",\"opened\":true}\n"
        try stale.write(to: fixture.client.receiptsPath, atomically: true, encoding: .utf8)

        let model = try #require(try await fixture.client.motorActionReadModel(actionId: "live-run"))
        #expect(model.phase == .running)
        #expect(model.verification == .pending)
    }

    @Test("terminal navigation distinguishes observed success from unverified legacy claim")
    func terminalVerificationIsExact() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeRuns([
            [
                "id": "observed",
                "status": "succeeded",
                "opened": true,
                "createdAt": "2026-07-12T03:00:00.000000+00:00",
            ],
            [
                "id": "legacy",
                "status": "succeeded",
                "createdAt": "2026-07-12T03:01:00.000000+00:00",
            ],
            [
                "id": "cancelled",
                "status": "canceled",
                "canceledAt": "2026-07-12T03:02:00.000000+00:00",
            ],
        ])

        let observed = try #require(try await fixture.client.motorActionReadModel(actionId: "observed"))
        #expect(observed.phase == .succeeded)
        #expect(observed.verification == .satisfied)
        #expect(observed.expectedNextEvidence == nil)
        #expect(observed.updatedAt == nil)
        #expect(observed.cancellationIdentity == nil)

        let legacy = try #require(try await fixture.client.motorActionReadModel(actionId: "legacy"))
        #expect(legacy.phase == .succeeded)
        #expect(legacy.verification == .unverified)
        #expect(legacy.expectedNextEvidence == "browser_navigation_receipt")
        #expect(legacy.updatedAt == nil)

        let cancelled = try #require(try await fixture.client.motorActionReadModel(actionId: "cancelled"))
        #expect(cancelled.phase == .cancelled)
        #expect(cancelled.verification == .notRequired)
        #expect(cancelled.updatedAt == "2026-07-12T03:02:00.000000+00:00")
        #expect(cancelled.cancellationIdentity == nil)
    }

    @Test("dry-run remains nonterminal and cancellable because the canonical owner can cancel it")
    func dryRunMatchesOwnerCancellationSemantics() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeRuns([[
            "id": "dry-run",
            "status": "dry_run",
            "createdAt": "2026-07-12T03:30:00.000000+00:00",
        ]])

        let model = try #require(try await fixture.client.motorActionReadModel(actionId: "dry-run"))
        let opaque = CausalTransitionEvidence.opaqueIdentity("dry-run")
        #expect(model.phase == .ready)
        #expect(!model.phase.isTerminal)
        #expect(model.verification == .notRequired)
        #expect(model.expectedNextEvidence == "browser_run_cancellation")
        #expect(model.cancellationIdentity == opaque)
        #expect(model.updatedAt == "2026-07-12T03:30:00.000000+00:00")
    }

    @Test("corrupt or duplicate canonical identity fails loud")
    func corruptOwnerStateFailsLoud() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        try Data("not-json".utf8).write(to: fixture.client.runsPath, options: .atomic)
        await #expect(throws: BrowserMotorReadModelError.invalidRunsDocument) {
            _ = try await fixture.client.motorActionReadModel(actionId: "run")
        }

        try fixture.writeRuns([["id": "run", "url": "https://example.com"]])
        await #expect(throws: BrowserMotorReadModelError.invalidMatchingRun) {
            _ = try await fixture.client.motorActionReadModel(actionId: "run")
        }

        try fixture.writeRuns([
            ["id": "run", "status": "running"],
            ["id": "run", "status": "succeeded", "opened": true],
        ])
        await #expect(throws: BrowserMotorReadModelError.duplicateActionIdentity) {
            _ = try await fixture.client.motorActionReadModel(actionId: "run")
        }
    }

    @Test("unbounded status or timestamp payloads fail closed")
    func projectedStringsAreBoundedAndValidated() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        try fixture.writeRuns([[
            "id": "run",
            "status": "running\nhttps://private.example/secret",
            "createdAt": "2026-07-12T04:00:00.000000+00:00",
        ]])
        await #expect(throws: BrowserMotorReadModelError.invalidStatusToken) {
            _ = try await fixture.client.motorActionReadModel(actionId: "run")
        }

        try fixture.writeRuns([[
            "id": "run",
            "status": "running",
            "createdAt": "2026-07-12T04:00:00Z private-payload",
        ]])
        await #expect(throws: BrowserMotorReadModelError.invalidTimestamp) {
            _ = try await fixture.client.motorActionReadModel(actionId: "run")
        }

        try fixture.writeRuns([[
            "id": "run",
            "status": "running",
            "updatedAt": 123,
            "createdAt": "2026-07-12T04:00:00Z",
        ]])
        await #expect(throws: BrowserMotorReadModelError.invalidTimestamp) {
            _ = try await fixture.client.motorActionReadModel(actionId: "run")
        }

        try fixture.writeRuns([[
            "id": "run",
            "status": String(repeating: "x", count: 65),
            "createdAt": "2026-07-12T04:00:00Z",
        ]])
        await #expect(throws: BrowserMotorReadModelError.invalidStatusToken) {
            _ = try await fixture.client.motorActionReadModel(actionId: "run")
        }

        try fixture.writeRuns([[
            "id": "run",
            "status": "running",
            "createdAt": "2026-07-12T04:00:00Z",
            "deadlineSeconds": -1,
        ]])
        await #expect(throws: BrowserMotorReadModelError.invalidDeadline) {
            _ = try await fixture.client.motorActionReadModel(actionId: "run")
        }
    }

    @Test("missing owner file or unknown action is absent without side effects")
    func missingIsNil() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        #expect(try await fixture.client.motorActionReadModel(actionId: "run") == nil)
        try fixture.writeRuns([["id": "other", "status": "running"]])
        #expect(try await fixture.client.motorActionReadModel(actionId: "run") == nil)
        #expect(try await fixture.client.motorActionReadModel(actionId: "   ") == nil)
    }
}
