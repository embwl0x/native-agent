import ActivityWatch
import Foundation
import Testing
@testable import NativeAgentApp

// W8 — "no activity store on disk until consent exists".
//
// This is a user-visible privacy promise, not an implementation detail: a
// privacy-minded user who finds an activity_spans.sqlite in their data root will
// reasonably assume something has been recording. So the promise needs a test,
// and the test needs to fail if the promise is withdrawn.
//
// The bug this pins (found on the second read of the W7/W8 wiring, 2026-08-14):
// the retro-delete and wipe paths asked "is there anything to purge?" with
// `try? ActivitySpanStore(dataRoot:)`, which is not a read — it CREATES the
// directory and the SQLite file. Its else-branch therefore only fired on a disk
// ERROR, never on "no store yet", so hitting Exclude or Wipe on a fresh install
// with capture never once enabled manufactured the very file it was asking
// about.

private func freshDataRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ActivityConsentTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func storeExists(_ root: URL) -> Bool {
    FileManager.default.fileExists(
        atPath: ActivityWatchPaths.databaseURL(dataRoot: root).path
    )
}

@MainActor
@Test("CONSENT: launch with capture off creates no activity store on disk")
func launchWithCaptureOffCreatesNoStore() async throws {
    let root = freshDataRoot()
    let controller = ActivityWatchController(dataRoot: root)

    #expect(controller.policy.captureEnabled == false)  // OFF by default
    controller.startAtLaunch()

    #expect(controller.isCapturing == false)
    #expect(!storeExists(root), "launch with capture off must not create the span store")
}

@MainActor
@Test("CONSENT: excluding an app before capture was ever on creates no store")
func excludeBeforeConsentCreatesNoStore() async throws {
    let root = freshDataRoot()
    let controller = ActivityWatchController(dataRoot: root)
    controller.startAtLaunch()

    // The user tightens privacy before ever enabling capture — the most
    // privacy-conscious order of operations there is. It must not be the thing
    // that creates the recording file.
    await controller.addExclusion(bundleID: "com.apple.Safari")

    #expect(controller.policy.excludedBundleIDs.contains("com.apple.Safari"))
    #expect(controller.lastPurgedRowCount == 0)
    #expect(!storeExists(root), "retro-delete must not create the store it purges from")
}

@MainActor
@Test("CONSENT: wipe before capture was ever on creates no store")
func wipeBeforeConsentCreatesNoStore() async throws {
    let root = freshDataRoot()
    let controller = ActivityWatchController(dataRoot: root)
    controller.startAtLaunch()

    await controller.wipeAll()

    #expect(controller.lastPurgedRowCount == 0)
    #expect(!storeExists(root), "wipe must not create the store it empties")
}
