import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Bots shelf preview")
struct BotsShelfTests {
    @Test("Flag off preserves the shipped rail destination snapshot")
    func flagOffDestinationSnapshot() {
        let expected = ["Chat", "Activity", "Memories", "Personality", "Providers", "Trust",
                        "Connectors", "Diagnostics", "Capabilities", "Inbox Policy", "Desk", "Settings"]
        #expect(BotsShelfRailProposal.destinations(SidebarItem.shellPrimaryItems, enabled: false) == expected)
        let subset: [SidebarItem] = [.chat, .desk, .settings]
        #expect(BotsShelfRailProposal.destinations(subset, enabled: false) == subset.map(\.rawValue))
        let defaults = UserDefaults(suiteName: "BotsShelfTests.\(UUID().uuidString)")!
        #expect(!BotsShelfPreference.isEnabled(defaults))
    }

    @MainActor @Test("Render the review shelf offscreen when explicitly requested")
    func headlessSnapshots() throws {
        #if DEBUG
        guard let output = ProcessInfo.processInfo.environment["BOTS_SHELF_SNAPSHOT_DIR"] else { return }
        try BotsShelfSnapshots.render(to: URL(fileURLWithPath: output, isDirectory: true))
        #endif
    }

    @MainActor @Test("Snapshot entry points are enclosed in DEBUG only")
    func debugOnlySnapshotEntryPoints() async throws {
        let sources = try AppSourceScraping.appSourcesRoot()
        for file in ["BotsShelfSnapshots.swift", "SimplicitySnapshots.swift"] {
            let source = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            #expect(lines.first == "#if DEBUG")
            #expect(source.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("#endif"))
            // No early #endif/#else can leave an entry point in release code.
            #expect(lines.filter { $0.hasPrefix("#if") }.count == 1)
            #expect(lines.filter { $0.hasPrefix("#endif") }.count == 1)
            #expect(!lines.contains { $0.hasPrefix("#else") })
            #expect(source.contains("static func render(to directory: URL) throws"))
        }
        #if DEBUG
        let entryPoints: [@MainActor (URL) throws -> Void] = [
            BotsShelfSnapshots.render(to:), SimplicitySnapshots.render(to:),
        ]
        #expect(entryPoints.count == 2)
        #expect(SimplicitySnapshots.Screen.allCases.count == 7)
        if let output = ProcessInfo.processInfo.environment["SIMPLICITY_SNAPSHOT_DIR"] {
            if ProcessInfo.processInfo.environment["PROVIDERS_SNAPSHOT_ONLY"] != "1" {
                try entryPoints[1](URL(fileURLWithPath: output, isDirectory: true))
            }
            try await SimplicitySnapshots.renderProviders(to: URL(fileURLWithPath: output, isDirectory: true).appendingPathComponent("pass2"))
        }
        #endif
    }
}
