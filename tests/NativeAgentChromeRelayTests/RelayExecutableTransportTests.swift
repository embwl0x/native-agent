import Darwin
import Foundation
import Testing

@testable import NativeAgentChromeRelayCore

// End-to-end evals for the NativeAgentChromeRelay EXECUTABLE. Before this file
// nothing anywhere launched the binary: the env read, the AF_UNIX connect, the
// dup, both pumps, the opacity check, the teardown latch and every exit code
// were compile-checked only. The relay could have been a no-op that exits 0
// and all 7 framing tests would still have been green.
//
// Every wait here is bounded (poll + SIGTERM/SIGKILL escalation, never
// waitUntilExit) and every relay runs against a test-owned socket in a temp
// root with a temp HOME — no eval can reach the real
// ~/Library/Application Support/NativeAgent/chrome-control.sock.

@Suite("Chrome relay executable transport", .serialized)
struct RelayExecutableTransportTests {

    private static let request = #"{"version":1,"type":"request","id":"r1","action":"acquire"}"#
    private static let response = #"{"version":1,"type":"response","id":"r1","ok":true}"#

    // MARK: relay.transport.pump

    @Test("a JSON object round-trips byte-identically in both directions")
    func pumpRoundTripsObjectsUnchanged() throws {
        let harness = try RelayHarness()
        defer { harness.cleanup() }

        let requestFrame = try framedJSON(Self.request)
        #expect(harness.sendFromChrome(requestFrame))
        let onSocket = harness.appChannel.awaitBytes(requestFrame.count, timeout: 5)
        #expect(onSocket == requestFrame, "Chrome->app frame did not arrive byte-identical")

        let responseFrame = try framedJSON(Self.response)
        #expect(harness.sendFromApp(responseFrame))
        let onStdout = harness.chromeChannel?.awaitBytes(responseFrame.count, timeout: 5)
        #expect(onStdout == responseFrame, "app->Chrome frame did not arrive byte-identical")

        harness.closeChromeStdin()
        let exit = harness.waitForExit(timeout: 10)
        #expect(exit.exitedOnItsOwn)
        #expect(exit.status == 0)
    }

