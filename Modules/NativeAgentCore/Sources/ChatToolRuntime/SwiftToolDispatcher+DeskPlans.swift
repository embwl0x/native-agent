import NativeAgentShared
import Foundation
import NativeAgentCore
import PersistenceCore
import Desk
import Experiences
import ToolExecution
import AuthoredCapabilities
import StandingBots
import Research
import CryptoKit
import PersonaEngine
import MemoryV2
import ProviderRouting
import ToolRegistry
import TrustCenter
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
// Blueprint: | `SwiftToolDispatcher+DeskPlans.swift` | `SwiftToolDispatcher`: Desk plan construction; stable-handle reuse, validated batch-position dependencies, ordered child writes and explicit partial-write reporting |

extension SwiftToolDispatcher {
    /// Create or extend a parent with ordered children, dependency edges and defer dates.
    /// Bare integers in blocked_on are batch positions; other tokens resolve live Desk references.
    /// Wire top-level bare numbers afterward with desk_blocked_on; mid-batch refusals report partial writes.
    func impl_desk_breakdown(input: [String: JSONValue]) async throws -> JSONValue {
        guard case .array(let rawChildren)? = input["children"], !rawChildren.isEmpty else {
            throw deskInvalid("children", reason: "desk_breakdown: children must be a non-empty array")
        }
        struct ChildSpec {
            var title: String
            var summary: String?
            var blockedOn: [String]
            var deferUntil: String?
        }
        var specs: [ChildSpec] = []
        // Unknown child fields are refused before any write.
        let allowedChildKeys: Set<String> = ["title", "summary", "blocked_on", "defer_until"]
        for (idx, raw) in rawChildren.enumerated() {
            guard case .object(let obj) = raw,
                  case .string(let title)? = obj["title"],
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw deskInvalid("children.\(idx).title", reason: "desk_breakdown: child \(idx + 1) needs a non-empty title")
            }
            let unknown = obj.keys.filter { !allowedChildKeys.contains($0) }.sorted()
            guard unknown.isEmpty else {
                throw deskInvalid("children.\(idx).\(unknown[0])",
                    reason: "desk_breakdown: child \(idx + 1) has unknown field(s) \(unknown.joined(separator: ", ")) — allowed: title, summary, blocked_on, defer_until. For ordering, put the blocking sibling positions in blocked_on (e.g. \"1,2\" or [1,2]).")
            }
            func str(_ k: String) -> String? {
                if case .string(let s)? = obj[k] { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
                return nil
            }
            let blockedOn: [String]
            switch obj["blocked_on"] {
            case .some(.string(let s)):
                blockedOn = [s]
            case .some(.array(let arr)):
                var tokens: [String] = []
                for entry in arr {
                    switch entry {
                    case .string(let s): tokens.append(s)
                    case .int(let i): tokens.append(String(i))
                    // An integral JSON double is an integer position.
                    case .double(let d) where d == d.rounded() && d.magnitude < 1_000_000:
                        tokens.append(String(Int(d)))
                    default:
                        throw deskInvalid("children.\(idx).blocked_on",
                            reason: "desk_breakdown: child \(idx + 1) blocked_on array entries must be strings or integers")
                    }
                }
                blockedOn = tokens
            case .none:
                blockedOn = []
            default:
                throw deskInvalid("children.\(idx).blocked_on",
                    reason: "desk_breakdown: child \(idx + 1) blocked_on must be a CSV string or an array")
            }
            specs.append(ChildSpec(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                summary: (str("summary")?.isEmpty == false) ? str("summary") : nil,
                blockedOn: blockedOn.flatMap { $0.split(separator: ",") }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                deferUntil: (str("defer_until")?.isEmpty == false) ? str("defer_until") : nil
            ))
        }
        // Validate batch positions before any write.
        for (idx, spec) in specs.enumerated() {
            for token in spec.blockedOn {
                if let pos = Int(token) {
                    guard pos >= 1, pos <= specs.count else {
                        throw deskInvalid("children.\(idx).blocked_on",
                            reason: "desk_breakdown: child \(idx + 1) blocked_on '\(pos)' is not a position in this batch (1–\(specs.count))")
                    }
                    guard pos != idx + 1 else {
                        throw deskInvalid("children.\(idx).blocked_on", reason: "desk_breakdown: child \(idx + 1) cannot block on itself")
                    }
                }
            }
        }

        let store = deskStore()
        let parentHandle: String
        let project: String
        var reusedParent = false
        let parentRaw = optionalString(input, "parent")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parentRaw, !parentRaw.isEmpty {
            // Graft mode: attach the new sub-items to an existing item.
            let state = try await store.liveState()
            parentHandle = try resolveDeskRef(parentRaw, in: state, field: "parent")
            guard let parentItem = state.items.first(where: { $0.handle == parentHandle }) else {
                throw deskInvalid("parent", reason: "desk_breakdown: parent '\(parentRaw)' is not live")
            }
            project = parentItem.project
        } else {
            let proj = try deskString(input, "project").trimmingCharacters(in: .whitespacesAndNewlines)
            let title = try deskString(input, "title").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !proj.isEmpty, !title.isEmpty else {
                throw deskInvalid("title", reason: "desk_breakdown: project and title must be non-empty")
            }
            let kindRaw = optionalString(input, "kind")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let kind = (kindRaw?.isEmpty == false) ? DeskKind(rawValue: kindRaw!) : .plan
            guard let kind else {
                throw deskInvalid("kind",
                    reason: "desk_breakdown: unknown kind '\(kindRaw ?? "")' — one of \(DeskKind.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            let summary = optionalString(input, "summary")?.trimmingCharacters(in: .whitespacesAndNewlines)
            // Reuse an equivalent live campaign and add only its missing steps.
            let same = SwiftNativeDeskStore.equivalentDeskText
            if let existing = try await store.liveState().topLevel.first(where: {
                !$0.status.isTerminal && $0.kind == kind && same($0.project) == same(proj) && same($0.title) == same(title)
            }) {
                parentHandle = existing.handle
                reusedParent = true
            } else {
                parentHandle = try await store.createItem(
                    kind: kind, project: proj, title: title,
                    parent: nil, summary: (summary?.isEmpty == false) ? summary : nil
                ).handle
            }
            project = proj
        }

        // Create children before wiring edges and defers; subsequent refusals retain and report partial writes.
        var createdHandles: [String] = []
        var planLines: [String] = []
        // Reused steps keep their handles; finish their requested setup too.
        var reusedSteps: Set<Int> = []
        let openSteps = reusedParent
            ? try await store.liveState().children(of: parentHandle).filter { !$0.status.isTerminal } : []
        func partial(_ reason: String) async -> JSONValue {
            let state = try? await store.liveState()
            let parentAlias = state?.items.first { $0.handle == parentHandle }?.alias ?? parentHandle
            return .object([
                "status": .string("partial"),
                "reason": .string(reason),
                "parent": .string(parentAlias),
                "created": .array(planLines.map { .string($0) }),
            ])
        }
        for (idx, spec) in specs.enumerated() {
            if let open = openSteps.first(where: {
                SwiftNativeDeskStore.equivalentDeskText($0.title) == SwiftNativeDeskStore.equivalentDeskText(spec.title)
            }) {
                createdHandles.append(open.handle)
                reusedSteps.insert(idx)
                continue
            }
            do {
                let child = try await store.createItem(
                    kind: .plan, project: project, title: spec.title,
                    parent: parentHandle, summary: spec.summary
                )
                createdHandles.append(child.handle)
                planLines.append("\(child.alias) \(spec.title)")
            } catch {
                return await partial("creating child \(idx + 1) '\(spec.title)': \(error.localizedDescription)")
            }
        }
        let wiringState: DeskState
        do { wiringState = try await store.liveState() }
        catch { return await partial("reading created plan: \(error.localizedDescription)") }
        for (idx, spec) in specs.enumerated() {
            if !spec.blockedOn.isEmpty {
                var blockers: [String] = []
                do {
                    for token in spec.blockedOn {
                        if let pos = Int(token) {
                            blockers.append(createdHandles[pos - 1])
                        } else {
                            blockers.append(try resolveDeskRef(token, in: wiringState, field: "children.\(idx).blocked_on"))
                        }
                    }
                    _ = try await store.setBlockedOn(createdHandles[idx], blockers: blockers)
                } catch let e as DeskError {
                    return await partial("wiring child \(idx + 1) blockers: \(e.errorDescription ?? "\(e)")")
                } catch {
                    return await partial("wiring child \(idx + 1) blockers: \(error.localizedDescription)")
                }
            }
            if let until = spec.deferUntil {
                do {
                    _ = try await store.setDeferUntil(createdHandles[idx], until: until)
                } catch let e as DeskError {
                    return await partial("deferring child \(idx + 1): \(e.errorDescription ?? "\(e)")")
                } catch {
                    return await partial("deferring child \(idx + 1): \(error.localizedDescription)")
                }
            }
        }

        // The numbered plan + what's actionable right now, aliases only.
        let state = try await store.liveState()
        let plan = DeskSequencing.compute(state)
        let parentAlias = state.items.first { $0.handle == parentHandle }?.alias ?? parentHandle
        let byHandle = Dictionary(state.items.map { ($0.handle, $0) }, uniquingKeysWith: { first, _ in first })
        var lines: [String] = []
        let addedHandles = createdHandles.enumerated().filter { !reusedSteps.contains($0.offset) }.map(\.element)
        for handle in addedHandles {
            guard let item = byHandle[handle] else { continue }
            var segs = ["\(item.alias) \(item.title)"]
            segs.append(contentsOf: DeskPage.sequencingSegments(item, in: state, plan: plan, includeRollup: false))
            lines.append(segs.joined(separator: " · "))
        }
        let readyNow = createdHandles.filter { plan.byHandle[$0]?.isReady == true }
            .compactMap { byHandle[$0]?.alias }
        if reusedParent {
            return .object([
                "status": .string("existing"),
                "parent": .string(parentAlias),
                "handle": .string(parentHandle),
                "plan": .array(lines.map { .string($0) }),
                "ready_now": .array(readyNow.map { .string($0) }),
                "confirmation": .string("campaign \(parentAlias) already live · added \(addedHandles.count) missing step(s), \(reusedSteps.count) already open"),
            ])
        }
        return .object([
            "status": .string("ok"),
            "parent": .string(parentAlias),
            "handle": .string(parentHandle),
            "plan": .array(lines.map { .string($0) }),
            "ready_now": .array(readyNow.map { .string($0) }),
            "confirmation": .string("campaign \(parentAlias) · \(createdHandles.count) sub-items · ready now: \(readyNow.isEmpty ? "none" : readyNow.joined(separator: ", "))"),
        ])
    }
}
