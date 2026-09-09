import Foundation
import Testing
import Network
import Darwin
@testable import StandingBots

@Test func botAskDeadlineIncludesAdmissionAndReleasesClaim() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bot-ask-budget-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let bot = try BotDefinitionStore(dataRoot: root).create(BotDefinition(name: "News", brief: "Check news",
        cadence: .interval(seconds: 900), sources: ["https://example.org"], budget: BotBudget(tokens: 8000, seconds: 0.03)))
    let runner = BotRunner(dataRoot: root, session: { _, _, _ in
        Issue.record("Expired ask dispatched provider work")
        return "unexpected"
    }, fetch: { _, _ in "" }, admission: {
        try await Task.sleep(for: .seconds(1))
        return true
    })
    await #expect(throws: (any Error).self) { try await runner.ask(bot: bot.id, question: "What changed?") }
    let queue = BotRunQueue(dataRoot: root)
    _ = try queue.claim(bot: bot.id, requestID: nil)
    queue.finish(bot: bot.id)
    #expect(try ShelfStore(dataRoot: root).shelfRead().rows.isEmpty)
}

@Test func botRedirectRechecksDeniedAndUnreadableAuthority() async throws {
    for unreadable in [false, true] {
        let authority = BotAuthority()
        do {
            _ = try await BotRunnerHTTP.fetchPinned("https://public.example/start", admission: {
                if !(await authority.permits()), unreadable { throw StandingBotsError.corruptStore("policy") }
                return await authority.permits()
            }, resolve: { _ in ["8.8.8.8"] }, exchange: { _, _ in
                _ = await authority.fetch(revoke: true)
                return .init(status: 302, headers: ["location": "/next"], body: Data())
            })
            Issue.record("Redirect escaped revoked authority")
        } catch {
            #expect(String(describing: error) == "could not check: not permitted")
        }
        #expect(await authority.fetches == 1)
    }
}

@Test func botClaimExcludesAnotherProcessAndRecoversOnExit() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bot-process-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let bot = try BotDefinitionStore(dataRoot: root).create(BotDefinition(name: "News", brief: "Check news",
        cadence: .interval(seconds: 900), sources: ["https://example.org"], budget: BotBudget(tokens: 8000, seconds: 10)))
    let queue = BotRunQueue(dataRoot: root)
    _ = try queue.claim(bot: bot.id, requestID: nil)
    let path = root.appendingPathComponent("bots/\(bot.id.uuidString)/run.lock")
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    probe.arguments = ["-e", "open(my $f, '+<', $ARGV[0]) or die $!; exit(flock($f, 6) ? 1 : 0);", path.path]
    try probe.run(); probe.waitUntilExit()
    #expect(probe.terminationStatus == 0)
    queue.finish(bot: bot.id)

    let holder = Process()
    let output = Pipe()
    let input = Pipe()
    holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    holder.arguments = ["-e", "open(my $f, '+<', $ARGV[0]) or die $!; flock($f, 2) or die $!; $|=1; print 'R'; <STDIN>;", path.path]
    holder.standardOutput = output; holder.standardInput = input
    try holder.run()
    defer { if holder.isRunning { holder.terminate(); holder.waitUntilExit() } }
    #expect(output.fileHandleForReading.readData(ofLength: 1) == Data("R".utf8))
    #expect(throws: BotRunAdmissionError.alreadyRunning) { try queue.claim(bot: bot.id, requestID: nil) }
    #expect(try queue.enqueue(bot: bot.id).reason == "already_running")
    holder.terminate(); holder.waitUntilExit()
    let request = try queue.enqueue(bot: bot.id)
    #expect(request.accepted)
    _ = try queue.claim(bot: bot.id, requestID: request.runID)
    queue.finish(bot: bot.id)
}

