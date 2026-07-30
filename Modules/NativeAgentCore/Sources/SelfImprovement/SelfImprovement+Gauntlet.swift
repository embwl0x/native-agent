import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Subsystem #11 (wave 32 W09): Gauntlet status READ-SIDE
//
// Read-only local-disk port of ONE LIVE GET route that wave-31 W07
// incorrectly labeled KEPT_NO_NATIVE_IMPL. The reviewer flagged it as a
// clean portable read, and it is — `improvement_gauntlet_status()` is a
// pure file read + a static promotion-class table:
//
//   GET /v1/improvements/gauntlet -> runtime.improvement_gauntlet_status()
//
//                                    reads <root>/improvements/gauntlet/runs.json
//
// DAEMON SOURCE, ported VERBATIM:
//
//     def improvement_gauntlet_status(self) -> dict[str, Any]:
//         runs = read_json(self.gauntlet_runs_path, [])
//         runs = runs if isinstance(runs, list) else []
//         latest = runs[-1] if runs else None
//         return {
//             "status": latest.get("status", "ready") if latest else "ready",
//             "promotionClasses": [ ... 5 static entries ... ],
//             "latestRun": latest,
//             "runCount": len(runs),
//             "createdAt": now_iso(),
//         }
//
// where `self.gauntlet_runs_path = root / "improvements" / "gauntlet" / "runs.json"`
//.
//
// PARITY INVARIANTS (matched exactly):
//   - `latest` is `runs[-1]` — the LAST element in RAW FILE ORDER (NOT
//     reversed, unlike list_improvements). The gauntlet runs.json is written
//     append-only via `runs.append(record); write_json(...runs[-200:])`
//, so the last element is the newest run.
//   - `status` is `latest["status"]` defaulting to "ready" when the key is
//     absent on the last run, OR "ready" when there are no runs at all.
//     The `.get("status", "ready")` Python semantic: a PRESENT-but-null
//     status would yield None in Python (get returns the stored value), so
//     we mirror that — a present `status: null` decodes to nil status, NOT
//     "ready". Only an ABSENT key falls back to "ready".
//   - `promotionClasses` is a STATIC 5-entry table — identical bytes/order to
//     the daemon. It does not depend on file contents.
//   - `runCount` is `len(runs)` over the RAW array (every element, including
//     non-object junk entries — Python's `len()` counts them).
//   - `latestRun` rides through verbatim as the raw JSON of the last element
//     (preserved as JSONValue so no field is dropped on round-trip).
//   - `createdAt` is a fresh UTC ISO8601 timestamp per call (non-deterministic).
//     APPROXIMATES `now_iso()` — NOT byte-identical (millisecond `Z` here vs
//     Python microsecond `+00:00`); not load-bearing for a freshness stamp.
//     See `nowISO8601()` below. Injectable for tests via the `now` param.
//
// This local-disk read lives in the SelfImprovement module. It remains a pure
// helper until a product surface chooses to call it; unsupported callers fail
// closed rather than selecting a second runtime.
//
// NativeClient.getImprovementGauntlet() reads this owner directly and
// normalizes an absent stored status to the app model's `"ready"` default.
//
// NO TRUST GATE on this route in the daemon — `improvement_gauntlet_status()`
// is served unconditionally (no `_promotion_allowed()` / `_training_allowed()`
// wrapper, unlike the wave-31 W09 training/promotion routes). The Swift read
// is likewise unconditional; there is no leash to weaken here.

// MARK: - Gauntlet status models

/// One promotion-class descriptor in the gauntlet's static class table.
/// These five entries are emitted VERBATIM by `improvement_gauntlet_status()`
/// regardless of file contents.
public struct GauntletPromotionClass: Sendable, Codable, Equatable {
    public var id: String
    public var autoPromote: Bool
    public var requiredChecks: [String]

    public init(id: String, autoPromote: Bool, requiredChecks: [String]) {
        self.id = id
        self.autoPromote = autoPromote
        self.requiredChecks = requiredChecks
    }
}

