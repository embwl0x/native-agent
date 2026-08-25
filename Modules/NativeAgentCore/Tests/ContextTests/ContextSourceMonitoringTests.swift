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

    /// `replaceOwned` is the owner-scoped bulk replace — the path a projection
    /// owner uses to say "these, and only these, are mine now". Its REMOVAL half
    /// is what retires a persona skill body or an unregistered projection.
    /// `register` and the symlink-escape guard above are covered; this one had
    /// zero test references, and if the removal half regresses, retired sources
    /// stay registered and keep being compiled into every generation — content
    /// the user believes they deleted keeps riding into the prompt, invisibly.
    ///
    /// The other half of the contract is the owner FENCE: replacing one owner's
    /// set must not disturb another's.
    @Test
    func replaceOwnedDropsRetiredSourcesAndLeavesOtherOwnersUntouched() async throws {
        let root = try makeDirectory("replace-owned")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.md", "b.md", "c.md", "other.md"] {
            try name.write(
                to: root.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
        }
        func file(_ name: String) -> URL { root.appendingPathComponent(name) }

        let registry = try ContextSourceRegistry(allowedRoots: [root])
        try await registry.register(registration(id: "a", file: file("a.md"), root: root, owner: "skills"))
        try await registry.register(registration(id: "b", file: file("b.md"), root: root, owner: "skills"))
        try await registry.register(registration(id: "c", file: file("c.md"), root: root, owner: "skills"))
        try await registry.register(registration(id: "other", file: file("other.md"), root: root, owner: "persona"))
        #expect(await registry.allRegistrations().count == 4)

        // "skills" now claims only a and c. b is retired.
        try await registry.replaceOwned(owner: "skills", with: [
            registration(id: "a", file: file("a.md"), root: root, owner: "skills"),
            registration(id: "c", file: file("c.md"), root: root, owner: "skills"),
        ])

        let remaining = await registry.allRegistrations().map(\.descriptor.id.rawValue).sorted()
        #expect(remaining == ["a", "c", "other"])
        #expect(await registry.registration(for: ContextSourceID(rawValue: "b")) == nil)
        // The retired source must also stop being watched — a registration that
        // is gone from the list but still armed keeps waking reconciliation.
        let affected = try await registry.registrations(affectedBy: root).map(\.descriptor.id.rawValue).sorted()
        #expect(affected == ["a", "c", "other"])
        // The foreign owner's registration is byte-identical, not merely present.
        let untouched = try #require(await registry.registration(for: ContextSourceID(rawValue: "other")))
        #expect(untouched.descriptor.owner == "persona")
        #expect(untouched.fileURL == file("other.md").resolvingSymlinksInPath())

        // A replacement carrying a foreign owner is ignored rather than
        // smuggled in under the caller's owner scope.
        try await registry.replaceOwned(owner: "skills", with: [
            registration(id: "a", file: file("a.md"), root: root, owner: "skills"),
            registration(id: "smuggled", file: file("b.md"), root: root, owner: "persona"),
        ])
        let afterSmuggle = await registry.allRegistrations().map(\.descriptor.id.rawValue).sorted()
        #expect(afterSmuggle == ["a", "other"])
    }

    /// `addAllowedRoot` is the MUTATING half of the containment boundary; the
    /// `init(allowedRoots:)` half is what the symlink-escape test above uses.
    /// It canonicalizes before inserting, and `normalizedRegistration` later
    /// compares a canonicalized declared root against that set by equality — so
    /// if the two canonicalizations ever disagree, every source under a
    /// perfectly legitimate root silently fails to register with
    /// `rootNotAllowed` and context just gets quieter.
    ///
    /// Asserted as an envelope on the boundary, not on any path spelling:
    /// equivalent spellings of one directory admit the same sources, and
    /// admitting a root never admits anything outside it.
    @Test
    func addAllowedRootAdmitsEquivalentSpellingsAndStillFencesOutsidePaths() async throws {
        let parent = try makeDirectory("roots")
        defer { try? FileManager.default.removeItem(at: parent) }
        let real = parent.appendingPathComponent("real", isDirectory: true)
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let inside = real.appendingPathComponent("SOUL.md")
        try "identity".write(to: inside, atomically: true, encoding: .utf8)
        let outsideFile = outside.appendingPathComponent("private.md")
        try "private".write(to: outsideFile, atomically: true, encoding: .utf8)
        let link = parent.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let registry = try ContextSourceRegistry(allowedRoots: [])

        // Before the add, the root is not allowed at all.
        do {
            try await registry.register(registration(id: "early", file: inside, root: real))
            Issue.record("source registered before its root was allowed")
        } catch let error as ContextSourceRegistryError {
            guard case .rootNotAllowed = error else {
                Issue.record("unexpected registry error before addAllowedRoot: \(error)")
                return
            }
        }

        // Add the root by its SYMLINKED spelling; register declaring the real
        // one. Equivalent spellings have to resolve to one root or the boundary
        // silently stops admitting legitimate sources.
        try await registry.addAllowedRoot(link)
        try await registry.register(registration(id: "soul", file: inside, root: real))
        #expect(await registry.allRegistrations().map(\.descriptor.id.rawValue) == ["soul"])

        // Trailing-slash spelling is the same root, not a second one.
        try await registry.addAllowedRoot(URL(fileURLWithPath: real.path + "/", isDirectory: true))
        #expect(await registry.allowedRootList().count == 1)

        // Admitting a root admits only what is under it.
        do {
            try await registry.register(registration(id: "outside", file: outsideFile, root: outside))
            Issue.record("a path outside every allowed root registered")
        } catch let error as ContextSourceRegistryError {
            guard case .rootNotAllowed = error else {
                Issue.record("unexpected registry error for outside path: \(error)")
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

    private func registration(
        id: String,
        file: URL,
        root: URL,
        owner: String = "persona"
    ) -> ContextSourceRegistration {
        ContextSourceRegistration(
            descriptor: ContextSourceDescriptor(
                id: ContextSourceID(rawValue: id),
                owner: owner,
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
