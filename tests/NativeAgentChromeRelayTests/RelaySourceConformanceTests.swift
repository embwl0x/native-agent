import Foundation
import Testing

@testable import NativeAgentChromeRelayCore

// Source-conformance guards for relay invariants that no runtime seam can
// reach today. Each one is here because the ledger row says the contract is
// currently enforced by CONVENTION ONLY — these turn convention into a build
// failure. They read production sources; they never modify them.

private func relaySource(_ path: String) throws -> [String] {
    try RelayTestPaths.source(path).components(separatedBy: "\n")
}

private func swiftSources(under relativeDirectory: String) throws -> [String] {
    let root = RelayTestPaths.repoRoot.appendingPathComponent(relativeDirectory)
    guard
        let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        )
    else { return [] }
    var found: [String] = []
    for case let url as URL in walker where url.pathExtension == "swift" {
        found.append(
            url.path.replacingOccurrences(
                of: RelayTestPaths.repoRoot.path + "/", with: ""
            )
        )
    }
    return found.sorted()
}

/// Body of `func <name>() -> String { … }` with whitespace collapsed, so two
/// copies of the same expression compare equal regardless of indentation.
private func normalizedFunctionBody(_ source: String, named name: String) -> String? {
    guard let start = source.range(of: "func \(name)() -> String {") else { return nil }
    var depth = 0
    var body = ""
    var index = start.upperBound
    depth = 1
    while index < source.endIndex {
        let character = source[index]
        if character == "{" { depth += 1 }
        if character == "}" {
            depth -= 1
            if depth == 0 { break }
        }
        body.append(character)
        index = source.index(after: index)
    }
    guard depth == 0 else { return nil }
    return
        body
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

@Suite("Chrome relay source conformance")
struct RelaySourceConformanceTests {

    // MARK: relay.socket.defaultPath

    @Test("relay and app derive the SAME default chrome-control socket path")
    func defaultSocketPathsAgree() throws {
        // The identical literal is independently hardcoded on both sides —
        // Sources/NativeAgentChromeRelay/main.swift:64-69 and
        // Sources/NativeAgentApp/ChromeControlRuntime.swift defaultSocketPath().
        // Change one and the relay connects to a path nobody binds: Chrome
        // control goes permanently dead with no failing test and no UI signal.
        // This is a guard until the constant is promoted into
        // NativeAgentChromeRelayCore (see productionSeamNeeded).
        let relay = try RelayTestPaths.source("Sources/NativeAgentChromeRelay/main.swift")
        let app = try RelayTestPaths.source("Sources/NativeAgentApp/ChromeControlRuntime.swift")
        let relayBody = normalizedFunctionBody(relay, named: "defaultSocketPath")
        let appBody = normalizedFunctionBody(app, named: "defaultSocketPath")
        #expect(relayBody != nil, "relay defaultSocketPath() not found — did it get renamed?")
        #expect(appBody != nil, "app defaultSocketPath() not found — did it get renamed?")
        #expect(relayBody == appBody)
        // And pin what that shared expression actually resolves to, so a
        // matched-but-wrong edit on BOTH sides still trips something.
        let expected =
            "FileManager.default.homeDirectoryForCurrentUser "
            + ".appendingPathComponent(\"Library/Application Support/NativeAgent\", "
            + "isDirectory: true) .appendingPathComponent(\"chrome-control.sock\") .path"
        #expect(relayBody == expected)
    }

    // MARK: relay.stdout.protocolChannelPurity (source half)

    @Test("nothing but the framer may write to stdout in either relay module")
    func stdoutIsTheFrameChannelOnly() throws {
        // A single stray print()/NSLog-to-stdout anywhere in the relay
        // executable OR in NativeAgentChromeRelayCore (which is ALSO linked
        // into NativeAgentApp, so a library-side debug print looks harmless
        // there) injects bytes into the length-prefixed stream; Chrome reads
        // them as a garbage 4-byte length prefix and kills the host port.
        var offenders: [String] = []
        var standardOutputSites: [String] = []
        for relativePath in try swiftSources(under: "Sources/NativeAgentChromeRelay")
            + swiftSources(under: "Sources/NativeAgentChromeRelayCore")
        {
            for (index, line) in try relaySource(relativePath).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                let site = "\(relativePath):\(index + 1)"
                if trimmed.contains("print(") || trimmed.contains("NSLog(")
                    || trimmed.contains("debugPrint(") || trimmed.contains("fputs(")
                {
                    offenders.append("\(site) \(trimmed)")
                }
                if trimmed.contains("standardOutput") {
                    // File + exact source text, not a line NUMBER: a pin that
                    // breaks on unrelated edits above it teaches people to
                    // rebaseline it, which is how a real regression slips by.
                    standardOutputSites.append("\(relativePath) | \(trimmed)")
                }
            }
        }
        #expect(offenders.isEmpty, "stdout-polluting call(s): \(offenders)")
        // Exactly one stdout reference: main.swift's `output: .standardOutput`,
        // the Chrome frame channel itself. Diagnostics go to standardError.
        #expect(
            standardOutputSites == [
                "Sources/NativeAgentChromeRelay/main.swift | output: .standardOutput"
            ],
            "stdout reference set changed: \(standardOutputSites)"
        )
    }

    // MARK: relay.cli.argumentContract (source half)

    @Test("argv reaches launch authentication only, against a single origin constant")
    func relayReadsArgvOnlyToAuthenticateItsLaunch() throws {
        // 2026-09-06: 06af1541 ("Chrome control: a relay only counts if Chrome
        // launched it") inverted this pin. The relay used to read no argv at
        // all and the origin lived solely in the native-host manifest; it now
        // refuses to start unless a signed Chromium-family parent launched it
        // AND argv carries the registered extension origin
        // (Sources/NativeAgentChromeRelay/main.swift refuseUnlessLaunchedByChrome).
        //
        // What still has to hold, and is what this guards:
        //  1. argv feeds AUTHENTICATION ONLY. Nothing about how the relay runs
        //     — socket path, framing bound, anything — may come from an
        //     argument, or an impersonating launcher gets to configure the
        //     process it just failed to authenticate. The socket path stays an
        //     environment/default decision (see run()).
        //  2. The origin the relay checks and the origin the manifest allows
        //     are ONE value. Two literals silently drift, and drift here means
        //     either a dead channel or a check that passes for an extension
        //     Chrome would never have launched us for.
        var argvSites: [String] = []
        for relativePath in try swiftSources(under: "Sources/NativeAgentChromeRelay") {
            for (index, line) in try relaySource(relativePath).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                guard trimmed.contains("CommandLine") || trimmed.contains("processInfo.arguments")
                else { continue }
                argvSites.append("\(relativePath) | \(trimmed)")
            }
        }
        // File + exact source text, not line numbers: a pin that breaks on
        // unrelated edits above it teaches people to rebaseline it.
        #expect(
            argvSites == [
                // The self-path fallback, used only to decide whether this is
                // the bundled relay that has to authenticate at all.
                "Sources/NativeAgentChromeRelay/main.swift | ?? CommandLine.arguments.first ?? \"\"",
                // The origin check itself.
                "Sources/NativeAgentChromeRelay/main.swift | "
                    + "guard ChromeHostIdentity.argumentsCarryAllowedOrigin(CommandLine.arguments) else {",
            ],
            "argv now reaches something other than launch authentication: \(argvSites)"
        )

        // One origin constant, shared by the check and the manifest.
        let identity = try RelayTestPaths.source(
            "Sources/NativeAgentChromeRelayCore/ChromeHostIdentity.swift"
        )
        guard let idRange = identity.range(of: "public static let extensionID = \""),
              let closing = identity.range(of: "\"", range: idRange.upperBound..<identity.endIndex)
        else {
            Issue.record("ChromeHostIdentity.extensionID not found — did it get renamed?")
            return
        }
        let extensionID = String(identity[idRange.upperBound..<closing.lowerBound])
        #expect(!extensionID.isEmpty)
        // allowedOrigin is what argumentsCarryAllowedOrigin matches argv against.
        #expect(
            identity.contains("chrome-extension://\\(extensionID)/"),
            "the origin the relay checks no longer derives from extensionID"
        )
        let manifest = try RelayTestPaths.source(
            "Extensions/NativeAgentChrome/native-host/com.nativeagent.chrome.json.in"
        )
        #expect(manifest.contains("allowed_origins"))
        #expect(
            manifest.contains("chrome-extension://\(extensionID)/"),
            "manifest allowed_origins drifted from ChromeHostIdentity.extensionID (\(extensionID))"
        )
    }

    // MARK: relay.framing.customMaximumInit

    @Test("no production site passes a custom maximumMessageBytes")
    func framerIsAlwaysConstructedWithTheDefault() throws {
        // The initializer's ONLY validation of the bound is a
        // `precondition(...)` — a fatal trap with no throwable error and no
        // diagnostic line. It is safe today ONLY because every production site
        // constructs the framer with no argument. The day anyone derives the
        // bound from config or a plist, the host process traps at launch.
        var customSites: [String] = []
        var totalSites = 0
        for relativePath in try swiftSources(under: "Sources") {
            for (index, line) in try relaySource(relativePath).enumerated() {
                guard let range = line.range(of: "NativeMessagingFramer(") else { continue }
                totalSites += 1
                if !line[range.upperBound...].hasPrefix(")") {
                    customSites.append(
                        "\(relativePath):\(index + 1) "
                            + line.trimmingCharacters(in: .whitespaces)
                    )
                }
            }
        }
        #expect(
            customSites.isEmpty,
            "custom maximumMessageBytes reaches a fatal precondition: \(customSites)"
        )
        // Sanity: the scan actually found the known construction sites, so an
        // empty result can never come from a broken walker.
        #expect(totalSites >= 2, "expected the relay + app construction sites, found \(totalSites)")
    }
}