/// Result of GET /v1/improvements/gauntlet. Mirrors the dict returned by
/// `improvement_gauntlet_status()` field-for-field.
public struct ImprovementGauntletStatus: Sendable, Codable, Equatable {
    /// `latest["status"]` with absent-key fallback to "ready"; "ready" when
    /// there are no runs. A present-but-null status decodes to nil (matching
    /// Python's `.get` returning the stored None).
    public var status: String?
    /// The static 5-entry promotion-class table (see `staticPromotionClasses`).
    public var promotionClasses: [GauntletPromotionClass]
    /// `runs[-1]` verbatim (raw JSON of the newest run), or nil when empty.
    public var latestRun: JSONValue?
    /// `len(runs)` over the raw array.
    public var runCount: Int
    /// Fresh UTC ISO8601 timestamp per call (`now_iso()` parity).
    public var createdAt: String

    public init(
        status: String?,
        promotionClasses: [GauntletPromotionClass],
        latestRun: JSONValue?,
        runCount: Int,
        createdAt: String
    ) {
        self.status = status
        self.promotionClasses = promotionClasses
        self.latestRun = latestRun
        self.runCount = runCount
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case status, promotionClasses, latestRun, runCount, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.status = try c.decodeIfPresent(String.self, forKey: .status)
        self.promotionClasses = try c.decodeIfPresent([GauntletPromotionClass].self, forKey: .promotionClasses) ?? []
        self.latestRun = try c.decodeIfPresent(JSONValue.self, forKey: .latestRun)
        self.runCount = try c.decodeIfPresent(Int.self, forKey: .runCount) ?? 0
        self.createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Daemon ALWAYS emits the `status` key (value may be null). Encode it
        // unconditionally — encode null when nil — to match the wire shape.
        if let status {
            try c.encode(status, forKey: .status)
        } else {
            try c.encodeNil(forKey: .status)
        }
        try c.encode(promotionClasses, forKey: .promotionClasses)
        // Daemon ALWAYS emits the `latestRun` key (null when empty).
        if let latestRun {
            try c.encode(latestRun, forKey: .latestRun)
        } else {
            try c.encodeNil(forKey: .latestRun)
        }
        try c.encode(runCount, forKey: .runCount)
        try c.encode(createdAt, forKey: .createdAt)
    }
}

extension SwiftNativeSelfImprovement {

    /// The STATIC promotion-class table, byte-identical to the daemon's
    ///. Order is load-bearing for wire parity.
    public static var staticGauntletPromotionClasses: [GauntletPromotionClass] {
        [
            GauntletPromotionClass(id: "prompt", autoPromote: true,  requiredChecks: ["syntax", "secret_scan", "targeted_eval"]),
            GauntletPromotionClass(id: "skill",  autoPromote: true,  requiredChecks: ["syntax", "validation", "targeted_eval"]),
            GauntletPromotionClass(id: "tool",   autoPromote: false, requiredChecks: ["static_scan", "sandbox_tests", "doctor"]),
            GauntletPromotionClass(id: "daemon", autoPromote: false, requiredChecks: ["py_compile", "isolated_smoke", "rollback_dry_run"]),
            GauntletPromotionClass(id: "swift",  autoPromote: false, requiredChecks: ["swift_build", "isolated_smoke", "app_verify"]),
        ]
    }

    /// `<root>/improvements/gauntlet/runs.json` — the daemon's
    /// `gauntlet_runs_path`.
    private func gauntletRunsPath() -> URL {
        trainingPromotionDataRoot()
            .appendingPathComponent("improvements", isDirectory: true)
            .appendingPathComponent("gauntlet", isDirectory: true)
            .appendingPathComponent("runs.json")
    }

