import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import MacControl
@testable import ChatOrchestration

private struct PairedAXFixtureHost: MacFourVerbsHost {
    var extraUnnamed = false
    var changedFirstLabel = false

    func entry(_ path: Int, view: Bool) -> JSONValue {
        let label: JSONValue = path <= 2
            ? .string(view && changedFirstLabel && path == 1 ? "Replaced" : "Remove") : .null
        return .object([
            "path": .array([.int(Int64(path))]),
            "handle": .string("semantic-\(path)"),
            "mark": .int(Int64(100 + path)),
            "role": .string("AXButton"),
            "label": label,
            "label_source": .string(path <= 2 ? "title" : "none"),
            "enabled": .bool(path != 4 && path != 6),
            "frame": .object([
                "x": .double(Double(path * 100)), "y": .double(100),
                "w": .double(80), "h": .double(30),
            ]),
        ])
    }

    func dispatch(action: String, body: [String: JSONValue]) async throws -> MacControlResult {
        #expect(action == "look" || action == "view", "The fixture must never perform input")
        var output: [String: JSONValue] = [
            "app": .object(["name": .string("Local controls fixture")]),
            "window": .string("Controls"),
            "frame_id": .string("semantic-frame"),
            "accessibility_trusted": .bool(true),
        ]
        if action == "look" {
            output["affordances"] = .array((1...5).map { entry($0, view: false) })
        } else {
            // Capture ranking is deliberately different from semantic order,
            // as with the installed window's enabled/disabled titlebar buttons.
            let order = [5, 3, 4, 2, 1] + (extraUnnamed ? [6] : [])
            output["marks"] = .array(order.map { entry($0, view: true) })
            output["view"] = .string("private-capture-id")
        }
        return MacControlResult(ok: true, action: action, output: .object(output), error: nil, durationMs: 0, viaSwift: true)
    }
}

private func pairedSight(_ host: PairedAXFixtureHost) async throws -> MacFourVerbs.Sighting {
    let verbs = MacFourVerbs(
        host: host,
        supplementalSource: SwiftToolDispatcherFourVerbPerceptionSource(host: host),
        namedLocationRoots: []
    )
    guard case .seen(let sight) = await verbs.sight(part: nil) else {
        throw CocoaError(.coderInvalidValue)
    }
    return sight
}

private struct PairedFinderItemHost: MacFourVerbsHost {
    var duplicateFile = false
    var omitted = 0
    func dispatch(action: String, body: [String: JSONValue]) async throws -> MacControlResult {
        #expect(action == "look" || action == "view")
        let leaf = action == "look"
        func item(_ index: Int) -> JSONValue {
            .object([
                "path": .array(([0, index] + (leaf ? [0, 1] : [])).map { .int(Int64($0)) }),
                "handle": .string("filename-\(index)"), "mark": .int(Int64(index + 10)),
                "role": .string(leaf ? "AXTextField" : "AXRow"),
                "label": .string("fixture.html"), "enabled": .bool(true),
                "frame": .object(["x": .int(100), "y": .int(Int64(100 + index * 30)),
                                  "w": .int(leaf ? 180 : 500), "h": .int(20)])
            ])
        }
        let items = [item(0)] + (duplicateFile ? [item(1)] : [])
        return MacControlResult(ok: true, action: action, output: .object([
            "app": .object(["name": .string("Finder")]), "window": .string("Fixture folder"),
            "frame_id": .string("frame"), "view": .string("capture"),
            "affordances_omitted": .int(Int64(omitted)),
            "accessibility_trusted": .bool(true), (leaf ? "affordances" : "marks"): .array(items)
        ]), error: nil, durationMs: 0, viaSwift: true)
    }
}

@Test func pairedFinderRowAndFilenameBecomeOneAddressWithoutBorrowingAncestorMark() async throws {
    for duplicates in [false, true] {
        let host = PairedFinderItemHost(duplicateFile: duplicates)
        let verbs = MacFourVerbs(host: host,
            supplementalSource: SwiftToolDispatcherFourVerbPerceptionSource(host: host), namedLocationRoots: [])
        guard case .seen(let sight) = await verbs.sight(part: nil) else {
            Issue.record("Missing fixture sight"); continue
        }
        #expect(sight.targets.count == (duplicates ? 2 : 1))
        #expect(sight.targets.allSatisfy { $0.handle.hasPrefix("filename-") && $0.mark == nil })
        #expect(sight.render.components(separatedBy: "\n").filter { $0.contains("fixture.html") }.count == (duplicates ? 2 : 1))
        if duplicates {
            guard case .ambiguous(let targets) = MacFourVerbs.resolve("fixture.html", among: sight.targets) else {
                Issue.record("Separate identically named rows must remain ambiguous"); continue
            }
            #expect(targets.count == 2)
        } else {
            guard case .hit(let target) = MacFourVerbs.resolve("fixture.html", among: sight.targets) else {
                Issue.record("One visible filename must resolve once"); continue
            }
            #expect(target.handle == "filename-0")
            #expect(target.sourceAXPath == [0, 0, 0, 1])
        }
    }
}

