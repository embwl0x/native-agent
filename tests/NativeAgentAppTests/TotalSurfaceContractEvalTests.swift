import Foundation
import CryptoKit
import Testing

/// A mutation-sensitive structural floor underneath the expensive behavior
/// lanes. The checked-in campaign manifest freezes the exact surface IDs being
/// closed: deleting a row, moving its production owner, turning a control into
/// inert text, or weakening its proposed assertion makes this suite fail.
///
/// This is deliberately not the only proof. `script/evals.sh --full` pairs it
/// with the complete Swift suites, required iOS simulator tests, the live
/// instrument, and an exact verified install. The separate `--ui` flag adds
/// the strict installed-app Accessibility walk.
@Suite("Total surface contract")
struct TotalSurfaceContractEvalTests {
    static let repo = EvalCoverageLedgerTests.repo

    struct Campaign: Decodable {
        struct Key: Decodable, Hashable { let fence: String; let id: String }
        let baselineInputs: [String: String]
        let surfaces: [Key]
    }
    struct Ledger: Decodable { let surfaces: [Surface] }
    struct Surface: Decodable {
        struct Proposed: Decodable {
            let tier: String
            let reads: String
            let asserts: String
            let liveOrClone: String
            let costSeconds: Int
        }
        let id: String
        let fence: String
        let kind: String
        let `where`: String
        let proposedEval: Proposed?
        let silentFailureMode: String?
    }

    static func decode<T: Decodable>(_ type: T.Type, _ relativePath: String) throws -> T {
        let data = try Data(contentsOf: repo.appendingPathComponent(relativePath))
        return try JSONDecoder().decode(type, from: data)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static let swiftFilesByBasename: [String: URL] = {
        var result: [String: URL] = [:]
        for root in ["Sources", "Modules", "iOS"] {
            guard let enumerator = FileManager.default.enumerator(
                at: repo.appendingPathComponent(root),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                result[url.lastPathComponent] = result[url.lastPathComponent] ?? url
            }
        }
        return result
    }()

    static func productionPaths(in text: String) -> [String] {
        let pattern = #"(?:Modules|Sources|iOS|script|tests|Shared|NativeAgentChromeRelay)/[^\s`,;()]+"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        var paths: [String] = regex.matches(in: text, range: range).compactMap { match -> String? in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            var path = String(text[swiftRange])
            while let last = path.last, [".", ":"].contains(last) { path.removeLast() }
            if let colon = path.firstIndex(of: ":") {
                path = String(path[..<colon])
            }
            return path
        }
        let basenameRegex = try! NSRegularExpression(pattern: #"[A-Za-z0-9_+.-]+\.swift"#)
        paths += basenameRegex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
        return Array(Set(paths))
    }

    static func source(_ path: String) -> String? {
        var url = repo.appendingPathComponent(path)
        if !path.contains("/"), let match = swiftFilesByBasename[path] { url = match }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return "<directory>" }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    @Test func campaignIsFrozenCompleteAndStillPointsAtProduction() throws {
        let campaign = try Self.decode(Campaign.self, "docs/evals/total-coverage-surface-ids.json")
        let ledger = try Self.decode(Ledger.self, "docs/evals/ledger.json")
        let byKey = Dictionary(uniqueKeysWithValues: ledger.surfaces.map { (Campaign.Key(fence: $0.fence, id: $0.id), $0) })

        // 2026-08-30: User authorized retiring the unused substrate.runReplay
        // compatibility API and its dedicated test. The other 640 IDs remain
        // frozen; the real app-level replay/integration surfaces remain live.
        #expect(campaign.surfaces.count == 640, "The authorized burn-down must retain its reviewed 640-row boundary after the one explicit retirement.")
        #expect(Set(campaign.surfaces).count == campaign.surfaces.count, "Campaign fence/ID keys must be unique.")
        #expect(Set(campaign.baselineInputs.keys) == Set(["phase1-fragments.json", "coverage-overrides.json"]))
        for (name, expectedHash) in campaign.baselineInputs {
            let data = try Data(contentsOf: Self.repo.appendingPathComponent("docs/evals/\(name)"))
            #expect(Self.sha256(data) == expectedHash, "\(name) changed after the 640-row campaign was reviewed; deliberately regenerate/review its frozen membership")
        }

        var failures: [String] = []
        let validTiers = Set(["test", "instrument", "smoke", "bench", "turn-replay", "ui-walk"])
        for key in campaign.surfaces {
            guard let row = byKey[key] else {
                failures.append("\(key.fence).\(key.id): disappeared from ledger")
                continue
            }
            let id = row.id
            if let proposed = row.proposedEval {
                if proposed.asserts.trimmingCharacters(in: .whitespacesAndNewlines).count < 12 {
                    failures.append("\(id): assertion contract is empty/vacuous")
                }
                if proposed.reads.trimmingCharacters(in: .whitespacesAndNewlines).count < 8 {
                    failures.append("\(id): evaluator has no named observation")
                }
                if !validTiers.contains(proposed.tier) || proposed.costSeconds <= 0 {
                    failures.append("\(id): invalid tier/cost")
                }
            } else {
                if (row.silentFailureMode ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {
                    failures.append("\(id): campaign row has neither a proposed evaluator nor a silent-failure contract")
                }
            }

            let paths = Self.productionPaths(in: row.where)
            let owners = paths.compactMap { path -> (String, String)? in
                Self.source(path).map { (path, $0) }
            }
            let dataOwned = row.where.hasPrefix("data/") || row.where.contains(" data/")
            if owners.isEmpty && !dataOwned {
                failures.append("\(id): no resolvable production owner in `where`")
                continue
            }

            if row.kind == "ui-control" {
                let joined = owners.map(\.1).joined(separator: "\n")
                let actionTokens = ["Button(", "Toggle(", "Picker(", "TextField(", "Menu(", ".onTapGesture", ".gesture(", ".contextMenu", ".sheet(", "accessibilityAction", "Binding<", "func ", "send(", "post(", "perform(", "action"]
                if !actionTokens.contains(where: joined.contains) && !actionTokens.contains(where: row.where.contains) {
                    failures.append("\(id): UI control owner contains no actionable primitive")
                }
            } else if row.kind == "ui-summary" {
                let joined = owners.map(\.1).joined(separator: "\n")
                let renderTokens = ["Text(", "Label(", "LabeledContent(", "StatusBadge(", "NativeEmptyState(", "var body:", "String", "status", "summary", "label"]
                if !renderTokens.contains(where: joined.contains) && !renderTokens.contains(where: row.where.contains) {
                    failures.append("\(id): UI summary owner contains no rendering primitive")
                }
            } else if row.kind == "cli" {
                for (path, _) in owners where path.hasPrefix("script/") && path.hasSuffix(".sh") {
                    if !FileManager.default.isExecutableFile(atPath: Self.repo.appendingPathComponent(path).path) {
                        failures.append("\(id): CLI script is not executable: \(path)")
                    }
                }
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.prefix(80).joined(separator: "\n")))
    }
}
