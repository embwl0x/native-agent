import Foundation
import Testing
import BackgroundLoops
@testable import NativeAgentApp

// MARK: - Sweep FIX 3 — heartbeat's error section watches the LIVE sinks
//
// The heartbeat used to read `data/logs/errors.jsonl` — a file with thirteen
// readers and no writer since 2026-06-02 — and report "Errors: 0 recent row(s)
// … ok" forever. It now reads the sinks the app actually appends to, and a feed
// nobody has written in a week reads "no signal", never "clean".

private func errorFeedTempRoot() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("heartbeat-errfeed-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeErrorFeed(_ root: URL, relative: String, rows: [String]) {
    let url = relative.split(separator: "/").reduce(root) {
        $0.appendingPathComponent(String($1))
    }
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(rows.joined(separator: "\n").utf8).write(to: url)
}

@Test func heartbeatReportsNoSignalWhenEveryErrorFeedIsDead() async {
    let root = errorFeedTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let assessment = await BackgroundLoopsAssembly.gatherHeartbeatAssessment(dataRoot: root)

    // Nothing has ever been written, so nothing is reporting. That is not a
    // clean bill of health.
    #expect(assessment.signals.contains("no signal"))
    #expect(assessment.signals.contains("telegram no signal"))
    #expect(!assessment.signals.contains("Errors: 0 recent row(s)"))
    #expect(assessment.deterministicOK == false)
}

@Test func heartbeatCountsRecentRowsFromTheLiveTelegramFeed() async {
    let root = errorFeedTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date()
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    let ts = iso.string(from: now)
    writeErrorFeed(root, relative: "telegram/errors.jsonl", rows: (0..<3).map {
        "{\"at\":\"\(ts)\",\"context\":\"poll\",\"error\":\"unavailable \($0)\"}"
    })

    let assessment = await BackgroundLoopsAssembly.gatherHeartbeatAssessment(
        dataRoot: root, now: now)

    #expect(assessment.signals.contains("telegram 3 row(s)"))
    // The dead legacy feed is still named, and still called what it is.
    #expect(assessment.signals.contains("legacy no signal"))
}
