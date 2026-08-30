import Foundation
import Testing
@testable import NativeAgentApp

// evals-total-coverage — fence `app.bridges`.
//
// The bridge lane's loud failures are already covered (BridgeCoreTests,
// BridgeStartGateTests, MacControlBridgeExecSlotTests, …). What was NOT covered
// is the class of change that breaks a bridge SILENTLY: a renamed SSE event
// kind that no consumer's filter matches any more, a launch hook that stops
// calling one of the four bridge starts, a descriptor written on a path that
// nothing unlinks, a privilege allowlist quietly gaining a seventh entry, an
// env kill-switch whose truthy set drifts.
//
// Those seams are `private`/`fileprivate` inside `ClaudeBridge` /
// `MacControlBridge` / `InboxPushNotifier`, so `@testable import` cannot reach
// them (only `internal` is re-exported). The honest instrument available at the
// `test` tier is the source-scraping guard the ledger itself proposes for
// `bridge.claude.events.kinds` — the pattern already in
// FluidContextSurfaceWiringTests / OperationalSettingsPresentationTests.
//
// Every assertion below is a FROZEN INVENTORY or an ORDERING, not a
// "does this string appear somewhere" smoke test: adding, renaming, dropping or
// reordering the real thing fails the test. Where a set is frozen, the
// expectation is asserted in BOTH directions so a drop fails as loudly as an
// addition. Where a value is a path, it is checked against the live filesystem
// so a typo cannot pass.
//
// Rows whose honest eval needs a production seam (an adversarial-argv
// `validateExecArgv` call, a `WorkLatch` single-answer race, an injectable
// `dataRoot` for MacSyncEngine.start) are reported, not faked.
@Suite("app.bridges source contracts")
struct BridgeSourceContractTests {

    // MARK: - Scraping helpers

    /// Balanced `{...}` body that follows `marker` (marker included in the
    /// search only, not the result). Unlike `AppSourceScraping.functionBody`
    /// this matches an EXACT signature, so `func start()` cannot be shadowed by
    /// `func startGateAllows(...)`.
    private func body(after marker: String, in source: String) throws -> String {
        guard let range = source.range(of: marker) else {
            throw AppSourceScraping.ScrapeError("marker not found: \(marker)")
        }
        guard let open = source[range.upperBound...].firstIndex(of: "{"),
              let close = AppSourceScraping.balancedEnd(in: source, startingAt: open, opening: "{", closing: "}")
        else {
            throw AppSourceScraping.ScrapeError("unbalanced body after: \(marker)")
        }
        return String(source[open...close])
    }

