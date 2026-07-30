import Foundation
import PersistenceCore

// DeskSweepCLI — operator hygiene for Agent Desk (2026-07-12: "we
// really should have cleared that desk").
//
// Two sweep modes, both writing through SwiftNativeDeskStore.closeItem (the
// store-owned, flocked seam her own tools use — never raw JSONL edits):
//   --close-settled-gh    close active gh-kind items whose PR/issue the
//                         tracking snapshot shows as no longer open; the
//                         outcome summary records the settled state.
//   --close-aliases a,b   close the named aliases AND their dot-children,
//                         with --reason as the outcome summary.
//   --retire-tracker-gh   close ALL active tracker-managed gh rows (kind gh,
//                         github refresh cadence). One-time migration to the
//                         actionable-only Desk policy: the tracker recreates
//                         rows only for blocked/needs-User entities, everything
//                         else lives in the Workshop's GitHub lane.
//   --gh-report           read-only: print the GitHub Command store's derived
//                         state distribution (what the Workshop lane renders).
// --dry-run prints the plan without writing. Pursuits are never touched.

func stateLabel(_ state: GitHubCommandItemState) -> String {
    switch state {
    case .detected: return "detected"
    case .needsCodex: return "needs_codex"
    case .codexWorking: return "codex_working"
    case .verifying: return "verifying"
    case .needsUser: return "needs_user"
    case .waitingUpstream(let kind): return "waiting_upstream(\(kind))"
    case .attention(let reason): return "attention(\(reason))"
    case .resolved: return "resolved"
    }
}

