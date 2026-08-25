import Testing
import Foundation
@testable import TrustCenter

// Eval coverage ledger — fence core.trust
//   • core.trust.securityPolicy.securityCenterEnabled
//   • core.trust.securityPolicy.remoteHighRiskDefault
//   • core.trust.policy.toolPolicy
//   • core.trust.policy.mcpPolicy
//   • core.trust.policy.skillBuilderPolicy
//   • core.trust.trustCenter.protocolFacade
//   • core.trust.trustCenter.simulateTrust
//   • core.trust.trustCenter.getAutonomyPolicy
//
// A REACHABILITY GUARD, not a behaviour test. Every entry below is a policy key
// or a public API that LOOKS live — it is defined in the default policy, decoded
// for display, advertised by name in a lane's `policyGate`, or exported as a
// protocol — and is read by NOTHING in production. A dead gate is worse than no
// gate: "riskyToolApproval: deny" renders as a live setting while gating
// nothing, and `getAutonomyPolicy()` carries a Full-Mac definition that IGNORES
// expiry, so anything that ever wires it up reports an active grant on a lapsed
// one.
//
// The guard is a set EQUALITY, so it bites in both directions:
//   • a NEW dead key/API appears        -> red (add the eval, not the allowlist)
//   • a listed one becomes reachable    -> red (wire-up landed; audit the
//     divergence, drop the entry, flip the ledger row)
//
// It reads SOURCE TEXT because these members are unreachable BY DEFINITION —
// no symbol-level test can observe a call site that does not exist. Comment
// lines are stripped so a doc-comment mention never counts as a read.

private enum TrustSourceScan {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // TrustCenterTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // NativeAgentCore
        .deletingLastPathComponent()   // Modules
        .deletingLastPathComponent()   // repo root

    /// Production source trees only — never Tests/, never script/.
    static let searchRoots = [
        "Sources",
        "Modules/NativeAgentCore/Sources",
        "Modules/NativeAgentShared/Sources",
        "iOS",
    ]

    /// The two files that DEFINE the policy shape. A key appearing only here is
    /// declared, never consulted — which is exactly what we are measuring.
    static let declarationOnlyFiles = [
        "Modules/NativeAgentCore/Sources/TrustCenter/TrustCenter+Defaults.swift",
        "Modules/NativeAgentCore/Sources/TrustCenter/TrustCenter+PolicyLoading.swift",
    ]

    /// The file that DEFINES the trust-center facade. Same reasoning.
    static let facadeDefinitionFile =
        "Modules/NativeAgentCore/Sources/TrustCenter/TrustCenter.swift"

    /// Every production .swift file, keyed by repo-relative path, with `//`
    /// line comments stripped.
    static let codeByPath: [String: String] = {
        var out: [String: String] = [:]
        let fm = FileManager.default
        for relativeRoot in searchRoots {
            let root = repoRoot.appendingPathComponent(relativeRoot)
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
                continue
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let relative = url.path.replacingOccurrences(
                    of: repoRoot.path + "/", with: "")
                out[relative] = stripLineComments(text)
            }
        }
        return out
    }()

    static func stripLineComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
                return trimmed.hasPrefix("//") ? "" : line
            }
            .joined(separator: "\n")
    }

    /// Files (repo-relative) containing `needle`, excluding `ignoring`.
    static func sites(of needle: String, ignoring: [String] = []) -> [String] {
        codeByPath
            .filter { !ignoring.contains($0.key) && $0.value.contains(needle) }
            .keys
            .sorted()
    }
}

