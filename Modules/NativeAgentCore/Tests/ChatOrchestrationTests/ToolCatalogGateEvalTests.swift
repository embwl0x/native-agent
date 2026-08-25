import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import ActivityWatch

// ─────────────────────────────────────────────────────────────────────────────
// EVAL FENCE: core.chat.tools
// Ledger rows closed here:
//   • chat.tools.activityQueryToolNames  (privacy-shaped wrong value)
//   • chat.tools.fullMacSystemToolNames  (dead control — never seen in the live trace)
//
// Both are "catalog and dispatch must agree" rows. A catalog that advertises a
// tool dispatch will refuse teaches the model to keep trying it; a catalog that
// hides a tool dispatch would allow makes her deny a capability she has. For
// activity_query the catalog entry is itself a DISCLOSURE — its presence tells
// the model this Mac records activity — and the toggle is read twice from two
// different places with nothing pinning them together.
// ─────────────────────────────────────────────────────────────────────────────

private func catalogEvalRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToolCatalogGateEval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func writeActivityPolicy(captureEnabled: Bool, allowModelAccess: Bool, dataRoot: URL) throws {
    let url = ActivityWatchPaths.policyURL(dataRoot: dataRoot)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let json = """
    {"captureEnabled": \(captureEnabled), "allowModelAccess": \(allowModelAccess)}
    """
    try Data(json.utf8).write(to: url)
}

private func writeTrustPolicy(_ object: [String: JSONValue], dataRoot: URL) async throws {
    try await SwiftNativePersistenceCore().writeJSON(
        .object(object),
        to: dataRoot.appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
    )
}

// MARK: - chat.tools.activityQueryToolNames

/// All four (captureEnabled × allowModelAccess) combinations, catalog and
/// dispatch read together. Membership must equal `capture && modelAccess` —
/// the AND is the point: capture-on/access-off is a real user state and
/// advertising the tool there would leak that the Mac is recording.
///
/// The dispatch half asserts the refusal is NAMED (it says which toggle), so
/// "capture is off" can never read as "you did nothing today".
@Test func activityQueryTool_catalogAndDispatchAgreeOnAllFourPolicyCombinations() async throws {
    for capture in [false, true] {
        for modelAccess in [false, true] {
            let root = try catalogEvalRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try writeActivityPolicy(captureEnabled: capture, allowModelAccess: modelAccess, dataRoot: root)
            let dispatcher = SwiftToolDispatcher(dataRoot: root)
            let expected = capture && modelAccess

            let names = try await dispatcher.listAvailableTools()
            #expect(
                names.contains("activity_query") == expected,
                "capture=\(capture) modelAccess=\(modelAccess): catalog membership must equal capture AND modelAccess"
            )

            do {
                _ = try await dispatcher.impl_activity_query_tool(
                    tool: "activity_query", input: ["range": .string("today")], surface: "chat"
                )
                #expect(expected, "capture=\(capture) modelAccess=\(modelAccess): dispatch answered a tool the catalog hides")
            } catch {
                let reason = "\(error)"
                if expected {
                    // With both toggles on the query may still fail for
                    // non-policy reasons (an empty span store). What must NOT
                    // happen is a POLICY refusal the catalog disagreed with.
                    #expect(
                        !reason.contains("Activity capture is turned OFF")
                            && !reason.contains("local-only until you enable"),
                        "both toggles are on but dispatch refused on policy: \(reason)"
                    )
                } else {
                    #expect(
                        reason.contains("Activity capture is turned OFF")
                            || reason.contains("local-only until you enable"),
                        "capture=\(capture) modelAccess=\(modelAccess): the refusal must NAME the toggle, got: \(reason)"
                    )
                }
            }

            // The remote-surface refusal is a decision, not a policy read: it
            // fires on every surface profile that is remote, in all four
            // combinations, INCLUDING the fully-enabled one.
            for surface in ["ios", "telegram"] {
                await #expect(
                    throws: (any Error).self,
                    "activity_query must be refused on '\(surface)' regardless of the toggles (capture=\(capture) modelAccess=\(modelAccess))"
                ) {
                    _ = try await dispatcher.impl_activity_query_tool(
                        tool: "activity_query", input: ["range": .string("today")], surface: surface
                    )
                }
            }
        }
    }
}

// MARK: - chat.tools.fullMacSystemToolNames

/// `system_info` / `remote_node_list` have NEVER appeared in the live trace, so
/// a gating regression here would be invisible indefinitely — in either
/// direction. Every layer that has to line up is exercised.
///
/// FOUND WHILE WRITING THIS EVAL, and now pinned: the `system` category is not
/// just a Full Mac category bit. `normalizedTrustPolicy` FORCES
/// `system_control_allowed` (and `shell_allowed`) back to false whenever
/// `developerMode` is off — so a saved policy asking for the system category
/// without the developer-mode escalation is silently overridden at load. That
/// floor had no test; scenario 3 below is it. Remove the override and scenario
/// 3 goes red, which is exactly the widening you would want to hear about.
@Test func fullMacSystemTools_catalogMembershipFlipsExactlyWithTheSystemCategory() async throws {
    let fullMacBase: [String: JSONValue] = [
        "permissionLevel": .string("full_mac_os"),
        "fullMacNeverExpires": .bool(true),
    ]
    func policy(
        master: Bool, systemCategory: Bool, developerMode: Bool
    ) -> [String: JSONValue] {
        fullMacBase.merging([
            "developerMode": .bool(developerMode),
            "macControlPolicy": .object([
                "enabled": .bool(master),
                "system_control_allowed": .bool(systemCategory),
            ]),
        ]) { _, new in new }
    }
    let scenarios: [(name: String, policy: [String: JSONValue]?, expected: Bool)] = [
        ("default hard-OFF policy", nil, false),
        (
            "Full Mac + master gate ON + system category ON + developer mode ON",
            policy(master: true, systemCategory: true, developerMode: true),
            true
        ),
        (
            "system category asked for WITHOUT developer mode (must be forced off at load)",
            policy(master: true, systemCategory: true, developerMode: false),
            false
        ),
        (
            "developer mode ON but system category OFF",
            policy(master: true, systemCategory: false, developerMode: true),
            false
        ),
        (
            "system category ON but master gate OFF",
            policy(master: false, systemCategory: true, developerMode: true),
            false
        ),
    ]

    for scenario in scenarios {
        let root = try catalogEvalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        if let policy = scenario.policy {
            try await writeTrustPolicy(policy, dataRoot: root)
        }
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        let names = Set(try await dispatcher.listAvailableTools())
        let access = await dispatcher.fullMacToolAccess()

        #expect(
            access.systemAllowed == scenario.expected,
            "\(scenario.name): systemAllowed should be \(scenario.expected)"
        )
        for tool in SwiftToolDispatcher.fullMacSystemToolNames {
            #expect(
                names.contains(tool) == scenario.expected,
                "\(scenario.name): '\(tool)' catalog membership should be \(scenario.expected)"
            )
        }

        // Dispatch agrees with the catalog. When the gate is off the refusal
        // must be explicit rather than a silent empty result.
        if !scenario.expected {
            await #expect(
                throws: (any Error).self,
                "\(scenario.name): system_info must refuse when the catalog hides it"
            ) {
                _ = try await dispatcher.impl_local_connector_tool(
                    tool: "system_info", input: [:], surface: "chat"
                )
            }
        }
    }

    // The list itself is small and load-bearing; pin it so an addition is a
    // review trigger rather than a quiet widening of the `system` surface.
    #expect(SwiftToolDispatcher.fullMacSystemToolNames == ["system_info", "remote_node_list"])
}