@Test func botBudgetIncludesBlockedShelfPublication() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bot-store-budget-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let bot = try BotDefinitionStore(dataRoot: root).create(BotDefinition(name: "News", brief: "Check news",
        cadence: .interval(seconds: 900), sources: ["https://example.org"], budget: BotBudget(tokens: 8000, seconds: 0.3)))
    let runner = BotRunner(dataRoot: root, session: { _, _, _ in
        await withCheckedContinuation { ready in
            DispatchQueue.global().async {
                try! StandingBotsDisk(dataRoot: root).locked {
                    let release = DispatchSemaphore(value: 0)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { release.signal() }
                    ready.resume()
                    release.wait()
                }
            }
        }
        return """
        {"headline":"Checked","findings":"Evidence","changedSinceLastGood":"None","sourceURLs":["https://example.org"],"uncertainties":[],"runHealth":"ok"}
        """
    }, fetch: { _, _ in "Evidence" }, admission: { true })
    let entry = try #require(await runner.run(bot: bot.id))
    #expect(entry.runHealth == .partial || entry.runHealth == .failed)
    #expect(entry.spend.seconds >= 0.5)
    #expect(entry.uncertainties.contains("budgetStop"))
    let shelf = ShelfStore(dataRoot: root)
    #expect(try shelf.entry(entry.id) == entry)
    #expect(try shelf.lastGood(bot: bot.id) == nil)
    #expect(try shelf.shelfRead().rows.count == 1)
    #expect(try BotContinuityStore(dataRoot: root).context(bot: bot.id).lastRunID == nil)
}

@Test func botHTTPRejectsNonPublicSourcesAndRedirectsWithBookReason() async throws {
    let privateAddresses = ["127.0.0.1", "0.0.0.0", "10.1.2.3", "172.16.0.1", "192.168.1.1",
        "169.254.169.254", "100.100.100.200", "168.63.129.16", "224.0.0.1", "255.255.255.255",
        "::", "::1", "fc00::1", "fe80::1", "ff02::1", "::ffff:127.0.0.1", "2002:7f00:1::1"]
    for address in privateAddresses {
        #expect(!BotRunnerHTTP.isPublicAddress(address))
        #expect(throws: BotRunnerError.self) {
            try BotRunnerHTTP.admit(URL(string: "https://public.example")!, resolve: { _ in ["8.8.8.8", address] })
        }
    }
    for address in ["8.8.8.8", "1.1.1.1", "2606:4700:4700::1111"] {
        #expect(BotRunnerHTTP.isPublicAddress(address))
    }
    for source in ["file:///etc/hosts", "https://user:password@example.org", "http://127.0.0.1", "http://[::1]"] {
        #expect(throws: BotRunnerError.self) { try BotRunnerHTTP.admit(URL(string: source)!) }
    }
    await #expect(throws: BotRunnerError.self) {
        try await BotRunnerHTTP.fetchPinned("https://example.org", admission: { true }, resolve: { host in
            host == "example.org" ? ["8.8.8.8"] : ["127.0.0.1"]
        }, exchange: { url, address in
            #expect(url.host == "example.org" && address == "8.8.8.8")
            return .init(status: 302, headers: ["location": "http://127.0.0.1/private"], body: Data())
        })
    }

    let resolver = RebindingResolver()
    await #expect(throws: BotRunnerError.self) {
        try await BotRunnerHTTP.fetchPinned("https://rebind.example", admission: { true }, resolve: { _ in resolver.next() }, exchange: { _, address in
            // The transport receives the admitted literal, never a second DNS lookup.
            #expect(address == "8.8.8.8")
            return .init(status: 302, headers: ["location": "/next"], body: Data())
        })
    }
    #expect(resolver.calls == 2)
    #expect(throws: BotRunnerError.self) {
        try BotRunnerHTTP.verifyPeer(.hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: .http),
                                     address: "8.8.8.8", port: .http)
    }

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bot-ssrf-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let bot = try BotDefinitionStore(dataRoot: root).create(BotDefinition(name: "News", brief: "Check news",
        cadence: .interval(seconds: 900), sources: ["http://127.0.0.1"], budget: BotBudget(tokens: 8000, seconds: 10)))
    let fake = FakeBotSession()
    let runner = BotRunner(dataRoot: root, session: { try await fake.complete($0, $1, $2) }, admission: { true })
    let entry = try await runner.run(bot: bot.id)
    #expect(entry?.runHealth == .failed)
    #expect(entry?.uncertainties.contains(where: { $0.contains("unsafe destination") }) == true)
    #expect(await fake.calls == 0)
}

