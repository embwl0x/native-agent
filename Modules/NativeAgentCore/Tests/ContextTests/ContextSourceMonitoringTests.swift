import Context
import Foundation
import Testing

private actor ContextDirectoryEventRecorder {
    private var events: [ContextDirectoryEvent] = []
    private var batches: [Set<URL>] = []
    private var cancellationStates: [Bool] = []

    func record(_ event: ContextDirectoryEvent) {
        events.append(event)
    }

    func record(batch: Set<URL>) {
        batches.append(batch)
    }

    func recordCancellationState(_ cancelled: Bool) {
        cancellationStates.append(cancelled)
    }

    func eventCount() -> Int { events.count }
    func recordedBatches() -> [Set<URL>] { batches }
    func recordedCancellationStates() -> [Bool] { cancellationStates }
}

@Suite(.serialized)
struct ContextSourceMonitoringTests {
    @Test
    func registryAllowsOnlyExplicitRootsAndRejectsSymlinkEscape() async throws {
        let root = try makeDirectory("allowed")
        let outside = try makeDirectory("outside")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let validFile = root.appendingPathComponent("SOUL.md")
        try "identity".write(to: validFile, atomically: true, encoding: .utf8)
        let outsideFile = outside.appendingPathComponent("private.md")
        try "private".write(to: outsideFile, atomically: true, encoding: .utf8)
        let escapedLink = root.appendingPathComponent("escaped.md")
        try FileManager.default.createSymbolicLink(at: escapedLink, withDestinationURL: outsideFile)

        let registry = try ContextSourceRegistry(allowedRoots: [root])
        let valid = registration(id: "soul", file: validFile, root: root)
        try await registry.register(valid)
        #expect(await registry.allRegistrations().map(\.descriptor.id) == [valid.descriptor.id])

        let escaped = registration(id: "escaped", file: escapedLink, root: root)
        do {
            try await registry.register(escaped)
            Issue.record("symlink escape unexpectedly registered")
        } catch let error as ContextSourceRegistryError {
            guard case .sourceOutsideRoot = error else {
                Issue.record("unexpected registry error: \(error)")
                return
            }
        }
    }

    @Test
    func registryReturnsAffectedSourcesAndParentWatch() async throws {
        let root = try makeDirectory("root")
        defer { try? FileManager.default.removeItem(at: root) }
        let persona = root.appendingPathComponent("persona", isDirectory: true)
        try FileManager.default.createDirectory(at: persona, withIntermediateDirectories: true)
        let soul = persona.appendingPathComponent("SOUL.md")
        let voice = persona.appendingPathComponent("VOICE.md")
        try "soul".write(to: soul, atomically: true, encoding: .utf8)
        try "voice".write(to: voice, atomically: true, encoding: .utf8)

        let registry = try ContextSourceRegistry(allowedRoots: [persona])
        try await registry.register(registration(id: "soul", file: soul, root: persona))
        try await registry.register(registration(id: "voice", file: voice, root: persona))

        let affected = try await registry.registrations(affectedBy: persona)
        #expect(affected.map(\.descriptor.id.rawValue) == ["soul", "voice"])
        let watched = await registry.watchedDirectories()
        #expect(watched.contains(persona.resolvingSymlinksInPath()))
        #expect(watched.contains(persona.deletingLastPathComponent().resolvingSymlinksInPath()))
    }

    @Test
    func coalescerBatchesDirtyDirectoriesDeterministically() async throws {
        let recorder = ContextDirectoryEventRecorder()
        let first = URL(fileURLWithPath: "/tmp/context-first")
        let second = URL(fileURLWithPath: "/tmp/context-second")
        let coalescer = ContextSourceEventCoalescer(delay: .seconds(30)) { batch in
            await recorder.record(batch: batch)
        }

        await coalescer.enqueue(first)
        await coalescer.enqueue(second)
        await coalescer.enqueue(first)
        await coalescer.flush()

        let batches = await recorder.recordedBatches()
        #expect(batches.count == 1)
        #expect(batches[0] == Set([first.standardizedFileURL, second.standardizedFileURL]))
    }

    @Test
    func coalescerAutomaticDeliveryDoesNotCancelItsHandler() async throws {
        let recorder = ContextDirectoryEventRecorder()
        let directory = URL(fileURLWithPath: "/tmp/context-automatic")
        let coalescer = ContextSourceEventCoalescer(delay: .milliseconds(5)) { batch in
            await recorder.record(batch: batch)
            await recorder.recordCancellationState(Task.isCancelled)
        }
        await coalescer.enqueue(directory)

        let deadline = ContinuousClock.now + .seconds(1)
        while await recorder.recordedBatches().isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(await recorder.recordedBatches() == [Set([directory.standardizedFileURL])])
        #expect(await recorder.recordedCancellationStates() == [false])
    }

    @Test
    func coalescerCancelSuppressesScheduledDelivery() async throws {
        let recorder = ContextDirectoryEventRecorder()
        let coalescer = ContextSourceEventCoalescer(delay: .milliseconds(20)) { batch in
            await recorder.record(batch: batch)
        }
        await coalescer.enqueue(URL(fileURLWithPath: "/tmp/context-cancelled"))
        await coalescer.cancel()
        try await Task.sleep(for: .milliseconds(40))

        #expect(await recorder.recordedBatches().isEmpty)
    }

    @Test
    func directoryMonitorObservesAtomicFileReplacement() async throws {
        let root = try makeDirectory("watch")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ContextDirectoryEventRecorder()
        let monitor = ContextSourceMonitor { event in
            await recorder.record(event)
        }
        await monitor.setDirectories([root])
        #expect(await monitor.watchedDirectories() == [root.resolvingSymlinksInPath()])

        let target = root.appendingPathComponent("SOUL.md")
        try "one".write(to: target, atomically: true, encoding: .utf8)
        try "two".write(to: target, atomically: true, encoding: .utf8)

        let deadline = ContinuousClock.now + .seconds(2)
        while await recorder.eventCount() == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await recorder.eventCount() > 0)
        await monitor.stop()
        #expect(await monitor.watchedDirectories().isEmpty)
    }

    private func registration(id: String, file: URL, root: URL) -> ContextSourceRegistration {
        ContextSourceRegistration(
            descriptor: ContextSourceDescriptor(
                id: ContextSourceID(rawValue: id),
                owner: "persona",
                kind: .persona,
                canonicalLocator: file.path,
                authority: .identity,
                privacy: .localPrivate,
                permittedSurfaces: [.chat],
                injectionPolicy: .always
            ),
            fileURL: file,
            allowedRoot: root
        )
    }

    private func makeDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextSourceMonitoringTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
