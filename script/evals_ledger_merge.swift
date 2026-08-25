#!/usr/bin/env swift
// Merge eval-coverage ledger fragments (docs/evals/ledger.schema.json shape) into
// docs/evals/ledger.json and render docs/evals/COVERAGE.md.
//
// usage: swift script/evals_ledger_merge.swift <fragments.json> [--out docs/evals]
//        [--overrides docs/evals/coverage-overrides.json]
//        [--campaigns docs/evals/coverage-campaigns.json]
// fragments.json = the phase-1 workflow return: [{fence, fragment, critic}, ...]
// Critic 'missed' surfaces are merged in (tagged source=critic); 'disputed' ids are
// annotated, never dropped — the ledger shows the dispute.
//
// Direct port of script/evals_ledger_merge.py (retired 2026-08-23, zero-Python canon).
// Behavior is byte-identical: dedupe keeps the FIRST row and unions coverage;
// Coverage entries without an explicit `strength` are incidental, never
// asserting. Optional overrides are keyed by (fence,id) and are the durable
// source for post-inventory eval work; generated ledger files are never the
// source of truth.

import Foundation

// MARK: - Python-compatible helpers

func pyTruthy(_ v: Any?) -> Bool {
    guard let v = v, !(v is NSNull) else { return false }
    if let n = v as? NSNumber {
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        return n.doubleValue != 0
    }
    if let s = v as? String { return !s.isEmpty }
    if let a = v as? [Any] { return !a.isEmpty }
    if let d = v as? [String: Any] { return !d.isEmpty }
    return true
}

func pyStr(_ v: Any?) -> String {
    guard let v = v, !(v is NSNull) else { return "None" }
    if let n = v as? NSNumber {
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "True" : "False" }
        if CFNumberIsFloatType(n) { return "\(n.doubleValue)" }
        return "\(n.int64Value)"
    }
    if let s = v as? String { return s }
    return "\(v)"
}

/// Python code-point string comparison (sorted(), sort_keys use this).
func pyLess(_ a: String, _ b: String) -> Bool {
    var ai = a.unicodeScalars.makeIterator(), bi = b.unicodeScalars.makeIterator()
    while true {
        switch (ai.next(), bi.next()) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case let (x?, y?):
            if x.value != y.value { return x.value < y.value }
        }
    }
}

/// json.dumps string escaping with ensure_ascii=True.
func pyJSONString(_ s: String) -> String {
    var out = "\""
    for u in s.unicodeScalars {
        switch u {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\u{08}": out += "\\b"
        case "\u{09}": out += "\\t"
        case "\u{0A}": out += "\\n"
        case "\u{0C}": out += "\\f"
        case "\u{0D}": out += "\\r"
        default:
            if u.value < 0x20 {
                out += String(format: "\\u%04x", u.value)
            } else if u.value < 0x7F {
                out.unicodeScalars.append(u)
            } else if u.value <= 0xFFFF {
                out += String(format: "\\u%04x", u.value)
            } else {
                let v = u.value - 0x10000
                out += String(format: "\\u%04x\\u%04x", 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF))
            }
        }
    }
    return out + "\""
}

/// json.dump(obj, indent=1, sort_keys=True, ensure_ascii=True) — exact format.
func pyJSON(_ v: Any?, _ level: Int) -> String {
    let pad = String(repeating: " ", count: level + 1)
    let close = String(repeating: " ", count: level)
    guard let v = v, !(v is NSNull) else { return "null" }
    if let n = v as? NSNumber {
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
        if CFNumberIsFloatType(n) { return "\(n.doubleValue)" }
        return "\(n.int64Value)"
    }
    if let s = v as? String { return pyJSONString(s) }
    if let a = v as? [Any] {
        if a.isEmpty { return "[]" }
        let items = a.map { pad + pyJSON($0, level + 1) }
        return "[\n" + items.joined(separator: ",\n") + "\n" + close + "]"
    }
    if let d = v as? [String: Any] {
        if d.isEmpty { return "{}" }
        let keys = d.keys.sorted(by: pyLess)
        let items = keys.map { pad + pyJSONString($0) + ": " + pyJSON(d[$0], level + 1) }
        return "{\n" + items.joined(separator: ",\n") + "\n" + close + "}"
    }
    fatalError("unserializable value: \(v)")
}

