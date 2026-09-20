import Foundation
import Darwin
import Testing
@testable import Dispatcher

private func runDeadlineFixture(_ script: String, descriptor: Bool, timeout: TimeInterval) throws -> ProcessRunResult {
    if descriptor {
        let fd = open(NSTemporaryDirectory(), O_RDONLY | O_DIRECTORY)
        defer { close(fd) }
        #expect(fd >= 0)
        return runProcess("/bin/sh", ["-c", script], cwdDescriptor: fd, timeout: timeout)
    }
    return runProcess("/bin/sh", ["-c", script], timeout: timeout)
}

@Test(arguments: [false, true])
func processDeadlineStopsPipesHeldByDescendants(descriptor: Bool) throws {
    let start = ContinuousClock.now
    let result = try runDeadlineFixture(
        "sleep 30 & echo $!; printf partial >&2; exit 0",
        descriptor: descriptor, timeout: 10)
    // Stop the fixture descendant even though it no longer holds up its caller.
    if let pid = Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 {
        kill(pid, SIGKILL)
    }
    #expect(start.duration(to: .now) < .seconds(5))
    #expect(result.launched && result.timedOut)
    #expect(result.stderr == "partial")
    #expect(!result.captureReadFailed)
}

@Test(arguments: [false, true])
func processDeadlineKillsChildrenIgnoringTermination(descriptor: Bool) throws {
    let start = ContinuousClock.now
    let result = try runDeadlineFixture(
        "trap '' TERM; printf ready; exec sleep 30",
        descriptor: descriptor, timeout: 0.1)
    #expect(start.duration(to: .now) < .seconds(5))
    #expect(result.launched && result.timedOut)
    #expect(result.stdout == "ready")
}
