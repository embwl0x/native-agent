import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
import TriggerScheduler
@testable import NativeAgentApp

/// Coverage ledger: app.background / app.background.triggerNotifierBinding
///
/// A trigger fire is useful only if its card reaches the one notifications
/// inbox every user-facing surface reads. This drives the real app-side mirror
/// at an isolated root; it does not borrow the live iCloud/notification path.
@Suite("app.background · trigger notifier binding", .serialized)
struct TriggerNotifierBindingCoverageEvalTests {
    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trigger-notifier-binding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func fire(id: String, title: String, notified: Bool) -> TriggerFireResult {
        TriggerFireResult(
            status: "fired",
            name: "eval_trigger",
            itemId: id,
            item: .object([
                "id": .string(id),
                "source": .string("trigger:eval_trigger"),
                "severity": .string("info"),
                "title": .string(title),
                "summary": .string("A hermetic trigger fire: \(id)"),
            ]),
            notified: notified
        )
    }

    @Test("each non-notified fire gets one observable inbox card while an already-notified fire gets none")
    func mirrorWritesOnlyTheFiresWhoseNotifierDidNotAlreadyHandleThem() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = fire(id: "fire-one", title: "First trigger", notified: false)
        let second = fire(id: "fire-two", title: "Second trigger", notified: false)
        let alreadyNotified = fire(id: "fire-three", title: "Already notified", notified: true)

        #expect(await TriggerNotifierBinding.mirrorNonNotifiedFire(first, dataRoot: root))
        // Re-entering the same fire must find its active equivalent, not append
        // a second row while the first card is still visible.
        #expect(await TriggerNotifierBinding.mirrorNonNotifiedFire(first, dataRoot: root))
        #expect(await TriggerNotifierBinding.mirrorNonNotifiedFire(second, dataRoot: root))
        #expect(await TriggerNotifierBinding.mirrorNonNotifiedFire(alreadyNotified, dataRoot: root))

        let inbox = root
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        let rows = try await SwiftNativePersistenceCore().readJSONL(inbox)
        #expect(rows.count == 2)
        let ids = Set(rows.compactMap { row -> String? in
            guard case .object(let object) = row,
                  case .string(let id)? = object["id"] else { return nil }
            return id
        })
        #expect(ids == ["fire-one", "fire-two"])
        #expect(!ids.contains("fire-three"))
    }

    @Test("the background loop reserves its no-op mirror only for non-default roots")
    func alternateRootStubIsGuardedByTheSameLiveRootPredicateThatBindsTheNotifier() throws {
        let assembly = try AppSourceScraping.appSource("BackgroundLoopsAssembly+TriggerScheduler.swift")
        let factory = try AppSourceScraping.functionBody(named: "makeTriggerSchedulerLoop", in: assembly)

        #expect(factory.contains("let isLiveRoot = standardized\n            == PersistenceCore.defaultDataRoot().standardizedFileURL"))
        #expect(factory.contains("let notifier: TriggerNotifier? = isLiveRoot\n            ? TriggerNotifierBinding.pairedDevicePush\n            : nil"))
        #expect(factory.contains("if isLiveRoot {\n            mirror = { result in\n                await TriggerNotifierBinding.mirrorNonNotifiedFire(result)\n            }\n        } else {\n            mirror = { _ in true }"))
    }
}
