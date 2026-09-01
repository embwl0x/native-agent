import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
import SwarmRuns
@testable import ChatOrchestration

private func inspectionObject(_ value: JSONValue?) -> [String: JSONValue]? {
    guard case .object(let object)? = value else { return nil }
    return object
}

private struct SwarmInspectionFixture {
    let root: URL
    let dataRoot: URL
    let file: URL
    let output = String(repeating: "🍎", count: 4_500)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("swarm-inspection-\(UUID().uuidString)")
        dataRoot = root.appendingPathComponent("body")
        file = dataRoot.appendingPathComponent("swarms/runs.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    var receipt: JSONValue {
        .object([
            "id": .string("run-exact"), "status": .string("cancelled"), "createdAt": .string("2026-08-30T17:00:00Z"),
            "workers": .array([
                .object(["id": .string("worker-1"), "name": .string("reader"), "status": .string("completed"),
                         "output": .string(output), "outputTruncated": .bool(true)]),
                .object(["id": .string("worker-2"), "status": .string("cancelled"), "output": .string(""),
                         "error": .string("interrupted effects remain unverified"), "outputTruncated": .bool(false)]),
            ]),
            "synthesis": .object(["status": .string("skipped"), "output": .string(""), "error": .string("parent cancelled")]),
        ])
    }

    func write(_ value: JSONValue) throws { try value.serializedData(pretty: false).write(to: file) }

    func inspect(_ extra: [String: JSONValue] = [:]) async throws -> [String: JSONValue] {
        let dispatcher = SwiftToolDispatcher(dataRoot: dataRoot, agentBridgeConfigRoot: root.appendingPathComponent("unrelated-bridge-root"))
        let input = ["agent": JSONValue.string("swarm"), "run_id": .string("run-exact")].merging(extra) { _, new in new }
        let value = try await dispatcher.dispatch(tool: "delegation_status", input: input, surface: "telegram")
        return try #require(inspectionObject(value))
    }
}

@Suite("SwarmReceiptInspection")
struct SwarmReceiptInspectionTests {
    @Test func outputErrorBoundaryPagesPreserveExactUnicodeTextAndStableOffsets() async throws {
        let fixture = try SwarmInspectionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for limit in [1, 9, 2_000] {
            let output = String(repeating: "👩🏽‍💻e\u{301}🇺🇸", count: limit == 2_000 ? 1_500 : 3) + "\r"
            let error = "interrupted: 🧑🏾‍🚀\r\ncafe\u{301}"
            let expected = "Output:\n" + output + "\n\nError:\n" + error
            try fixture.write(.array([.object([
                "id": .string("run-exact"), "status": .string("cancelled"),
                "workers": .array([.object([
                    "id": .string("worker-1"), "status": .string("failed"),
                    "output": .string(output), "error": .string(error), "outputTruncated": .bool(false),
                ])]),
            ])]))
            let original = try Data(contentsOf: fixture.file)
            var recovered = ""
            var offset = 0
            for _ in 0...expected.count {
                let input: [String: JSONValue] = ["report_id": .string("worker-1"), "offset": .int(Int64(offset)), "limit": .int(Int64(limit))]
                let response = try await fixture.inspect(input)
                let report = try #require(inspectionObject(response["report"]))
                let repeated = try await fixture.inspect(input)
                #expect(repeated["report"] == response["report"])
                guard case .string(let text)? = report["text"] else { Issue.record("missing report text"); return }
                let start = expected.index(expected.startIndex, offsetBy: offset)
                let expectedPage = String(expected[start...].prefix(limit))
                #expect(Array(text.utf8) == Array(expectedPage.utf8))
                #expect(report["retained_chars"] == .int(Int64(expected.count)))
                #expect(report["returned_chars"] == .int(Int64(text.count)))
                #expect(text.count <= limit)
                recovered += text
                offset += text.count
                if report["has_more"] == .bool(false) {
                    #expect(report["next_offset"] == nil)
                    break
                }
                #expect(report["next_offset"] == .int(Int64(offset)))
                try #require(!text.isEmpty && offset < expected.count)
            }
            #expect(offset == expected.count)
            #expect(Array(recovered.utf8) == Array(expected.utf8))
            #expect(try Data(contentsOf: fixture.file) == original)
        }
    }

