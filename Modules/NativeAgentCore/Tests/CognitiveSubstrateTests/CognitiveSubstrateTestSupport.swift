import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ current: Date) {
        self.current = current
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

final class TestUUIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0

    func next() -> UUID {
        lock.lock()
        defer {
            index += 1
            lock.unlock()
        }
        return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
    }
}

func makeSubstrate(
    clock: TestClock,
    uuids: TestUUIDs = TestUUIDs(),
    configuration: CognitiveConfiguration = CognitiveConfiguration(
        enabled: true,
        maximumActiveNodes: 256,
        defaultDecayHalfLife: 100
    ),
    store: CognitiveSQLiteStore? = nil
) -> CognitiveSubstrate {
    CognitiveSubstrate(
        configuration: configuration,
        dependencies: CognitiveSubstrateDependencies(
            now: { clock.now() },
            makeUUID: { uuids.next() },
            // Configured user name flows into the capsule/reflection cues (no
            // hardcoded "User" in source). These tests assert "…with User" etc.,
            // which now verifies the name is threaded end-to-end.
            userName: { "User" }
        ),
        store: store
    )
}

func tempDataRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("nativeagent-cognitive-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

func event(
    id: String,
    kind: CognitiveEventKind = .userMessageReceived,
    subjectID: String,
    importance: Double = 0.5,
    occurredAt: Date,
    metadata: [String: JSONValue] = [:]
) -> CognitiveEvent {
    CognitiveEvent(
        id: id,
        kind: kind,
        subject: CognitiveSubjectReference(type: "topic", id: subjectID, label: subjectID),
        sourceClass: kind == .toolSucceeded ? .observed : .userStated,
        occurredAt: occurredAt,
        summary: "event \(id)",
        importance: importance,
        metadata: metadata
    )
}