private final class RebindingResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func next() -> [String] {
        lock.withLock { count += 1; return count == 1 ? ["8.8.8.8"] : ["127.0.0.1"] }
    }
}

@Test func botHTTPPublicFetchUsesPinnedSocketAndOriginalHost() async throws {
    for response in ["HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello",
                     "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nhe\r\n3\r\nllo\r\n0\r\n\r\n"] {
        let server = try BotHTTPTestServer(response: response)
        defer { server.stop() }
        let text = try await BotRunnerHTTP.fetchPinned("http://public.example:\(server.port)/news?q=one", admission: { true }, resolve: { host in
            #expect(host == "public.example")
            return ["127.0.0.1"]
        }, allowsAddress: { $0 == "127.0.0.1" })
        #expect(text == "hello")
        #expect(server.request.contains("GET /news?q=one HTTP/1.1\r\n"))
        #expect(server.request.contains("Host: public.example:\(server.port)\r\n"))
    }
}

/// One real HTTP exchange, bound only to loopback. No production policy changes.
private final class BotHTTPTestServer: @unchecked Sendable {
    let socket: Int32
    let port: UInt16
    private let lock = NSLock()
    private var received = ""
    var request: String { lock.withLock { received } }

    init(response: String) throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        self.socket = socket
        guard socket >= 0 else { throw BotRunnerError.unavailableSource }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(socket, 1) == 0 else {
            Darwin.close(socket); throw BotRunnerError.unavailableSource
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        guard named == 0 else { Darwin.close(socket); throw BotRunnerError.unavailableSource }
        port = UInt16(bigEndian: address.sin_port)
        DispatchQueue.global().async { [self] in
            let client = Darwin.accept(socket, nil, nil)
            guard client >= 0 else { return }
            defer { Darwin.close(client) }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var requestBytes = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while requestBytes.range(of: Data("\r\n\r\n".utf8)) == nil && requestBytes.count < 16384 {
                let count = Darwin.recv(client, &buffer, buffer.count, 0)
                guard count > 0 else { return }
                requestBytes.append(contentsOf: buffer.prefix(count))
            }
            lock.withLock { received = String(decoding: requestBytes, as: UTF8.self) }
            let bytes = Array(response.utf8)
            bytes.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let count = Darwin.send(client, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                    guard count > 0 else { return }
                    sent += count
                }
            }
        }
    }
    func stop() { Darwin.shutdown(socket, SHUT_RDWR); Darwin.close(socket) }
}

private actor BotAuthority {
    var allowed = true
    var fetches = 0
    func permits() -> Bool { allowed }
    func revoke() { allowed = false }
    func fetch(revoke: Bool = false) -> String {
        fetches += 1
        if revoke { allowed = false }
        return "News unchanged"
    }
}

@Test func botEffectAdmissionCoversScheduledQueuedAndProviderBoundaries() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bot-authority-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BotDefinitionStore(dataRoot: root)
    let shelf = ShelfStore(dataRoot: root)
    let fake = FakeBotSession()
    let authority = BotAuthority()
    let bot = try store.create(BotDefinition(name: "News", brief: "Check news", cadence: .interval(seconds: 900),
        sources: ["https://example.org"], budget: BotBudget(tokens: 8000, seconds: 10),
        createdAt: Date().addingTimeInterval(-3600)))
    let scheduler = BotRunnerScheduler(dataRoot: root, session: { try await fake.complete($0, $1, $2) },
        fetch: { _, _ in await authority.fetch() }, admission: { await authority.permits() })
    await authority.revoke() // Revoked after creation, before the due occurrence.
    #expect(await scheduler.runDue().count == 1)
    let receipt = try BotRunQueue(dataRoot: root).enqueue(bot: bot.id)
    #expect(receipt.accepted)
    #expect(await scheduler.runDue().count == 1)
    let queued = try shelf.entry(receipt.runID)
    #expect(queued.uncertainties.contains("could not check: not permitted"))
    #expect(queued.spend.tokens == 0)
    #expect(try BotRunQueue(dataRoot: root).pending().isEmpty)
    #expect(await authority.fetches == 0)

    let changed = BotAuthority()
    let runner = BotRunner(dataRoot: root, session: { try await fake.complete($0, $1, $2) },
        fetch: { _, _ in await changed.fetch(revoke: true) }, admission: { await changed.permits() })
    #expect(try await runner.run(bot: bot.id)?.uncertainties.contains("could not check: not permitted") == true)
    #expect(await changed.fetches == 1)
    let unavailable = BotRunner(dataRoot: root, session: { try await fake.complete($0, $1, $2) },
        fetch: { _, _ in await authority.fetch() }, admission: { throw StandingBotsError.corruptStore("policy") })
    #expect(try await unavailable.run(bot: bot.id)?.uncertainties.contains("could not check: not permitted") == true)
    #expect(await authority.fetches == 0)
    #expect(await fake.calls == 0)
    let permitted = BotRunnerScheduler(dataRoot: root, session: { try await fake.complete($0, $1, $2) },
        fetch: { _, _ in "News unchanged" }, admission: { true })
    let accepted = try BotRunQueue(dataRoot: root).enqueue(bot: bot.id)
    #expect(accepted.accepted)
    #expect(await permitted.runDue().count == 1)
    #expect(try shelf.entry(accepted.runID).runHealth == .nothingNew)
    #expect(await fake.calls == 1)
}