    @Test func mixedLegacyAndCurrentSynthesisShapesPreserveOnlyKnownEvidence() async throws {
        let fixture = try SwarmInspectionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let legacyText = String(repeating: "retained synthesis 🍎 ", count: 150)
        let synthesisValues: [JSONValue?] = [nil, .null, .string(""), .string(legacyText),
            .object(["status": .string("completed"), "output": .string("current synthesis"), "outputTruncated": .bool(false)])]
        let rows: [JSONValue] = synthesisValues.enumerated().map { index, synthesis in
            var receipt: [String: JSONValue] = [
                "id": .string("shape-\(index)"), "status": .string("failed"),
                "workers": .array([.object(["id": .string("legacy-worker"), "status": .string("failed"),
                                            "error": .string("retained failure")])]),
            ]
            receipt["synthesis"] = synthesis
            return .object(receipt)
        }
        try fixture.write(.array(rows + [fixture.receipt]))
        let original = try Data(contentsOf: fixture.file)
        let current = try await fixture.inspect()
        #expect(current["status"] == .string("ok"))
        for index in 0..<2 {
            let response = try await fixture.inspect(["run_id": .string("shape-\(index)"), "report_id": .string("synthesis")])
            #expect(response["reason"] == .string("report_not_retained"))
        }
        let empty = try await fixture.inspect(["run_id": .string("shape-2"), "report_id": .string("synthesis")])
        let emptyReport = try #require(inspectionObject(empty["report"]))
        #expect(emptyReport["status"] == .string("unknown"))
        #expect(emptyReport["stored_output_truncated"] == .null)
        #expect(emptyReport["text"] == .string(""))
        var recovered = ""
        var offset: Int64 = 0
        for _ in 0..<2 {
            let response = try await fixture.inspect(["run_id": .string("shape-3"), "report_id": .string("synthesis"), "offset": .int(offset)])
            let report = try #require(inspectionObject(response["report"]))
            #expect(report["status"] == .string("unknown"))
            #expect(report["stored_output_truncated"] == .null)
            guard case .string(let text)? = report["text"] else { Issue.record("missing legacy synthesis text"); return }
            #expect(text.count <= 2_000)
            recovered += text
            if case .int(let next)? = report["next_offset"] { offset = next }
        }
        #expect(recovered == "Output:\n" + legacyText)
        let modern = try await fixture.inspect(["run_id": .string("shape-4"), "report_id": .string("synthesis")])
        #expect(inspectionObject(modern["report"])?["status"] == .string("completed"))
        #expect(inspectionObject(modern["report"])?["stored_output_truncated"] == .bool(false))
        #expect(try Data(contentsOf: fixture.file) == original)
        for invalid in [JSONValue.bool(false), .int(0), .array([])] {
            var malformed = try #require(inspectionObject(fixture.receipt))
            malformed["synthesis"] = invalid
            try fixture.write(.array([.object(malformed)]))
            let response = try await fixture.inspect()
            #expect(response["reason"] == .string("receipt_store_malformed"))
        }
    }

    @Test func legacyFailedWorkerRetainsErrorWithoutInventingOutput() async throws {
        let fixture = try SwarmInspectionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldWorker: [String: JSONValue] = [
            "id": .string("old-worker"), "index": .int(0), "status": .string("failed"),
            "error": .string("provider failed before output was retained"), "durationSeconds": .double(1),
            "model": .string("fixture"), "providerId": .string("fixture"), "requestedModel": .string("fixture"),
            "reasoningEffort": .string("medium"), "role": .string("reader"),
        ]
        func oldReceipt(_ worker: [String: JSONValue]) -> JSONValue {
            .object(["id": .string("old-run"), "status": .string("failed"), "workers": .array([.object(worker)])])
        }
        try fixture.write(.array([oldReceipt(oldWorker), fixture.receipt]))
        let original = try Data(contentsOf: fixture.file)
        let current = try await fixture.inspect(["report_id": .string(" ")])
        #expect(current["status"] == .string("ok"))
        #expect(current["report"] == nil)
        let legacy = try await fixture.inspect(["run_id": .string("old-run"), "report_id": .string("old-worker")])
        let report = try #require(inspectionObject(legacy["report"]))
        #expect(report["status"] == .string("failed"))
        #expect(report["output_available"] == .bool(false))
        #expect(report["output_unavailable_reason"] == .string("legacy_failed_worker_omitted_output"))
        #expect(report["stored_output_truncated"] == .null)
        #expect(report["text"] == .string("Error:\nprovider failed before output was retained"))
        #expect(try Data(contentsOf: fixture.file) == original)

        var malformedRows: [[String: JSONValue]] = []
        for replacement in [JSONValue.null, .bool(false), .int(0)] {
            var malformed = oldWorker
            malformed["output"] = replacement
            malformedRows.append(malformed)
        }
        let invalidEvidence: [[String: JSONValue]] = [["status": .string("completed")], ["error": .string(" ")], ["error": .null]]
        malformedRows += invalidEvidence.map { oldWorker.merging($0) { _, new in new } }
        for worker in malformedRows {
            try fixture.write(.array([oldReceipt(worker), fixture.receipt]))
            // The corrupt row's OWN run still fails loud...
            let corrupt = try await fixture.inspect(["run_id": .string("old-run")])
            #expect(corrupt["reason"] == .string("receipt_store_malformed"))
            // ...while every other run stays inspectable, with the skip counted.
            let intact = try await fixture.inspect()
            #expect(intact["status"] == .string("ok"))
            #expect(intact["skipped_malformed_rows"] == .int(1))
        }
    }