@Test func fusedScreenDoesNotTurnUnknownOmissionsIntoPhantomFileRows() async throws {
    let host = PairedFinderItemHost(omitted: 14)
    let verbs = MacFourVerbs(host: host,
        supplementalSource: SwiftToolDispatcherFourVerbPerceptionSource(host: host), namedLocationRoots: [])
    guard case .seen(let sight) = await verbs.sight(part: nil) else {
        Issue.record("Missing fixture sight"); return
    }
    #expect(sight.render.contains("LIST    1 items"))
    #expect(!sight.render.contains("15 items"))
    #expect(!sight.render.contains("14 more below"))
    #expect(sight.render.contains("Semantic read omitted 14 AX targets; types/locations unknown."))
    #expect(sight.detail["semantic_targets_omitted"] == .int(14))
    #expect(sight.detail["rows_dropped"] == .int(0))
    #expect(sight.targets.count == 1)
    guard case .seen(let zoomed) = await verbs.sight(part: "fixture.html") else {
        Issue.record("Missing zoomed sight"); return
    }
    #expect(zoomed.render.contains("Semantic read omitted 14 AX targets"))
}

@Test
func pairedStructuralFusionKeepsDuplicateMarksAndPrintedOrdinalsDistinct() async throws {
    let sight = try await pairedSight(PairedAXFixtureHost())
    #expect(sight.targets.count == 5)
    for path in 1...5 {
        let target = try #require(sight.targets.first { $0.sourceAXPath == [path] })
        #expect(target.handle == "semantic-\(path)")
        #expect(target.mark == 100 + path)
        #expect(target.viewId == "private-capture-id")
        #expect(target.enabled == (path != 4))
        #expect(target.roleOrdinal == (path <= 2 ? path + 3 : path - 2))
    }
    for ordinal in 1...5 {
        let lines = sight.render.components(separatedBy: "\n").filter { $0.contains("button \(ordinal) ") }
        #expect(lines.count == 1, "Each printed address must appear once: \(sight.render)")
        #expect(lines.first?.contains("disabled") == (ordinal == 2))
    }
    for (address, path) in [("button 4 Remove", 1), ("button 5 Remove", 2), ("button 1", 3), ("button 2", 4), ("button 3", 5)] {
        guard case .hit(let target) = MacFourVerbs.resolve(address, among: sight.targets) else {
            Issue.record("Printed address did not resolve: \(address)"); continue
        }
        #expect(target.sourceAXPath == [path])
        #expect(target.mark == 100 + path)
    }
    guard case .ambiguous(let duplicateNames) = MacFourVerbs.resolve("Remove", among: sight.targets) else {
        Issue.record("An unqualified duplicate name must still abstain"); return
    }
    #expect(duplicateNames.count == 2)
    #expect(!sight.render.contains("private-capture-id"))
    #expect(!sight.render.contains("semantic-"))
    #expect(!sight.render.contains("sourceAXPath"))
}

@Test
func pairedStructuralFusionAssignsUnmatchedDisabledControlOneSharedOrdinal() async throws {
    let sight = try await pairedSight(PairedAXFixtureHost(extraUnnamed: true))
    let target = try #require(sight.targets.first { $0.sourceAXPath == [6] })
    #expect(target.roleOrdinal == 6)
    #expect(!target.enabled)
    let lines = sight.render.components(separatedBy: "\n").filter { $0.contains("button 6 ") }
    #expect(lines.count == 1)
    #expect(lines.first?.contains("disabled") == true)
    #expect(sight.targets.first { $0.sourceAXPath == [3] }?.roleOrdinal == 1)
    #expect(sight.targets.first { $0.sourceAXPath == [4] }?.roleOrdinal == 2)
    #expect(sight.targets.first { $0.sourceAXPath == [5] }?.roleOrdinal == 3)
}

@Test
func pairedStructuralFusionDoesNotGiveReusedPathMarkToDifferentLabel() async throws {
    let sight = try await pairedSight(PairedAXFixtureHost(changedFirstLabel: true))
    let old = try #require(sight.targets.first { $0.handle == "semantic-1" })
    #expect(old.label == "Remove")
    #expect(old.mark == nil)
    let replacement = try #require(sight.targets.first { $0.label == "Replaced" })
    #expect(replacement.mark == 101)
    #expect(replacement.handle.isEmpty)
    #expect(sight.targets.first { $0.handle == "semantic-2" }?.mark == 102)
    #expect(sight.render.contains("Replaced"))
}