/// Counter with Python insertion-order semantics.
struct PyCounter {
    private(set) var counts: [String: Int] = [:]
    private(set) var order: [String] = []
    mutating func add(_ k: String) {
        if counts[k] == nil { order.append(k) }
        counts[k, default: 0] += 1
    }
    subscript(k: String) -> Int { counts[k] ?? 0 }
    /// most_common(): count desc, ties in insertion order (Python's stable sort).
    func mostCommon() -> [(String, Int)] {
        return order.enumerated()
            .sorted { l, r in
                let cl = counts[l.element]!, cr = counts[r.element]!
                if cl != cr { return cl > cr }
                return l.offset < r.offset
            }
            .map { ($0.element, counts[$0.element]!) }
    }
    /// dict(counter) repr — insertion order, Python literal style.
    func dictRepr() -> String {
        if order.isEmpty { return "{}" }
        return "{" + order.map { "'\($0)': \(counts[$0]!)" }.joined(separator: ", ") + "}"
    }
}

// MARK: - Args + load

let argv = CommandLine.arguments
guard argv.count > 1 else {
    FileHandle.standardError.write("usage: swift script/evals_ledger_merge.swift <fragments.json> [--out docs/evals] [--overrides FILE]\n".data(using: .utf8)!)
    exit(1)
}
let src = argv[1]
var out = "docs/evals"
if let i = argv.firstIndex(of: "--out"), i + 1 < argv.count { out = argv[i + 1] }
var overridesPath: String? = nil
if let i = argv.firstIndex(of: "--overrides"), i + 1 < argv.count {
    overridesPath = argv[i + 1]
} else {
    let candidate = URL(fileURLWithPath: src).deletingLastPathComponent()
        .appendingPathComponent("coverage-overrides.json").path
    if FileManager.default.fileExists(atPath: candidate) { overridesPath = candidate }
}
var campaignsPath: String? = nil
if let i = argv.firstIndex(of: "--campaigns"), i + 1 < argv.count {
    campaignsPath = argv[i + 1]
} else {
    let candidate = URL(fileURLWithPath: src).deletingLastPathComponent()
        .appendingPathComponent("coverage-campaigns.json").path
    if FileManager.default.fileExists(atPath: candidate) { campaignsPath = candidate }
}

guard let raw = FileManager.default.contents(atPath: src),
      let data = (try? JSONSerialization.jsonObject(with: raw)) as? [Any] else {
    FileHandle.standardError.write("cannot load fragments array from \(src)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Merge (port of lines 14-38 of the .py)

struct FenceID: Hashable { let fence: String?; let id: String? }

var rows: [[String: Any]] = []
var disputes: [FenceID: Any?] = [:]
var ran: [String: Any] = [:]
var ranOrderMatters = false  // ran/uncertain serialize sorted; order irrelevant
_ = ranOrderMatters
var uncertain: [String: Any] = [:]

let allowedKinds: Set<String> = [
    "public-api", "setting", "ui-control", "ui-summary", "store-write",
    "feed", "loop", "tool", "route", "env", "cli", "telemetry",
    "turn-ingredient", "speed-stage", "other",
]
let allowedTiers: Set<String> = ["instrument", "bench", "test", "smoke", "ui-walk", "turn-replay"]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("eval ledger: " + message + "\n").data(using: .utf8)!)
    exit(2)
}

func validateSurface(_ surface: [String: Any], fence: String?) {
    guard let fence, !fence.isEmpty else { fail("surface has no fence") }
    guard let id = str(surface["id"]), !id.isEmpty else { fail("\(fence): surface has no id") }
    guard let kind = str(surface["kind"]), allowedKinds.contains(kind) else {
        fail("\(fence).\(id): unknown or missing kind '\(pyStr(surface["kind"]))'")
    }
    guard let whereText = str(surface["where"]), !whereText.isEmpty else {
        fail("\(fence).\(id): missing where")
    }
    guard surface["coverage"] is [Any] else { fail("\(fence).\(id): coverage must be an array") }
    for case let coverage as [String: Any] in (surface["coverage"] as? [Any]) ?? [] {
        guard let tier = str(coverage["tier"]), allowedTiers.contains(tier) else {
            fail("\(fence).\(id): invalid coverage tier '\(pyStr(coverage["tier"]))'")
        }
        guard let ref = str(coverage["ref"]), !ref.isEmpty else { fail("\(fence).\(id): coverage ref is empty") }
        if let strength = str(coverage["strength"]), !["asserts", "reports-only", "incidental"].contains(strength) {
            fail("\(fence).\(id): invalid coverage strength '\(strength)'")
        }
    }
}

