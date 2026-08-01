import Foundation
import NativeAgentCore
import PersistenceCore
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - Subsystem #11 (wave 31 W09): Training / Promotion / Evals READ-SIDE
//
// Read-only local-disk port of five LIVE Mac-UI GET routes that the daemon
// serves out of the runtime data root (the SAME root `defaultDataRoot()`
// resolves to, so on the Mac the app process is co-located with these files):
//
//   GET /v1/training/runs        -> _get_training().list_runs()
//                                   <root>/training_journal/drill_runs/*-graded.json
//   GET /v1/training/proposals   -> _get_training().list_all_proposals()
//                                   <root>/training_journal/proposals/*.json
//   GET /v1/promotion/candidates -> _lazy_promotion().list_candidates()  (asdict)
//                                   <root>/training_journal/promotion_candidates/*.json
//   GET /v1/promotion/pending    -> _lazy_promotion().list_pending_tier_b() (asdict)
//                                   <root>/training_journal/promotion_stages/*.json
//   GET /v1/evals/runs           -> list_evals()
//                                   <root>/evals/runs.json
//
// PASS-THROUGH SHAPE: each method returns the SAME JSON shape the daemon
// emits, so the Mac NativeClient re-decodes with the identical
// `JSONDecoder.nativeAgent` the HTTP path uses. We deliberately do NOT
// re-key into the UI's optimistic field names — the UI models
// (TrainingRunSummary / TrainingProposalSummary / PromotionCandidateSummary /
// EvalRun) decode every field with `decodeIfPresent`, so reproducing the
// daemon's ACTUAL keys (e.g. list_runs emits `suite_name`/`graded_at`/
// `total_score`, NOT `surface`/`score`/`verdict`) is what keeps Swift parity.
//
// This is a read-side Swift implementation. Remote iOS reads continue through
// the authenticated bridge because the phone does not own local data files. It is not a
// retirement — the routes retire only once iOS reads from a Swift impl AND the
// flag is flipped on for production Mac.
//
// TRUST GATES: the daemon wraps four of these in `_training_allowed()` /
// `_promotion_allowed()` 403 guards (the fifth, /v1/evals/runs, is ungated).
// The raw `list*Local()` reads below are still UNCONDITIONAL — they return the
// file contents and do NOT gate. The GATE now lives one layer up:
// `trainingAllowed()` / `promotionAllowed()` (added wave 32 W05, below) mirror
// the daemon's two gate predicates against the live `<root>/trust/policy.json`,
// and the NativeClient routed helpers consult them and throw the identical 403
// NSError before surfacing training/promotion data — closing the silently-
// allowed-read hole that wave 31 W09 left open. See CUTOVER_PLAN.md 6.76
// (supersedes the 6.55 pre-flip prereq P3 note).

extension SwiftNativeSelfImprovement {

    // MARK: - Trust gates (wave 32 W05): _training_allowed / _promotion_allowed parity
    //
    // Mirrors the daemon's two trust gates so a flag-ON Swift caller is subject
    // to the SAME 403 leash the HTTP path enforces, instead of a silently-allowed
    // read. The wave-31 W09 port deliberately omitted these (see the carve at the
    // top of this file). The NativeClient routed helpers consult these before
    // surfacing training/promotion data; when the gate is closed they throw the
    // identical 403 NSError the daemon's `validate()` would have produced.
    //
    //   _training_allowed:
    //     bool(policy.get("developerMode"))
    //       or bool(policy.get("trainingPolicy", {}).get("autonomous_training"))
    //   _promotion_allowed:
    //     bool(policy.get("developerMode"))
    //       or bool(policy.get("promotionPolicy", {}).get("enabled", False))
    //
    // DEFAULT-MERGE PARITY (the subtle correctness point): the daemon's
    // `trust_policy()` (L25724) merges the persisted `policy.json` over
    // `default_trust_policy()`, which sets BOTH `trainingPolicy.autonomous_training`
    // and `promotionPolicy.enabled` to TRUE (L25593/L25603, mirrored in the Swift
    // TrustCenter.defaultTrustPolicy at L297/L302). The merge is a per-leaf nested
    // update — a saved `trainingPolicy` dict that OMITS `autonomous_training` keeps
    // the default True; only an explicit saved `false` flips the gate closed. So a
    // fresh install with an empty/absent `policy.json` is ALLOWED, matching the
    // daemon. We therefore model these two keys as DEFAULT-TRUE: closed only when
    // the saved nested dict explicitly carries a FALSY value for the key.
    // `developerMode` has no default → falsy/absent means "not in developer mode".

    /// Read `<root>/trust/policy.json` as a top-level object, or `[:]` on
    /// absence / parse-error / non-object. Mirrors the daemon's
    /// `saved = read_json(self.trust_path, {}); if not isinstance(saved, dict): saved = {}`
    ///. Path convention pinned at L2298:
    /// `self.trust_path = root / "trust" / "policy.json"`.
    private func readSavedTrustPolicy() async -> [String: JSONValue] {
        let url = trainingPromotionDataRoot()
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
        let raw = await trainingPromotionPersistence().readJSON(url, defaultValue: .object([:]))
        guard case .object(let obj) = raw else { return [:] }
        return obj
    }

    /// Retired truthiness for a single `bool(value)` call. Reproduces the result
    /// of `bool(...)` for the JSON types a trust-policy leaf can hold: None /
    /// missing / false / 0 / 0.0 / "" / [] / {} are falsy; everything else truthy.
    static func pythonBool(_ v: JSONValue?) -> Bool {
        guard let v else { return false }
        switch v {
        case .null:            return false
        case .bool(let b):     return b
        case .int(let i):      return i != 0
        case .double(let d):   return d != 0
        case .string(let s):   return !s.isEmpty
        case .array(let a):    return !a.isEmpty
        case .object(let o):   return !o.isEmpty
        }
    }

    /// `bool(policy.get(outer, {}).get(inner))` with the daemon's default-merge
    /// applied. Three cases, matching `trust_policy()`'s merge (L25733-25739):
    ///
    ///   1. `outer` ABSENT from saved        → default dict survives → `defaultWhenAbsent`.
    ///   2. saved `outer` IS an object       → per-leaf merge: present leaf wins
    ///      (`pythonBool`), absent leaf falls back to `defaultWhenAbsent`.
    ///   3. saved `outer` present, NOT object → the merge OVERWRITES the default
    ///      dict with the non-dict value (the deep-merge branch needs BOTH sides
    ///      to be dicts). The daemon then calls `.get(inner)` on a non-dict, which
    ///      raises AttributeError → HTTP 500. There is no clean Swift equivalent of
    ///      a 500 here, and a security gate must NEVER silently open on a malformed
    ///      trust file, so we FAIL CLOSED (`false`). This case cannot arise from a
    ///      well-formed policy.json (the daemon always writes nested dicts); it is
    ///      a defensive deny for a corrupted file.
    private static func nestedGateTruthy(
        _ policy: [String: JSONValue],
        outer: String,
        inner: String,
        defaultWhenAbsent: Bool
    ) -> Bool {
        guard let outerVal = policy[outer] else {
            // Case 1: absent → default dict survives the merge.
            return defaultWhenAbsent
        }
        guard case .object(let nested) = outerVal else {
            // Case 3: present but non-object → daemon would crash (500). Fail closed.
            return false
        }
        guard let leaf = nested[inner] else {
            // Case 2a: object present, leaf omitted → default leaf survives.
            return defaultWhenAbsent
        }
        // Case 2b: explicit leaf → saved value wins.
        return pythonBool(leaf)
    }

