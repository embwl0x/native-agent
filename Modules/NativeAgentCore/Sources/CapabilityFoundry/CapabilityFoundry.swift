import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - CapabilityFoundry summary
//
// SwiftNative returns the structural contract the Mac panel renders chrome
// from, with partial native counts: skill/tool/workflow/MCP lane counts are
// aggregated read-only from the on-disk Swift stores. Lanes with no native
// source yet (panel/plugin/catalog) and review queues stay 0/empty, and the
// envelope is honest about it: top-level status is "partial" with a `detail`
// naming the unwired surfaces. No state is mutated from this read path.
//
// To make the "build capabilities on demand" lane functional, port the
// aggregation and backlog implementation natively and keep the side-effecting
// implement step out of this pure read.

// MARK: - Result types

/// Mirrors `CapabilityFoundrySummary.hotPathContract` on the Mac client.
public struct CapabilityFoundryHotPath: Sendable, Equatable {
    public let chatInjection: String?
    public let bodiesLoaded: String?
    public let pluginPolicy: String?
    public let reviewRequiredFor: [String]
    public let riskyPermissionsPresent: [String]

    public init(
        chatInjection: String?,
        bodiesLoaded: String?,
        pluginPolicy: String?,
        reviewRequiredFor: [String],
        riskyPermissionsPresent: [String]
    ) {
        self.chatInjection = chatInjection
        self.bodiesLoaded = bodiesLoaded
        self.pluginPolicy = pluginPolicy
        self.reviewRequiredFor = reviewRequiredFor
        self.riskyPermissionsPresent = riskyPermissionsPresent
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "reviewRequiredFor": .array(reviewRequiredFor.map { .string($0) }),
            "riskyPermissionsPresent": .array(riskyPermissionsPresent.map { .string($0) }),
        ]
        if let v = chatInjection { obj["chatInjection"] = .string(v) }
        if let v = bodiesLoaded { obj["bodiesLoaded"] = .string(v) }
        if let v = pluginPolicy { obj["pluginPolicy"] = .string(v) }
        return .object(obj)
    }
}

/// Mirrors `CapabilityFoundryCounts` on the Mac client.
public struct CapabilityFoundryCounts: Sendable, Equatable {
    public let total: Int
    public let active: Int
    public let review: Int
    public let autoCreated: Int
    public let byKind: [String: Int]

    public init(total: Int, active: Int, review: Int, autoCreated: Int, byKind: [String: Int]) {
        self.total = total
        self.active = active
        self.review = review
        self.autoCreated = autoCreated
        self.byKind = byKind
    }

    public func toJSON() -> JSONValue {
        .object([
            "total": .int(Int64(total)),
            "active": .int(Int64(active)),
            "review": .int(Int64(review)),
            "autoCreated": .int(Int64(autoCreated)),
            "byKind": .object(byKind.mapValues { .int(Int64($0)) }),
        ])
    }
}

/// Mirrors `CapabilityFoundryLane` on the Mac client.
public struct CapabilityFoundryLane: Sendable, Equatable {
    public let id: String
    public let title: String
    public let status: String
    public let count: Int
    public let reviewCount: Int
    public let endpoint: String?
    public let policyGate: String?
    public let hotPath: String?

    public init(
        id: String,
        title: String,
        status: String,
        count: Int,
        reviewCount: Int,
        endpoint: String?,
        policyGate: String?,
        hotPath: String?
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.count = count
        self.reviewCount = reviewCount
        self.endpoint = endpoint
        self.policyGate = policyGate
        self.hotPath = hotPath
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "title": .string(title),
            "status": .string(status),
            "count": .int(Int64(count)),
            "reviewCount": .int(Int64(reviewCount)),
        ]
        if let v = endpoint { obj["endpoint"] = .string(v) }
        if let v = policyGate { obj["policyGate"] = .string(v) }
        if let v = hotPath { obj["hotPath"] = .string(v) }
        return .object(obj)
    }
}

/// Mirrors `CapabilityFoundryReadout` on the Mac client.
public struct CapabilityFoundryReadout: Sendable, Equatable {
    public let id: String
    public let title: String
    public let status: String
    public let surface: String?

    public init(id: String, title: String, status: String, surface: String?) {
        self.id = id
        self.title = title
        self.status = status
        self.surface = surface
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "title": .string(title),
            "status": .string(status),
        ]
        if let v = surface { obj["surface"] = .string(v) }
        return .object(obj)
    }
}

/// The top-level readout, byte-shape-compatible with the daemon's
/// `capability_foundry_summary()` for the fields the Mac `CapabilityFoundrySummary`
/// decoder consumes. The DORMANT SwiftNative impl populates the static structural
/// fields and leaves the dynamic queues empty (see file header).
public struct CapabilityFoundryResult: Sendable, Equatable {
    public let status: String
    /// Honest scope marker for partial aggregation: names which lane counts
    /// are native and which are not yet wired. Extra key for the Mac decoder
    /// (which ignores unknown keys); empty string means "no caveat".
    public let detail: String
    public let principle: String
    public let hotPathContract: CapabilityFoundryHotPath
    public let summary: CapabilityFoundryCounts
    public let lanes: [CapabilityFoundryLane]
    public let reviewQueue: [JSONValue]
    public let recentArtifacts: [JSONValue]
    public let readouts: [CapabilityFoundryReadout]
    public let createdAt: String