    @Test func reportSelectorSchemaExplicitlyAcceptsNull() throws {
        let fixture = try SwarmInspectionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let dispatcher = SwiftToolDispatcher(dataRoot: fixture.dataRoot)
        let schema = try #require(dispatcher.builtInToolSchemas(includeFullMacFileTools: false).first { $0.name == "delegation_status" })
        let parameters = try #require(inspectionObject(JSONValue.parse(schema.parametersJSON)))
        let properties = try #require(inspectionObject(parameters["properties"]))
        let selector = try #require(inspectionObject(properties["report_id"]))
        #expect(selector["type"] == .array([.string("string"), .string("null")]))
    }

    @Test func exactMetadataAndSelectedReportPagesAreBoundedAndReadOnly() async throws {
        let fixture = try SwarmInspectionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.write(.array([fixture.receipt]))
        let original = try Data(contentsOf: fixture.file)
        let metadata = try await fixture.inspect(["detail": .string("full"), "report_id": .null, "offset": .null, "limit": .null])
        #expect(metadata["status"] == .string("ok"))
        #expect(metadata["run_status"] == .string("cancelled"))
        #expect(metadata["report"] == nil)
        guard case .array(let reports)? = metadata["reports"] else { Issue.record("missing report descriptors"); return }
        #expect(reports.count == 3)
        #expect(inspectionObject(reports[0])?["report_id"] == .string("worker-1"))
        #expect(inspectionObject(reports[0])?["text"] == nil)
        var offset = 0
        var recovered = ""
        for _ in 0..<3 {
            let response = try await fixture.inspect(["report_id": .string("worker-1"), "offset": .int(Int64(offset)), "limit": .int(20_000)])
            let page = try #require(inspectionObject(response["report"]))
            guard case .string(let text)? = page["text"] else { Issue.record("missing report text"); return }
            #expect(text.count <= 2_000)
            #expect(page["stored_output_truncated"] == .bool(true))
            #expect(page["page_truncated"] == .bool(true))
            recovered += text
            if case .int(let next)? = page["next_offset"] { offset = Int(next) }
        }
        #expect(recovered == "Output:\n" + fixture.output)
        let interrupted = try await fixture.inspect(["report_id": .string("worker-2")])
        #expect(inspectionObject(interrupted["report"])?["text"] == .string("Error:\ninterrupted effects remain unverified"))
        let synthesis = try await fixture.inspect(["report_id": .string("synthesis")])
        #expect(inspectionObject(synthesis["report"])?["text"] == .string("Error:\nparent cancelled"))
        #expect(inspectionObject(synthesis["report"])?["stored_output_truncated"] == .null)
        #expect(inspectionObject(synthesis["report"])?["page_truncated"] == .bool(false))
        #expect(try Data(contentsOf: fixture.file) == original)
    }

    @Test func exactIDsAndNumericBindingsCannotBecomePathsOrLaunchWork() async throws {
        let fixture = try SwarmInspectionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.write(.array([fixture.receipt]))
        let unknown = try await fixture.inspect(["run_id": .string("../../unrelated")])
        #expect(unknown["status"] == .string("not_found"))
        let missingID = try await fixture.inspect(["run_id": .null])
        #expect(missingID["reason"] == .string("swarm_run_id_required"))
        let invalidOffset = try await fixture.inspect(["offset": .double(1e100)])
        #expect(invalidOffset["reason"] == .string("swarm_pagination_invalid"))
        let invalidReport = try await fixture.inspect(["report_id": .bool(true)])
        #expect(invalidReport["reason"] == .string("swarm_report_id_invalid"))
        let unknownReport = try await fixture.inspect(["report_id": .string("worker-other")])
        #expect(unknownReport["reason"] == .string("report_not_retained"))
        let end = try await fixture.inspect(["report_id": .string("worker-1"), "offset": .int(Int64.max)])
        #expect(inspectionObject(end["report"])?["text"] == .string(""))
        #expect(inspectionObject(end["report"])?["has_more"] == .bool(false))
    }