@main
struct DeskSweep {
    static func main() async {
        var dataRoot = PersistenceCore.defaultDataRoot()
        var closeSettledGh = false
        var retireTrackerGh = false
        var ghReport = false
        var aliases: [String] = []
        var reason = "closed by operator sweep"
        var dryRun = false

        var args = ArraySlice(CommandLine.arguments.dropFirst())
        while let arg = args.popFirst() {
            switch arg {
            case "--data-root": if let v = args.popFirst() { dataRoot = URL(fileURLWithPath: v, isDirectory: true) }
            case "--close-settled-gh": closeSettledGh = true
            case "--retire-tracker-gh": retireTrackerGh = true
            case "--gh-report": ghReport = true
            case "--close-aliases": if let v = args.popFirst() { aliases = v.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
            case "--reason": if let v = args.popFirst() { reason = v }
            case "--dry-run": dryRun = true
            default:
                FileHandle.standardError.write(Data("unknown argument: \(arg)\n".utf8))
                exit(2)
            }
        }

        if ghReport {
            let commandStore = GitHubCommandStore(dataRoot: dataRoot)
            do {
                let live = try await commandStore.liveState()
                var counts: [String: Int] = [:]
                for item in live.items { counts[stateLabel(item.state), default: 0] += 1 }
                print("items: \(live.items.count)")
                for (state, count) in counts.sorted(by: { $0.value > $1.value }) {
                    print("  \(state): \(count)")
                }
                for item in live.items where stateLabel(item.state).hasPrefix("attention") || stateLabel(item.state) == "needs_user" {
                    print("ATTN \(item.itemId)  \(stateLabel(item.state))  \(item.title.prefix(60))")
                }
            } catch {
                FileHandle.standardError.write(Data("cannot load github command store: \(error)\n".utf8))
                exit(1)
            }
            return
        }

        // Tracking snapshot → (repo, number, kind) → state, for settled-gh mode.
        var entityState: [String: (state: String, merged: Bool)] = [:]
        if closeSettledGh {
            let snapshotURL = dataRoot
                .appendingPathComponent("connectors/github/tracking_snapshot.json")
            guard let data = try? Data(contentsOf: snapshotURL),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entities = raw["entities"] as? [[String: Any]] else {
                FileHandle.standardError.write(Data("cannot read tracking snapshot at \(snapshotURL.path)\n".utf8))
                exit(1)
            }
            for e in entities {
                // Snapshot JSON uses "repository"; number serializes as a string.
                guard let repo = e["repository"] as? String,
                      let number = (e["number"] as? String) ?? (e["number"] as? Int).map(String.init) else { continue }
                let state = (e["state"] as? String) ?? "unknown"
                let merged = ((e["merged"] as? Bool) ?? false)
                    || ((e["state"] as? String) == "merged")
                entityState["\(repo.lowercased())#\(number)"] = (state, merged)
            }
        }

        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        let state: DeskState
        do { state = try await store.liveState() } catch {
            FileHandle.standardError.write(Data("cannot load desk: \(error)\n".utf8))
            exit(1)
        }

        var planned: [(handle: String, alias: String, title: String, summary: String, plannedUpdatedAt: String)] = []

        for item in state.items where !item.status.isTerminal && !item.isPursuit {
            // Alias-mode: exact alias or a dot-child of one.
            if aliases.contains(where: { item.alias == $0 || item.alias.hasPrefix($0 + ".") }) {
                planned.append((item.handle, item.alias, item.title, reason, item.updatedAt))
                continue
            }
            // Retire-tracker-gh mode: every active tracker-managed gh row goes.
            if retireTrackerGh, item.kind == .gh,
               item.cadence.refreshSources.contains("github") {
                planned.append((item.handle, item.alias, item.title,
                                "retired to actionable-only Desk policy — tracked in the Workshop GitHub lane",
                                item.updatedAt))
                continue
            }
            // Settled-gh mode: the item's gh ref resolves to a non-open entity.
            guard closeSettledGh, item.kind == .gh else { continue }
            for ref in item.refs {
                let key: String?
                switch ref.kind {
                case .ghPr(let repo, let number, _, _, _): key = "\(repo.lowercased())#\(number)"
                case .ghIssue(let repo, let number, _, _): key = "\(repo.lowercased())#\(number)"
                default: key = nil
                }
                // Only KNOWN settled states close — a malformed snapshot row
                // (empty/unknown state) must never read as "settled".
                guard let key, let entity = entityState[key],
                      ["closed", "merged"].contains(entity.state.lowercased()) else { continue }
                let outcome = entity.merged ? "merged" : entity.state
                planned.append((item.handle, item.alias, item.title,
                                "\(key) \(outcome) upstream — swept from tracking snapshot",
                                item.updatedAt))
                break
            }
        }

        if planned.isEmpty {
            print("nothing to close")
            return
        }
        for p in planned {
            print("\(dryRun ? "DRY " : "CLOSE") \(p.alias)  \(p.title.prefix(70))  ← \(p.summary.prefix(60))")
        }
        guard !dryRun else { return }

        // Children before parents: the store (correctly) refuses terminal
        // status on a parent with non-terminal children.
        planned.sort { $0.alias.filter { $0 == "." }.count > $1.alias.filter { $0 == "." }.count }

        // Staleness guard (2026-07-21 audit): the close itself re-reads the
        // item UNDER the store flock and refuses when the row changed or
        // reached a terminal state since planning. The previous separate
        // liveState() re-read + closeItem pair was a TOCTOU window — a
        // concurrent mutation between the two transactions got stomped.
        var closed = 0
        var failed = 0
        var skipped = 0
        for p in planned {
            do {
                let didClose = try await store.closeItemIfUnchanged(
                    p.handle,
                    expectedUpdatedAt: p.plannedUpdatedAt,
                    outcomeSummary: p.summary
                )
                if didClose {
                    closed += 1
                } else {
                    skipped += 1
                    print("SKIP \(p.alias) — changed or closed since planning")
                }
            } catch {
                failed += 1
                FileHandle.standardError.write(Data("FAILED \(p.alias): \(error)\n".utf8))
            }
        }
        print("closed \(closed), failed \(failed), skipped \(skipped)")
        if failed > 0 { exit(1) }
    }
}