    public init(
        status: String,
        detail: String = "",
        principle: String,
        hotPathContract: CapabilityFoundryHotPath,
        summary: CapabilityFoundryCounts,
        lanes: [CapabilityFoundryLane],
        reviewQueue: [JSONValue],
        recentArtifacts: [JSONValue],
        readouts: [CapabilityFoundryReadout],
        createdAt: String
    ) {
        self.status = status
        self.detail = detail
        self.principle = principle
        self.hotPathContract = hotPathContract
        self.summary = summary
        self.lanes = lanes
        self.reviewQueue = reviewQueue
        self.recentArtifacts = recentArtifacts
        self.readouts = readouts
        self.createdAt = createdAt
    }

    public func toJSON() -> JSONValue {
        .object([
            "status": .string(status),
            "detail": .string(detail),
            "principle": .string(principle),
            "hotPathContract": hotPathContract.toJSON(),
            "summary": summary.toJSON(),
            "lanes": .array(lanes.map { $0.toJSON() }),
            "reviewQueue": .array(reviewQueue),
            "recentArtifacts": .array(recentArtifacts),
            "readouts": .array(readouts.map { $0.toJSON() }),
            "createdAt": .string(createdAt),
        ])
    }

    /// Mirrors `SystemOps.isoTimestamp` / the daemon's `now_iso()` convention.
    public static func isoTimestamp(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let zulu = fmt.string(from: date)
        if zulu.hasSuffix("Z") { return String(zulu.dropLast()) + "+00:00" }
        return zulu
    }
}

// MARK: - Client protocol

public protocol CapabilityFoundryClient: Sendable {
    func capabilityFoundrySummary() async throws -> CapabilityFoundryResult
}

// MARK: - SwiftNative impl (PARTIAL native aggregation)

