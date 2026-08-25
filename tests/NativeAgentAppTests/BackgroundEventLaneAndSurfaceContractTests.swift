// Fence app.background — the event/deadline physiology lane and the chat-surface
// loop cadence.
//
// Ledger rows closed here:
//   app.background.eventLane.storeAndFileEvents
//   app.background.chatSurfaces.telegramPollInterval
//
// Class: LIFECYCLE / SILENT ZERO. `storeAndFileEvents` is the ingress every
// event-driven loop hangs off. If it arms a watcher on a path whose parent
// directory does not exist yet — the normal state on a fresh install — the
// stream is created, never yields, and every event-driven loop degrades to its
// slow integrity interval with nothing anywhere reporting it. The Telegram poll
// cadence has the mirror problem: a loop whose tick budget falls back to the
// scheduler's 300s default gets a full chat turn (tool subprocesses included)
// cancelled mid-flight, and the user just sees no reply.

import Foundation
import Testing
import BackgroundLoops
import NativeAgentCore
import PersistenceCore
import TelegramBot
@testable import NativeAgentApp

private func eventLaneTempRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BackgroundEventLane-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite("app.background event lane and chat surfaces")
struct BackgroundEventLaneAndSurfaceContractTests {

    @Test("arming the event lane creates every watched parent directory")
    func storeAndFileEventsArmsOnPathsThatDoNotExistYet() throws {
        let root = try eventLaneTempRoot("arm")
        defer { try? FileManager.default.removeItem(at: root) }

        // Nothing here exists yet — the fresh-install state. A watcher armed on
        // a missing parent can never fire, and the loop that depends on it
        // silently falls back to its slow interval forever.
        let a = root.appendingPathComponent("trust/policy.json")
        let b = root.appendingPathComponent("desk/nested/deeper/desk_ops.jsonl")
        #expect(!FileManager.default.fileExists(atPath: a.deletingLastPathComponent().path))
        #expect(!FileManager.default.fileExists(atPath: b.deletingLastPathComponent().path))

        let stream = EventDeadlinePhysiology.storeAndFileEvents(paths: [a, b])
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: a.deletingLastPathComponent().path, isDirectory: &isDir) && isDir.boolValue,
            "arming must create the watched parent, or the stream can never fire")
        #expect(FileManager.default.fileExists(
            atPath: b.deletingLastPathComponent().path, isDirectory: &isDir) && isDir.boolValue,
            "arming must create nested watched parents too")
        // Terminating the stream tears the watcher and bus task down (the
        // onTermination hook); dropping it here exercises that path.
        _ = stream
    }

    @Test("a write to a watched file yields an invalidation on the event lane")
    func storeAndFileEventsYieldsOnAFileWrite() async throws {
        let root = try eventLaneTempRoot("fire")
        defer { try? FileManager.default.removeItem(at: root) }
        let watched = root.appendingPathComponent("trust/policy.json")

        let stream = EventDeadlinePhysiology.storeAndFileEvents(paths: [watched])

        // Bounded: a lane that can never fire must fail the test, never hang the
        // suite. The write happens after the stream exists so the edge cannot
        // be missed by the arm.
        let writer = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            try? Data("{\"permissionLevel\":\"workspace\"}".utf8).write(to: watched)
            try? await Task.sleep(nanoseconds: 150_000_000)
            try? Data("{\"permissionLevel\":\"supervised\"}".utf8).write(to: watched)
        }
        defer { writer.cancel() }

        let fired = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                for await _ in stream { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(fired, "a write to a watched path produced no invalidation within 5s")
    }

    @Test("the Telegram poll loop keeps its sub-second cadence and a full-turn tick budget")
    func telegramPollLoopCadenceAndBudget() throws {
        let root = try eventLaneTempRoot("telegram")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("telegram", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        func writeConfig(_ obj: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: obj)
                .write(to: dir.appendingPathComponent("config.json"))
        }

        try writeConfig(["bot_token": "123:TEST-TOKEN", "enabled": true])
        guard let loop = BackgroundLoopsAssembly.makeTelegramPollLoopIfConfigured(dataRoot: root) else {
            Issue.record("a configured, enabled Telegram surface produced no loop")
            return
        }
        let runner: any LoopRunner = loop
        #expect(runner.loopId == "telegram_poll")
        // 0.25s: this is the responsiveness of the whole Telegram surface. A
        // regression to a multi-second cadence reads as "she's slow today".
        #expect(runner.interval == 0.25)
        // A tick runs an ENTIRE chat turn including tool subprocesses. Falling
        // back to the scheduler's 300s default cancels long turns mid-flight
        // and the user simply never gets a reply.
        #expect(runner.tickTimeoutOverride == 3600)

        // Fail-closed: disabled or token-less config must produce no loop at all,
        // not a loop that polls a bad token forever.
        try writeConfig(["bot_token": "123:TEST-TOKEN", "enabled": false])
        #expect(BackgroundLoopsAssembly.makeTelegramPollLoopIfConfigured(dataRoot: root) == nil)
        try writeConfig(["bot_token": "", "enabled": true])
        #expect(BackgroundLoopsAssembly.makeTelegramPollLoopIfConfigured(dataRoot: root) == nil)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("config.json"))
        #expect(BackgroundLoopsAssembly.makeTelegramPollLoopIfConfigured(dataRoot: root) == nil)
    }
}