    @Test("a top-level array from the CHROME side terminates the relay and forwards nothing")
    func pumpRefusesNonObjectFromChrome() throws {
        // main.swift:115 is where the relay's opacity contract is actually
        // enforced. The unit test proves the FUNCTION rejects non-objects;
        // this proves the BINARY calls it — delete line 115 and the framing
        // tests all still pass while arbitrary bytes cross into the app.
        let harness = try RelayHarness()
        defer { harness.cleanup() }

        #expect(harness.sendFromChrome(try framedJSON("[]")))
        let exit = harness.waitForExit(timeout: 10)
        #expect(exit.exitedOnItsOwn)
        #expect(exit.status == 1)
        #expect(
            harness.awaitStderr(timeout: 3)
                == relayDiagnosticPrefix
                + "Native-messaging payload must be a top-level JSON object.\n"
        )
        #expect(harness.appChannel.snapshot().isEmpty, "non-object leaked onto the app socket")
    }

    @Test("a top-level array from the APP side terminates the relay and reaches no stdout")
    func pumpRefusesNonObjectFromApp() throws {
        let harness = try RelayHarness()
        defer { harness.cleanup() }

        #expect(harness.sendFromApp(try framedJSON("[1,2,3]")))
        let exit = harness.waitForExit(timeout: 10)
        #expect(exit.exitedOnItsOwn)
        #expect(exit.status == 1)
        #expect(
            harness.awaitStderr(timeout: 3).contains(
                "Native-messaging payload must be a top-level JSON object."
            )
        )
        #expect(harness.chromeChannel?.snapshot().isEmpty == true)
    }

    @Test("malformed JSON is refused by the running relay, in either direction")
    func pumpRefusesMalformedJSON() throws {
        // The second branch of the opacity check in the BINARY: bytes that are
        // not JSON at all must never reach the peer.
        for fromChrome in [true, false] {
            let harness = try RelayHarness()
            defer { harness.cleanup() }
            let frame = try framedJSON(#"{"unterminated": "#)
            #expect(fromChrome ? harness.sendFromChrome(frame) : harness.sendFromApp(frame))
            let exit = harness.waitForExit(timeout: 10)
            #expect(exit.exitedOnItsOwn)
            #expect(exit.status == 1)
            #expect(
                harness.awaitStderr(timeout: 3)
                    == relayDiagnosticPrefix + "Native-messaging payload is not valid JSON.\n"
            )
            #expect(harness.appChannel.snapshot().isEmpty)
            #expect(harness.chromeChannel?.snapshot().isEmpty == true)
        }
    }

    // MARK: relay.framing.maximumMessageBytes.default (cross-process)

    @Test("the running relay enforces the 1 MiB default bound, naming both numbers")
    func oversizeFrameNamesTheDefaultBound() throws {
        // Both processes build a bare NativeMessagingFramer(), so the bound is
        // an unwritten cross-process contract. This is the end-to-end half of
        // NativeMessagingFramingCoverageTests.defaultMaximumIsPinned: the
        // running binary's own diagnostic must name 1048576.
        let maximum = NativeMessagingFramer.defaultMaximumMessageBytes
        let harness = try RelayHarness()
        defer { harness.cleanup() }

        let oversize = UInt32(maximum + 1)
        let header = Data([
            UInt8(oversize & 0xFF),
            UInt8((oversize >> 8) & 0xFF),
            UInt8((oversize >> 16) & 0xFF),
            UInt8((oversize >> 24) & 0xFF),
        ])
        #expect(harness.sendFromApp(header))
        let exit = harness.waitForExit(timeout: 10)
        #expect(exit.exitedOnItsOwn)
        #expect(exit.status == 1)
        #expect(
            harness.awaitStderr(timeout: 3)
                == relayDiagnosticPrefix
                + "Native-messaging frame is \(maximum + 1) bytes; maximum is \(maximum).\n"
        )
    }

    // MARK: relay.env.NATIVEAGENT_CHROME_SOCKET_PATH

    @Test("NATIVEAGENT_CHROME_SOCKET_PATH is the seam the relay actually connects through")
    func socketPathOverrideIsHonored() throws {
        // If the env var stopped being read, the relay would fall through to
        // ~/Library/Application Support/NativeAgent/chrome-control.sock and
        // this harness would never see a connection.
        let harness = try RelayHarness()
        defer { harness.cleanup() }
        #expect(harness.socketPath.hasPrefix("/tmp/na-relay-evals/"))
        #expect(!harness.socketPath.contains("Library/Application Support"))
        #expect(harness.connectionDescriptor >= 0)

        let frame = try framedJSON(Self.request)
        #expect(harness.sendFromChrome(frame))
        #expect(harness.appChannel.awaitBytes(frame.count, timeout: 5) == frame)
        harness.closeChromeStdin()
        #expect(harness.waitForExit(timeout: 10).exitedOnItsOwn)
    }

    @Test("a relative or over-long socket path fails closed with a named reason")
    func socketPathOverrideIsValidated() throws {
        let relative = try runRelayExpectingFailure(socketPath: "relative/chrome-control.sock")
        #expect(relative.exitedOnItsOwn)
        #expect(relative.status == 1)
        #expect(
            relative.stderr
                == relayDiagnosticPrefix + "NativeAgent Chrome socket path must be absolute.\n"
        )

        // sun_path is 104 bytes on Darwin; a long home or relocated data root
        // hits this, and today it fails closed but invisibly.
        let tooLong = try runRelayExpectingFailure(
            socketPath: "/tmp/" + String(repeating: "a", count: 200) + ".sock"
        )
        #expect(tooLong.exitedOnItsOwn)
        #expect(tooLong.status == 1)
        #expect(
            tooLong.stderr
                == relayDiagnosticPrefix
                + "NativeAgent Chrome socket path exceeds the Unix-socket limit.\n"
        )
    }

    // MARK: relay.socket.connect

    @Test("connect failures exit nonzero promptly instead of hanging")
    func connectFailsClosedAndFast() throws {
        let root = URL(fileURLWithPath: "/tmp/na-relay-evals", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // (a) nothing bound at an otherwise valid absolute path.
        let missing = try runRelayExpectingFailure(
            socketPath: root.appendingPathComponent("absent.sock").path
        )
        #expect(missing.exitedOnItsOwn, "relay hung instead of failing closed")
        #expect(missing.status == 1)
        #expect(
            missing.stderr
                == relayDiagnosticPrefix
                + "Could not connect to NativeAgent.app Chrome socket (errno \(ENOENT)).\n"
        )
        #expect(missing.stdout.isEmpty)

        // (b) the path exists but is not a socket (a stale plain file).
        let plainFile = root.appendingPathComponent("not-a-socket")
        try Data("x".utf8).write(to: plainFile)
        let wrongType = try runRelayExpectingFailure(socketPath: plainFile.path)
        #expect(wrongType.exitedOnItsOwn)
        #expect(wrongType.status == 1)
        #expect(
            wrongType.stderr.hasPrefix(
                relayDiagnosticPrefix
                    + "Could not connect to NativeAgent.app Chrome socket (errno "
            ),
            "unexpected diagnostic: \(wrongType.stderr)"
        )
        #expect(wrongType.stdout.isEmpty)
    }

    // MARK: relay.diagnostics.stderr

    @Test("every relay failure emits one prefixed stderr line and writes nothing anywhere else")
    func diagnosticsAreStderrOnlyAndPrefixed() throws {
        // The headline gap of this fence: the relay writes NOTHING observable
        // — no traces/events.jsonl row, no operations entry, no app-side
        // surface — and Chrome discards native-host stderr. This is the
        // minimum honest pin: the line exists, it is prefixed, it goes to
        // stderr only, and NOTHING lands under the process's HOME.
        let root = URL(fileURLWithPath: "/tmp/na-relay-evals", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cases: [(String, String)] = [
            ("relative path", "relative/x.sock"),
            ("over-long path", "/tmp/" + String(repeating: "b", count: 200) + ".sock"),
            ("no listener", root.appendingPathComponent("absent.sock").path),
        ]
        for (label, path) in cases {
            let run = try runRelayExpectingFailure(socketPath: path)
            #expect(run.exitedOnItsOwn, "\(label): relay hung")
            #expect(run.status != 0, "\(label): relay exited 0 on a failure")
            #expect(run.reason == .exit, "\(label): died by signal, not its own error path")
            #expect(run.stderr.hasPrefix(relayDiagnosticPrefix), "\(label): \(run.stderr)")
            #expect(run.stderr.hasSuffix("\n"), "\(label): \(run.stderr)")
            let description = run.stderr.dropFirst(relayDiagnosticPrefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(!description.isEmpty, "\(label): empty localized description")
            #expect(run.stdout.isEmpty, "\(label): diagnostics leaked into the frame channel")
            // Nothing written under HOME: the relay has no feed, no row, no
            // file. If that ever changes, this eval is the place to say so.
            #expect(
                run.homeContents.isEmpty,
                "\(label): relay wrote \(run.homeContents) under HOME"
            )
        }
    }

    // MARK: relay.cli.argumentContract

    @Test("argv is ignored: no args, Chrome's real argv, and a foreign origin all behave alike")
    func argvIsIgnoredIdentically() throws {
        // Chrome launches a native host with argv[1] = the calling extension
        // origin. The relay authenticates nothing about its parent, so all
        // three of these round-trip identically. This pins the decision
        // (argv ignored by design) so a future origin check cannot be added
        // and silently reverted; the authentication gap itself is a production
        // seam, reported not made.
        let argvCases: [[String]] = [
            [],
            ["chrome-extension://egdbijiogeeggnmjheomgnnkhmlepfcn/", "--parent-window=0"],
            ["chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/"],
        ]
        for arguments in argvCases {
            let harness = try RelayHarness(arguments: arguments)
            defer { harness.cleanup() }
            let requestFrame = try framedJSON(Self.request)
            #expect(harness.sendFromChrome(requestFrame))
            #expect(
                harness.appChannel.awaitBytes(requestFrame.count, timeout: 5) == requestFrame,
                "argv \(arguments) changed Chrome->app behavior"
            )
            let responseFrame = try framedJSON(Self.response)
            #expect(harness.sendFromApp(responseFrame))
            #expect(
                harness.chromeChannel?.awaitBytes(responseFrame.count, timeout: 5)
                    == responseFrame,
                "argv \(arguments) changed app->Chrome behavior"
            )
            harness.closeChromeStdin()
            let exit = harness.waitForExit(timeout: 10)
            #expect(exit.exitedOnItsOwn)
            #expect(exit.status == 0, "argv \(arguments) changed the exit code")
            #expect(harness.stderrText.isEmpty)
        }
    }

    // MARK: relay.stdout.protocolChannelPurity

    @Test("stdout carries exactly the framer's bytes and nothing else")
    func stdoutIsByteExact() throws {
        // A single stray print()/debug write injects bytes into the
        // length-prefixed stream and Chrome kills the host port. Only a
        // byte-exact comparison of the WHOLE stream catches it.
        let harness = try RelayHarness()
        defer { harness.cleanup() }

        let framer = NativeMessagingFramer()
        let payloads = [
            Data(#"{"id":"a","ok":true}"#.utf8),
            Data(#"{"id":"b","ok":false,"error":"nope"}"#.utf8),
            Data(#"{"id":"c","payload":{"nested":[1,2,3]}}"#.utf8),
        ]
        var expected = Data()
        for payload in payloads {
            let frame = try framer.encode(payload)
            expected.append(frame)
            #expect(harness.sendFromApp(frame))
        }
        #expect(harness.chromeChannel?.awaitBytes(expected.count, timeout: 5) != nil)

        harness.closeAppSocket()
        harness.closeChromeStdin()
        let exit = harness.waitForExit(timeout: 10)
        #expect(exit.exitedOnItsOwn)
        let stdout = harness.chromeChannel?.awaitEOF(timeout: 5) ?? Data()
        #expect(stdout == expected, "stdout carried \(stdout.count) bytes, expected \(expected.count)")
    }

    // MARK: relay.transport.teardownLatch

    @Test("CHARACTERIZATION: stdin EOF discards an in-flight app->Chrome frame")
    func teardownLatchDropsInFlightFrame() throws {
        // RelayCompletion is first-finish-wins INCLUDING a clean EOF: when
        // Chrome closes stdin, the Chrome->app pump returns nil, the process
        // shuts the socket down both ways and exits, and any app->Chrome frame
        // still in flight is discarded — with EXIT_SUCCESS.
        //
        // This pins the CURRENT behavior on purpose (the fix is a production
        // change: drain-before-exit or a nonzero exit — see
        // productionSeamNeeded). The load-bearing assertion is that stdout is
        // empty: the day the relay learns to deliver the pending frame, this
        // eval fails and must be updated deliberately rather than the drop
        // going on being invisible.
        let harness = try RelayHarness()
        defer { harness.cleanup() }

        // Header only: the app->Chrome pump is now blocked mid-frame, so the
        // drop is deterministic rather than a race.
        #expect(harness.sendFromApp(Data([50, 0, 0, 0])))
        Thread.sleep(forTimeInterval: 0.1)
        harness.closeChromeStdin()

        let exit = harness.waitForExit(timeout: 10)
        #expect(exit.exitedOnItsOwn, "relay hung on teardown")
        #expect(exit.reason == .exit)
        // 0 today (EXIT_SUCCESS with a silently dropped frame); 1 is the
        // benign race where the second pump's unexpectedEndOfFile lands first.
        #expect(exit.status == 0 || exit.status == 1, "unexpected status \(exit.status)")
        let stdout = harness.chromeChannel?.awaitEOF(timeout: 5) ?? Data()
        #expect(stdout.isEmpty, "in-flight frame is now delivered — update this pin")
    }

    // MARK: relay.process.sigpipeDisposition

    @Test("CHARACTERIZATION: a dead Chrome stdout kills the relay by SIGPIPE with no diagnostic")
    func writeToDeadChromeStdoutRaisesSIGPIPE() throws {
        // The most common real-world teardown — Chrome unloads the extension
        // while the app is mid-response — does NOT take the
        // throw -> diagnostic -> exit(EXIT_FAILURE) path. There is no
        // signal(SIGPIPE, SIG_IGN) and no SO_NOSIGPIPE anywhere in the relay,
        // so the process dies by signal 13 with an EMPTY stderr: the failure
        // most likely to happen in production is the only one producing zero
        // diagnostic text. Pinned as current behavior; the fix is a production
        // change (see productionSeamNeeded).
        let harness = try RelayHarness(captureStdout: false)
        defer { harness.cleanup() }

        #expect(harness.sendFromApp(try framedJSON(Self.response)))
        let exit = harness.waitForExit(timeout: 10)
        #expect(exit.exitedOnItsOwn, "relay hung instead of dying")
        #expect(exit.reason == .uncaughtSignal, "no longer signal-terminated — update this pin")
        #expect(exit.status == SIGPIPE, "expected signal 13, got \(exit.status)")
        #expect(
            harness.awaitStderr(timeout: 2).isEmpty,
            "a diagnostic now exists for the SIGPIPE path — update this pin"
        )
    }

    // MARK: relay.loop.pumpPair

    @Test("a peer stalled mid-frame keeps the relay alive, and Chrome's exit still reaps it")
    func stalledPeerHasNoIdleTimeoutButIsReapedByStdinEOF() throws {
        // readExactly blocks forever on a peer that wrote a header and then
        // stalled: the relay has no idle deadline, no cancellation token and
        // no liveness signal, and nothing anywhere counts live relay
        // processes. Both halves matter — (1) no idle timeout exists today, so
        // the bound is NOT "the relay times itself out"; (2) the bound that
        // DOES hold is Chrome's port lifetime: closing stdin reaps it.
        let harness = try RelayHarness()
        defer { harness.cleanup() }

        #expect(harness.sendFromApp(Data([100, 0, 0, 0])))
        Thread.sleep(forTimeInterval: 1.0)
        #expect(
            harness.isStillRunning(),
            "an idle timeout now exists — the orphan bound changed, update this pin"
        )
        #expect(harness.chromeChannel?.snapshot().isEmpty == true)

        harness.closeChromeStdin()
        let exit = harness.waitForExit(timeout: 8)
        #expect(exit.exitedOnItsOwn, "relay orphaned: it outlived its Chrome parent's stdin")
        #expect(exit.reason == .exit)
    }
}