public struct SwiftNativeCapabilityFoundryClient: CapabilityFoundryClient {
    private let now: @Sendable () -> Date
    private let root: URL

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        root: URL = PersistenceCore.defaultDataRoot()
    ) {
        self.now = now
        self.root = root
    }

    public func capabilityFoundrySummary() async throws -> CapabilityFoundryResult {
        // PARTIAL native aggregation (audit fix 2026-06-10). This summary is
        // served LIVE to the Mac Capabilities panel, and the previous all-
        // static stub claimed status "ready" with 7 zeroed lanes — an
        // all-green lie. Now: lane counts that are cheaply countable from
        // on-disk stores this module can reach are REAL —
        //   skill    → <root>/skills/registry.json      (entry count)
        //   tool     → <root>/tools/registry.json       (status=="active")
        //   workflow → <root>/workflows/registry.json   (definition count)
        //   mcp      → <root>/mcp/servers.json          (entry count)
        // 2026-08-02 (E-1): lanes with no native source (panel/plugin/catalog)
        // are GONE rather than reported as zero — the Mac panel renders one
        // card per lane, so a permanently-zero lane is a rendered claim about a
        // system that does not exist. Top-level status stays "partial" (a
        // neutral badge via NativeAgentTheme.statusColor's default branch) with
        // a `detail` naming exactly what is and isn't wired. The review queues +
        // the side-effecting backlog tick remain unported (see file header);
        // their envelope fields stay empty and nothing renders them.
        let skillEntries = InstalledSkillInventory.list(dataRoot: root)
        let toolEntries = Self.arrayEntries(at: root.appendingPathComponent("tools/registry.json"))
        let workflowEntries = Self.arrayEntries(at: root.appendingPathComponent("workflows/registry.json"))
        let mcpEntries = Self.arrayEntries(at: root.appendingPathComponent("mcp/servers.json"))

        let skillCount = skillEntries.count
        let workflowCount = workflowEntries.count
        let mcpCount = mcpEntries.count

        // "active" across the wired stores: registry convention is
        // status=="active" (skills/tools/workflows); MCP server records use
        // "ready" for a configured healthy server.
        let activeStatuses: Set<String> = ["active", "installed", "ready"]
        let activeCount = (skillEntries + toolEntries + workflowEntries + mcpEntries)
            .filter { activeStatuses.contains(Self.status(of: $0) ?? "") }
            .count

        let hotPath = CapabilityFoundryHotPath(
            chatInjection: "compact capability index only",
            bodiesLoaded: "only when routed or explicitly looked up",
            pluginPolicy: "no preinstalled plugin pile; draft or install plugin-shaped capability packs only when useful for a task",
            reviewRequiredFor: [
                "shell", "network_public", "computer_files", "mcp",
                "app_patch", "ui_panel", "plugin_install",
            ],
            riskyPermissionsPresent: []
        )
        let summary = CapabilityFoundryCounts(
            total: skillCount + toolEntries.count + workflowCount + mcpCount,
            active: activeCount,
            review: 0,       // review pipeline not natively countable yet
            autoCreated: 0,  // auto-implementation ledger not natively countable yet
            byKind: [
                "skill": skillCount,
                "tool": toolEntries.count,
                "workflow": workflowCount,
                "mcp": mcpCount,
            ]
        )
        // 2026-07-21 audit, two honesty fixes:
        //  1. Lane counts now agree with summary.byKind — the tool lane used
        //     to show only ACTIVE tools (2) while byKind/total counted the
        //     whole store (3), so the lanes and the summary told two
        //     different stories. Lane count = per-store total; the active
        //     breakdown stays in summary.active.
        //  2. Lane endpoints advertised RETIRED daemon /v1 routes
        //     (the daemon is dead; nothing serves them). Wired lanes now
        //     name the Swift-native store the count actually comes from;
        //     unwired lanes carry no endpoint rather than a dead route.
        let lanes: [CapabilityFoundryLane] = [
            CapabilityFoundryLane(id: "skill", title: "Skills", status: "ready", count: skillCount, reviewCount: 0, endpoint: "native:skills/registry.json", policyGate: "skillBuilderPolicy.v2_enabled", hotPath: "manifest_only"),
            CapabilityFoundryLane(id: "tool", title: "Tools", status: "ready", count: toolEntries.count, reviewCount: 0, endpoint: "native:tools/registry.json", policyGate: "signed_manifest_and_validation", hotPath: "summary_only_until_matched"),
            CapabilityFoundryLane(id: "workflow", title: "Workflows", status: "ready", count: workflowCount, reviewCount: 0, endpoint: "native:workflows/registry.json", policyGate: "step_approval_gates", hotPath: "summary_only_until_routed"),
            CapabilityFoundryLane(id: "mcp", title: "MCP Servers", status: "ready", count: mcpCount, reviewCount: 0, endpoint: "native:mcp/servers.json", policyGate: "consent_ledger", hotPath: "server_manifest_only"),
            // REMOVED 2026-08-02 (E-1): the panel / plugin / catalog lanes.
            // 2026-06-13 downgraded them from "ready" to "degraded" — honest
            // about the code, still a lie on screen, because CapabilitiesView
            // renders one card per lane and three cards reading
            // "App Readouts — DEGRADED — 0" are furniture around systems that
            // do not exist (no native source, no store, no backend). A lane
            // appears here when it can count something real. The result-level
            // `detail` below names what is and isn't wired.
        ]
        let readouts: [CapabilityFoundryReadout] = [
            CapabilityFoundryReadout(id: "capabilities", title: "Capabilities tab", status: "active", surface: "mac"),
            CapabilityFoundryReadout(id: "panels", title: "JSON Panel Hub", status: "active", surface: "mac_ios"),
            CapabilityFoundryReadout(id: "activity", title: "Receipts and Activity", status: "active", surface: "mac_ios"),
            CapabilityFoundryReadout(id: "trust", title: "Trust and Approval Center", status: "active", surface: "mac"),
        ]
        return CapabilityFoundryResult(
            status: "partial",
            detail: "Native counts for skills/tools/workflows/mcp. No panel, plugin, or capability-pack lane exists; the review queue and the auto-implementation ledger are unported, so reviewQueue/recentArtifacts are always empty and summary.review/autoCreated are always 0.",
            principle: "Tiny core runtime; the agent can build plugin-shaped add-ons on demand through manifests, validation, approval, and lazy routing.",
            hotPathContract: hotPath,
            summary: summary,
            lanes: lanes,
            reviewQueue: [],
            recentArtifacts: [],
            readouts: readouts,
            createdAt: CapabilityFoundryResult.isoTimestamp(now())
        )
    }

    // MARK: On-disk store readers (best-effort, read-only)

    /// Entries of a JSON-array store, or [] when the file is missing,
    /// unreadable, or not an array. Read-only and best-effort — a Doctor-class
    /// problem with a store must not break the Capabilities panel.
    private static func arrayEntries(at url: URL) -> [JSONValue] {
        guard let data = try? Data(contentsOf: url),
              case .array(let items)? = try? JSONValue.parse(data) else {
            return []
        }
        return items
    }

    /// `status` string of an object entry, or nil.
    private static func status(of entry: JSONValue) -> String? {
        if case .object(let obj) = entry, case .string(let s)? = obj["status"] {
            return s
        }
        return nil
    }
}

// MARK: - Factory

public func makeCapabilityFoundryClient(
    now: @escaping @Sendable () -> Date = { Date() },
    root: URL = PersistenceCore.defaultDataRoot()
) -> any CapabilityFoundryClient {
    return SwiftNativeCapabilityFoundryClient(now: now, root: root)
}