@Test func botCadenceCompletionAndDurableFleetSpendAreBounded() async throws {
    let suite = "bot-floor-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(BotRunLimits.minimumInterval(in: defaults) == 900)
    defaults.set(1, forKey: BotRunLimits.minimumIntervalMinutesKey)
    #expect(BotRunLimits.minimumInterval(in: defaults) == 60)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bot-cadence-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BotDefinitionStore(dataRoot: root)
    var definition = BotDefinition(name: "News", brief: "Check news", cadence: .interval(seconds: 0.001),
        sources: ["https://example.org"], budget: BotBudget(tokens: 8000, seconds: 10),
        createdAt: Date().addingTimeInterval(-3600))
    #expect(throws: StandingBotsError.self) { try store.create(definition) }
    definition.cadence = .interval(seconds: 60)
    let anchor = Date(timeIntervalSince1970: 0)
    #expect(try StandingBotsDisk.nextOccurrence(definition, after: anchor,
        minimumInterval: BotRunLimits.minimumInterval(in: defaults)) == anchor.addingTimeInterval(60))
    #expect(try StandingBotsDisk.nextOccurrence(definition, after: anchor, minimumInterval: 900)
        == anchor.addingTimeInterval(900))
    defaults.set(0, forKey: BotRunLimits.minimumIntervalMinutesKey)
    #expect(BotRunLimits.minimumInterval(in: defaults) == 900)
    definition.cadence = .interval(seconds: BotRunLimits.minimumInterval)
    definition.budget.tokens = BotRunLimits.maximumTokens + 1
    #expect(throws: StandingBotsError.self) { try store.create(definition) }
    definition.budget = BotBudget(tokens: BotRunLimits.maximumTokens, seconds: BotRunLimits.maximumSeconds + 1)
    #expect(throws: StandingBotsError.self) { try store.create(definition) }
    definition.budget.seconds = 10
    let bot = try store.create(definition)
    let fake = FakeBotSession()
    let authority = BotAuthority()
    let scheduler = BotRunnerScheduler(dataRoot: root, session: { try await fake.complete($0, $1, $2) },
        fetch: { _, _ in await authority.fetch() }, admission: { true })
    #expect(await scheduler.runDue().count == 1)
    let book = try #require(try ShelfStore(dataRoot: root).lastGood(bot: bot.id))
    let deadline = try #require(await scheduler.nextDeadline(after: Date()))
    #expect(deadline >= book.coverageEnd.addingTimeInterval(BotRunLimits.minimumInterval))
    #expect(await scheduler.runDue().isEmpty)
    // New runner and queue instances share the persisted fleet allowance.
    for _ in 1..<(BotRunLimits.dailyTokens / BotRunLimits.maximumTokens) {
        let other = try store.create(BotDefinition(name: "News", brief: "Check news", cadence: .interval(seconds: 900),
            sources: ["https://example.org"], budget: definition.budget))
        let runner = BotRunner(dataRoot: root, session: { try await fake.complete($0, $1, $2) },
            fetch: { _, _ in await authority.fetch() }, admission: { true })
        #expect(try await runner.run(bot: other.id)?.runHealth == .nothingNew)
    }
    let receipt = try BotRunQueue(dataRoot: root).enqueue(bot: bot.id)
    #expect(await scheduler.runDue().count == 1)
    let skipped = try ShelfStore(dataRoot: root).entry(receipt.runID)
    #expect(skipped.runHealth == .failed && skipped.spend.tokens == 0)
    #expect(skipped.uncertainties.contains("could not check: daily fleet token ceiling reached"))
    #expect(await fake.calls == BotRunLimits.dailyTokens / BotRunLimits.maximumTokens)
    #expect(await authority.fetches == BotRunLimits.dailyTokens / BotRunLimits.maximumTokens)
    let spendPath = root.appendingPathComponent("bots/daily-spend.json")
    let corrupt = Data("{broken".utf8)
    try corrupt.write(to: spendPath)
    #expect(throws: (any Error).self) { try BotRunQueue(dataRoot: root).reserveDailySpend(tokens: 1) }
    #expect(try Data(contentsOf: spendPath) == corrupt)
}