/// Vacuity guard: if the scan finds no files (a moved tree, a bad relative path)
/// every "no read sites" assertion below passes trivially.
@Test func TrustPolicyReachability_scannerSeesTheProductionTree() {
    #expect(TrustSourceScan.codeByPath.count > 300,
            "the source scan found only \(TrustSourceScan.codeByPath.count) swift files — the reachability guard would pass vacuously")
    // Positive controls: things that ARE wired, proving the scan reaches both
    // the Mac app tree and the core module tree.
    #expect(!TrustSourceScan.sites(of: "SwiftNativeSecurityCenter").filter {
        $0.hasPrefix("Sources/")
    }.isEmpty, "the scan cannot see the Mac app tree")
    #expect(TrustSourceScan.sites(
        of: "\"killSwitchEnabled\"",
        ignoring: TrustSourceScan.declarationOnlyFiles).count >= 1,
            "a known-live security key reports zero read sites — the scan is broken")
    #expect(TrustSourceScan.sites(
        of: "\"originTrustEnabled\"",
        ignoring: TrustSourceScan.declarationOnlyFiles).count >= 1)
    #expect(TrustSourceScan.sites(
        of: "\"toolSigningRequired\"",
        ignoring: TrustSourceScan.declarationOnlyFiles).count >= 1)
}

/// Policy keys with ZERO production read sites, dated 2026-08-23.
/// Burn this down; never grow it without a ledger row and a reason.
private let inertPolicyKeys: Set<String> = [
    "\"securityCenterEnabled\"",
    "\"remoteHighRiskDefault\"",
    "\"autoPromoteSafeTools\"",
    "\"autoRunSafeTools\"",
    "\"riskyToolApproval\"",
    "\"allow_lifecycle_ops\"",
    "\"allow_ui_panels\"",
    "\"v2_enabled\"",
]

/// Every securityPolicy / toolPolicy / mcpPolicy / skillBuilderPolicy key the
/// default policy declares, as the quoted literal a gate would read it by.
private let declaredPolicyKeyProbes: [String] = [
    // securityPolicy
    "\"securityCenterEnabled\"", "\"capabilityPolicyEnabled\"", "\"originTrustEnabled\"",
    "\"signedRemoteCommandsRequired\"", "\"promptInjectionShieldEnabled\"",
    "\"dangerGatesEnabled\"", "\"rollbackByDefault\"", "\"secretFirewallEnabled\"",
    "\"toolSigningRequired\"", "\"auditReceiptsEnabled\"", "\"allowAppNotifications\"",
    "\"killSwitchEnabled\"", "\"remoteHighRiskDefault\"", "\"criticalRequiresDeveloperMode\"",
    // toolPolicy
    "\"autoPromoteSafeTools\"", "\"autoRunSafeTools\"", "\"riskyToolApproval\"",
    // mcpPolicy
    "\"allow_lifecycle_ops\"",
    // skillBuilderPolicy
    "\"allow_ui_panels\"", "\"v2_enabled\"",
]