func str(_ v: Any?) -> String? { (v is NSNull) ? nil : v as? String }

for case let entry as [String: Any] in data {
    let fRaw = entry["fence"]
    let f = str(fRaw)
    let frag = (entry["fragment"] as? [String: Any]) ?? [:]
    let crit = (entry["critic"] as? [String: Any]) ?? [:]
    if let f = f { ran[f] = frag["ranRun"] ?? NSNull() }
    if let f = f { uncertain[f] = pyTruthy(frag["uncertain"]) ? frag["uncertain"]! : [Any]() }
    for case var s as [String: Any] in (frag["surfaces"] as? [Any]) ?? [] {
        validateSurface(s, fence: f)
        s["fence"] = fRaw ?? NSNull(); s["source"] = "inventory"; rows.append(s)
    }
    for case var s as [String: Any] in (crit["missed"] as? [Any]) ?? [] {
        validateSurface(s, fence: f)
        s["fence"] = fRaw ?? NSNull(); s["source"] = "critic"; rows.append(s)
    }
    for case let d as [String: Any] in (crit["disputed"] as? [Any]) ?? [] {
        disputes[FenceID(fence: f, id: str(d["id"]))] = d["why"] ?? NSNull()
    }
}

// dedupe by (fence,id): keep the first, union coverage
var seenIndex: [FenceID: Int] = [:]
var deduped: [[String: Any]] = []
for s in rows {
    let k = FenceID(fence: str(s["fence"]), id: str(s["id"]))
    if let i = seenIndex[k] {
        let old = (pyTruthy(deduped[i]["coverage"]) ? deduped[i]["coverage"] as? [Any] : []) ?? []
        let new = (pyTruthy(s["coverage"]) ? s["coverage"] as? [Any] : []) ?? []
        deduped[i]["coverage"] = old + new
        let oldWhere = pyStr(deduped[i]["where"])
        let newWhere = pyStr(s["where"])
        if oldWhere != newWhere {
            deduped[i]["where"] = oldWhere + "; duplicate inventory site: " + newWhere
        }
        continue
    }
    seenIndex[k] = deduped.count
    deduped.append(s)
}
rows = deduped

// Post-inventory work is captured here, not by editing generated ledger.json.
// Each row is a partial surface object keyed by fence + id. Unknown ids are a
// hard error so a rename cannot silently discard hundreds of hours of evals.
if let overridesPath {
    guard let overrideData = FileManager.default.contents(atPath: overridesPath),
          let overrides = try? JSONSerialization.jsonObject(with: overrideData) as? [[String: Any]] else {
        fail("cannot load overrides array from \(overridesPath)")
    }
    var overrideKeys: Set<FenceID> = []
    for patch in overrides {
        let key = FenceID(fence: str(patch["fence"]), id: str(patch["id"]))
        guard overrideKeys.insert(key).inserted else {
            fail("duplicate override for \(pyStr(patch["fence"])).\(pyStr(patch["id"]))")
        }
        if let index = seenIndex[key] {
            for (field, value) in patch where field != "fence" && field != "id" {
                rows[index][field] = value
            }
            validateSurface(rows[index], fence: key.fence)
        } else {
            var added = patch
            added["source"] = added["source"] ?? "override"
            validateSurface(added, fence: key.fence)
            seenIndex[key] = rows.count
            rows.append(added)
        }
    }
}