private actor FakeBotSession {
    var calls = 0
    var outputLimits: [Int] = []
    let blocked: Bool
    init(blocked: Bool = false) { self.blocked = blocked }
    func complete(_ system: String, _ prompt: String, _ limit: Int) async throws -> String {
        calls += 1
        outputLimits.append(limit)
        #expect(system.contains("UNTRUSTED EVIDENCE"))
        #expect(prompt.contains("Check news"))
        if blocked { try await Task.sleep(for: .seconds(60)) }
        return """
        {"headline":"Checked, nothing new","findings":"No change","changedSinceLastGood":"None","sourceURLs":["https://example.org"],"uncertainties":[],"runHealth":"nothingNew"}
        """
    }
}

@Test func botRunnerAppendsOneBookAndStopsAtBudget() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bot-runner-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BotDefinitionStore(dataRoot: root)
    let shelf = ShelfStore(dataRoot: root)
    let bot = try store.create(BotDefinition(name: "News", brief: "Check news", cadence: .interval(seconds: 900),
                                            sources: ["https://example.org"], budget: BotBudget(tokens: 8000, seconds: 10)))
    let fake = FakeBotSession()
    let runner = BotRunner(dataRoot: root, session: { try await fake.complete($0, $1, $2) }, fetch: { _, _ in "News unchanged" }, admission: { true })
    let book = try await runner.run(bot: bot.id)
    #expect(book?.runHealth == .nothingNew)
    #expect(try shelf.shelfRead(bot: bot.id).rows.count == 1)
    #expect(try shelf.lastGood(bot: bot.id)?.id == book?.id)
    #expect(await fake.calls == 1)
    #expect(await fake.outputLimits.allSatisfy { $0 > 0 && $0 < 8000 })

    var short = bot
    short.budget.seconds = 0.03
    short = try store.update(short)
    let slow = FakeBotSession(blocked: true)
    let bounded = BotRunner(dataRoot: root, session: { try await slow.complete($0, $1, $2) }, fetch: { _, _ in "News unchanged" }, admission: { true })
    let began = ContinuousClock.now
    let failed = try await bounded.run(bot: short.id)
    #expect(began.duration(to: .now) < .seconds(2))
    #expect(failed?.runHealth == .failed)
    #expect(failed?.uncertainties.contains(where: { $0.contains("budgetStop") }) == true)
    #expect(try shelf.shelfRead(bot: bot.id).rows.count == 2)
    #expect(try shelf.lastGood(bot: bot.id)?.id == book?.id)

    short.budget = BotBudget(tokens: 100, seconds: 10)
    short = try store.update(short)
    await #expect(throws: BotRunAdmissionError.overBudget) { try await runner.run(bot: short.id) }
    #expect(await fake.calls == 1)
    #expect(try shelf.shelfRead(bot: bot.id).rows.count == 2)
    _ = try store.pause(bot.id)
    #expect(try await runner.run(bot: bot.id) == nil)
    #expect(try shelf.shelfRead(bot: bot.id).rows.count == 2)
}