    @Test func missingUnreadableMalformedAndAmbiguousStoresStayDistinct() async throws {
        let fixture = try SwarmInspectionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let missing = try await fixture.inspect()
        #expect(missing["reason"] == .string("receipt_store_missing"))
        var collision = try #require(inspectionObject(fixture.receipt))
        collision["workers"] = .array([.object(["id": .string("synthesis"), "status": .string("completed"), "output": .string("ambiguous")])])
        let malformed: [Data] = [
            Data("{invalid".utf8),
            try JSONValue.object(["runs": .array([])]).serializedData(pretty: false),
            try JSONValue.array([fixture.receipt, fixture.receipt]).serializedData(pretty: false),
            // Every row unreadable is still a malformed STORE, not an empty one.
            try JSONValue.array([.object(collision)]).serializedData(pretty: false),
            try JSONValue.array([.string("malformed unrelated row"), .object(collision)]).serializedData(pretty: false),
        ]
        for bytes in malformed {
            try bytes.write(to: fixture.file)
            let unavailable = try await fixture.inspect()
            #expect(unavailable["status"] == .string("unavailable"))
            #expect(try Data(contentsOf: fixture.file) == bytes)
        }
        try FileManager.default.removeItem(at: fixture.file)
        try FileManager.default.createDirectory(at: fixture.file, withIntermediateDirectories: true)
        let unreadable = try await fixture.inspect()
        #expect(unreadable["reason"] == .string("receipt_store_unreadable"))
    }

    @Test func oneMalformedRowSkipsItselfInsteadOfBlackingOutEveryOtherRun() async throws {
        let fixture = try SwarmInspectionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // A legacy-shaped worker: no `output`, and status != "failed".
        let legacyRow = JSONValue.object([
            "id": .string("legacy-run"), "status": .string("completed"),
            "workers": .array([.object(["id": .string("w"), "status": .string("completed")])]),
        ])
        let unrelated = JSONValue.object([
            "id": .string("other-run"), "status": .string("completed"),
            "workers": .array([.object(["id": .string("w"), "status": .string("completed"), "output": .string("kept")])]),
        ])
        try fixture.write(.array([legacyRow, fixture.receipt, unrelated]))
        let original = try Data(contentsOf: fixture.file)

        let intact = try await fixture.inspect()
        #expect(intact["status"] == .string("ok"))
        #expect(intact["run_status"] == .string("cancelled"))
        #expect(intact["skipped_malformed_rows"] == .int(1))
        let other = try await fixture.inspect(["run_id": .string("other-run")])
        #expect(other["status"] == .string("ok"))
        #expect(other["skipped_malformed_rows"] == .int(1))
        // The corrupt row's own run is never reported as merely not-retained.
        let corrupt = try await fixture.inspect(["run_id": .string("legacy-run")])
        #expect(corrupt["status"] == .string("unavailable"))
        #expect(corrupt["reason"] == .string("receipt_store_malformed"))
        // An unknown run is still not_found, but carries the skip count so the
        // caller can tell "absent" from "possibly hidden by corruption".
        let unknown = try await fixture.inspect(["run_id": .string("never-ran")])
        #expect(unknown["status"] == .string("not_found"))
        #expect(unknown["reason"] == .string("receipt_not_retained"))
        #expect(unknown["skipped_malformed_rows"] == .int(1))

        // Clean rows only: no skip count is emitted at all.
        try fixture.write(.array([fixture.receipt, unrelated]))
        #expect(try await fixture.inspect()["skipped_malformed_rows"] == nil)

        // All rows malformed and none of them the requested run: the store as a
        // whole is malformed, never an empty not_found.
        try fixture.write(.array([legacyRow, legacyRow]))
        let allBad = try await fixture.inspect(["run_id": .string("never-ran")])
        #expect(allBad["status"] == .string("unavailable"))
        #expect(allBad["reason"] == .string("receipt_store_malformed"))

        // An empty store is empty, not malformed.
        try fixture.write(.array([]))
        #expect(try await fixture.inspect()["reason"] == .string("receipt_not_retained"))

        try original.write(to: fixture.file)
        #expect(try Data(contentsOf: fixture.file) == original)
    }

    @Test func oversizedStoreIsRejectedBeforeLoadingItsBody() async throws {
        let fixture = try SwarmInspectionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data().write(to: fixture.file)
        let handle = try FileHandle(forWritingTo: fixture.file)
        try handle.truncate(atOffset: 64 * 1_024 * 1_024 + 1)
        try handle.close()
        let oversized = try await fixture.inspect()
        #expect(oversized["reason"] == .string("receipt_store_too_large"))
    }
}