@Test func TrustPolicyReachability_deadPolicyKeySetIsExactlyTheDatedAllowlist() {
    var inert: Set<String> = []
    for probe in declaredPolicyKeyProbes {
        let sites = TrustSourceScan.sites(
            of: probe, ignoring: TrustSourceScan.declarationOnlyFiles)
        if sites.isEmpty { inert.insert(probe) }
    }
    #expect(inert == inertPolicyKeys, """
        The set of trust-policy keys nothing reads changed.
          newly dead: \(inert.subtracting(inertPolicyKeys).sorted())
          newly wired: \(inertPolicyKeys.subtracting(inert).sorted())
        Newly dead = a switch the panel renders that gates nothing: add the gate,
        not an allowlist entry. Newly wired = audit the new read for a definition
        that diverges from the enforcing path, then drop the entry here and flip
        the matching docs/evals/ledger.json row.
        """)
}

/// Every key the default securityPolicy declares must be covered by a probe —
/// otherwise a key added tomorrow is never measured at all.
@Test func TrustPolicyReachability_everyDeclaredSecurityPolicyKeyHasAProbe() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TrustReachability-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let defaults = await SwiftNativeTrustCenter(dataRoot: root).defaultTrustPolicy()
    guard case .object(let security)? = defaults["securityPolicy"] else {
        Issue.record("defaultTrustPolicy() no longer carries a securityPolicy block")
        return
    }
    let probed = Set(declaredPolicyKeyProbes)
    let unprobed = security.keys.filter { !probed.contains("\"\($0)\"") }.sorted()
    #expect(unprobed.isEmpty,
            "securityPolicy keys with no reachability probe: \(unprobed). Add them to declaredPolicyKeyProbes so a new dead switch cannot hide.")
}

/// The whole `TrustCenterProtocol` facade — getTrust / updateTrust /
/// simulateTrust / getAutonomyPolicy / makeTrustCenter — has zero production
/// callers; the live app talks to `SwiftNativeTrustCenter`'s checked methods
/// directly. Two of those members carry DIVERGENT second opinions
/// (`simulateTrust` re-derives risk from tool autonomy alone; `getAutonomyPolicy`
/// hand-rolls a Full-Mac check that ignores expiry), so the day one is wired up
/// is the day to re-derive it — this test is the tripwire for that day.
private let inertFacadeMembers: Set<String> = [
    "TrustCenterProtocol",
    "makeTrustCenter",
    "simulateTrust",
    "getAutonomyPolicy",
    ".getTrust()",
    "updateTrust(",
]

@Test func TrustPolicyReachability_trustCenterFacadeHasNoProductionCallers() {
    var inert: Set<String> = []
    for member in inertFacadeMembers {
        let sites = TrustSourceScan.sites(
            of: member, ignoring: [TrustSourceScan.facadeDefinitionFile])
        if sites.isEmpty { inert.insert(member) }
    }
    #expect(inert == inertFacadeMembers, """
        TrustCenterProtocol facade reachability changed.
          newly wired: \(inertFacadeMembers.subtracting(inert).sorted())
        A caller now depends on a facade member. Before dropping it from this
        list: simulateTrust ignores origin trust / Full Mac / kill switch /
        injection + secret gates, and getAutonomyPolicy's fullMacActive ignores
        expiry entirely — reconcile with evaluateTool / MacControlGate first.
        """)
}

/// `CapabilityFoundryLane.policyGate` advertises gate names as free text. The
/// skill lane names `skillBuilderPolicy.v2_enabled`, which nothing evaluates —
/// an advertised gate that does not exist. Pin the advertised-but-unevaluated
/// set so a NEW lane cannot quietly claim a gate it does not have.
@Test func TrustPolicyReachability_advertisedPolicyGateNamesAreAccountedFor() throws {
    let foundry = TrustSourceScan.repoRoot.appendingPathComponent(
        "Modules/NativeAgentCore/Sources/CapabilityFoundry/CapabilityFoundry.swift")
    guard let text = try? String(contentsOf: foundry, encoding: .utf8) else {
        Issue.record("CapabilityFoundry.swift moved; the policyGate scan needs a new path")
        return
    }
    let regex = try NSRegularExpression(pattern: #"policyGate:\s*"([^"]*)""#)
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    var advertised: Set<String> = []
    for match in regex.matches(in: text, range: range) {
        guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) else { continue }
        let gate = String(text[r])
        if !gate.isEmpty { advertised.insert(gate) }
    }
    #expect(!advertised.isEmpty, "no policyGate names found — the scan is measuring nothing")

    var unevaluated: Set<String> = []
    for gate in advertised {
        // The leaf key is what a gate would read: "skillBuilderPolicy.v2_enabled" -> "v2_enabled".
        guard let leaf = gate.split(separator: ".").last else { continue }
        if TrustSourceScan.sites(of: "\"\(leaf)\"",
                                 ignoring: TrustSourceScan.declarationOnlyFiles).isEmpty {
            unevaluated.insert(gate)
        }
    }
    #expect(unevaluated == ["skillBuilderPolicy.v2_enabled"], """
        Advertised-but-unevaluated policy gates changed: \(unevaluated.sorted()).
        A lane naming a gate nothing reads tells the user it is protected when it is not.
        """)
}