    /// Local-disk port of `improvement_gauntlet_status()` (the retired daemon
    /// L21646). Reads the gauntlet runs file and returns the status envelope.
    /// Returns the empty-state envelope (status "ready", runCount 0, latestRun
    /// nil) when the file is absent or is not a JSON array — mirroring the
    /// daemon's `runs = runs if isinstance(runs, list) else []` guard.
    ///
    /// - Parameter now: the timestamp source for `createdAt`. Defaults to the
    ///   current UTC ISO8601 instant (`now_iso()` parity); injectable so tests
    ///   can pin a deterministic value.
    public func improvementGauntletStatusLocal(
        now: @Sendable () -> String = { SwiftNativeSelfImprovement.nowISO8601() }
    ) async -> ImprovementGauntletStatus {
        let raw = await trainingPromotionPersistence()
            .readJSON(gauntletRunsPath(), defaultValue: .array([]))

        // Python: `runs = runs if isinstance(runs, list) else []`. A non-array
        // (object, string, null from a corrupt file) collapses to empty.
        let runs: [JSONValue]
        if case .array(let arr) = raw {
            runs = arr
        } else {
            runs = []
        }

        // Python: `latest = runs[-1] if runs else None` — LAST element in raw
        // file order (newest, since the file is append-only).
        let latest = runs.last

        // Python: `latest.get("status", "ready") if latest else "ready"`.
        //   - no runs            -> "ready"
        //   - last has no status -> "ready" (absent-key fallback)
        //   - last status: null  -> nil (Python .get returns the stored None)
        //   - last status: "x"   -> "x"
        let status: String?
        if let latest {
            if case .object(let obj) = latest {
                if let statusVal = obj["status"] {
                    // Key PRESENT — take its value as-is. null -> nil.
                    if case .string(let s) = statusVal {
                        status = s
                    } else if case .null = statusVal {
                        status = nil
                    } else {
                        // DEFENSIVE DIVERGENCE (not exact parity): a present
                        // non-string, non-null status (e.g. a number/bool/array)
                        // — Python `.get` would return it verbatim, but the
                        // wire/consumer contract for this field is a STRING
                        // (the Mac app's `ImprovementGauntletStatus.status` is a
                        // non-optional `String`; see Sources/NativeAgentApp/
                        // Models.swift:1857). The daemon only ever writes string
                        // statuses, so this branch is unreachable in practice;
                        // we surface nil rather than fabricate or crash.
                        status = nil
                    }
                } else {
                    // Key ABSENT — fallback to "ready".
                    status = "ready"
                }
            } else {
                // DEFENSIVE DIVERGENCE (not exact parity): `latest` is a
                // non-object junk entry. Python would RAISE AttributeError on
                // `latest.get(...)`. The daemon only ever appends dicts here, so
                // this is unreachable in practice; we fall back to "ready"
                // rather than crash on a hand-corrupted fixture file.
                status = "ready"
            }
        } else {
            status = "ready"
        }

        return ImprovementGauntletStatus(
            status: status,
            promotionClasses: Self.staticGauntletPromotionClasses,
            latestRun: latest,
            runCount: runs.count,
            createdAt: now()
        )
    }

    /// Approximate `now_iso()` (`datetime.now(timezone.utc).isoformat()`).
    ///
    /// NOT BYTE-IDENTICAL to the Python output, by design:
    ///   - Python:  `2026-06-01T23:53:21.404526+00:00` (microsecond precision,
    ///              explicit `+00:00` UTC offset).
    ///   - This:    `2026-06-01T23:53:21.404Z` (millisecond precision, `Z`).
    /// Both are valid RFC3339/ISO8601 instants for the same UTC moment.
    ///
    /// Byte-parity is NOT load-bearing here: `createdAt` is a freshness stamp
    /// generated fresh on every call (so it never matches across two reads
    /// anyway), and no consumer parses it for ordering — the Mac app model
    /// (`Sources/NativeAgentApp/Models.swift:1861`) holds it as an optional
    /// `String?` it only displays. Chasing microsecond precision would add a
    /// hand-rolled formatter for zero behavioral gain.
    public static func nowISO8601() -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.string(from: Date())
    }
}
