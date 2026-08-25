import Foundation
import Testing
@testable import NativeAgentApp

private func memoryMenuActionRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("memory-menu-actions-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite("Memory actions menu — canonical maintenance receipts")
struct MemoryMenuActionsEvalTests {
    @Test("the real hygiene menu owner writes and reports only through its injected root")
    @MainActor
    func hygieneActionUsesTheAppModelRoot() async throws {
        let root = try memoryMenuActionRoot("hygiene")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        let controller = MemoryMenuActionController()

        await controller.run(.hygiene, appModel: app)
        let feedback = try #require(controller.feedback)
        guard case let .completed(message) = feedback else {
            Issue.record("empty isolated store should complete hygiene, received \(feedback)")
            return
        }
        #expect(FileManager.default.fileExists(
            atPath: MemoryConsolidationHygiene.lastRunPath(dataRoot: root).path
        ))

        // MemoryView renders this exact controller-owned receipt. Assert the
        // action boundary itself instead of relying on an offscreen SwiftUI
        // host to materialize an AppKit text field.
        #expect(controller.runningAction == nil)
        #expect(controller.feedback == .completed(message))
        #expect(!feedback.isAdverse)
    }

    @Test("the real consolidation menu owner stages against the injected store")
    @MainActor
    func consolidateActionUsesTheAppModelRoot() async throws {
        let root = try memoryMenuActionRoot("consolidate")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        let controller = MemoryMenuActionController()

        await controller.run(.consolidate, appModel: app)
        let feedback = try #require(controller.feedback)
        switch feedback {
        case .completed, .pendingApproval:
            break
        default:
            Issue.record("isolated consolidation should return an actionable owner receipt: \(feedback)")
        }
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("memory/memory.sqlite").path
        ))

        #expect(controller.runningAction == nil)
        #expect(controller.feedback == feedback)
        #expect(!feedback.message.isEmpty)
    }

    @Test("an unusable menu root is a visible failure, not a maintenance success")
    @MainActor
    func hygieneFailureStaysAdverseAndPreservesTheRootBytes() async throws {
        let container = try memoryMenuActionRoot("unavailable")
        defer { try? FileManager.default.removeItem(at: container) }
        let rootFile = container.appendingPathComponent("not-a-data-root")
        let original = Data("not a directory".utf8)
        try original.write(to: rootFile)
        let app = AppModel(dataRootOverride: rootFile, startBackgroundTasks: false)
        let controller = MemoryMenuActionController()

        await controller.run(.hygiene, appModel: app)
        let feedback = try #require(controller.feedback)
        guard case let .failed(message) = feedback else {
            Issue.record("an unusable Memory root must fail rather than claim hygiene completion: \(feedback)")
            return
        }
        #expect(message.hasPrefix("Memory hygiene failed:"))
        #expect(try Data(contentsOf: rootFile) == original)

        #expect(controller.runningAction == nil)
        #expect(controller.feedback == .failed(message))
        #expect(feedback.isAdverse)
    }
}
