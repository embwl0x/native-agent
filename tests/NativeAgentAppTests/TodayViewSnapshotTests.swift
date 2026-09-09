#if DEBUG
import Foundation
import SwiftUI
import Testing
@testable import NativeAgentApp

/// Explicit headless layout receipt. No AppModel, windows, or private stores.
@MainActor
struct TodayViewSnapshotTests {
    @Test func renderRequestedTodayFixtures() throws {
        guard let output = ProcessInfo.processInfo.environment["TODAY_SNAPSHOT_DIR"] else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let at = Date(timeIntervalSince1970: 1_788_780_600)
        for scheme in [ColorScheme.light, .dark] {
            let rows = [
                TodayRow(id: "talked", title: "Talked with you", line: "One conversation, on Mac.", at: at),
                TodayRow(id: "worked", title: "I worked with another builder",
                         line: "One loaded conversation with builder participation.", at: at),
                TodayRow(id: "dream", title: "I dreamed",
                         line: "A garden after rain. Quiet, with something new taking root beyond the familiar paths.",
                         at: at, dreamDate: "2026-09-07"),
            ]
            try BotsShelfSnapshots.write(
                VStack(alignment: .leading, spacing: 20) {
                    Text("Today").font(ShellType.display)
                    TodaySection(title: "What I did today", rows: rows, onReadDream: { _ in true })
                    TodayRowCard(row: TodayRow(id: "dream", title: "I dreamed",
                        line: "A garden after rain.", at: at))
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(scheme == .dark ? Color.black : Color.white),
                name: scheme == .dark ? "today-dark" : "today-light",
                size: CGSize(width: 920, height: 480), scheme: scheme, directory: directory, scale: 1
            )
        }
    }
}
#endif