    /// Capture group 1 of every match of `pattern` in `source`, in order.
    private func captures(_ pattern: String, in source: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[r])
        }
    }

    /// Parse a `[ "a", "b" ]` Swift array-of-string-literals starting at `marker`.
    private func stringArrayLiteral(at marker: String, in source: String) throws -> [String] {
        guard let hit = source.range(of: marker) else {
            throw AppSourceScraping.ScrapeError("array literal marker not found: \(marker)")
        }
        let tail = source[hit.lowerBound...]
        guard let open = tail.firstIndex(of: "["),
              let close = AppSourceScraping.balancedEnd(in: source, startingAt: open, opening: "[", closing: "]")
        else {
            throw AppSourceScraping.ScrapeError("unbalanced array literal at: \(marker)")
        }
        let inner = String(source[source.index(after: open)..<close])
        return inner
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("\"") && $0.hasSuffix("\"") && $0.count >= 2 }
            .map { String($0.dropFirst().dropLast()) }
    }

    private func index(of needle: String, in source: String) throws -> Int {
        guard let range = source.range(of: needle) else {
            throw AppSourceScraping.ScrapeError("expected call site missing: \(needle)")
        }
        return source.distance(from: source.startIndex, to: range.lowerBound)
    }

    // MARK: - bridge.claude.events.kinds

    /// Row `bridge.claude.events.kinds`. Every SSE consumer (the agent
    /// instrument, the wake helper, `script/lib/nativeagent_bridge.sh`) filters
    /// on the `kind` string. Rename one emit site and the lane reads IDLE — a
    /// dropped row that looks exactly like "nothing happened".
    ///
    /// Frozen in both directions: an added kind fails (inventory must be
    /// updated deliberately), a removed kind fails (a lane went dark).
    @Test("the SSE event-kind inventory is frozen in both directions")
    func eventKindInventoryIsFrozen() throws {
        let source = try AppSourceScraping.appSource("ClaudeBridge.swift")
        // Only LITERAL kinds are enumerable; the declaration itself
        // (`kind: String`) never matches this pattern.
        let emitted = try captures(#"publishEvent\(kind: "([^"]+)""#, in: source)

        let expected: Set<String> = [
            "message_in",
            "message_out",
            "message_failed",
            "message_timeout",
            "message_enqueue_failed",
            "message_enqueued",
            "message_enqueue_timeout",
            "tool",
            "tool_failed",
            "tool_timeout",
            "organism_debug",
            "organism_reflex_review",
        ]

        #expect(Set(emitted) == expected, "SSE kinds drifted: \(Set(emitted).symmetricDifference(expected).sorted())")
        // 14 canonical emitters for 12 kinds (message_out ×2 and
        // message_failed ×2). Organism route branches converge on one typed
        // emitter per kind so their exact payload routing is executable
        // without a live listener.
        #expect(emitted.count == 14, "publishEvent emit-site count changed: \(emitted.count)")
        #expect(emitted.filter { $0 == "organism_debug" }.count == 1)
        #expect(emitted.filter { $0 == "organism_reflex_review" }.count == 1)
        #expect(emitted.filter { $0 == "message_out" }.count == 2)
        #expect(emitted.filter { $0 == "message_failed" }.count == 2)
        // Every kind must be a literal — a computed `kind:` argument would make
        // the inventory unenumerable and this guard vacuous.
        // +1 for the declaration `fileprivate func publishEvent(kind: String,`.
        // Any other non-literal call site would make the inventory
        // unenumerable and this guard vacuous.
        #expect(AppSourceScraping.occurrences(of: "publishEvent(kind: ", in: source) == emitted.count + 1,
                "a publishEvent call site no longer passes a string literal")
    }

    // MARK: - bridge.startOrder

    /// Row `bridge.startOrder`. All four bridge starts live in ONE launch hook.
    /// The documented regression is exactly this: ClaudeBridge used to be wired
    /// in `MainWindowContent.task` and "silently never fired" on a menu-bar
    /// launch. Assert every start is present in `applicationDidFinishLaunching`
    /// and that `setup()` precedes `observeIncomingMessages` (an inverted order
    /// registers a handler onto a bridge that has no transport yet).
    @Test("every bridge start is wired into the launch hook, in order")
    func bridgeStartOrderIsWiredAtLaunch() throws {
        let source = try AppSourceScraping.appSource("AppDelegate+Launch.swift")
        let launch = try body(after: "func applicationDidFinishLaunching", in: source)

        let macctl = try index(of: "MacControlBridge.shared.start()", in: launch)
        let claude = try index(of: "ClaudeBridge.shared.startSyncForBootstrap()", in: launch)
        let icloudSetup = try index(of: "iCloudBridge.shared.setup()", in: launch)
        let observe = try index(of: "iCloudBridge.shared.observeIncomingMessages", in: launch)
        let pairing = try index(of: "PairingSecretManager.publishMaterialToKVS()", in: launch)

        #expect(macctl < claude)
        #expect(claude < icloudSetup)
        #expect(icloudSetup < observe, "the message handler must be registered AFTER setup selects a transport")
        #expect(observe < pairing)

        // Row `pairing.launchKVSPublish`: the KVS publish is detached so it
        // cannot block launch, but it must still be REACHED from the hook.
        #expect(launch.contains("Task.detached"), "the pairing KVS publish lost its detached wrapper")

        // Symmetric teardown: both loopback listeners stop before drain, so no
        // stale bearer token outlives the process.
        let terminate = try body(after: "func applicationWillTerminate", in: source)
        let stopClaude = try index(of: "ClaudeBridge.shared.stop()", in: terminate)
        let stopMacctl = try index(of: "MacControlBridge.shared.stop()", in: terminate)
        #expect(stopClaude < stopMacctl)
    }

    // MARK: - icloud.remoteNotificationDelegate / icloud.push.registration

    /// Rows `icloud.remoteNotificationDelegate` + `icloud.push.registration`.
    /// If the delegate methods stop calling the bridge, APNs registration
    /// outcome never reaches it, the responsive drain fallback is never armed,
    /// and every phone message arrives at watchdog latency — with nothing
    /// reporting the degrade.
    @Test("APNs delegate callbacks reach the iCloud bridge and the wake is guarded")
    func remoteNotificationDelegateIsWired() throws {
        let source = try AppSourceScraping.appSource("AppDelegate+Launch.swift")

        let succeeded = try body(after: "didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data", in: source)
        #expect(succeeded.contains("iCloudBridge.shared.cloudKitPushRegistrationSucceeded()"))

        let failed = try body(after: "didFailToRegisterForRemoteNotificationsWithError error: Error", in: source)
        #expect(failed.contains("iCloudBridge.shared.cloudKitPushRegistrationFailed(error)"))

        let received = try body(after: "didReceiveRemoteNotification userInfo: [String: Any]", in: source)
        let guardIndex = try index(of: "recognizesCloudKitRemoteNotification", in: received)
        let wakeIndex = try index(of: "handleCloudKitPushWake", in: received)
        #expect(guardIndex < wakeIndex, "an unrecognized push must not drive a device-transport drain")
        #expect(received.contains("guard iCloudBridge.shared.recognizesCloudKitRemoteNotification"),
                "the recognition check must be a GUARD, not an advisory read")

        // Both registration outcomes arm the SAME responsive fallback: success
        // proves capability, not delivery. (iCloudBridge.swift:364/:369.)
        let bridge = try AppSourceScraping.appSource("iCloudBridge.swift")
        let ok = try body(after: "func cloudKitPushRegistrationSucceeded()", in: bridge)
        let bad = try body(after: "func cloudKitPushRegistrationFailed(", in: bridge)
        #expect(ok.contains("startDeviceDrainFallback(every: Self.responsiveDeviceDrainFallbackSeconds)"))
        #expect(bad.contains("startDeviceDrainFallback(every: Self.responsiveDeviceDrainFallbackSeconds)"))
        #expect(iCloudBridge.responsiveDeviceDrainFallbackSeconds == 8)
    }

    // MARK: - bridge.claude.discoveryDescriptor

    /// Row `bridge.claude.discoveryDescriptor`. Two files are written to a
    /// shared `~/.config/claude-bridge` directory; every agent tool reads them
    /// to find a live bearer for a live port. State-lifecycle rule: every add
    /// path needs a remove path — a file written by `writeDiscoveryFiles` and
    /// not unlinked by `removeDiscoveryFiles` outlives the process advertising a
    /// credential for a dead port.
    @Test("every discovery file written is also unlinked, and the descriptor stays diagnosable")
    func discoveryDescriptorWriteAndRemovePathsAreSymmetric() throws {
        let source = try AppSourceScraping.appSource("ClaudeBridge.swift")
        let write = try body(after: "func writeDiscoveryFiles(", in: source)
        let remove = try body(after: "func removeDiscoveryFiles()", in: source)

        let fileSymbols = ["tokenFileURL", "descriptorFileURL"]
        for symbol in fileSymbols {
            #expect(write.contains(symbol), "\(symbol) is no longer written")
            #expect(remove.contains(symbol), "\(symbol) is written but never unlinked — stale-credential leak")
        }
        // Nothing may be written that the remove path does not know about.
        let writtenSymbols = Set(
            fileSymbols.filter { write.contains($0) }
        )
        let removedSymbols = Set(fileSymbols.filter { remove.contains($0) })
        #expect(writtenSymbols == removedSymbols)

        // The descriptor must carry enough to tell LIVE from STALE without
        // connecting: the pid and the write time. Absent-is-not-zero.
        for key in ["\"processIdentifier\"", "\"writtenAt\"", "\"port\"", "\"url\"", "\"token\"", "\"schemaVersion\""] {
            #expect(write.contains(key), "discovery descriptor lost \(key)")
        }
        // The config dir is the credential surface; 0700 or a sibling account
        // can read the bearer.
        #expect(write.contains("0o700"), "the claude-bridge config dir lost its 0700 mode")
    }

    // MARK: - bridge.macctl.descriptor

    /// Row `bridge.macctl.descriptor`. `data/macctl_bridge.json` advertises a
    /// bearer for port 8770. The crash/gated-off case is the silent one: a
    /// descriptor from a previous run survives while nothing is listening.
    @Test("the Mac Control descriptor is written only when a port is bound, and swept on every exit")
    func macControlDescriptorHasARemovePathOnEveryExit() throws {
        let wholeFile = try AppSourceScraping.appSource("MacControlBridge.swift")
        // Scope to the bridge class: `MacControlBridgeStartupState` above it has
        // its own `stop()`, and matching that one would make the sweep
        // assertions look at the wrong subject.
        guard let classStart = wholeFile.range(of: "final class MacControlBridge:") else {
            Issue.record("MacControlBridge class declaration not found"); return
        }
        let source = String(wholeFile[classStart.lowerBound...])

        // A gated-off launch mints no token and binds no port, so any descriptor
        // still on disk is a crashed run's — sweep it before returning.
        let start = try body(after: "func start()", in: source)
        let gateIndex = try index(of: "guard Self.startGateAllows() else", in: start)
        let sweepIndex = try index(of: "removeDescriptor()", in: start)
        #expect(gateIndex < sweepIndex, "the sweep must live inside the gated-off branch")
        #expect(start.contains("removeDescriptor()\n            return"),
                "the gated-off branch no longer sweeps before returning")
        // …and the admitted path sweeps again before durable recovery, so no
        // window advertises a stale bearer next to a fresh one.
        #expect(AppSourceScraping.occurrences(of: "removeDescriptor()", in: start) == 2,
                "start() lost one of its two sweep points (gated-off branch / pre-listener)")
        // The bind path sweeps once more when the listener refuses to start.
        let afterRecovery = try body(after: "func startListenerAfterRecovery(", in: source)
        #expect(afterRecovery.contains("if !started { removeDescriptor() }"),
                "a failed bind no longer sweeps the descriptor")

        // The ONE write site is the listener-ready callback. A descriptor
        // written anywhere else could advertise a port nothing is serving —
        // exactly the failure this row names.
        let writeSites = AppSourceScraping.occurrences(of: "writeDescriptor(token: token", in: source)
        #expect(writeSites == 1, "\(writeSites) writeDescriptor call sites — the descriptor must follow the bind")
        let ready = try body(after: "func handleListenerReady(", in: source)
        #expect(ready.contains("writeDescriptor(token: token, port: port)"),
                "the descriptor is no longer published from the listener-ready callback")

        // Every terminal path removes it.
        for (name, marker) in [
            ("stop", "func stop()"),
            ("failStartup", "func failStartup("),
            ("handleListenerTerminated", "func handleListenerTerminated("),
        ] {
            let scope = try body(after: marker, in: source)
            #expect(scope.contains("removeDescriptor()"), "\(name) no longer removes the descriptor")
        }

        // Build identity in the descriptor is what makes a stale row
        // diagnosable rather than merely wrong (the subject-VERSION misread).
        let write = try body(after: "func writeDescriptor(", in: source)
        for key in ["\"port\"", "\"token\"", "\"bundleId\"", "\"version\"", "\"build\"", "\"sourceRevision\"", "\"writtenAt\""] {
            #expect(write.contains(key), "macctl descriptor lost \(key)")
        }
    }

    // MARK: - bridge.macctl.execAllowlist

    /// Row `bridge.macctl.execAllowlist`. A privilege boundary: six executables,
    /// each pinned to an ABSOLUTE path. The silent widening is a seventh entry
    /// added with no policy check, or a relative/typo'd path that lets a
    /// same-named binary elsewhere on PATH win.
    ///
    /// Frozen in both directions AND checked against the live filesystem: a
    /// typo'd path fails here even though it would compile.
    @Test("the exec allowlist is a frozen set of real absolute system paths")
    func execAllowlistIsFrozenAndCanonical() throws {
        let source = try AppSourceScraping.appSource("MacControlBridge.swift")
        // The marker ENDS on the literal's opening bracket, so the balanced
        // scan starts there and not on the `[String: String]` type annotation.
        guard let hit = source.range(of: "allowedExecutablePaths: [String: String] = ["),
              case let open = source.index(before: hit.upperBound),
              let close = AppSourceScraping.balancedEnd(in: source, startingAt: open, opening: "[", closing: "]")
        else {
            Issue.record("allowedExecutablePaths literal not found")
            return
        }
        let inner = String(source[source.index(after: open)..<close])
        var parsed: [String: String] = [:]
        for line in inner.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t,\""))
            }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
            parsed[parts[0]] = parts[1]
        }

        let expected: [String: String] = [
            "osascript": "/usr/bin/osascript",
            "shortcuts": "/usr/bin/shortcuts",
            "pmset": "/usr/bin/pmset",
            "mdfind": "/usr/bin/mdfind",
            "ls": "/bin/ls",
            "mv": "/bin/mv",
        ]
        #expect(parsed == expected, "exec allowlist drifted: \(parsed)")

        for (name, path) in parsed {
            #expect(path.hasPrefix("/"), "\(name) is not an absolute path — PATH lookup would decide it")
            #expect(URL(fileURLWithPath: path).lastPathComponent == name,
                    "\(name) maps to \(path): key and basename disagree, so canonicalArgv can never match it")
            #expect(FileManager.default.isExecutableFile(atPath: path),
                    "\(path) is not an executable file on this machine")
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
            #expect(["/usr/bin", "/bin", "/usr/sbin", "/sbin"].contains(dir),
                    "\(name) escaped the system binary directories: \(dir)")
        }

        // The canonicalization itself: a supplied path must be compared after
        // `standardizedFileURL` (kills `/usr/bin/../bin/ls`), the lookup key
        // must be the lowercased basename (kills `/tmp/LS`), and argv[0] must be
        // REWRITTEN to the canonical path (kills a bare `ls` resolving via PATH).
        let canonical = try body(after: "func canonicalArgv(", in: source)
        #expect(canonical.contains("lastPathComponent.lowercased()"))
        #expect(canonical.contains("standardizedFileURL"))
        #expect(canonical.contains("supplied == canonical"))
        #expect(canonical.contains("out[0] = canonical"), "argv[0] is no longer rewritten to the canonical path")

        // Every rejection must carry a REASON string — a nil/empty refusal is
        // the silent-deny case the audit feed cannot explain.
        let validate = try body(after: "func validateExecArgv(", in: source)
        #expect(validate.contains("executable_not_allowed:"))
        #expect(validate.contains("mac_control_policy_denied:"))
        #expect(validate.contains("missing executable"))
    }

    // MARK: - bridge.claude.ackMode.enqueue

    /// Row `bridge.claude.ackMode.enqueue`. The named failure is a MISSPELLED
    /// key or a branch that stops being taken: every caller silently falls back
    /// to the coupled lane and any POST that both starts and waits on the same
    /// turn self-deadlocks. That presents as a hang, not an error.
    @Test("the ack-on-enqueue branch keeps its exact key, compare, and response shape")
    func ackOnEnqueueBranchContract() throws {
        let source = try AppSourceScraping.appSource("ClaudeBridge.swift")

        #expect(source.contains("(json[\"ackMode\"] as? String)?.lowercased() == \"enqueue\""),
                "the ackMode key/compare changed — every caller silently falls back to the coupled lane")
        // Codex completions must STAY on the legacy lane: their
        // claim/settled/conflict response semantics carry at-most-once delivery.
        guard let branch = source.range(of: "(json[\"ackMode\"] as? String)?.lowercased() == \"enqueue\"") else {
            Issue.record("ackMode branch not found"); return
        }
        let preceding = String(source[..<branch.lowerBound].suffix(200))
        #expect(preceding.contains("!isCodexCompletion"),
                "the enqueue lane no longer excludes Codex completions")

        let handler = try body(after: "func handleMessageAckOnEnqueue(", in: source)
        // The ack body is the contract the caller polls on: it must name the
        // enqueued session, not the turn result.
        #expect(handler.contains("\"ack\": \"enqueued\""))
        #expect(handler.contains("\"sessionId\": enqueued.sessionId"))
        #expect(handler.contains("\"enqueuedAt\""))
        // Both the success answer and the failure answer are latch-claimed, so
        // the deadline and the worker can never both answer one connection.
        let claims = AppSourceScraping.occurrences(of: "enqueueLatch.claim()", in: handler)
        let answers = AppSourceScraping.occurrences(of: "writeJSON(conn,", in: handler)
        #expect(claims == 3, "the enqueue lane's latch-claim count changed: \(claims)")
        #expect(answers == claims,
                "\(answers) answer paths for \(claims) latch claims — a path can answer the same connection twice")
        #expect(handler.contains("Self.enqueueAckDeadlineSeconds"),
                "the enqueue lane no longer bounds its ack on the enqueue deadline")
        #expect(ClaudeBridge.enqueueAckDeadlineSeconds < ClaudeBridge.messageWorkDeadlineSeconds,
                "the ack deadline must be strictly shorter than the coupled work deadline")
    }

    // MARK: - bridge.claude.codexReplyRecovery

    /// Row `bridge.claude.codexReplyRecovery`. Set in some launch context and
    /// never unset, relaunch repair of durable Codex reply jobs never runs and
    /// undelivered replies accumulate silently. The truthy set is scraped from
    /// source and RUN as a table, so widening it (e.g. adding "0") fails here.
    @Test("only {1,true,yes} disables Codex reply-job recovery")
    func codexReplyRecoveryDisableSetIsExact() throws {
        let source = try AppSourceScraping.appSource("ClaudeBridge.swift")
        let gate = try body(after: "func startCodexReplyJobRecovery()", in: source)

        #expect(gate.contains("NATIVE_AGENT_CODEX_REPLY_RECOVERY_DISABLED"))
        #expect(gate.contains(".lowercased()"), "the gate must be case-insensitive or `TRUE` silently misses")

        let truthy = try stringArrayLiteral(at: "if [", in: gate)
        #expect(Set(truthy) == ["1", "true", "yes"], "the disable set drifted: \(truthy)")

        // Run the scraped set as the predicate the app uses.
        func disabled(_ value: String?) -> Bool { truthy.contains(value?.lowercased() ?? "") }
        #expect(disabled("1"))
        #expect(disabled("true"))
        #expect(disabled("TRUE"))
        #expect(disabled("Yes"))
        #expect(disabled(nil) == false)
        #expect(disabled("") == false)
        #expect(disabled("0") == false, "\"0\" must NOT disable recovery")
        #expect(disabled("disabled") == false)
        #expect(disabled("false") == false)

        // The gate must return before anything is spawned: a disabled launch
        // must leave no Process, no node, no helper resolution.
        let returnIndex = try index(of: "return", in: gate)
        let processIndex = try index(of: "let process = Process()", in: gate)
        #expect(returnIndex < processIndex)
    }

    // MARK: - push.inboxNotifier.killSwitch

    /// Row `push.inboxNotifier.killSwitch`. Every gate must sit BEFORE the send:
    /// a reordering that sends first and filters after turns a severity filter
    /// into a notification storm, and the data-root gate is what keeps a test or
    /// clone process from pushing to User's actual phone.
    @Test("inbox push gates all precede the send, and the kill switch is exact")
    func inboxPushNotifierGateOrder() throws {
        let source = try AppSourceScraping.appSource("InboxPushNotifier.swift")
        let notify = try body(after: "func notifyIfAttentionWorthy(", in: source)

        let severity = try index(of: "guard shouldNotify(severity: severity)", in: notify)
        let liveRoot = try index(of: "guard usesLiveAppDataRoot(dataRoot)", in: notify)
        let xctest = try index(of: "XCTestConfigurationFilePath", in: notify)
        let killSwitch = try index(of: "NATIVE_AGENT_DISABLE_INBOX_PUSH", in: notify)
        let send = try index(of: "sendNotificationToPairedDevices", in: notify)

        #expect(severity < send)
        #expect(liveRoot < send)
        #expect(xctest < send, "a test process must never reach the real push sender")
        #expect(killSwitch < send)
        #expect(notify.contains("[\"NATIVE_AGENT_DISABLE_INBOX_PUSH\"] != \"1\""),
                "the kill switch compare drifted — only the literal \"1\" may disable pushes")

        // The severity allowlist is frozen: silently adding "info" here is the
        // notification-storm class.
        let should = try body(after: "func shouldNotify(", in: source)
        let cases = try captures(#""([^"]+)""#, in: should)
        #expect(Set(cases) == ["actionable", "important", "critical"], "severity allowlist drifted: \(cases)")

        // Text that leaves the machine is redacted and length-bounded.
        #expect(notify.contains("NativeAppSecretRedactor.redactText"))
        #expect(notify.contains("title.prefix(160)"))
        #expect(notify.contains("summary.prefix(500)"))
    }
}