// A campaign is a frozen, reviewed set of existing surface IDs sharing one
// cross-cutting evaluator. It keeps a 641-row coverage closure reproducible
// without duplicating the same ref 641 times in coverage-overrides.json.
if let campaignsPath {
    guard let campaignData = FileManager.default.contents(atPath: campaignsPath),
          let campaigns = try? JSONSerialization.jsonObject(with: campaignData) as? [[String: Any]] else {
        fail("cannot load campaigns array from \(campaignsPath)")
    }
    let campaignDirectory = URL(fileURLWithPath: campaignsPath).deletingLastPathComponent()
    var names: Set<String> = []
    for campaign in campaigns {
        guard let name = str(campaign["name"]), !name.isEmpty, names.insert(name).inserted else {
            fail("campaign has missing or duplicate name")
        }
        guard let idsFile = str(campaign["surfaceIDsFile"]), !idsFile.isEmpty else {
            fail("campaign \(name) has no surfaceIDsFile")
        }
        let idsURL = campaignDirectory.appendingPathComponent(idsFile)
        guard let idsData = FileManager.default.contents(atPath: idsURL.path),
              let idsObject = try? JSONSerialization.jsonObject(with: idsData) as? [String: Any],
              let surfaces = idsObject["surfaces"] as? [[String: Any]] else {
            fail("campaign \(name) cannot load surfaces from \(idsURL.path)")
        }
        let keys = surfaces.map { FenceID(fence: str($0["fence"]), id: str($0["id"])) }
        guard Set(keys).count == keys.count else { fail("campaign \(name) contains duplicate fence/ID keys") }
        let excludedEntries = (campaign["excludeSurfaceIDs"] as? [[String: Any]]) ?? []
        let excludedKeys = Set(excludedEntries.map { FenceID(fence: str($0["fence"]), id: str($0["id"])) })
        guard excludedKeys.count == excludedEntries.count else {
            fail("campaign \(name) contains duplicate excludeSurfaceIDs keys")
        }
        guard excludedKeys.allSatisfy({ key in
            guard let fence = key.fence, let id = key.id, !fence.isEmpty, !id.isEmpty else { return false }
            return keys.contains(key)
        }) else {
            fail("campaign \(name) has an invalid excludeSurfaceIDs key")
        }
        guard let campaignCoverage = campaign["coverage"] as? [[String: Any]], !campaignCoverage.isEmpty else {
            fail("campaign \(name) has no coverage")
        }
        for key in keys {
            guard !excludedKeys.contains(key) else { continue }
            guard let index = seenIndex[key] else {
                fail("campaign \(name) surface is missing: \(pyStr(key.fence)).\(pyStr(key.id))")
            }
            let existing = (rows[index]["coverage"] as? [Any]) ?? []
            rows[index]["coverage"] = existing + campaignCoverage
            validateSurface(rows[index], fence: key.fence)
        }
    }
}

for i in rows.indices {
    let cov = (pyTruthy(rows[i]["coverage"]) ? rows[i]["coverage"] as? [Any] : []) ?? []
    let asserts = cov.contains { c in
        let cd = c as? [String: Any] ?? [:]
        let strength = cd["strength"].flatMap { $0 is NSNull ? nil : $0 as? String } ?? "incidental"
        return strength == "asserts"
    }
    rows[i]["status"] = asserts ? "COVERED" : (cov.isEmpty ? "UNCOVERED" : "REPORTS-ONLY")
    let k = FenceID(fence: str(rows[i]["fence"]), id: str(rows[i]["id"]))
    if let why = disputes[k] { rows[i]["disputed"] = why ?? NSNull() }
}

try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

