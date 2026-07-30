import XCTest
@testable import Onboarding
import NativeAgentCore
import PersistenceCore
import Foundation
import Darwin
import NativeAgentTestSupport

final class OnboardingTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("onboarding-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Backwards-compatible alias for tests that conceptually want a personaRoot.
    private func makeTempPersonaRoot() throws -> URL { try makeTempDir() }

    /// Write a profile.json into `<dataRoot>/memory/profile.json`, mirroring the
    /// Python `self.root / 'memory' / 'profile.json'` layout.
    private func writeProfileJSON(under dataRoot: URL, name: String) throws {
        let memDir = dataRoot.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memDir, withIntermediateDirectories: true)
        try Data(#"{"name":"\#(name)"}"#.utf8).write(to: memDir.appendingPathComponent("profile.json"))
    }

    func test_startOnboarding_no_persona_returns_hasExisting_false() async throws {
        let root = try makeTempPersonaRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SwiftNativeOnboardingClient(personaRoot: root, dataRoot: root)
        let result = try await client.startOnboarding()
        XCTAssertTrue(result.ready)
        XCTAssertFalse(result.hasExisting)
        XCTAssertNil(result.currentPersonaName)
        XCTAssertEqual(result.personaTypeOptions.count, 3)
        XCTAssertEqual(result.abilityOverview.count, 6)
    }

    func test_startOnboarding_with_soul_md_and_named_profile() async throws {
        let root = try makeTempPersonaRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# soul".utf8).write(to: root.appendingPathComponent("SOUL.md"))
        try writeProfileJSON(under: root, name: "Agent")
        let client = SwiftNativeOnboardingClient(personaRoot: root, dataRoot: root)
        let result = try await client.startOnboarding()
        XCTAssertTrue(result.hasExisting)
        XCTAssertEqual(result.currentPersonaName, "Agent")
    }

    func test_startOnboarding_with_soul_md_no_profile() async throws {
        let root = try makeTempPersonaRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# soul".utf8).write(to: root.appendingPathComponent("SOUL.md"))
        let client = SwiftNativeOnboardingClient(personaRoot: root, dataRoot: root)
        let result = try await client.startOnboarding()
        XCTAssertTrue(result.hasExisting)
        XCTAssertEqual(result.currentPersonaName, "",
            "preserves retired str(profile.get('name') or '') behavior — missing profile.json collapses to empty string when SOUL exists")
    }

    func test_startOnboarding_recognizes_every_transaction_owned_persona_doc() async throws {
        for document in ["VOICE.md", "GROWTH.md"] {
            let root = try makeTempPersonaRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try Data("# orphan \(document)".utf8).write(
                to: root.appendingPathComponent(document)
            )
            let client = SwiftNativeOnboardingClient(personaRoot: root, dataRoot: root)
            let result = try await client.startOnboarding()
            XCTAssertTrue(result.hasExisting, "\(document) must block a fresh onboarding transaction")
            XCTAssertFalse(result.pendingRecovery)
            XCTAssertTrue(result.resetRequired, "\(document) must expose the backup-preserving reset lane")
        }
    }

    /// Regression pin: profile.json lives under dataRoot/memory, NOT under
    /// personaRoot. The two paths can diverge — Python's `onboarding_start`
    /// reads `self.root / 'memory' / 'profile.json'` (daemon data root) for the
    /// name while `_resolve_persona_root()` determines SOUL.md's location.
    func test_startOnboarding_personaRoot_and_dataRoot_can_diverge() async throws {
        let personaRoot = try makeTempDir()
        let dataRoot = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: personaRoot)
            try? FileManager.default.removeItem(at: dataRoot)
        }
        try Data("# soul".utf8).write(to: personaRoot.appendingPathComponent("SOUL.md"))
        try writeProfileJSON(under: dataRoot, name: "Agent")
        // Sanity: there must be NO profile.json under personaRoot, otherwise a
        // regression that reads <personaRoot>/profile.json could accidentally
        // pass this test.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: personaRoot.appendingPathComponent("profile.json").path),
            "test would not pin the bug if personaRoot also had a profile.json"
        )
        let client = SwiftNativeOnboardingClient(personaRoot: personaRoot, dataRoot: dataRoot)
        let result = try await client.startOnboarding()
        XCTAssertTrue(result.hasExisting)
        XCTAssertEqual(result.currentPersonaName, "Agent",
            "profile.json must be read from dataRoot/memory, NOT from personaRoot")
    }

    func test_persona_type_options_byte_match() {
        let opts = SwiftNativeOnboardingClient.personaTypeOptions
        XCTAssertEqual(opts.count, 3)

        XCTAssertEqual(opts[0].id, "female")
        XCTAssertEqual(opts[0].label, "Female-presenting")
        XCTAssertEqual(opts[0].description, "Warm, observational, judgment-forward.")
        XCTAssertEqual(opts[0].sampleAnchor, "Here's what I actually see.")
        XCTAssertEqual(opts[0].pronouns, "she/her")

        XCTAssertEqual(opts[1].id, "male")
        XCTAssertEqual(opts[1].label, "Male-presenting")
        XCTAssertEqual(opts[1].description, "Direct, dry, holds ground.")
        XCTAssertEqual(opts[1].sampleAnchor, "That's a real one. Worth pausing on.")
        XCTAssertEqual(opts[1].pronouns, "he/him")

        XCTAssertEqual(opts[2].id, "ai")
        XCTAssertEqual(opts[2].label, "AI")
        XCTAssertEqual(opts[2].description, "Gender-neutral, precise, character without performance.")
        XCTAssertEqual(opts[2].sampleAnchor, "Let me be exact about this.")
        XCTAssertEqual(opts[2].pronouns, "they/them")
    }

    func test_ability_overview_byte_match() {
        let overview = SwiftNativeOnboardingClient.abilityOverview
        XCTAssertEqual(overview.count, 6)

        XCTAssertEqual(overview[0].id, "chat")
        XCTAssertEqual(overview[0].title, "Chat with memory")
        XCTAssertEqual(overview[0].detail, "Long-running conversations, recall, corrections, and personality growth.")
        XCTAssertEqual(overview[0].systemImage, "message")

        XCTAssertEqual(overview[1].id, "projects")
        XCTAssertEqual(overview[1].title, "Build with you")
        XCTAssertEqual(overview[1].detail, "Read approved projects, edit files, run tests, and keep receipts when access allows.")
        XCTAssertEqual(overview[1].systemImage, "hammer")

        XCTAssertEqual(overview[2].id, "mac")
        XCTAssertEqual(overview[2].title, "Use Mac actions")
        XCTAssertEqual(overview[2].detail, "Notifications, Spotlight, Shortcuts, files, shell, and app control behind Trust settings.")
        XCTAssertEqual(overview[2].systemImage, "macbook")

        XCTAssertEqual(overview[3].id, "connectors")
        XCTAssertEqual(overview[3].title, "Connect services")
        XCTAssertEqual(overview[3].detail, "Optional providers and connectors for chat models, Telegram, GitHub, email, calendar, and more.")
        XCTAssertEqual(overview[3].systemImage, "point.3.connected.trianglepath.dotted")

        XCTAssertEqual(overview[4].id, "mobile")
        XCTAssertEqual(overview[4].title, "Work from iPhone")
        XCTAssertEqual(overview[4].detail, "Pair the mobile app for chat, approvals, push notifications, inbox, activity, and remote actions.")
        XCTAssertEqual(overview[4].systemImage, "iphone")

        XCTAssertEqual(overview[5].id, "improve")
        XCTAssertEqual(overview[5].title, "Improve safely")
        XCTAssertEqual(overview[5].detail, "Harness checks, evals, incidents, receipts, and gated promotions keep behavior from regressing.")
        XCTAssertEqual(overview[5].systemImage, "checkmark.shield")
    }

    func test_toJSON_round_trip() throws {
        let root = try makeTempPersonaRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = OnboardingStartResult(
            ready: true,
            hasExisting: true,
            currentPersonaName: "Agent",
            personaTypeOptions: SwiftNativeOnboardingClient.personaTypeOptions,
            abilityOverview: SwiftNativeOnboardingClient.abilityOverview
        )
        let json = original.toJSON()
        // Verify snake_case wire keys are present.
        if case .object(let obj) = json {
            XCTAssertNotNil(obj["has_existing"])
            XCTAssertNotNil(obj["current_persona_name"])
            XCTAssertNotNil(obj["persona_type_options"])
            XCTAssertNotNil(obj["ability_overview"])
            XCTAssertNotNil(obj["pending_recovery"])
        } else {
            XCTFail("expected object")
        }
        let parsed = try OnboardingStartResult(from: json)
        XCTAssertEqual(parsed, original)

        // Also verify nil currentPersonaName serializes as JSON null and round-trips.
        let noName = OnboardingStartResult(
            ready: true,
            hasExisting: false,
            currentPersonaName: nil,
            personaTypeOptions: SwiftNativeOnboardingClient.personaTypeOptions,
            abilityOverview: SwiftNativeOnboardingClient.abilityOverview
        )
        let parsedNoName = try OnboardingStartResult(from: noName.toJSON())
        XCTAssertEqual(parsedNoName, noName)
        XCTAssertNil(parsedNoName.currentPersonaName)
    }

    func test_factory_returns_swiftNative() {
        let client = makeOnboardingClient()
        XCTAssertTrue(client is SwiftNativeOnboardingClient,
            "expected SwiftNative, got \(type(of: client))")
    }

    // MARK: - Wave 20: complete + reset coverage

    private func profileJSONURL(under dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("profile.json")
    }

    private func pendingTransactionURL(under dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent(SwiftNativeOnboardingClient.pendingTransactionRelativePath)
    }

    private func pendingResetTransactionURL(under dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent(SwiftNativeOnboardingClient.pendingResetTransactionRelativePath)
    }

    private func resetBackupURLs(under root: URL) throws -> [String: URL] {
        let data = try Data(contentsOf: pendingResetTransactionURL(under: root))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let targets = try XCTUnwrap(json["targets"] as? [[String: Any]])
        return Dictionary(uniqueKeysWithValues: try targets.map { target in
            let role = try XCTUnwrap(target["role"] as? String)
            let fileName = try XCTUnwrap(target["backupFileName"] as? String)
            return (role, root.appendingPathComponent(fileName))
        })
    }

    private func readProfile(under dataRoot: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: profileJSONURL(under: dataRoot))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func test_completeOnboarding_creates_all_four_docs() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SwiftNativeOnboardingClient(personaRoot: root, dataRoot: root)
        let result = try await client.completeOnboarding(
            payload: OnboardingCompletePayload(agentName: "Aria", personaType: "female", userName: "the user")
        )
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.docsWritten, ["SOUL.md", "VOICE.md", "USER.md", "GROWTH.md"])
        for doc in ["SOUL.md", "VOICE.md", "USER.md", "GROWTH.md"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(doc).path),
                "expected \(doc) on disk")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: profileJSONURL(under: root).path),
            "expected profile.json under dataRoot/memory")
    }

    func test_completeOnboarding_refuses_when_SOUL_exists() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# existing".utf8).write(to: root.appendingPathComponent("SOUL.md"))
        let client = SwiftNativeOnboardingClient(personaRoot: root, dataRoot: root)
        let result = try await client.completeOnboarding(
            payload: OnboardingCompletePayload(agentName: "Aria", personaType: "female", userName: "the user")
        )
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.error, "persona_already_exists")
        XCTAssertNotNil(result.detail)
        XCTAssertTrue(result.detail?.contains("/v1/onboarding/reset") ?? false,
            "detail should mention reset path; got \(result.detail ?? "nil")")
        // No new docs.
        for doc in ["VOICE.md", "USER.md", "GROWTH.md"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(doc).path),
                "\(doc) must not be written when SOUL exists")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: profileJSONURL(under: root).path),
            "profile.json must not be written when persona already exists")
    }

    func test_completeOnboarding_rejects_missing_agent_name() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SwiftNativeOnboardingClient(personaRoot: root, dataRoot: root)
        let result = try await client.completeOnboarding(
            payload: OnboardingCompletePayload(agentName: "   ", personaType: "female", userName: "the user")
        )
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.error, "missing_agent_name")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("SOUL.md").path))
    }

    func test_completeOnboarding_rejects_invalid_persona_type() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SwiftNativeOnboardingClient(personaRoot: root, dataRoot: root)
        let result = try await client.completeOnboarding(
            payload: OnboardingCompletePayload(agentName: "Aria", personaType: "robot", userName: "the user")
        )
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.error, "invalid_persona_type")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("SOUL.md").path))
    }

    func test_completeOnboarding_substitutes_placeholders() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SwiftNativeOnboardingClient(personaRoot: root, dataRoot: root)
        let result = try await client.completeOnboarding(
            payload: OnboardingCompletePayload(agentName: "Nova", personaType: "ai", userName: "the user")
        )
        XCTAssertTrue(result.ok)
        let soul = try String(contentsOf: root.appendingPathComponent("SOUL.md"), encoding: .utf8)
        XCTAssertTrue(soul.contains("# Nova Soul"), "SOUL should carry agent name in heading")
        XCTAssertTrue(soul.contains("they/them"), "ai persona should substitute they/them")
        XCTAssertTrue(soul.contains("the user"), "SOUL should reference user name")
        for placeholder in ["{{NAME}}", "{{USER_NAME}}", "{{PRONOUNS}}", "{{PERSONA_TYPE}}", "{{TIMESTAMP}}"] {
            XCTAssertFalse(soul.contains(placeholder), "SOUL still contains unsubstituted \(placeholder)")
        }
    }

    func test_completeOnboarding_growth_md_has_timestamp_and_persona_type() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SwiftNativeOnboardingClient(personaRoot: root, dataRoot: root)
        _ = try await client.completeOnboarding(
            payload: OnboardingCompletePayload(agentName: "Nova", personaType: "ai", userName: "the user")
        )
        let growth = try String(contentsOf: root.appendingPathComponent("GROWTH.md"), encoding: .utf8)
        XCTAssertTrue(growth.contains("baseline · Soul layer initialized for ai persona."),
            "GROWTH should substitute persona_type into baseline line; got: \(growth)")
        XCTAssertFalse(growth.contains("{{TIMESTAMP}}"), "GROWTH still contains {{TIMESTAMP}}")
        // Recognizable ISO-8601-ish timestamp marker (YYYY-MM-DDTHH).
        let regex = try NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2}T"#)
        let range = NSRange(growth.startIndex..., in: growth)
        XCTAssertNotNil(regex.firstMatch(in: growth, range: range),
            "GROWTH should contain ISO-8601 timestamp; got: \(growth)")
    }

    func test_completeOnboarding_writes_profile_json_with_overrides() async throws {
        // female → Female, warmth voice
        do {
            let root = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let client = SwiftNativeOnboardingClient(personaRoot: root, dataRoot: root)
            _ = try await client.completeOnboarding(
                payload: OnboardingCompletePayload(agentName: "Aria", personaType: "female", userName: "the user")
            )
            let profile = try readProfile(under: root)
            XCTAssertEqual(profile["name"] as? String, "Aria")
            XCTAssertEqual(profile["personaKind"] as? String, "Female")
            XCTAssertEqual(profile["voice"] as? String, "Warm, observational, judgment-forward.")
        }
        // ai → AI
        do {
            let root = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let client = SwiftNativeOnboardingClient(personaRoot: root, dataRoot: root)
            _ = try await client.completeOnboarding(
                payload: OnboardingCompletePayload(agentName: "Nova", personaType: "ai", userName: "the user")
            )
            let profile = try readProfile(under: root)
            XCTAssertEqual(profile["personaKind"] as? String, "AI")
            XCTAssertEqual(profile["voice"] as? String, "Precise, characterful, honest.")
        }
        // male → Male
        do {
            let root = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let client = SwiftNativeOnboardingClient(personaRoot: root, dataRoot: root)
            _ = try await client.completeOnboarding(
                payload: OnboardingCompletePayload(agentName: "Atlas", personaType: "male", userName: "the user")
            )
            let profile = try readProfile(under: root)
            XCTAssertEqual(profile["personaKind"] as? String, "Male")
            XCTAssertEqual(profile["voice"] as? String, "Direct, dry, holds ground.")
        }
    }

    func test_completeOnboarding_trims_userName_defaults_to_User() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SwiftNativeOnboardingClient(personaRoot: root, dataRoot: root)
        let result = try await client.completeOnboarding(
            payload: OnboardingCompletePayload(agentName: "Aria", personaType: "female", userName: "   ")
        )
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.userName, "User")
        let soul = try String(contentsOf: root.appendingPathComponent("SOUL.md"), encoding: .utf8)
        let user = try String(contentsOf: root.appendingPathComponent("USER.md"), encoding: .utf8)
        XCTAssertTrue(soul.contains("User"), "SOUL should fall back to literal 'User' for empty user name")
        XCTAssertTrue(user.contains("User"), "USER should fall back to literal 'User' for empty user name")
    }

    func test_completeOnboarding_resumes_exact_transaction_after_failure_and_restart() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = OnboardingCompletePayload(agentName: "Aria", personaType: "female", userName: "User")
        let interrupted = SwiftNativeOnboardingClient(
            personaRoot: root,
            dataRoot: root,
            failureInjector: { step in
                if step == .soulCommitted { throw OnboardingError.ioFailure("injected after SOUL") }
            }
        )

        do {
            _ = try await interrupted.completeOnboarding(payload: payload)
            XCTFail("injected failure should interrupt onboarding")
        } catch let error as OnboardingError {
            XCTAssertTrue(error.errorDescription?.contains("injected after SOUL") == true)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("SOUL.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("VOICE.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".onboarded").path),
            "completion sentinel must remain absent while any target is uncommitted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingTransactionURL(under: root).path))
        let manifestData = try Data(contentsOf: pendingTransactionURL(under: root))
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        XCTAssertEqual((manifest["identityHash"] as? String)?.count, 64)
        let targetEvidence = try XCTUnwrap(manifest["targets"] as? [[String: Any]])
        XCTAssertEqual(targetEvidence.count, 6)
        XCTAssertTrue(targetEvidence.allSatisfy { (($0["sha256"] as? String)?.count ?? 0) == 64 })

        let restarted = SwiftNativeOnboardingClient(personaRoot: root, dataRoot: root)
        let start = try await restarted.startOnboarding()
        XCTAssertTrue(start.hasExisting, "older callers must remain fail-closed around a partial persona")
        XCTAssertTrue(start.pendingRecovery, "new callers must see the resumable transaction explicitly")
        XCTAssertEqual(start.currentPersonaName, "Aria")

        let wrongIdentity = try await restarted.completeOnboarding(
            payload: OnboardingCompletePayload(agentName: "Bret", personaType: "male", userName: "User")
        )
        XCTAssertFalse(wrongIdentity.ok)
        XCTAssertEqual(wrongIdentity.error, "onboarding_in_progress")

        let resumed = try await restarted.resumePendingOnboarding()
        XCTAssertTrue(resumed.ok)
        for doc in ["SOUL.md", "VOICE.md", "USER.md", "GROWTH.md"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(doc).path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: profileJSONURL(under: root).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".onboarded").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingTransactionURL(under: root).path),
            "manifest clears only after the final completion marker is durable")
    }

    func test_completeOnboarding_recovery_rejects_changed_target_and_preserves_bytes() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = OnboardingCompletePayload(agentName: "Aria", personaType: "female", userName: "User")
        let interrupted = SwiftNativeOnboardingClient(
            personaRoot: root,
            dataRoot: root,
            failureInjector: { step in
                if step == .soulCommitted { throw OnboardingError.ioFailure("injected") }
            }
        )
        do {
            _ = try await interrupted.completeOnboarding(payload: payload)
            XCTFail("injected failure should interrupt onboarding")
        } catch {}

        let soulURL = root.appendingPathComponent("SOUL.md")
        let changed = "# independently changed soul\n"
        try Data(changed.utf8).write(to: soulURL)
        let restarted = SwiftNativeOnboardingClient(personaRoot: root, dataRoot: root)
        do {
            _ = try await restarted.completeOnboarding(payload: payload)
            XCTFail("recovery must not adopt or overwrite changed target bytes")
        } catch let error as OnboardingError {
            XCTAssertTrue(error.errorDescription?.contains("changed outside") == true)
        }
        XCTAssertEqual(try String(contentsOf: soulURL, encoding: .utf8), changed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingTransactionURL(under: root).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".onboarded").path))
    }

    func test_completeOnboarding_does_not_publish_sentinel_when_profile_was_last_committed_step() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = OnboardingCompletePayload(agentName: "Aria", personaType: "female", userName: "User")
        let interrupted = SwiftNativeOnboardingClient(
            personaRoot: root,
            dataRoot: root,
            failureInjector: { step in
                if step == .profileCommitted { throw OnboardingError.ioFailure("injected before sentinel") }
            }
        )
        do {
            _ = try await interrupted.completeOnboarding(payload: payload)
            XCTFail("injected failure should interrupt onboarding")
        } catch {}
        for doc in ["SOUL.md", "VOICE.md", "USER.md", "GROWTH.md"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(doc).path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: profileJSONURL(under: root).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".onboarded").path),
            "the marker must be a final commit, never a best-effort side effect")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingTransactionURL(under: root).path))

        let restarted = SwiftNativeOnboardingClient(personaRoot: root, dataRoot: root)
        let resumed = try await restarted.completeOnboarding(payload: payload)
        XCTAssertTrue(resumed.ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".onboarded").path))
    }

    func test_completeOnboarding_malformed_existing_profile_fails_closed_without_writes() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let profileURL = profileJSONURL(under: root)
        try FileManager.default.createDirectory(at: profileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let malformed = Data("{not valid json".utf8)
        try malformed.write(to: profileURL)
        let client = SwiftNativeOnboardingClient(personaRoot: root, dataRoot: root)

        do {
            _ = try await client.completeOnboarding(
                payload: OnboardingCompletePayload(agentName: "Aria", personaType: "female", userName: "User")
            )
            XCTFail("malformed existing profile must fail closed")
        } catch let error as OnboardingError {
            XCTAssertTrue(error.errorDescription?.contains("malformed") == true)
        }
        XCTAssertEqual(try Data(contentsOf: profileURL), malformed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("SOUL.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingTransactionURL(under: root).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".onboarded").path))
    }

    func test_resetOnboarding_clears_pending_transaction_before_reporting_ready() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let interrupted = SwiftNativeOnboardingClient(
            personaRoot: root,
            dataRoot: root,
            failureInjector: { step in
                if step == .soulCommitted { throw OnboardingError.ioFailure("injected") }
            }
        )
        do {
            _ = try await interrupted.completeOnboarding(
                payload: OnboardingCompletePayload(agentName: "Aria", personaType: "female", userName: "User")
            )
            XCTFail("injected failure should interrupt onboarding")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingTransactionURL(under: root).path))

        let restarted = SwiftNativeOnboardingClient(personaRoot: root, dataRoot: root)
        let reset = try await restarted.resetOnboarding(confirm: true)
        XCTAssertTrue(reset.ok)
        XCTAssertTrue(reset.readyForOnboarding)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingTransactionURL(under: root).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".onboarded").path))
        let start = try await restarted.startOnboarding()
        XCTAssertFalse(start.hasExisting)
        XCTAssertFalse(start.pendingRecovery)
    }

    func test_resetOnboarding_resumes_after_mid_reset_failure_and_exposes_ready_start_state() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let soulBytes = Data([0x23, 0x20, 0x73, 0x6f, 0x75, 0x6c, 0x0a, 0xff])
        let voiceBytes = Data("# exact voice\n".utf8)
        try soulBytes.write(to: root.appendingPathComponent("SOUL.md"))
        try voiceBytes.write(to: root.appendingPathComponent("VOICE.md"))
        let sentinel = root.appendingPathComponent(".onboarded")
        try Data("completed_at=test\n".utf8).write(to: sentinel)
        let completion = pendingTransactionURL(under: root)
        try FileManager.default.createDirectory(
            at: completion.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let completionBytes = Data("pending completion bytes".utf8)
        try completionBytes.write(to: completion)

        let interrupted = SwiftNativeOnboardingClient(
            personaRoot: root,
            dataRoot: root,
            failureInjector: { step in
                if step == .resetSourceRemoved("soul") {
                    throw OnboardingError.ioFailure("injected after first reset source")
                }
            }
        )
        do {
            _ = try await interrupted.resetOnboarding(confirm: true)
            XCTFail("injected reset failure should escape")
        } catch let error as OnboardingError {
            XCTAssertTrue(error.errorDescription?.contains("injected after first reset source") == true)
        }

        let backups = try resetBackupURLs(under: root)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(backups["soul"])), soulBytes)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(backups["voice"])), voiceBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("SOUL.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("VOICE.md").path))
        XCTAssertEqual(try Data(contentsOf: completion), completionBytes,
            "completion intent must remain until every source has been backed up and removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path),
            "completion sentinel must remain until every source has been backed up and removed")

        // A plain start read after process restart reconciles the exact reset
        // manifest before exposing state to the wizard.
        let restarted = SwiftNativeOnboardingClient(personaRoot: root, dataRoot: root)
        let start = try await restarted.startOnboarding()
        XCTAssertFalse(start.hasExisting)
        XCTAssertFalse(start.pendingRecovery)
        XCTAssertFalse(start.resetRequired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: completion.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingResetTransactionURL(under: root).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("VOICE.md").path))
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(backups["soul"])), soulBytes)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(backups["voice"])), voiceBytes)
    }

    func test_resetOnboarding_changed_source_fails_closed_and_preserves_exact_backup() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data("# original soul\n".utf8)
        let changed = Data("# user changed soul while reset was interrupted\n".utf8)
        let soul = root.appendingPathComponent("SOUL.md")
        try original.write(to: soul)
        let sentinel = root.appendingPathComponent(".onboarded")
        try Data("completed_at=test\n".utf8).write(to: sentinel)

        let interrupted = SwiftNativeOnboardingClient(
            personaRoot: root,
            dataRoot: root,
            failureInjector: { step in
                if step == .resetBackupsCommitted {
                    throw OnboardingError.ioFailure("injected before source cleanup")
                }
            }
        )
        do {
            _ = try await interrupted.resetOnboarding(confirm: true)
            XCTFail("injected reset failure should escape")
        } catch {}
        let backup = try XCTUnwrap(resetBackupURLs(under: root)["soul"])
        XCTAssertEqual(try Data(contentsOf: backup), original)
        try changed.write(to: soul)

        let restarted = SwiftNativeOnboardingClient(personaRoot: root, dataRoot: root)
        do {
            _ = try await restarted.resetOnboarding(confirm: true)
            XCTFail("a source changed outside the reset transaction must fail closed")
        } catch let error as OnboardingError {
            XCTAssertTrue(error.errorDescription?.contains("changed outside") == true)
        }
        XCTAssertEqual(try Data(contentsOf: soul), changed)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingResetTransactionURL(under: root).path))
    }

    func test_resetOnboarding_requires_confirm() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# soul".utf8).write(to: root.appendingPathComponent("SOUL.md"))
        let client = SwiftNativeOnboardingClient(personaRoot: root, dataRoot: root)
        let result = try await client.resetOnboarding(confirm: false)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.error, "confirmation_required")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("SOUL.md").path),
            "no-confirm reset must not move files")
    }

    func test_resetOnboarding_backs_up_existing_docs() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let soulContent = "# soul body"
        let voiceContent = "# voice body"
        let agentsContent = "# agents body"
        try Data(soulContent.utf8).write(to: root.appendingPathComponent("SOUL.md"))
        try Data(voiceContent.utf8).write(to: root.appendingPathComponent("VOICE.md"))
        try Data(agentsContent.utf8).write(to: root.appendingPathComponent("AGENTS.md"))
        let client = SwiftNativeOnboardingClient(personaRoot: root, dataRoot: root)
        let result = try await client.resetOnboarding(confirm: true)
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.readyForOnboarding)
        XCTAssertEqual(result.backedUp.count, 3, "expected 3 backups; got \(result.backedUp)")
        for path in result.backedUp {
            XCTAssertTrue(path.contains(".pre-reset-"), "backup name pattern: \(path)")
            XCTAssertTrue(path.hasSuffix(".bak"), "backup suffix: \(path)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "backup must exist: \(path)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("SOUL.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("VOICE.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("AGENTS.md").path))
        // Content preserved in backups.
        let expectedByOriginal: [String: String] = [
            "SOUL.md": soulContent,
            "VOICE.md": voiceContent,
            "AGENTS.md": agentsContent,
        ]
        for path in result.backedUp {
            let base = (path as NSString).lastPathComponent
            // base looks like "SOUL.md.pre-reset-<stamp>.bak"
            let prefix = base.components(separatedBy: ".pre-reset-").first ?? ""
            guard let expected = expectedByOriginal[prefix] else {
                XCTFail("unexpected backup base: \(base)")
                continue
            }
            let body = try String(contentsOfFile: path, encoding: .utf8)
            XCTAssertEqual(body, expected, "backup body mismatch for \(prefix)")
        }
    }

    func test_resetOnboarding_handles_empty_dir() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SwiftNativeOnboardingClient(personaRoot: root, dataRoot: root)
        let result = try await client.resetOnboarding(confirm: true)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.backedUp, [])
        XCTAssertTrue(result.readyForOnboarding)
        XCTAssertNil(result.error)
    }

    func test_resetOnboarding_then_complete_round_trip() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SwiftNativeOnboardingClient(personaRoot: root, dataRoot: root)
        let first = try await client.completeOnboarding(
            payload: OnboardingCompletePayload(agentName: "X", personaType: "female", userName: "the user")
        )
        XCTAssertTrue(first.ok)
        // Sleep 1 second so reset's UTC stamp (second-precision) differs from a
        // potential collision — not strictly necessary, but keeps the backup
        // name unique if other tests run nearby.
        let reset = try await client.resetOnboarding(confirm: true)
        XCTAssertTrue(reset.ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("SOUL.md").path))
        let second = try await client.completeOnboarding(
            payload: OnboardingCompletePayload(agentName: "Y", personaType: "male", userName: "the user")
        )
        XCTAssertTrue(second.ok, "second onboard must succeed after reset; got \(second)")
        let soul = try String(contentsOf: root.appendingPathComponent("SOUL.md"), encoding: .utf8)
        XCTAssertTrue(soul.contains("# Y Soul"), "post-reset onboard should produce Y's SOUL; got: \(soul.prefix(60))")
    }

    func test_OnboardingCompleteResult_toJSON_success_round_trip() throws {
        let original = OnboardingCompleteResult(
            ok: true,
            agentName: "Aria",
            personaType: "female",
            userName: "the user",
            docsWritten: ["SOUL.md", "VOICE.md", "USER.md", "GROWTH.md"]
        )
        let json = original.toJSON()
        if case .object(let obj) = json {
            XCTAssertNotNil(obj["docs_written"])
            XCTAssertNotNil(obj["agent_name"])
            XCTAssertNotNil(obj["persona_type"])
            XCTAssertNotNil(obj["user_name"])
            if case .bool(let b) = obj["ok"] ?? .null { XCTAssertTrue(b) } else { XCTFail("ok must be true") }
        } else {
            XCTFail("expected object")
        }
        let parsed = try OnboardingCompleteResult(from: json)
        XCTAssertEqual(parsed, original)
    }

    func test_OnboardingCompleteResult_toJSON_error_round_trip() throws {
        let original = OnboardingCompleteResult(
            ok: false,
            error: "persona_already_exists",
            detail: "SOUL.md already exists. Use POST /v1/onboarding/reset first."
        )
        let json = original.toJSON()
        if case .object(let obj) = json {
            XCTAssertNil(obj["ok"], "error path must not carry ok=true key")
            XCTAssertNotNil(obj["error"])
            XCTAssertNotNil(obj["detail"])
        } else {
            XCTFail("expected object")
        }
        let parsed = try OnboardingCompleteResult(from: json)
        XCTAssertEqual(parsed, original)
    }

    func test_OnboardingResetResult_toJSON_round_trip() throws {
        // Success path.
        let ok = OnboardingResetResult(
            ok: true,
            backedUp: ["/tmp/x/SOUL.md.pre-reset-20260601T000000Z.bak"],
            readyForOnboarding: true
        )
        let okJSON = ok.toJSON()
        if case .object(let obj) = okJSON {
            XCTAssertNotNil(obj["backed_up"])
            XCTAssertNotNil(obj["ready_for_onboarding"])
        } else {
            XCTFail("expected object")
        }
        let parsedOK = try OnboardingResetResult(from: okJSON)
        XCTAssertEqual(parsedOK, ok)

        // Error path.
        let err = OnboardingResetResult(ok: false, error: "confirmation_required")
        let errJSON = err.toJSON()
        let parsedErr = try OnboardingResetResult(from: errJSON)
        XCTAssertEqual(parsedErr, err)
    }

    func test_PersonaTemplates_generate_rejects_invalid_type() {
        XCTAssertThrowsError(try PersonaTemplates.generate(name: "X", personaType: "robot", userName: "Y")) { error in
            guard let e = error as? OnboardingError else {
                XCTFail("expected OnboardingError; got \(error)")
                return
            }
            if case .ioFailure = e { } else {
                XCTFail("expected .ioFailure; got \(e)")
            }
        }
    }

    func test_PersonaTemplates_generate_all_three_types_produce_distinct_soul() throws {
        let female = try PersonaTemplates.generate(name: "X", personaType: "female", userName: "Y")
        let male = try PersonaTemplates.generate(name: "X", personaType: "male", userName: "Y")
        let ai = try PersonaTemplates.generate(name: "X", personaType: "ai", userName: "Y")
        XCTAssertNotEqual(female.soul, male.soul)
        XCTAssertNotEqual(male.soul, ai.soul)
        XCTAssertNotEqual(female.soul, ai.soul)
    }

    // MARK: - WAVE 34 W02: concurrent-writer flock coverage
    //
    // The Swift onboarding write path (completeOnboarding's 5 doc/profile
    // writes + resetOnboarding's renames) was the third RESIDUAL unlocked
    // persona writer (CUTOVER §6.96 prereq-A-residual). Each write is now held
    // under `withFileLock(<target>)` on the SAME `<path>.lock` file other
    // native writers use. These tests pin that
    // the lock is actually taken on the per-target lock file so a concurrent
    // writer cannot tear the onboarding write.

    private struct HeldExternalFlock {
        let child: NativeAgentFlockChild
        let releaseURL: URL

        func releaseAndWait() {
            try? Data("release".utf8).write(to: releaseURL)
            if child.wait(timeout: 3.0) == nil {
                // A helper that never observed the release file means the
                // release protocol is broken — killing it would drop the lock
                // and let the blocking assertions pass vacuously. Fail LOUDLY,
                // then still reap so nothing leaks.
                XCTFail("external flock helper did not exit within 3s of the release request — release protocol broken; terminating")
                child.terminate()
            }
        }
    }

    /// Holds an external flock on `<target>.lock` until `releaseAndWait()` is
    /// called. Uses the same sibling `<path>.lock`, `flock(LOCK_EX)` convention
    /// as the app's cross-process writers.
    private func holdExternalFlock(on target: URL) throws -> HeldExternalFlock {
        let lockPath = target.path + ".lock"
        let lockDir = (lockPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: lockDir, withIntermediateDirectories: true)
        let markerBase = URL(fileURLWithPath: lockDir)
            .appendingPathComponent("\(target.lastPathComponent).\(UUID().uuidString)")
        let acquiredURL = markerBase.appendingPathExtension("acquired")
        let releaseURL = markerBase.appendingPathExtension("release")
        let child = try NativeAgentFlockChild.hold(
            lockPath: lockPath,
            acquiredMarker: acquiredURL,
            releaseRequest: releaseURL
        )
        if !NativeAgentFlockChild.waitForFile(acquiredURL, timeout: 10.0) {
            try? Data("release".utf8).write(to: releaseURL)
            child.terminate()
            throw NSError(
                domain: "OnboardingTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "external holder failed to acquire \(target.lastPathComponent).lock"]
            )
        }
        return HeldExternalFlock(child: child, releaseURL: releaseURL)
    }

    func test_completeOnboarding_blocks_on_concurrent_SOUL_flock() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let soulURL = root.appendingPathComponent("SOUL.md")

        // A concurrent writer holds SOUL.md's lock. completeOnboarding
        // writes SOUL.md FIRST (order: SOUL, VOICE, USER, GROWTH, profile.json),
        // so its first locked write must block until the external holder releases.
        let holder = try holdExternalFlock(on: soulURL)
        defer { holder.releaseAndWait() }

        let client = SwiftNativeOnboardingClient(personaRoot: root, dataRoot: root)
        let finishedURL = root.appendingPathComponent("complete-finished")
        let task = Task {
            let result = try await client.completeOnboarding(
                payload: OnboardingCompletePayload(agentName: "Aria", personaType: "female", userName: "the user")
            )
            try Data("done".utf8).write(to: finishedURL)
            return result
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finishedURL.path),
            "completeOnboarding finished while SOUL.md.lock was still held")

        holder.releaseAndWait()
        let result = try await task.value

        XCTAssertTrue(result.ok, "onboarding should succeed once the lock is released")
        // The onboarding-written SOUL must be intact (not torn / not the empty
        // file the daemon writer would have left).
        let soul = try String(contentsOf: soulURL, encoding: .utf8)
        XCTAssertTrue(soul.contains("Aria"), "SOUL.md missing onboarding content: \(soul.prefix(80))")
    }

    func test_resetOnboarding_blocks_on_concurrent_SOUL_flock() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let soulURL = root.appendingPathComponent("SOUL.md")
        // Seed all five reset-managed docs.
        for doc in ["SOUL.md", "VOICE.md", "USER.md", "GROWTH.md", "AGENTS.md"] {
            try Data("# \(doc) body".utf8).write(to: root.appendingPathComponent(doc))
        }

        // Hold SOUL.md's lock; reset renames SOUL.md first and must wait.
        let holder = try holdExternalFlock(on: soulURL)
        defer { holder.releaseAndWait() }

        let client = SwiftNativeOnboardingClient(personaRoot: root, dataRoot: root)
        let finishedURL = root.appendingPathComponent("reset-finished")
        let task = Task {
            let result = try await client.resetOnboarding(confirm: true)
            try Data("done".utf8).write(to: finishedURL)
            return result
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finishedURL.path),
            "resetOnboarding finished while SOUL.md.lock was still held")

        holder.releaseAndWait()
        let result = try await task.value

        XCTAssertTrue(result.ok)
        // SOUL.md must have been moved to a .bak (rename completed after the lock).
        XCTAssertFalse(FileManager.default.fileExists(atPath: soulURL.path),
            "SOUL.md should have been renamed to its .bak")
        XCTAssertTrue(result.backedUp.contains { $0.contains("SOUL.md.pre-reset-") },
            "expected SOUL.md backup in \(result.backedUp)")
    }

    /// profile.json is the LAST write in completeOnboarding. Holding its lock
    /// proves the profile write specifically is flocked (the doc writes finish
    /// first, then completeOnboarding must block on profile.json.lock).
    func test_completeOnboarding_blocks_on_concurrent_profile_flock() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let profileURL = profileJSONURL(under: root)

        let holder = try holdExternalFlock(on: profileURL)
        defer { holder.releaseAndWait() }

        let client = SwiftNativeOnboardingClient(personaRoot: root, dataRoot: root)
        let finishedURL = root.appendingPathComponent("profile-complete-finished")
        let task = Task {
            let result = try await client.completeOnboarding(
                payload: OnboardingCompletePayload(agentName: "Aria", personaType: "ai", userName: "the user")
            )
            try Data("done".utf8).write(to: finishedURL)
            return result
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finishedURL.path),
            "completeOnboarding finished while profile.json.lock was still held")

        holder.releaseAndWait()
        let result = try await task.value

        XCTAssertTrue(result.ok)
        let profile = try readProfile(under: root)
        XCTAssertEqual(profile["name"] as? String, "Aria")
    }

    // MARK: - WAVE 36 W07 (§6.138): completeOnboarding TOCTOU regression
    //
    // §6.137 #7: the SOUL.md existence check ran OUTSIDE the flock, then the
    // SOUL.md write ran inside it. Two concurrent onboarders could both pass the
    // unlocked check and both run the full generate→write→profile pipeline, the
    // loser clobbering the winner's persona + double-writing profile.json. The
    // fix re-checks existence INSIDE SOUL.md's flock. This test races two
    // onboarders against a SHARED persona root and pins: exactly one wins
    // (ok=true), exactly one is rejected (persona_already_exists), and the
    // surviving SOUL.md belongs to the winner intact (not torn / not the loser's).

    func test_completeOnboarding_concurrent_calls_only_one_wins() async throws {
        // Run several races; the TOCTOU window is timing-dependent, so repeating
        // shrinks the chance a single scheduling order masks a regression.
        for trial in 0..<8 {
            let root = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            // Two clients sharing ONE persona root model two concurrent callers
            // of the sole live onboarding write path.
            let clientA = SwiftNativeOnboardingClient(personaRoot: root, dataRoot: root)
            let clientB = SwiftNativeOnboardingClient(personaRoot: root, dataRoot: root)

            async let a = clientA.completeOnboarding(
                payload: OnboardingCompletePayload(agentName: "Aria", personaType: "female", userName: "the user"))
            async let b = clientB.completeOnboarding(
                payload: OnboardingCompletePayload(agentName: "Bret", personaType: "male", userName: "the user"))
            let results = try await [a, b]

            let oks = results.filter { $0.ok }
            let rejects = results.filter { !$0.ok }
            XCTAssertEqual(oks.count, 1,
                "trial \(trial): exactly one concurrent onboarder must win; got \(results.map { ($0.ok, $0.error ?? "") })")
            XCTAssertEqual(rejects.count, 1,
                "trial \(trial): exactly one concurrent onboarder must be rejected; got \(results.map { ($0.ok, $0.error ?? "") })")
            XCTAssertEqual(rejects.first?.error, "persona_already_exists",
                "trial \(trial): the loser must be rejected with persona_already_exists; got \(rejects.first?.error ?? "nil")")

            // SOUL.md must be intact and belong to the winner — not a torn write
            // and not a clobber that left the loser's content.
            let winnerName = oks.first?.agentName ?? ""
            XCTAssertFalse(winnerName.isEmpty, "trial \(trial): winner must report an agentName")
            let soul = try String(contentsOf: root.appendingPathComponent("SOUL.md"), encoding: .utf8)
            XCTAssertTrue(soul.contains("# \(winnerName) Soul"),
                "trial \(trial): SOUL.md must hold the winner (\(winnerName)) intact; got: \(soul.prefix(80))")
            // profile.json must name the winner (not double-written by the loser).
            let profile = try readProfile(under: root)
            XCTAssertEqual(profile["name"] as? String, winnerName,
                "trial \(trial): profile.json must name the winning onboarder, not be clobbered by the loser")
        }
    }
}
