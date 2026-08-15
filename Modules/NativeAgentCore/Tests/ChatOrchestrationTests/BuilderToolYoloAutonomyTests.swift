import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import TrustCenter

// MARK: - Full Mac yolo autonomy elevation
//
// the user's call 2026-06-13 (U4 KEY FINDING — confirm-vs-auto posture): when a
// Full Mac (yolo) window is ACTIVE, local/team NativeAgent-native tools resolve
// to autonomy="auto" — no per-call confirm caused by a stale/missing
// toolAutonomy key. Builder tools still prove the sharpest case because they
// spawn processes. Authenticated remote origins share the selected YOLO posture
// only after SecurityCenter proves their allowlist/pairing; an untrusted remote
// surface label never elevates. Outside yolo they stay confirm-class.
// Self-modification tools (self_install/evolution_*) and external account sends
// are deliberately excluded from yolo autonomy.
//
// These tests drive the REAL SwiftNativeTrustCenter.autonomyLevel(forTool:
// surface:) resolution (the full-mac bypass in ChatOrchestration+AutonomyGate),
// not a mock — so they exercise the changed code path end to end.

@Suite("BuilderToolYoloAutonomy")
struct BuilderToolYoloAutonomyTests {

    private let builderTools = [
        "shell", "bash", "git", "apply_patch", "run_tests",
        "swift_build", "swift_test",
    ]

