import Context
import Foundation
import Testing

// Ledger row: cli.ContextSelectionABHarness
//
// The harness is an operator-facing executable, so this contract invokes the
// separately-built binary rather than calling its helpers. Every input and
// output root below is temporary; the store snapshot proves its sqlite source
// was only read through the production `.backup` path.

private struct ABHarnessRun {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

private func contextABHarnessProduct() throws -> URL {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // ContextTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // NativeAgentCore
    let buildRoot = packageRoot.appendingPathComponent(".build", isDirectory: true)
    var candidates: [URL] = ["debug", "release"].map {
        buildRoot.appendingPathComponent($0, isDirectory: true)
            .appendingPathComponent("ContextSelectionABHarness")
    }
    if let entries = try? FileManager.default.contentsOfDirectory(
        at: buildRoot,
        includingPropertiesForKeys: nil
    ) {
        for entry in entries where entry.lastPathComponent.contains("apple-macosx") {
            candidates.append(entry.appendingPathComponent("debug/ContextSelectionABHarness"))
            candidates.append(entry.appendingPathComponent("release/ContextSelectionABHarness"))
        }
    }
    if let product = candidates.first(where: {
        FileManager.default.isExecutableFile(atPath: $0.path)
    }) {
        return product
    }
    throw NSError(domain: "ContextSelectionABHarnessCLIEval", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "ContextSelectionABHarness is not built under \(buildRoot.path)",
    ])
}

private func runContextABHarness(
    _ executable: URL,
    arguments: [String],
    cwd: URL,
    timeout: TimeInterval = 30
) throws -> ABHarnessRun {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = cwd
    var environment = ProcessInfo.processInfo.environment
    // The harness has no root-default behavior: its --store is the sole
    // database authority. Remove an operator's ambient root to prove that.
    environment.removeValue(forKey: "NATIVE_AGENT_DATA_ROOT")
    process.environment = environment

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    try process.run()

    let lock = NSLock()
    var stdout = Data()
    var stderr = Data()
    let readers = DispatchGroup()
    for (pipe, isStdout) in [(stdoutPipe, true), (stderrPipe, false)] {
        readers.enter()
        let reader = Thread {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock()
            if isStdout { stdout = data } else { stderr = data }
            lock.unlock()
            readers.leave()
        }
        reader.stackSize = 512 * 1024
        reader.start()
    }

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning {
        process.terminate()
        Thread.sleep(forTimeInterval: 0.5)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    process.waitUntilExit()
    _ = readers.wait(timeout: .now() + 10)

    lock.lock()
    defer { lock.unlock() }
    return ABHarnessRun(
        exitCode: process.terminationStatus,
        stdout: String(decoding: stdout, as: UTF8.self),
        stderr: String(decoding: stderr, as: UTF8.self)
    )
}

private func ABHarnessFixtureRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ContextSelectionABHarnessCLIEval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func regularFileSnapshot(under root: URL) throws -> [String: Data] {
    let keys: Set<URLResourceKey> = [.isRegularFileKey]
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: Array(keys),
        options: []
    ) else { return [:] }
    var result: [String: Data] = [:]
    for case let file as URL in enumerator {
        guard try file.resourceValues(forKeys: keys).isRegularFile == true else { continue }
        let name = file.path.replacingOccurrences(of: root.path + "/", with: "")
        result[name] = try Data(contentsOf: file)
    }
    return result
}

private func makeABFixtureSource() -> ContextCompiledSource {
    let sourceID = ContextStableID.source(owner: "selection-ab-eval", locator: "fixture")
    let descriptor = ContextSourceDescriptor(
        id: sourceID,
        owner: "selection-ab-eval",
        kind: .other,
        canonicalLocator: "fixture",
        authority: .external,
        privacy: .localPrivate,
        permittedSurfaces: [.chat],
        injectionPolicy: .adaptive
    )
    let bodies = [
        "orchid calibration archive explains the current repair procedure",
        "unrelated weather notes describe a distant mountain trail",
    ]
    let atoms = bodies.enumerated().map { index, body in
        ContextAtomDraft(
            id: ContextStableID.atom(
                sourceID: sourceID,
                kind: .project,
                headingPath: ["fixture", String(index)],
                blockAnchor: String(index)
            ),
            sourceID: sourceID,
            kind: .project,
            headingPath: ["fixture", String(index)],
            sourceRange: ContextSourceRange(utf8Start: 0, utf8End: body.utf8.count),
            sourceHash: ContextStableID.digest(parts: [body]),
            body: body,
            deterministicSummary: body,
            authority: descriptor.authority,
            confidence: 1,
            freshness: ContextFreshness(updatedAt: Date(timeIntervalSince1970: 1)),
            privacy: descriptor.privacy,
            permittedSurfaces: descriptor.permittedSurfaces,
            injectionPolicy: descriptor.injectionPolicy,
            contentRole: .untrustedExternalData,
            entities: [],
            triggers: ["orchid", "calibration"],
            embedding: ContextEmbedding(modelFingerprint: "selection-ab-eval", values: [0.1, 0.2])
        )
    }
    return ContextCompiledSource(
        descriptor: descriptor,
        sourceHash: ContextStableID.digest(parts: bodies),
        atoms: atoms
    )
}