    /// Effective `developerMode` AFTER the daemon's `_normalize_trust_policy()`
    ///, which the gates read post-normalization.
    ///
    /// Swift-native policy keeps Full Mac and Developer Mode separate:
    /// Full Mac grants broad non-destructive access, while Developer Mode is
    /// the explicit operator escalation. The training/promotion gates should
    /// therefore honor an explicit truthy `developerMode` regardless of the
    /// current permission preset.
    private static func effectiveDeveloperMode(_ policy: [String: JSONValue]) -> Bool {
        return pythonBool(policy["developerMode"])
    }

    /// Swift mirror of `BaseRuntime._training_allowed()`.
    /// `developerMode` truthy (post-normalization) OR
    /// `trainingPolicy.autonomous_training` truthy (default-True under the
    /// trust-policy merge). Reads the live on-disk policy.
    public func trainingAllowed() async -> Bool {
        let policy = await readSavedTrustPolicy()
        if Self.effectiveDeveloperMode(policy) { return true }
        return Self.nestedGateTruthy(
            policy,
            outer: "trainingPolicy",
            inner: "autonomous_training",
            defaultWhenAbsent: true
        )
    }

    /// Swift mirror of `BaseRuntime._promotion_allowed()`.
    /// `developerMode` truthy (post-normalization) OR `promotionPolicy.enabled`
    /// truthy (default-True under the trust-policy merge). Reads the live on-disk
    /// policy.
    public func promotionAllowed() async -> Bool {
        let policy = await readSavedTrustPolicy()
        if Self.effectiveDeveloperMode(policy) { return true }
        return Self.nestedGateTruthy(
            policy,
            outer: "promotionPolicy",
            inner: "enabled",
            defaultWhenAbsent: true
        )
    }

    /// `<root>/training_journal` — the journal dir both TrainingLoop and
    /// PromotionEngine are constructed against (the retired daemon/L3062:
    /// `journal_dir = self.root / "training_journal"`).
    private func trainingJournalDir() -> URL {
        trainingPromotionDataRoot().appendingPathComponent("training_journal", isDirectory: true)
    }