    private func tempRoot(_ tag: String) -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("builder-yolo-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Full Mac ACTIVE, but with the `shell_allowed` category flag explicitly
    /// OFF — proving the builder-auto elevation rides the yolo window ALONE and
    /// is NOT gated on a second toggle (the user: "yolo alone unlocks it").
    private func seedYoloActive_shellFlagOff(_ dataRoot: URL) throws {
        let dir = dataRoot.appendingPathComponent("trust", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let policy: JSONValue = .object([
            "enableAutonomy": .bool(true),
            "permissionLevel": .string("full_mac_os"),
            "fullMacNeverExpires": .bool(true),
            "filePolicy": .object([
                "outsideWorkspaceDefault": .string("allow"),
            ]),
            "macControlPolicy": .object([
                "enabled": .bool(true),
                "file_ops_allowed": .bool(true),
                "shell_allowed": .bool(false),  // <-- deliberately OFF
            ]),
        ])
        try policy.serializedData(pretty: true)
            .write(to: dir.appendingPathComponent("policy.json"))
    }

    /// Full Mac INACTIVE (balanced permission, no yolo window).
    private func seedYoloInactive(_ dataRoot: URL) throws {
        let dir = dataRoot.appendingPathComponent("trust", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let policy: JSONValue = .object([
            "enableAutonomy": .bool(true),
            "permissionLevel": .string("balanced"),
            "filePolicy": .object([
                "outsideWorkspaceDefault": .string("deny"),
            ]),
        ])
        try policy.serializedData(pretty: true)
            .write(to: dir.appendingPathComponent("policy.json"))
    }

    // MARK: builder tools auto IN yolo on the LOCAL chat surface (the feature)

    @Test func builderTools_resolveAuto_whenYoloActive_localChatSurface() async throws {
        let root = tempRoot("on")
        try seedYoloActive_shellFlagOff(root)
        let tc = SwiftNativeTrustCenter(dataRoot: root)
        for tool in builderTools {
            let level = try await tc.autonomyLevel(forTool: tool, surface: "chat")
            #expect(level == "auto", "\(tool) must be auto in an active yolo window on chat (got \(level))")
        }
    }

    @Test func macPrefixedBuilderTool_resolvesAuto_catalogDriftDefense() async throws {
        let root = tempRoot("prefix")
        try seedYoloActive_shellFlagOff(root)
        let tc = SwiftNativeTrustCenter(dataRoot: root)
        // The policy keys use the `mac.` prefix; the model calls the bare name.
        // Both forms must elevate so a catalog rename can't silently re-arm the
        // confirm prompt.
        let level = try await tc.autonomyLevel(forTool: "mac.shell", surface: "chat")
        #expect(level == "auto", "mac.shell must elevate the same as shell (got \(level))")
    }

    @Test func normalNativeTools_resolveAuto_whenYoloActive_localTeamSurfaces() async throws {
        let root = tempRoot("native")
        try seedYoloActive_shellFlagOff(root)
        let tc = SwiftNativeTrustCenter(dataRoot: root)
        for surface in ["chat", "codex-bridge", "claude-bridge", "mission"] {
            for tool in ["restart_app", "install_app", "workshop_submit", "task_ledger_post"] {
                let level = try await tc.autonomyLevel(forTool: tool, surface: surface)
                #expect(level == "auto", "\(tool) must be auto on \(surface) in an active yolo window (got \(level))")
            }
        }
    }

    // MARK: builder tools are auto even OUTSIDE yolo (post-cutover catch-all)

    /// YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
    /// execution ungated. The `toolAutonomy["default"]` catch-all flipped
    /// `send_approval` → `auto`, so a builder tool no longer needs the yolo
    /// window to resolve auto — with no window at all it falls through to the
    /// catch-all and still resolves auto.
    ///
    /// OLD CONTRACT: builder tools were confirm-class without an active yolo
    /// window. NEW CONTRACT: the autonomy layer is not a gate for them at all;
    /// the Trust Center categories, Full Mac and the macOS TCC grant are.
    @Test func builderTools_autoEvenWithYoloInactive_catchAllIsAuto() async throws {
        let root = tempRoot("off")
        try seedYoloInactive(root)
        let tc = SwiftNativeTrustCenter(dataRoot: root)
        for tool in builderTools {
            let level = try await tc.autonomyLevel(forTool: tool, surface: "chat")
            #expect(level == "auto", "\(tool) resolves auto via the catch-all with no yolo window (got \(level))")
        }
        // TEETH: the catch-all is not blanket-auto. The deliberate floors that
        // SURVIVED the cutover still resolve confirm in the same fixture, so
        // this test cannot pass on an "everything is auto" resolver.
        for tool in ["self_install", "evolution_propose", "remote_node_execute"] {
            let level = try await tc.autonomyLevel(forTool: tool, surface: "chat")
            #expect(level == "confirm", "\(tool) keeps its floor post-cutover (got \(level))")
        }
    }

    // MARK: authenticated remote surfaces share yolo; labels alone do not

    @Test func builderTools_resolveAuto_fromTrustedTelegramOriginInYolo() async throws {
        let root = tempRoot("tg")
        try seedYoloActive_shellFlagOff(root)
        let tc = SwiftNativeTrustCenter(dataRoot: root)
        for tool in builderTools {
            let level = try await tc.autonomyLevel(
                forTool: tool,
                surface: "telegram",
                originTrusted: true
            )
            #expect(level == "auto", "\(tool) from trusted telegram must auto in yolo (got \(level))")
        }
    }

    /// YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
    /// execution ungated. An untrusted Telegram LABEL still fails the
    /// `originTrusted` check inside `fullMacPolicyAllows`, so it does not take
    /// the yolo branch — but the per-tool fall-through now lands on the
    /// `default: auto` catch-all, so the resolved level is auto anyway.
    ///
    /// OLD CONTRACT: an unauthenticated remote label was held at confirm by the
    /// autonomy layer. NEW CONTRACT: the autonomy layer no longer discriminates
    /// by origin trust for builder tools — the PERIMETER does. A Telegram sender
    /// who is not in `allowed_chat_ids` / `allowed_user_ids` is dropped in
    /// TelegramPollLoop before any turn runs (not_allowlisted receipt), so no
    /// untrusted sender ever reaches this resolver in production.
    @Test func builderTools_autoFromUntrustedTelegramLabel_perimeterIsTheBoundary() async throws {
        let root = tempRoot("tg-untrusted")
        try seedYoloActive_shellFlagOff(root)
        let tc = SwiftNativeTrustCenter(dataRoot: root)
        for tool in builderTools {
            let level = try await tc.autonomyLevel(
                forTool: tool,
                surface: "telegram",
                originTrusted: false
            )
            #expect(level == "auto", "\(tool) resolves auto via the catch-all (got \(level))")
        }
        // TEETH: origin trust still changes a REAL outcome elsewhere — the
        // deliberate floors do not move for a trusted origin either, and the
        // catch-all is not blanket-auto.
        let remote = try await tc.autonomyLevel(
            forTool: "remote_node_execute", surface: "telegram", originTrusted: false
        )
        #expect(remote == "confirm", "remote effects keep their floor (got \(remote))")
    }

    @Test func appLifecycleTools_resolveAuto_fromAllKnownChatSurfaces_whenYoloActive() async throws {
        let root = tempRoot("chat-surfaces")
        try seedYoloActive_shellFlagOff(root)
        let tc = SwiftNativeTrustCenter(dataRoot: root)
        for surface in ["chat", "codex-bridge", "claude-bridge",
                        "telegram", "ios", "icloud", "iphone", "ipad", "mobile", "watch"] {
            for tool in ["restart_app", "install_app"] {
                let level = try await tc.autonomyLevel(
                    forTool: tool,
                    surface: surface,
                    originTrusted: true
                )
                #expect(level == "auto", "\(tool) from \(surface) must auto in yolo after the surface trust proof (got \(level))")
            }
        }
    }

    @Test func builderTools_resolveAuto_fromTrustedIOSOriginInYolo() async throws {
        let root = tempRoot("ios")
        try seedYoloActive_shellFlagOff(root)
        let tc = SwiftNativeTrustCenter(dataRoot: root)
        let level = try await tc.autonomyLevel(
            forTool: "shell",
            surface: "ios",
            originTrusted: true
        )
        #expect(level == "auto", "shell from a trusted iOS origin must auto in yolo (got \(level))")
    }

    /// YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
    /// execution ungated. An unrecognized surface string still fails
    /// `isYoloEligibleSurface`, so it does not take the yolo branch — and the
    /// per-tool fall-through now lands on `default: auto`.
    ///
    /// OLD CONTRACT: an unknown surface fail-safed to confirm. NEW CONTRACT:
    /// the catch-all is auto; a surface label is not a security boundary at
    /// all, because nothing reaches this resolver that did not already pass the
    /// perimeter (local Mac window, bridge token, or the Telegram allowlist).
    @Test func builderTools_autoFromUnknownSurface_catchAllIsAuto() async throws {
        let root = tempRoot("unknown")
        try seedYoloActive_shellFlagOff(root)
        let tc = SwiftNativeTrustCenter(dataRoot: root)
        let level = try await tc.autonomyLevel(forTool: "shell", surface: "some-future-surface")
        #expect(level == "auto", "shell from an unknown surface resolves auto via the catch-all (got \(level))")
        // TEETH: the surviving floors do not follow it.
        let evo = try await tc.autonomyLevel(forTool: "self_install", surface: "some-future-surface")
        #expect(evo == "confirm", "self_install keeps its floor on any surface (got \(evo))")
    }

    // MARK: the firewall — self-modification tools never elevate

    @Test func evolutionTools_stayNonAuto_evenInYolo() async throws {
        let root = tempRoot("evo")
        try seedYoloActive_shellFlagOff(root)
        let tc = SwiftNativeTrustCenter(dataRoot: root)
        for tool in ["self_install", "evolution_propose", "evolution_status"] {
            let level = try await tc.autonomyLevel(forTool: tool, surface: "chat")
            #expect(level != "auto", "\(tool) must NEVER elevate to auto via the yolo window (got \(level))")
        }
    }

    @Test func remoteNodeExecutionKeepsApprovalFloorEvenInYolo() async throws {
        let root = tempRoot("remote-node")
        try seedYoloActive_shellFlagOff(root)
        let tc = SwiftNativeTrustCenter(dataRoot: root)
        for surface in ["chat", "codex-bridge", "telegram", "ios"] {
            let level = try await tc.autonomyLevel(
                forTool: "remote_node_execute",
                surface: surface,
                originTrusted: true
            )
            #expect(level == "confirm", "remote effects must retain an approval floor on \(surface) (got \(level))")
        }
    }

    @Test func approvalGatedExternalSendTools_stayNonAuto_evenInYolo() async throws {
        let root = tempRoot("send")
        try seedYoloActive_shellFlagOff(root)
        let tc = SwiftNativeTrustCenter(dataRoot: root)
        for tool in [
            "email.send", "gmail.send", "x.post_tweet",
            "slack.post_message", "slack_post_message",
            "agentmail.send", "agentmail_send",
        ] {
            let level = try await tc.autonomyLevel(forTool: tool, surface: "chat")
            #expect(level != "auto", "\(tool) must not become an automatic external send in yolo (got \(level))")
        }
    }

    @Test func slackPostRequiresApprovalByDefaultForBothAliases() async throws {
        let root = tempRoot("slack-send")
        let tc = SwiftNativeTrustCenter(dataRoot: root)
        #expect(try await tc.autonomyLevel(forTool: "slack.post_message", surface: "chat") == "send_approval")
        #expect(try await tc.autonomyLevel(forTool: "slack_post_message", surface: "chat") == "send_approval")
    }

    @Test func agentMailSendRequiresApprovalByDefaultForBothAliases() async throws {
        let root = tempRoot("agentmail-send")
        let tc = SwiftNativeTrustCenter(dataRoot: root)
        #expect(try await tc.autonomyLevel(forTool: "agentmail.send", surface: "chat") == "send_approval")
        #expect(try await tc.autonomyLevel(forTool: "agentmail_send", surface: "chat") == "send_approval")
    }
}