// generatedAt = datetime.datetime.now(datetime.timezone.utc).isoformat()
var utcCal = Calendar(identifier: .gregorian)
utcCal.timeZone = TimeZone(identifier: "UTC")!
let now = Date()
let c = utcCal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: now)
let micro = (c.nanosecond ?? 0) / 1000
var generatedAt = String(format: "%04d-%02d-%02dT%02d:%02d:%02d",
                         c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
if micro != 0 { generatedAt += String(format: ".%06d", micro) }
generatedAt += "+00:00"

let ledgerObj: [String: Any] = ["generatedAt": generatedAt, "surfaces": rows,
                                "ranRun": ran, "uncertain": uncertain]
try! pyJSON(ledgerObj, 0).write(toFile: "\(out)/ledger.json", atomically: true, encoding: .utf8)

// MARK: - Render (port of lines 43-69 of the .py)

var byFenceOrder: [String] = []
var byFence: [String: [[String: Any]]] = [:]
for s in rows {
    let f = pyStr(s["fence"])  // dict key: None would break sorted() in Python too; data always has fences
    if byFence[f] == nil { byFenceOrder.append(f) }
    byFence[f, default: []].append(s)
}
var tot = PyCounter()
for s in rows { tot.add(pyStr(s["status"])) }

// date.today() — local date
let localCal = Calendar.current
let lc = localCal.dateComponents([.year, .month, .day], from: Date())
let today = String(format: "%04d-%02d-%02d", lc.year!, lc.month!, lc.day!)

var L: [String] = ["# Eval coverage — NativeAgent", "",
                   "_generated \(today) from phase-1 fragments; \(rows.count) surfaces across \(byFence.count) fences._", "",
                   "**COVERED \(tot["COVERED"]) · REPORTS-ONLY \(tot["REPORTS-ONLY"]) · UNCOVERED \(tot["UNCOVERED"])**", "",
                   "**Behaviorally open: \(tot["REPORTS-ONLY"] + tot["UNCOVERED"])** (mapped/structural evidence is useful, but only `COVERED` means an asserting evaluator executed.)", "",
                   "## Uncovered by silent-failure class (keyword-classified; refine in phase 2)", ""]
var cls = PyCounter()
for s in rows {
    if pyStr(s["status"]) != "COVERED" {
        let m = (pyTruthy(s["silentFailureMode"]) ? pyStr(s["silentFailureMode"]) : "unstated").lowercased()
        let keys = ["lifecycle", "leak", "silent zero", "zero", "dead", "slow", "wrong", "stale", "drop"]
        cls.add(keys.first { m.contains($0) } ?? "other")
    }
}
L += cls.mostCommon().map { "- \($0.0): \($0.1)" } + [""]

for f in byFence.keys.sorted(by: pyLess) {
    let ss = byFence[f]!
    var cc = PyCounter()
    for s in ss { cc.add(pyStr(s["status"])) }
    L += ["## \(f)  — COVERED \(cc["COVERED"]) · REPORTS-ONLY \(cc["REPORTS-ONLY"]) · UNCOVERED \(cc["UNCOVERED"])", "",
          "_ran: \(pyTruthy(ran[f]) ? pyStr(ran[f]) : "—")_", "",
          "| surface | kind | status | coverage | silent failure | proposed eval |", "|---|---|---|---|---|---|"]
    let sortedSS = ss.enumerated().sorted { l, r in
        let ls = pyStr(l.element["status"]), rs = pyStr(r.element["status"])
        let lk = (ls != "UNCOVERED" ? 1 : 0, ls != "REPORTS-ONLY" ? 1 : 0)
        let rk = (rs != "UNCOVERED" ? 1 : 0, rs != "REPORTS-ONLY" ? 1 : 0)
        if lk != rk { return lk < rk }
        let li = pyStr(l.element["id"]), ri = pyStr(r.element["id"])
        if li != ri { return pyLess(li, ri) }
        return l.offset < r.offset
    }.map { $0.element }
    for s in sortedSS {
        let covList = (pyTruthy(s["coverage"]) ? s["coverage"] as? [Any] : []) ?? []
        let covParts = covList.map { c -> String in
            let cd = c as? [String: Any] ?? [:]
            return "\(pyStr(cd["tier"])):\(pyStr(cd["ref"]))"
        }
        let cov = covParts.isEmpty ? "—" : covParts.joined(separator: "; ")
        let peAny = pyTruthy(s["proposedEval"]) ? s["proposedEval"] : nil
        let pe = peAny as? [String: Any] ?? [:]
        let pes = pe.isEmpty ? "—" : "\(pyStr(pe["tier"])) — reads \(pyStr(pe["reads"])); asserts \(pyStr(pe["asserts"]))"
        let flag = pyTruthy(s["disputed"]) ? " ⚠disputed" : ""
        L.append("| `\(pyStr(s["id"]))`\(flag) | \(pyStr(s["kind"])) | \(pyStr(s["status"])) | \(cov) | \(pyTruthy(s["silentFailureMode"]) ? pyStr(s["silentFailureMode"]) : "—") | \(pes) |")
    }
    if pyTruthy(uncertain[f]) {
        let u = (uncertain[f] as? [Any] ?? []).map { pyStr($0) }
        L += ["", "uncertain: " + u.joined(separator: "; ")]
    }
    L.append("")
}
try! (L.joined(separator: "\n") + "\n").write(toFile: "\(out)/COVERAGE.md", atomically: true, encoding: .utf8)
print("ledger: \(rows.count) surfaces → \(out)/ledger.json, \(out)/COVERAGE.md; \(tot.dictRepr())")