@Test("ContextSelectionABHarness subprocess validates flags, roots, and live score evidence")
func contextSelectionABHarnessSubprocessEval() async throws {
    let executable = try contextABHarnessProduct()
    let root = try ABHarnessFixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let storeRoot = root.appendingPathComponent("store", isDirectory: true)
    let store = try ContextSQLiteStore(dataRoot: storeRoot)
    _ = try await store.publish(ContextGenerationDraft(
        reason: "selection A/B subprocess fixture",
        changedSources: [makeABFixtureSource()],
        createdAt: Date(timeIntervalSince1970: 1)
    ))
    let storeURL = await store.databaseURL
    let queries = root.appendingPathComponent("queries.json")
    try Data("{\"queries\":[\"orchid calibration archive\"]}".utf8).write(to: queries)
    let output = root.appendingPathComponent("report.json")
    let before = try regularFileSnapshot(under: storeRoot)

    let valid = try runContextABHarness(
        executable,
        arguments: ["--store", storeURL.path, "--queries", queries.path, "--out", output.path],
        cwd: root
    )
    #expect(valid.exitCode == 0, "valid harness run failed: \(valid.stderr)")
    #expect(valid.stdout.contains("mandatory invariant: OK"))
    let reportData = try Data(contentsOf: output)
    let report = try #require(JSONSerialization.jsonObject(with: reportData) as? [String: Any])
    #expect(report["evaluatedQueryCount"] as? Int == 1)
    #expect(report["skippedQueryCount"] as? Int == 0)
    #expect(report["mandatorySetIdenticalAcrossVariants"] as? Bool == true)
    #expect((report["mandatoryDivergences"] as? [Any])?.isEmpty == true)
    let evidence = try #require(report["comparisonEvidence"] as? [String: Any])
    #expect(evidence["isNonVacuous"] as? Bool == true)
    #expect((evidence["queriesWithMessageCoverage"] as? Int ?? 0) > 0)
    #expect((evidence["scoreChangedQueryCount"] as? Int ?? 0) > 0)
    let variants = try #require(report["variants"] as? [[String: Any]])
    #expect(variants.count == 3)
    let baselineQueries = try #require(variants[0]["queries"] as? [[String: Any]])
    let shippedQueries = try #require(variants[1]["queries"] as? [[String: Any]])
    let baselineScores = try #require(baselineQueries.first?["dynamicScores"] as? [[String: Any]])
    let shippedScores = try #require(shippedQueries.first?["dynamicScores"] as? [[String: Any]])
    let baselineScore = try #require(baselineScores.first?["total"] as? Double)
    let shippedScore = try #require(shippedScores.first?["total"] as? Double)
    #expect(baselineScore != shippedScore,
            "the emitted score payload must show the live message-coverage weight effect")
    #expect(try regularFileSnapshot(under: storeRoot) == before,
            "the harness must read the store through its temporary sqlite backup, never mutate --store")

    let help = try runContextABHarness(executable, arguments: ["--help"], cwd: root)
    #expect(help.exitCode == 0)
    #expect(help.stdout.contains("--store <context.sqlite>"))

    let missingFlags = try runContextABHarness(executable, arguments: ["--store", storeURL.path], cwd: root)
    #expect(missingFlags.exitCode != 0)
    #expect(missingFlags.stderr.contains("usage:"))

    let malformed = root.appendingPathComponent("malformed.json")
    try Data("not JSON".utf8).write(to: malformed)
    let malformedOutput = root.appendingPathComponent("malformed-report.json")
    let malformedRun = try runContextABHarness(
        executable,
        arguments: ["--store", storeURL.path, "--queries", malformed.path, "--out", malformedOutput.path],
        cwd: root
    )
    #expect(malformedRun.exitCode != 0)
    #expect(malformedRun.stderr.contains("expected {\"queries\""))
    #expect(!FileManager.default.fileExists(atPath: malformedOutput.path))

    let missingOutput = root.appendingPathComponent("missing-report.json")
    let missingInput = try runContextABHarness(
        executable,
        arguments: ["--store", storeURL.path, "--queries", root.appendingPathComponent("missing.json").path, "--out", missingOutput.path],
        cwd: root
    )
    #expect(missingInput.exitCode != 0)
    #expect(!FileManager.default.fileExists(atPath: missingOutput.path))

    let shortQueries = root.appendingPathComponent("short.json")
    try Data("{\"queries\":[\"  \",\"ok\"]}".utf8).write(to: shortQueries)
    let shortOutput = root.appendingPathComponent("short-report.json")
    let shortRun = try runContextABHarness(
        executable,
        arguments: ["--store", storeURL.path, "--queries", shortQueries.path, "--out", shortOutput.path],
        cwd: root
    )
    #expect(shortRun.exitCode != 0)
    #expect(shortRun.stderr.contains("no query with at least"))
    #expect(!FileManager.default.fileExists(atPath: shortOutput.path))

    let inertQueries = root.appendingPathComponent("inert.json")
    try Data("{\"queries\":[\"completely disconnected vocabulary\"]}".utf8).write(to: inertQueries)
    let inertOutput = root.appendingPathComponent("inert-report.json")
    let inertRun = try runContextABHarness(
        executable,
        arguments: ["--store", storeURL.path, "--queries", inertQueries.path, "--out", inertOutput.path],
        cwd: root
    )
    #expect(inertRun.exitCode != 0)
    #expect(inertRun.stderr.contains("comparison produced no usable score evidence"))
    #expect(!FileManager.default.fileExists(atPath: inertOutput.path))
}