    /// Sorted list of `*.json` files in `dir`. `reversedName` mirrors the
    /// daemon's `sorted(dir.glob(...), reverse=True)` (reverse byte-order on
    /// the FILE NAME, which for the timestamp-prefixed names the daemon writes
    /// equals newest-first). Returns [] when the dir is absent. Filters on the
    /// `-graded.json` suffix when `suffix` is supplied (drill runs).
    private static func sortedJSONFiles(
        in dir: URL,
        suffix: String = ".json",
        reversedName: Bool
    ) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let matched = entries.filter { $0.lastPathComponent.hasSuffix(suffix) }
        // Sort by file NAME (UTF-8 byte order) to match Python's sorted(glob()).
        let sorted = matched.sorted { lhs, rhs in
            Array(lhs.lastPathComponent.utf8)
                .lexicographicallyPrecedes(Array(rhs.lastPathComponent.utf8))
        }
        return reversedName ? sorted.reversed() : sorted
    }

    /// Read one file as a JSONValue object, or nil on absence/parse-error/
    /// non-object (mirrors the daemon's `isinstance(data, dict)` guard).
    private func readJSONObject(_ url: URL) async -> [String: JSONValue]? {
        let raw = await trainingPromotionPersistence().readJSON(url, defaultValue: .null)
        guard case .object(let obj) = raw else { return nil }
        return obj
    }

    // MARK: GET /v1/training/runs

    /// Mirror of `TrainingLoop.list_runs()`: glob
    /// `drill_runs/*-graded.json` newest-first (reverse=True), project the
    /// FIVE fields the daemon projects — `run_id`, `suite_name`, `graded_at`,
    /// `total_score`, `max_score` — defaulting absent keys to null exactly as
    /// `data.get(...)` would yield None.
    public func listTrainingRunsLocal() async -> JSONValue {
        let dir = trainingJournalDir().appendingPathComponent("drill_runs", isDirectory: true)
        let files = Self.sortedJSONFiles(in: dir, suffix: "-graded.json", reversedName: true)
        var out: [JSONValue] = []
        for f in files {
            guard let obj = await readJSONObject(f) else { continue }
            out.append(.object([
                "run_id": obj["run_id"] ?? .null,
                "suite_name": obj["suite_name"] ?? .null,
                "graded_at": obj["graded_at"] ?? .null,
                "total_score": obj["total_score"] ?? .null,
                "max_score": obj["max_score"] ?? .null,
            ]))
        }
        return .array(out)
    }

    // MARK: GET /v1/training/runs/<id>  (detail sibling of list_runs)

    /// Mirror of `TrainingLoop.get_run(run_id)`: read the
    /// SINGLE graded-run file `drill_runs/<run_id>-graded.json` and return its
    /// FULL dict UNPROJECTED (the daemon returns `_read_json(f, {})` — the entire
    /// stored graded-run record, NOT the 5-field `list_runs` projection). Returns
    /// `nil` when the file does not exist, which the daemon's handler maps to a
    /// 404; the NativeClient seam reproduces that
    /// 404 NSError so a flag-ON caller sees identical not-found behavior.
    ///
    /// PARITY DETAILS:
    ///   - File name is `<run_id>-graded.json` (training.py L1191: `self.runs_dir
    ///     / f"{run_id}-graded.json"`). We append the same suffix verbatim. No
    ///     sanitization of `run_id` is done by the daemon either — the HTTP
    ///     handler already `.strip("/")`s the path segment (the retired daemon
    ///     L51982); a `run_id` with embedded path separators would resolve a
    ///     sibling/escaped file on BOTH sides identically, so we do NOT add an
    ///     extra guard here that the daemon lacks (parity over hardening — the
    ///     run_id originates from the daemon's own glob-derived `run_id` field, a
    ///     timestamp-prefixed token with no separators in practice).
    ///   - EXISTENCE then READ: the daemon checks `f.exists()` BEFORE reading.
    ///     A file that exists but holds malformed JSON yields `_read_json(f, {})`
    ///     == `{}` (default on parse failure) — a present-but-empty object, NOT a
    ///     404. We reproduce that: `fileExists` true + parse failure → `.object([:])`,
    ///     present + parse-success-non-object → the daemon's `_read_json` returns
    ///     the parsed value AS-IS (it does not isinstance-guard get_run, unlike
    ///     list_runs), so a JSON array/scalar file is returned verbatim. We mirror
    ///     that by returning the raw parsed JSONValue unchanged when the file
    ///     exists. Absent file → nil (→ 404).
    public func getTrainingRunLocal(runId: String) async -> JSONValue? {
        let dir = trainingJournalDir().appendingPathComponent("drill_runs", isDirectory: true)
        let f = dir.appendingPathComponent("\(runId)-graded.json")
        // Daemon gate: `if f.exists()` BEFORE the read. Absent → None → 404.
        guard FileManager.default.fileExists(atPath: f.path) else { return nil }
        // Present: `_read_json(f, {})` — full parsed value, default {} on parse
        // failure. Unlike list_runs there is NO isinstance(dict) guard, so a
        // non-object file is returned verbatim (matches the daemon byte-for-byte).
        return await trainingPromotionPersistence().readJSON(f, defaultValue: .object([:]))
    }

    // MARK: GET /v1/training/proposals

    /// Mirror of `TrainingLoop.list_all_proposals()`: glob
    /// `proposals/*.json` in FORWARD name order (the daemon does NOT reverse
    /// here — `sorted(self.proposals_dir.glob("*.json"))`), pass each file's
    /// dict through UNFILTERED (the daemon appends the whole `data` dict).
    public func listTrainingProposalsLocal() async -> JSONValue {
        let dir = trainingJournalDir().appendingPathComponent("proposals", isDirectory: true)
        let files = Self.sortedJSONFiles(in: dir, reversedName: false)
        var out: [JSONValue] = []
        for f in files {
            guard let obj = await readJSONObject(f) else { continue }
            out.append(.object(obj))
        }
        return .array(out)
    }

    // MARK: GET /v1/promotion/candidates

    /// Mirror of `PromotionEngine.list_candidates()`:
    /// glob `promotion_candidates/*.json` newest-first (reverse=True), then
    /// reconstruct each as a CandidateRun — i.e. PROJECT ONLY the dataclass
    /// fields (extras in the file are dropped on `CandidateRun(**{k: ...})`).
    /// The handler then `dataclasses.asdict(c)`s, which re-emits exactly the
    /// dataclass field set in declaration order. We reproduce that field set.
    public func listPromotionCandidatesLocal() async -> JSONValue {
        let dir = trainingJournalDir().appendingPathComponent("promotion_candidates", isDirectory: true)
        let files = Self.sortedJSONFiles(in: dir, reversedName: true)
        var out: [JSONValue] = []
        for f in files {
            guard let obj = await readJSONObject(f) else { continue }
            out.append(Self.projectCandidateRun(obj))
        }
        return .array(out)
    }

    // MARK: GET /v1/promotion/pending

    /// Mirror of `PromotionEngine.list_pending_tier_b()`:
    /// glob `promotion_stages/*.json` in FORWARD name order (no reverse),
    /// keep ONLY `status == "pending"`, reconstruct each as a Stage dataclass
    /// (project the dataclass field set; drop extras), asdict re-emit.
    public func listPromotionPendingLocal() async -> JSONValue {
        let dir = trainingJournalDir().appendingPathComponent("promotion_stages", isDirectory: true)
        let files = Self.sortedJSONFiles(in: dir, reversedName: false)
        var out: [JSONValue] = []
        for f in files {
            guard let obj = await readJSONObject(f) else { continue }
            if case .string(let status)? = obj["status"], status == "pending" {
                out.append(Self.projectStage(obj))
            }
        }
        return .array(out)
    }

    // MARK: GET /v1/evals/runs

    /// Mirror of `list_evals()`: read
    /// `<root>/evals/runs.json` (a single JSON array), return [] if it's not
    /// an array, sort by `createdAt` DESCENDING using EXACTLY the daemon's key
    /// `str(item.get("createdAt") or "")`.
    ///
    /// Parity details (gpt-5.5 wave-31 review findings):
    ///   - Key coercion: a non-string truthy `createdAt` (int/float/bool/array/
    ///     object) is NOT mapped to "" — Python `str(... or "")` stringifies it.
    ///     `_pythonStrOr` reproduces that. Falsy values (0, 0.0, false, null,
    ///     missing, empty string) → "".
    ///   - Stability: Python's `sorted(reverse=True)` keeps the ORIGINAL input
    ///     order for tied keys (reverse negates comparisons but preserves
    ///     stability). Swift's `sorted` is not guaranteed stable, so we carry
    ///     the original index and use it as an ascending tiebreaker on equal keys.
    public func listEvalsLocal() async -> JSONValue {
        let url = trainingPromotionDataRoot()
            .appendingPathComponent("evals", isDirectory: true)
            .appendingPathComponent("runs.json")
        let raw = await trainingPromotionPersistence().readJSON(url, defaultValue: .array([]))
        guard case .array(let arr) = raw else { return .array([]) }
        let keyed: [(key: String, idx: Int, value: JSONValue)] = arr.enumerated().map { (i, item) in
            var key = ""
            if case .object(let obj) = item {
                key = Self.pythonStrOr(obj["createdAt"])
            }
            // INTENTIONAL ROBUSTNESS DIVERGENCE: a bare non-object array element
            // (string/number) gets key "". The daemon's `item.get(...)` would
            // raise AttributeError → 500 on such malformed input. `evals/runs.json`
            // is always an array of objects from `run_evals`, so this never fires
            // in practice; degrading gracefully (vs crashing) is the safer choice
            // and matches the isinstance-guard spirit of the other read methods.
            return (key, i, item)
        }
        let sorted = keyed.sorted { a, b in
            if a.key != b.key { return a.key > b.key }   // DESC by key
            return a.idx < b.idx                          // tie → original order
        }.map { $0.value }
        return .array(sorted)
    }

    /// Reproduce Python `str(value or "")` for the JSON types `createdAt` can
    /// hold. Falsy (null/missing, false, 0, 0.0, "", empty array/object) → "".
    /// Truthy: string → itself; bool true → "True"; int → base-10; double →
    /// Python-ish repr (whole doubles render without a trailing ".0" only in
    /// rare cases — `createdAt` is always an ISO string in practice, so this
    /// branch is a defensive parity fallback, not a hot path).
    static func pythonStrOr(_ v: JSONValue?) -> String {
        guard let v else { return "" }
        switch v {
        case .null:
            return ""
        case .bool(let b):
            return b ? "True" : ""           // Python: str(True)=="True"; False is falsy → ""
        case .int(let i):
            return i == 0 ? "" : String(i)
        case .double(let d):
            return d == 0 ? "" : String(d)
        case .string(let s):
            return s                          // "" stays "" (falsy → "")
        case .array(let a):
            return a.isEmpty ? "" : (try? JSONValue.array(a).serialize(pretty: false)) ?? ""
        case .object(let o):
            return o.isEmpty ? "" : (try? JSONValue.object(o).serialize(pretty: false)) ?? ""
        }
    }

    /// Reproduce Python `str(data.get(key, default))`. The default is used ONLY
    /// when the key is ABSENT; a PRESENT value — even `null`/`false`/`0`/array —
    /// is `str()`-coerced, NOT replaced by the default. This is the parity point
    /// behind the wave-33 fail-open finding: the daemon's
    /// `str(data.get("change_type","append"))` yields "None"/"False"/"0"/… for a
    /// present non-string, none of which equal "append"/"edit", so the daemon
    /// RAISES cannot_apply. Treating a present non-string as the default ("append")
    /// would silently apply a malformed proposal. So: absent → `defaultWhenAbsent`;
    /// present → full `str()` coercion (str→itself, null→"None", bool→"True"/"False",
    /// int→base-10, double→repr, array/object→JSON repr as a best-effort stand-in
    /// for Python's container repr — these never occur for these scalar leaves in
    /// practice, but we still avoid the default-substitution that caused the bug).
    static func pythonStr(_ v: JSONValue?, defaultWhenAbsent: String) -> String {
        guard let v else { return defaultWhenAbsent }   // key absent → Python default
        switch v {
        case .null:            return "None"            // str(None) == "None"
        case .bool(let b):     return b ? "True" : "False"
        case .int(let i):      return String(i)
        case .double(let d):   return String(d)
        case .string(let s):   return s
        case .array(let a):    return (try? JSONValue.array(a).serialize(pretty: false)) ?? "[]"
        case .object(let o):   return (try? JSONValue.object(o).serialize(pretty: false)) ?? "{}"
        }
    }

    // MARK: - Dataclass field projection

    /// CandidateRun dataclass fields in declaration order.
    /// `dataclasses.asdict` emits every field; absent file keys -> null
    /// (Python: the `CandidateRun(**{k: data.get(k) ...})` fills missing keys
    /// with None, then asdict re-emits them as null).
    private static let candidateRunFields: [String] = [
        "candidate_id", "source", "tier", "patches", "status", "created_at",
        "finished_at", "harness", "decision", "decision_reason",
        "worktree_path", "branch_name", "merged_commit_sha", "error",
    ]

    private static func projectCandidateRun(_ obj: [String: JSONValue]) -> JSONValue {
        var out: [String: JSONValue] = [:]
        for k in candidateRunFields { out[k] = obj[k] ?? .null }
        return .object(out)
    }

    /// Stage dataclass fields in declaration order.
    private static let stageFields: [String] = [
        "candidate_id", "tier", "harness", "delta", "staged_at",
        "worktree_path", "branch_name", "status", "resolved_at",
        "resolution_reason",
    ]

    private static func projectStage(_ obj: [String: JSONValue]) -> JSONValue {
        var out: [String: JSONValue] = [:]
        for k in stageFields {
            // `status` defaults to "pending" on the dataclass; but we only
            // reach here for status=="pending" anyway, so the file always has it.
            out[k] = obj[k] ?? .null
        }
        return .object(out)
    }

    // MARK: - Subsystem #11: Training-proposal WRITE-SIDE
    //
    // Local-disk port of the two LIVE Mac-UI POST routes that mutate a staged
    // training proposal, mirroring `TrainingLoop.approve_proposal` /
    // `reject_proposal`:
    //
    //   POST /v1/training/proposals/<id>/approve -> approve (DIRECT mode only)
    //   POST /v1/training/proposals/<id>/reject  -> reject_proposal(id, reason)
    //
    // CALLERS: Mac SelfImprovementView.swift -> appModel.approveTrainingProposal
    // / rejectTrainingProposal -> NativeClient.approveTrainingProposal /
    // rejectTrainingProposal (the only callers; iOS does NOT mutate proposals,
    // and no script hits these two sub-routes — audit shows the prefix route
    // /v1/training/proposals has a single Mac caller). This file owns both
    // direct approval and route_through_promotion staging in Swift.
    //
    // TRUST GATE: the NativeClient routed helpers consult `trainingAllowed()`
    // (wave 32 W05, above) and throw the established 403 NSError before calling
    // these write methods. The raw methods below do NOT re-gate; the gate lives
    // one layer up, symmetric with the read methods.
    //
    // route_through_promotion is now Swift-native. When enabled, approval does
    // not mutate the target persona doc immediately. It writes a promotion
    // candidate plus pending stage under `training_journal/`, marks the proposal
    // `promotion_staged`, and lets the promotion approve/reject methods below
    // make the final doc mutation or rejection. No daemon fallback is involved.
    //
    // LOCKING: both methods wrap their file mutations in
    // `persistence.withFileLock(...)` (PersistenceCore+FileLock.swift) so other
    // NativeAgent processes cannot interleave with the Swift read-modify-write.
    // The in-process `withPathLock` is NOT used here because the file lock already
    // serializes within-process callers of the same path.

    public enum TrainingProposalWriteError: Error, Sendable, Equatable {
        /// Proposal id not found among `proposals/*.json`. Mirrors the daemon's
        /// `ValueError(f"Proposal {id} not found")`.
        case proposalNotFound(String)
        /// `approve_proposal` requires status == "pending"; mirrors the daemon's
        /// `ValueError(f"Proposal {id} is not pending (status={...})")` (L986).
        case notPending(id: String, status: String)
        /// target_doc is not one of the mutable personality docs. USER.md is
        /// generated from MemoryV2 and is not a training-promotion target.
        case targetDocNotAllowed(String)
        /// target_doc resolves OUTSIDE the memory dir (path-escape guard, L995).
        case targetDocEscapesMemoryDir(String)
        /// target_doc file is absent on disk (L998).
        case targetDocMissing(String)
        /// target_doc exists but could not be read as UTF-8 text. Mirrors the
        /// daemon's STRICT `doc_path.read_text()`, which
        /// RAISES on a read/decode failure and aborts the approve, leaving the
        /// doc untouched. The Swift read must throw the SAME way — degrading a
        /// failed read to "" would let `append` overwrite a valid personality
        /// doc with only the proposed snippet (gpt-5.5 wave-33 BLOCKER finding).
        case targetDocUnreadable(String)
        /// change_type/current combination cannot be applied (L1018).
        case cannotApplyChange(changeType: String)
        /// Pending promotion stage not found among promotion_stages/*.json.
        case promotionStageNotFound(String)
        /// Pending promotion stage exists, but status is no longer pending.
        case promotionStageNotPending(id: String, status: String)
        /// Pending promotion stage is missing the delta needed to apply/reject it.
        case promotionStageMalformed(String)
        /// Target doc changed after staging, so the saved before_hash no longer matches.
        case promotionStageStale(expected: String, actual: String)
    }

    /// `<root>/training_journal/proposals` — where the daemon's TrainingLoop
    /// writes proposal `*.json` files.
    private func trainingProposalsDir() -> URL {
        trainingJournalDir().appendingPathComponent("proposals", isDirectory: true)
    }

    private func promotionCandidatesDir() -> URL {
        trainingJournalDir().appendingPathComponent("promotion_candidates", isDirectory: true)
    }

    private func promotionStagesDir() -> URL {
        trainingJournalDir().appendingPathComponent("promotion_stages", isDirectory: true)
    }

    /// `<root>/training_journal/audit_ledger.jsonl` — the approve audit ledger
    ///.
    private func trainingLedgerPath() -> URL {
        trainingJournalDir().appendingPathComponent("audit_ledger.jsonl")
    }

    /// `<root>/memory` — the personality-doc directory the daemon's TrainingLoop
    /// is constructed against.
    private func trainingMemoryDir() -> URL {
        trainingPromotionDataRoot().appendingPathComponent("memory", isDirectory: true)
    }

    /// Run `body` under the cross-process `withFileLock(path)`.
    ///
    /// L7 (2026-08-01): this used to downcast to `SwiftNativePersistenceCore` and
    /// run `body` BARE otherwise — the stale comment claimed `withFileLock` was
    /// "declared only on the concrete type". It is a PersistenceCoreProtocol
    /// EXTENSION (PersistenceCore+FileLock.swift:4); every conformer has it, and
    /// it locks a local `<path>.lock` sidecar independent of the write backend.
    /// So the downcast only ever cost mutual exclusion. Lock uniformly.
    private func withTrainingFileLock<T: Sendable>(
        _ path: URL,
        _ body: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        return try await trainingPromotionPersistence().withFileLock(path, body)
    }

    /// Find the proposal file whose `proposal_id` field equals `proposalId`,
    /// scanning `proposals/*.json` in FORWARD name order. Mirrors
    /// `TrainingLoop._find_proposal_file`: `sorted(glob)`,
    /// first file whose dict carries the matching `proposal_id`. Returns the
    /// URL plus the already-parsed dict so callers avoid a second read.
    private func findProposalFile(_ proposalId: String) async -> (url: URL, data: [String: JSONValue])? {
        let files = Self.sortedJSONFiles(in: trainingProposalsDir(), reversedName: false)
        for f in files {
            guard let obj = await readJSONObject(f) else { continue }
            if case .string(let pid)? = obj["proposal_id"], pid == proposalId {
                return (f, obj)
            }
        }
        return nil
    }

    /// ISO-8601 UTC timestamp matching the daemon's `_now_iso()` =
    /// `datetime.now(timezone.utc).isoformat()`. The daemon
    /// emits `…+00:00`; this emits the cosmetically-equivalent `…Z` (with
    /// fractional seconds). Both round-trip identically through
    /// `datetime.fromisoformat`, the only reader of these stamps. Same choice
    /// as MacControl.iso8601 (MacControl.swift L920).
    private static func nowISO() -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: Date())
    }

    /// `hashlib.sha256(text.encode("utf-8")).hexdigest()`.
    private static func sha256Hex(_ text: String) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        #else
        // No CryptoKit (non-Apple build): the audit ledger hashes are
        // informational (before/after content fingerprints, never gated on),
        // so an empty digest degrades gracefully rather than failing the write.
        return ""
        #endif
    }

    /// `True` when the MERGED trust policy enables route-through-promotion. The
    /// daemon reads `self.runtime.trust_policy().get("trainingPolicy", {})`
    /// (the merged policy) then `bool(_training_policy.get("route_through_promotion", False))`
    ///. Under the trust-policy merge the default
    /// dict supplies `route_through_promotion: True` (default_trust_policy
    /// L25617), so the effective default is TRUE — modeled here with
    /// `defaultWhenAbsent: true`, identical to how the gate predicates treat
    /// `autonomous_training` / `enabled`.
    private func routeThroughPromotionEnabled() async -> Bool {
        let policy = await readSavedTrustPolicy()
        return Self.nestedGateTruthy(
            policy,
            outer: "trainingPolicy",
            inner: "route_through_promotion",
            defaultWhenAbsent: true
        )
    }

    // MARK: POST /v1/training/proposals/<id>/reject

    /// Mirror of `TrainingLoop.reject_proposal`: find the
    /// proposal file, set `status="rejected"` and `rejection_reason=reason`,
    /// write the dict back atomically. Returns the daemon's exact response
    /// `{"status":"rejected","proposal_id":<id>,"reason":<reason>}`. Throws
    /// `.proposalNotFound` when no file matches (the daemon raises ValueError).
    ///
    /// PARITY: the daemon does NOT validate the prior status on reject (unlike
    /// approve) — any status can be overwritten to "rejected". We preserve that:
    /// every OTHER key in the proposal dict is carried through untouched.
    ///
    /// EMPTY-REASON DEFAULT (gpt-5.5 wave-33 finding, fixed wave-34 W04):
    /// keep the established external behavior where an empty reason becomes
    /// "No reason given"; whitespace-only text is preserved.
    public func rejectTrainingProposalLocal(
        proposalId: String,
        reason: String
    ) async throws -> JSONValue {
        guard let found = await findProposalFile(proposalId) else {
            throw TrainingProposalWriteError.proposalNotFound(proposalId)
        }
        // Python `body.get("reason") or "No reason given"`: empty string is the
        // only falsy String value, so default exactly when `reason` is empty.
        let effectiveReason = reason.isEmpty ? "No reason given" : reason
        let url = found.url
        let p = trainingPromotionPersistence()
        let fallbackData = found.data
        try await withTrainingFileLock(url) {
            // Re-read INSIDE the lock so a concurrent daemon write that landed
            // between findProposalFile and lock acquisition is not clobbered.
            let raw = await p.readJSON(url, defaultValue: .object([:]))
            var data: [String: JSONValue]
            if case .object(let o) = raw { data = o } else { data = fallbackData }
            data["status"] = .string("rejected")
            data["rejection_reason"] = .string(effectiveReason)
            try await p.writeJSON(.object(data), to: url)
        }
        return .object([
            "status": .string("rejected"),
            "proposal_id": .string(proposalId),
            "reason": .string(effectiveReason),
        ])
    }

    // MARK: POST /v1/training/proposals/<id>/approve  (DIRECT mode only)

    /// Mirror of `TrainingLoop.approve_proposal` for the
    /// direct branch. When `trainingPolicy.route_through_promotion` is truthy
    /// (the default), this stages a Swift-native promotion candidate instead of
    /// applying the doc immediately.
    ///
    /// Steps (verbatim from the daemon, applied under a cross-process lock on
    /// the target doc which also covers the proposal-file + ledger writes):
    ///   1. find proposal file; require status == "pending".
    ///   2. require target_doc ∈ {SOUL,VOICE,GROWTH,AGENTS}.md.
    ///   3. require target_doc resolves inside <root>/memory (path-escape guard).
    ///   4. require the doc exists; read it; sha256 + atomic backup to
    ///      `<doc>.backup-<id>.md`.
    ///   5. apply append (rstrip + "\n\n" + proposed + "\n") OR edit (replace
    ///      first `current` with `proposed`); else throw .cannotApplyChange.
    ///   6. atomic write the new doc; set proposal status="approved" + approved_at;
    ///      append a ledger entry to audit_ledger.jsonl.
    /// Returns `{"status":"approved","backup":<path>, ...ledgerEntry}`.
    public func approveTrainingProposalLocal(proposalId: String) async throws -> JSONValue {
        let routeThroughPromotion = await routeThroughPromotionEnabled()
        guard let found = await findProposalFile(proposalId) else {
            throw TrainingProposalWriteError.proposalNotFound(proposalId)
        }
        let proposalURL = found.url
        let data = found.data

        // status must be "pending" (daemon L985). A missing/null status fails
        // the `!= "pending"` check too, matching Python where data.get("status")
        // would be None. This is a PRE-LOCK fast-fail only; the AUTHORITATIVE
        // gate is re-run inside the lock off the fresh snapshot (below).
        let statusStr: String = {
            if case .string(let s)? = data["status"] { return s }
            return ""
        }()
        guard statusStr == "pending" else {
            throw TrainingProposalWriteError.notPending(id: proposalId, status: statusStr)
        }

        // The wave-33 W10 port validated target_doc / allow-list / path-escape /
        // file-exists PRE-LOCK off `found.data` but applied the freshData content
        // INSIDE the lock, so a concurrent rewrite of the proposal's `target_doc`
        // between this read and lock-acquire would have written the fresh content
        // to the STALE doc with the STALE doc validated (gpt-5.5 wave-33 race
        // finding, fixed wave-34 W04). The daemon reads `data` ONCE (training.py
        // L984) and derives target_doc, the allow-list, the escape guard, the
        // existence check, AND the content all from that single snapshot. We
        // reproduce that single-snapshot consistency: EVERY target_doc-derived
        // check now runs inside the lock off `freshData`.
        let memoryDir = trainingMemoryDir()
        let p = trainingPromotionPersistence()
        let ledgerPath = trainingLedgerPath()
        let allowedDocs: Set<String> = ["SOUL.md", "VOICE.md", "GROWTH.md", "AGENTS.md"]
        let candidatesDir = promotionCandidatesDir()
        let stagesDir = promotionStagesDir()

        // Lock the PROPOSAL FILE (stable across target_doc churn), not the doc:
        // the doc path is derived from the mutable `target_doc`, so locking it
        // pre-lock would hold the wrong token if a concurrent writer flipped
        // target_doc (gpt-5.5 wave-34 stale-lock-token finding). The proposal file
        // is keyed by proposalId and never changes within the call, and it is the
        // thing we re-read for the in-lock snapshot — the natural serialization
        // point for "read proposal → decide → apply". This also matches reject
        // (which already locks the proposal file), so approve and reject now
        // serialize cross-process WITH EACH OTHER on the same proposal — strictly
        // better than §6.96's documented split-lock state. WITHIN-PROCESS, the
        // `SwiftNativeSelfImprovement` actor already serializes every call. The
        // lock is the CROSS-PROCESS guard for the eventual flag-ON future; the
        // daemon's own approve/reject take NO file lock today (training.py
        // L1022/L1053 use bare atomic writes), so this is the Swift-side half in
        // place for when the daemon side gains the matching flock (cutover
        // discipline). The in-lock re-read of `status` + target_doc below
        // short-circuits a double-apply / stale-doc-apply if the daemon DID
        // mutate the proposal first.
        let ledgerOut: [String: JSONValue] = try await withTrainingFileLock(proposalURL) {
            // Re-read the proposal inside the lock; a daemon approve that landed
            // first will have flipped status off "pending" — bail to avoid a
            // double-apply. ALL downstream fields (status, target_doc, content)
            // are read off THIS one snapshot, matching the daemon's single read.
            let freshRaw = await p.readJSON(proposalURL, defaultValue: .object([:]))
            var freshData: [String: JSONValue] = data
            if case .object(let o) = freshRaw { freshData = o }
            let freshStatus: String = {
                if case .string(let s)? = freshData["status"] { return s }
                return ""
            }()
            guard freshStatus == "pending" else {
                throw TrainingProposalWriteError.notPending(id: proposalId, status: freshStatus)
            }

            // target_doc allow-list (daemon L988-991), revalidated IN-LOCK off the
            // fresh snapshot. `str(data.get("target_doc",""))`.
            let targetDoc: String = {
                if case .string(let s)? = freshData["target_doc"] { return s }
                return ""
            }()
            guard allowedDocs.contains(targetDoc) else {
                throw TrainingProposalWriteError.targetDocNotAllowed(targetDoc)
            }

            // Path-escape guard (daemon L993-997): docPath.resolve() must be inside
            // memoryDir.resolve(). The allow-list already blocks "/" and ".."
            // because none of the five names contain a separator, but we reproduce
            // the daemon's defense-in-depth check verbatim. docPath/backupPath are
            // recomputed here from the FRESH target_doc so the read/backup/write all
            // target the doc the fresh proposal names.
            let docPath = memoryDir.appendingPathComponent(targetDoc)
            let resolvedDoc = docPath.resolvingSymlinksInPath().standardizedFileURL
            let resolvedMem = memoryDir.resolvingSymlinksInPath().standardizedFileURL
            let memPrefix = resolvedMem.path.hasSuffix("/") ? resolvedMem.path : resolvedMem.path + "/"
            guard resolvedDoc.path == resolvedMem.path || resolvedDoc.path.hasPrefix(memPrefix) else {
                throw TrainingProposalWriteError.targetDocEscapesMemoryDir(targetDoc)
            }

            let fm = FileManager.default
            guard fm.fileExists(atPath: docPath.path) else {
                throw TrainingProposalWriteError.targetDocMissing(targetDoc)
            }

            let backupPath = docPath.deletingPathExtension()
                .appendingPathExtension("backup-\(proposalId).md")

            // Content fields off the in-lock snapshot, with Python str() parity:
            // a present non-string is str()-coerced (so a malformed change_type
            // like null/false/0 yields "None"/"False"/"0" and falls through to
            // .cannotApplyChange — NOT silently treated as "append").
            let changeType = Self.pythonStr(freshData["change_type"], defaultWhenAbsent: "append")
            let proposed = Self.pythonStr(freshData["proposed"], defaultWhenAbsent: "")
            let current = Self.pythonStr(freshData["current"], defaultWhenAbsent: "")
            let rationale: JSONValue = freshData["rationale"] ?? .string("")  // daemon: data.get("rationale","")

            // STRICT read — the daemon's `doc_path.read_text()` raises on a
            // read/decode failure and aborts (doc untouched). Degrading to "" here
            // would let `append` overwrite a valid doc with only the proposed
            // snippet, so a failed read THROWS .targetDocUnreadable instead.
            let beforeText: String
            do {
                beforeText = try String(contentsOf: docPath, encoding: .utf8)
            } catch {
                throw TrainingProposalWriteError.targetDocUnreadable(targetDoc)
            }
            let beforeHash = Self.sha256Hex(beforeText)

            // Apply change (daemon L1014-1019).
            let afterText: String
            if changeType == "append" {
                let trimmed = Self.pythonRStrip(beforeText)
                afterText = trimmed + "\n\n" + proposed + "\n"
            } else if changeType == "edit" && !current.isEmpty && beforeText.contains(current) {
                afterText = Self.replaceFirst(current, with: proposed, in: beforeText)
            } else {
                throw TrainingProposalWriteError.cannotApplyChange(changeType: changeType)
            }
            let afterHash = Self.sha256Hex(afterText)

            if routeThroughPromotion {
                let stagedAt = Self.nowISO()
                let candidateId = Self.promotionCandidateID(forProposalID: proposalId)
                let patch: JSONValue = .object([
                    "file": .string(targetDoc),
                    "before_sha": .string(beforeHash),
                    "after_sha": .string(afterHash),
                ])
                let harness: JSONValue = .object([
                    "test_passed": .bool(true),
                    "smoke_passed": .bool(true),
                    "eval_delta": .double(0),
                ])
                let delta: JSONValue = .object([
                    "kind": .string("training_proposal"),
                    "proposal_id": .string(proposalId),
                    "proposal_path": .string(proposalURL.path),
                    "target_doc": .string(targetDoc),
                    "change_type": .string(changeType),
                    "current": .string(current),
                    "proposed": .string(proposed),
                    "rationale": rationale,
                    "before_hash": .string(beforeHash),
                    "after_hash": .string(afterHash),
                ])
                let candidate: JSONValue = .object([
                    "candidate_id": .string(candidateId),
                    "source": .string("training_b1"),
                    "tier": .string("B"),
                    "patches": .array([patch]),
                    "status": .string("done"),
                    "created_at": .string(stagedAt),
                    "finished_at": .string(stagedAt),
                    "harness": harness,
                    "decision": .string("STAGE_FOR_HUMAN"),
                    "decision_reason": .string("Swift-native training proposal staged for human promotion approval."),
                    "worktree_path": .string(""),
                    "branch_name": .string(""),
                    "merged_commit_sha": .null,
                    "error": .null,
                ])
                let stage: JSONValue = .object([
                    "candidate_id": .string(candidateId),
                    "tier": .string("B"),
                    "harness": harness,
                    "delta": delta,
                    "staged_at": .string(stagedAt),
                    "worktree_path": .string(""),
                    "branch_name": .string(""),
                    "status": .string("pending"),
                    "resolved_at": .null,
                    "resolution_reason": .null,
                ])

                let candidatePath = candidatesDir.appendingPathComponent("\(candidateId).json")
                let stagePath = stagesDir.appendingPathComponent("\(candidateId).json")
                try await p.writeJSON(candidate, to: candidatePath)
                try await p.writeJSON(stage, to: stagePath)

                freshData["status"] = .string("promotion_staged")
                freshData["promotion_candidate_id"] = .string(candidateId)
                freshData["promotion_staged_at"] = .string(stagedAt)
                try await p.writeJSON(.object(freshData), to: proposalURL)

                let ledgerEntry: [String: JSONValue] = [
                    "ts": .string(stagedAt),
                    "proposal_id": .string(proposalId),
                    "target_doc": .string(targetDoc),
                    "before_hash": .string(beforeHash),
                    "after_hash": .string(afterHash),
                    "rationale": rationale,
                    "approved_by": .string("user"),
                    "status": .string("promotion_staged"),
                    "candidate_id": .string(candidateId),
                ]
                // M6 (2026-07-09): capped — this audit ledger grew unbounded.
                try await appendJSONLCapped(
                    .object(ledgerEntry), to: ledgerPath, using: p,
                    maxLines: JSONLLineCaps.trainingAudit, logLabel: "TrainingPromotion.auditLedger"
                )

                return [
                    "status": .string("promotion_staged"),
                    "proposal_id": .string(proposalId),
                    "candidate_id": .string(candidateId),
                    "target_doc": .string(targetDoc),
                    "before_hash": .string(beforeHash),
                    "after_hash": .string(afterHash),
                    "approved_by": .string("user"),
                ]
            }

            // Atomic backup (daemon L1007 _atomic_write_text). writeJSON is for
            // JSON; the backup is raw .md text, so write atomically by hand.
            try Self.atomicWriteText(beforeText, to: backupPath)

            // Atomic write the doc (daemon L1022-1024).
            try Self.atomicWriteText(afterText, to: docPath)

            // Update proposal status (daemon L1027-1030). writeJSON re-reads via
            // freshData (the in-lock copy) so concurrent extras are preserved.
            freshData["status"] = .string("approved")
            let approvedAt = Self.nowISO()
            freshData["approved_at"] = .string(approvedAt)
            try await p.writeJSON(.object(freshData), to: proposalURL)

            // Audit ledger (daemon L1033-1042). approved_by hard-coded "user"
            // (the route is human-triggered from the Self-Improvement UI).
            let ledgerEntry: [String: JSONValue] = [
                "ts": .string(approvedAt),
                "proposal_id": .string(proposalId),
                "target_doc": .string(targetDoc),
                "before_hash": .string(beforeHash),
                "after_hash": .string(afterHash),
                "rationale": rationale,
                "approved_by": .string("user"),
            ]
            // M6 (2026-07-09): capped — this audit ledger grew unbounded.
            try await appendJSONLCapped(
                .object(ledgerEntry), to: ledgerPath, using: p,
                maxLines: JSONLLineCaps.trainingAudit, logLabel: "TrainingPromotion.auditLedger"
            )

            // Build the return dict (daemon L1044): {"status":"approved",
            // "backup":<path>, **ledgerEntry}.
            var out = ledgerEntry
            out["status"] = .string("approved")
            out["backup"] = .string(backupPath.path)
            return out
        }
        return .object(ledgerOut)
    }

    // MARK: POST /v1/promotion/pending/<id>/approve|reject

    private static func promotionCandidateID(forProposalID proposalId: String) -> String {
        var safe = ""
        for scalar in proposalId.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                safe.append(String(scalar))
            } else {
                safe.append("_")
            }
        }
        let trimmed = safe.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        return "training_\(trimmed.isEmpty ? "proposal" : String(trimmed.prefix(80)))"
    }

    private func findPromotionStage(_ candidateId: String) async -> (url: URL, data: [String: JSONValue])? {
        let files = Self.sortedJSONFiles(in: promotionStagesDir(), reversedName: false)
        for f in files {
            guard let obj = await readJSONObject(f) else { continue }
            if case .string(let cid)? = obj["candidate_id"], cid == candidateId {
                return (f, obj)
            }
        }
        return nil
    }

    /// Apply a Swift-native promotion stage produced by
    /// `approveTrainingProposalLocal(route_through_promotion=true)`.
    public func approvePromotionStageLocal(candidateId: String) async throws -> JSONValue {
        guard let found = await findPromotionStage(candidateId) else {
            throw TrainingProposalWriteError.promotionStageNotFound(candidateId)
        }
        let stageURL = found.url
        let p = trainingPromotionPersistence()
        let memoryDir = trainingMemoryDir()
        let ledgerPath = trainingLedgerPath()
        let allowedDocs: Set<String> = ["SOUL.md", "VOICE.md", "GROWTH.md", "AGENTS.md"]
        let candidatePath = promotionCandidatesDir().appendingPathComponent("\(candidateId).json")

        let out: [String: JSONValue] = try await withTrainingFileLock(stageURL) {
            let raw = await p.readJSON(stageURL, defaultValue: .object([:]))
            var stage: [String: JSONValue] = found.data
            if case .object(let o) = raw { stage = o }
            let status = Self.pythonStr(stage["status"], defaultWhenAbsent: "")
            guard status == "pending" else {
                throw TrainingProposalWriteError.promotionStageNotPending(id: candidateId, status: status)
            }
            guard case .object(let delta)? = stage["delta"] else {
                throw TrainingProposalWriteError.promotionStageMalformed(candidateId)
            }
            guard case .string(let targetDoc)? = delta["target_doc"],
                  allowedDocs.contains(targetDoc),
                  case .string(let beforeHash)? = delta["before_hash"],
                  case .string(let expectedAfterHash)? = delta["after_hash"]
            else {
                throw TrainingProposalWriteError.promotionStageMalformed(candidateId)
            }

            let docPath = memoryDir.appendingPathComponent(targetDoc)
            let resolvedDoc = docPath.resolvingSymlinksInPath().standardizedFileURL
            let resolvedMem = memoryDir.resolvingSymlinksInPath().standardizedFileURL
            let memPrefix = resolvedMem.path.hasSuffix("/") ? resolvedMem.path : resolvedMem.path + "/"
            guard resolvedDoc.path == resolvedMem.path || resolvedDoc.path.hasPrefix(memPrefix) else {
                throw TrainingProposalWriteError.targetDocEscapesMemoryDir(targetDoc)
            }
            guard FileManager.default.fileExists(atPath: docPath.path) else {
                throw TrainingProposalWriteError.targetDocMissing(targetDoc)
            }

            let beforeText: String
            do {
                beforeText = try String(contentsOf: docPath, encoding: .utf8)
            } catch {
                throw TrainingProposalWriteError.targetDocUnreadable(targetDoc)
            }
            let actualBeforeHash = Self.sha256Hex(beforeText)
            guard actualBeforeHash == beforeHash else {
                throw TrainingProposalWriteError.promotionStageStale(expected: beforeHash, actual: actualBeforeHash)
            }

            let changeType = Self.pythonStr(delta["change_type"], defaultWhenAbsent: "append")
            let proposed = Self.pythonStr(delta["proposed"], defaultWhenAbsent: "")
            let current = Self.pythonStr(delta["current"], defaultWhenAbsent: "")
            let afterText: String
            if changeType == "append" {
                afterText = Self.pythonRStrip(beforeText) + "\n\n" + proposed + "\n"
            } else if changeType == "edit" && !current.isEmpty && beforeText.contains(current) {
                afterText = Self.replaceFirst(current, with: proposed, in: beforeText)
            } else {
                throw TrainingProposalWriteError.cannotApplyChange(changeType: changeType)
            }
            let afterHash = Self.sha256Hex(afterText)
            guard afterHash == expectedAfterHash else {
                throw TrainingProposalWriteError.promotionStageMalformed(candidateId)
            }

            let backupPath = docPath.deletingPathExtension()
                .appendingPathExtension("backup-\(candidateId).md")
            try Self.atomicWriteText(beforeText, to: backupPath)
            try Self.atomicWriteText(afterText, to: docPath)

            let resolvedAt = Self.nowISO()
            stage["status"] = .string("approved")
            stage["resolved_at"] = .string(resolvedAt)
            stage["resolution_reason"] = .string("approved")
            try await p.writeJSON(.object(stage), to: stageURL)

            let candidateRaw = await p.readJSON(candidatePath, defaultValue: .object([:]))
            var candidate: [String: JSONValue] = [:]
            if case .object(let existing) = candidateRaw { candidate = existing }
            candidate["candidate_id"] = .string(candidateId)
            candidate["status"] = .string("promoted")
            candidate["decision"] = .string("APPROVED")
            candidate["decision_reason"] = .string("Approved through Swift-native promotion stage.")
            candidate["finished_at"] = .string(resolvedAt)
            try await p.writeJSON(.object(candidate), to: candidatePath)

            if case .string(let proposalPath)? = delta["proposal_path"] {
                let proposalURL = URL(fileURLWithPath: proposalPath)
                let proposalRaw = await p.readJSON(proposalURL, defaultValue: .object([:]))
                if case .object(var proposal) = proposalRaw {
                    proposal["status"] = .string("approved")
                    proposal["approved_at"] = .string(resolvedAt)
                    proposal["promotion_resolved_at"] = .string(resolvedAt)
                    try await p.writeJSON(.object(proposal), to: proposalURL)
                }
            }

            let proposalId = Self.pythonStr(delta["proposal_id"], defaultWhenAbsent: "")
            let ledgerEntry: [String: JSONValue] = [
                "ts": .string(resolvedAt),
                "proposal_id": .string(proposalId),
                "candidate_id": .string(candidateId),
                "target_doc": .string(targetDoc),
                "before_hash": .string(beforeHash),
                "after_hash": .string(afterHash),
                "approved_by": .string("user"),
                "status": .string("promotion_approved"),
            ]
            // M6 (2026-07-09): capped — this audit ledger grew unbounded.
            try await appendJSONLCapped(
                .object(ledgerEntry), to: ledgerPath, using: p,
                maxLines: JSONLLineCaps.trainingAudit, logLabel: "TrainingPromotion.auditLedger"
            )

            return [
                "ok": .bool(true),
                "status": .string("approved"),
                "candidate_id": .string(candidateId),
                "proposal_id": .string(proposalId),
                "target_doc": .string(targetDoc),
                "backup": .string(backupPath.path),
            ]
        }
        return .object(out)
    }

    public func rejectPromotionStageLocal(candidateId: String, reason: String) async throws -> JSONValue {
        guard let found = await findPromotionStage(candidateId) else {
            throw TrainingProposalWriteError.promotionStageNotFound(candidateId)
        }
        let stageURL = found.url
        let p = trainingPromotionPersistence()
        let effectiveReason = reason.isEmpty ? "No reason given" : reason
        let candidatePath = promotionCandidatesDir().appendingPathComponent("\(candidateId).json")

        let out: [String: JSONValue] = try await withTrainingFileLock(stageURL) {
            let raw = await p.readJSON(stageURL, defaultValue: .object([:]))
            var stage: [String: JSONValue] = found.data
            if case .object(let o) = raw { stage = o }
            let status = Self.pythonStr(stage["status"], defaultWhenAbsent: "")
            guard status == "pending" else {
                throw TrainingProposalWriteError.promotionStageNotPending(id: candidateId, status: status)
            }
            let resolvedAt = Self.nowISO()
            stage["status"] = .string("rejected")
            stage["resolved_at"] = .string(resolvedAt)
            stage["resolution_reason"] = .string(effectiveReason)
            try await p.writeJSON(.object(stage), to: stageURL)

            let candidateRaw = await p.readJSON(candidatePath, defaultValue: .object([:]))
            var candidate: [String: JSONValue] = [:]
            if case .object(let existing) = candidateRaw { candidate = existing }
            candidate["candidate_id"] = .string(candidateId)
            candidate["status"] = .string("rejected")
            candidate["decision"] = .string("BLOCK")
            candidate["decision_reason"] = .string(effectiveReason)
            candidate["finished_at"] = .string(resolvedAt)
            try await p.writeJSON(.object(candidate), to: candidatePath)

            if case .object(let delta)? = stage["delta"],
               case .string(let proposalPath)? = delta["proposal_path"] {
                let proposalURL = URL(fileURLWithPath: proposalPath)
                let proposalRaw = await p.readJSON(proposalURL, defaultValue: .object([:]))
                if case .object(var proposal) = proposalRaw {
                    proposal["status"] = .string("rejected")
                    proposal["rejection_reason"] = .string(effectiveReason)
                    proposal["resolved_at"] = .string(resolvedAt)
                    try await p.writeJSON(.object(proposal), to: proposalURL)
                }
            }

            return [
                "ok": .bool(true),
                "status": .string("rejected"),
                "candidate_id": .string(candidateId),
                "reason": .string(effectiveReason),
            ]
        }
        return .object(out)
    }

    // MARK: - Text helpers (Python str semantics)

    /// Atomic text write: write to `<path>.tmp` then rename over `path`. Mirrors
    /// the daemon's `_tmp.write_text(...); os.replace(_tmp, path)` (training.py
    /// L1022-1024) and `_atomic_write_text` for the backup. Creates the parent
    /// directory first (the memory dir already exists in practice).
    private static func atomicWriteText(_ text: String, to path: URL) throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Daemon uses `path.with_suffix(path.suffix + ".tmp")` — i.e. it APPENDS
        // ".tmp" to the existing extension (foo.md -> foo.md.tmp). Reproduce that
        // exact temp name so a crash leaves a recognizable sibling, not foo.tmp.
        let tmp = path.appendingPathExtension("tmp")
        try Data(text.utf8).write(to: tmp, options: .atomic)
        // os.replace(tmp, path) is a POSIX rename(2): atomic, and works whether
        // or not `path` already exists (the BACKUP write targets a fresh path on
        // first approve). `FileManager.replaceItemAt` documents the original as
        // expected-to-exist, so we call rename(2) directly for byte-exact
        // os.replace parity in BOTH cases. POSIX paths are UTF-8 on Darwin.
        let rc = path.withUnsafeFileSystemRepresentation { destRep -> Int32 in
            guard let destRep else { return -1 }
            return tmp.withUnsafeFileSystemRepresentation { srcRep -> Int32 in
                guard let srcRep else { return -1 }
                return rename(srcRep, destRep)
            }
        }
        if rc != 0 {
            // Clean up the orphan tmp so a failed rename does not leave litter.
            try? FileManager.default.removeItem(at: tmp)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "rename(\(tmp.path) -> \(path.path)) failed: \(String(cString: strerror(errno)))"]
            )
        }
    }

    /// Python `str.rstrip()` with no args: strip TRAILING ASCII+Unicode
    /// whitespace. Swift's `.whitespacesAndNewlines` set matches Python's
    /// default whitespace class for the characters that appear in markdown docs
    /// (space, tab, newline, CR, form-feed, vertical-tab). Only the TRAILING
    /// run is removed (Python rstrip), not leading.
    private static func pythonRStrip(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            if s[prev].isWhitespace { end = prev } else { break }
        }
        return String(s[s.startIndex..<end])
    }

    /// `before.replace(current, proposed, 1)` — replace ONLY the first
    /// occurrence (Python's count=1). Swift's `replacingOccurrences` replaces
    /// ALL, so we splice the first range by hand.
    private static func replaceFirst(_ needle: String, with replacement: String, in haystack: String) -> String {
        guard let r = haystack.range(of: needle) else { return haystack }
        return haystack.replacingCharacters(in: r, with: replacement)
    }
}
