import Foundation
import Testing
@testable import NativeAgentApp

// evals-total-coverage — fence `app.bridges`. The WIRE VOCABULARY rows: the
// string identifiers two different processes must agree on. Their shared
// silent-failure mode is a two-vocabulary mismatch — one side is renamed, the
// compiler is happy on both sides, and the lane just goes quiet.
//
// Rows: `macsync.remoteMacControl`, `macintegration.icloudProjection` /
// `macIntegration.icloudBridge`, `slack.ignoredEnvelopes`.
@Suite("app.bridges wire vocabulary")
struct BridgeWireVocabularyTests {

    /// Balanced `{...}` body following `marker`. `looseFunctionBody` stops at
    /// `\n    func `/`\n    private func ` only, so it bleeds across a
    /// `private static func` sibling and silently widens a frozen inventory —
    /// exactly how this test first passed the wrong set.
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

    private func captures(_ pattern: String, in source: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
            Range($0.range(at: 1), in: source).map { r in String(source[r]) }
        }
    }

    // MARK: - macsync.remoteMacControl

    /// Row `macsync.remoteMacControl` (MacSyncRemoteMacControl.swift:8 dispatch,
    /// :99 endpoint(for:), :122 requiresFullRemoteMacControl).
    ///
    /// Two frozen inventories in one place because they are two halves of the
    /// same boundary:
    ///  - the method→route map: an unmapped method returns `endpoint == ""`, and
    ///    `dispatch` answers "Unknown mac_control method" — from the phone that
    ///    is indistinguishable from a Mac that is simply not responding;
    ///  - the Full-Mac gated subset: this is the privilege line. A method
    ///    silently leaving this set is a remote filesystem/shell capability
    ///    handed to the phone with no trust check and no visible symptom.
    @Test("the iOS mac_control method map and its Full-Mac gate are frozen")
    func remoteMacControlVocabularyIsFrozen() throws {
        let source = try AppSourceScraping.appSource("MacSyncRemoteMacControl.swift")

        let pairs = try captures(#""([A-Za-z]+)": "(?:/v1/mac_control/[^"]+)""#, in: source)
        let routes = try captures(#""[A-Za-z]+": "(/v1/mac_control/[^"]+)""#, in: source)
        #expect(pairs.count == routes.count)

        let map = Dictionary(uniqueKeysWithValues: zip(pairs, routes))
        let expected: [String: String] = [
            "runAppleScript": "/v1/mac_control/applescript",
            "runJxa": "/v1/mac_control/jxa",
            "runShortcut": "/v1/mac_control/shortcut",
            "runSpotlight": "/v1/mac_control/spotlight",
            "focusApp": "/v1/mac_control/focus_app",
            "quitApp": "/v1/mac_control/quit_app",
            "keystroke": "/v1/mac_control/keystroke",
            "clickAt": "/v1/mac_control/click",
            "system": "/v1/mac_control/system",
            "readFile": "/v1/mac_control/file/read",
            "writeFile": "/v1/mac_control/file/write",
            "listDirectory": "/v1/mac_control/file/list",
            "moveFile": "/v1/mac_control/file/move",
            "trashFile": "/v1/mac_control/file/trash",
            "notify": "/v1/mac_control/notify",
            "runShell": "/v1/mac_control/shell",
            "selfTest": "/v1/mac_control/self_test",
        ]
        #expect(map == expected, "the iOS→Mac mac_control map drifted: \(map)")
        #expect(Set(map.values).count == map.count, "two methods share one route")

        // The privilege line. Frozen in both directions: an ADDED method here
        // is a new gate (fine, but deliberate); a REMOVED one is a capability
        // that just became reachable without Full Mac.
        let gate = try body(after: "func requiresFullRemoteMacControl(", in: source)
        let gated = Set(try captures(#""([A-Za-z]+)""#, in: gate))
        #expect(gated == ["runShell", "readFile", "writeFile", "listDirectory", "moveFile", "trashFile"],
                "the Full-Mac gated method set drifted: \(gated.sorted())")
        for method in gated {
            #expect(map[method] != nil, "\(method) is gated but has no route — a dead gate")
        }

        // Every gated method must be one the trust policy can actually refuse:
        // the gate consults getTrustPolicy and answers with a message, never a
        // silent pass-through.
        let dispatch = try body(after: "func dispatch(", in: source)
        let gateIndex = try #require(dispatch.range(of: "Self.requiresFullRemoteMacControl(method: method)"))
        let runIndex = try #require(dispatch.range(of: "api.macControlRun("))
        #expect(dispatch.distance(from: dispatch.startIndex, to: gateIndex.lowerBound)
                < dispatch.distance(from: dispatch.startIndex, to: runIndex.lowerBound),
                "the Full-Mac check must run BEFORE the request is issued")
        #expect(dispatch.contains("requires Full Mac access with iOS remote enabled"),
                "a refusal must say why, or the phone shows an unexplained failure")
    }

    // MARK: - macintegration.icloudProjection

    /// Rows `macintegration.icloudProjection` + `macIntegration.icloudBridge`.
    /// The Mac WRITES this KVS key and the phone READS it. The two constants
    /// live in different targets that never link against each other, so a
    /// rename on one side compiles cleanly on both and the phone's Mac
    /// Integration screen simply shows stale permissions forever.
    @Test("the Mac and iOS halves of the permission projection use the same KVS key")
    @MainActor
    func macIntegrationProjectionKeyMatchesTheiOSReader() throws {
        #expect(MacIntegrationICloudBridge.kvsKey == "nativeagent.mac_integration_permissions")

        let root = try AppSourceScraping.repositoryRoot()
        let iosFile = root.appendingPathComponent(
            "iOS/NativeAgentMobile/Sources/MacIntegrationPermissionsSync.swift"
        )
        let ios = try String(contentsOf: iosFile, encoding: .utf8)
        let iosKeys = try captures(#"static let kvsKey = "([^"]+)""#, in: ios)
        #expect(iosKeys == [MacIntegrationICloudBridge.kvsKey],
                "the iOS reader is on a different KVS key than the Mac writer: \(iosKeys)")

        // The projection is a PROJECTION: both write paths use the same key and
        // the same {read,write} axis vocabulary the phone decodes.
        let source = try AppSourceScraping.appSource("MacIntegrationICloudBridge.swift")
        #expect(AppSourceScraping.occurrences(of: "forKey: Self.kvsKey", in: source) == 3,
                "a read or write of the projection stopped using the shared key constant")
        for axis in ["\"read\"", "\"write\""] {
            #expect(source.contains(axis), "the projection lost its \(axis) axis")
            #expect(ios.contains(axis), "the iOS decoder lost its \(axis) axis")
        }
    }

    // MARK: - slack.ignoredEnvelopes

    /// Row `slack.ignoredEnvelopes` (SlackSocketModeLoop.swift:1377
    /// recordIgnoredEnvelope, :1410 ignoredEnvelopeDetail).
    ///
    /// Every inbound Slack frame that does NOT become a turn is written to
    /// `data/slack/ignored.jsonl` with a `reason`. That feed is the only way to
    /// tell "Slack is quiet" from "Slack is being dropped on the floor", and
    /// triage reads it by reason string. Rename a reason and every saved query
    /// silently returns zero.
    @Test("the ignored-envelope reason inventory is frozen")
    func ignoredEnvelopeReasonsAreFrozen() throws {
        let source = try AppSourceScraping.appSource("SlackSocketModeLoop.swift")
        let detail = try body(after: "func ignoredEnvelopeDetail(", in: source)
        // Reasons are the FIRST tuple element of every return in the helper.
        let reasons = Set(try captures(#"return \("([a-z_]+)""#, in: detail))
        #expect(reasons == [
            "unsupported_envelope_type",
            "missing_payload",
            "unsupported_payload_type",
            "missing_event",
            "unsupported_event_type",
            "bot_message",
            "self_message",
            "unsupported_message_channel",
            "missing_user",
            "empty_text",
            "missing_channel_or_ts",
            "unknown_filtered",
        ], "the ignored-envelope reason inventory drifted: \(reasons.sorted())")

        // The subtype reason is built, not literal — keep its prefix pinned too.
        #expect(detail.contains("\"message_subtype_\\(subtype)\""),
                "the per-subtype ignore reason lost its stable prefix")

        // The ingress denials share this feed's `reason` column, so their raw
        // values are part of the same vocabulary. These are real enum values,
        // asserted behaviourally rather than scraped.
        #expect(SlackIngressDenial.allowlistEmpty.rawValue == "allowlist_empty_fail_closed")
        #expect(SlackIngressDenial.notAllowlisted.rawValue == "not_allowlisted")
        #expect(SlackIngressDenial.mentionRequired.rawValue == "mention_required")
        // A fail-CLOSED default: an unconfigured allowlist must deny, and the
        // row must say so rather than reading as an ordinary "not allowlisted".
        let unconfigured = SlackIngressPolicy(
            allowedChannelIds: [], allowedUserIds: [], requireMention: false, botUserId: nil
        )
        #expect(unconfigured.isConfigured == false)
        #expect(unconfigured.denial(
            channelId: "C1", userId: "U1", eventType: "message", channelType: "im", rawText: "hi"
        ) == .allowlistEmpty)

        // Every ignore is BOTH a durable row and a state-file breadcrumb; losing
        // either half is how a dark lane starts reading as an idle one.
        let record = try body(after: "func recordIgnoredEnvelope(", in: source)
        #expect(record.contains("ignored.jsonl"))
        #expect(record.contains("lastIgnoredReason"))
        #expect(record.contains("await writeState(statePatch)"))
    }
}
