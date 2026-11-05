import Foundation
import NativeAgentCore
import os
// Blueprint: | `Flow.swift` | `Flow`. |

/// Keep landed work on one unfinished experience; the latest complete list preserves positions that land or reconcile later.
public enum Flow {
    /// After a failed flow write, absence is ambiguous; refuse reads until a successful write restores evidence.
    private static let unrecorded = OSAllocatedUnfairLock(initialState: [String: String]())

    private static func write(_ root: URL, _ scope: String,
                              _ body: @escaping @Sendable (ExperienceStore) async throws -> Void) -> Task<Void, Never> {
        let key = ExperienceStore.recordIdentity(root, "flow:" + scope)
        return ExperienceStore.record(root, "flow:" + scope) { store in
            do {
                try await body(store)
                unrecorded.withLock { $0[key] = nil }
            } catch {
                unrecorded.withLock { $0[key] = error.localizedDescription }
                throw error
            }
        }
    }

    private static func open(_ store: ExperienceStore, scope: String) async throws -> Experience? {
        try await store.open().first {
            $0.owes["finish"]?.phase.isSettled == false && $0.claims.contains { $0.claim == "scope: " + scope }
        }
    }

    /// Queue reads behind scope writes; unreadable flow may contain landed work and cannot mean none.
    public static func open(_ root: URL, scope: String) async throws -> Experience? {
        let result = OSAllocatedUnfairLock<Result<Experience?, Error>>(initialState: .success(nil))
        await ExperienceStore.record(root, "flow:" + scope) { store in
            do {
                let flow = try await open(store, scope: scope)
                result.withLock { $0 = .success(flow) }
            } catch {
                result.withLock { $0 = .failure(error) }
                throw error
            }
        }.value
        let key = ExperienceStore.recordIdentity(root, "flow:" + scope)
        if let failure = unrecorded.withLock({ $0[key] }) {
            throw NSError(domain: "Flow", code: 1, userInfo: [NSLocalizedDescriptionKey: "the last record of this flow failed: " + failure])
        }
        return try result.withLock { $0 }.get()
    }

    public static func landed(_ flow: Experience) -> [String] {
        guard let latest = flow.claims.last(where: { $0.claim.hasPrefix("landed@") }),
              let colon = latest.claim.range(of: ": ") else { return [] }
        let list = latest.claim[colon.upperBound...]
        return list.isEmpty ? [] : list.split(separator: ",").map(String.init)
    }

    /// Queue closure behind prior scope writes; new work may release a flow, while stops only add landed evidence.
    @discardableResult
    public static func stopped(_ root: URL, scope: String, landed: [String], words: String,
                               evidence: Experience.Ref, cause: [String] = []) -> Task<Void, Never> {
        write(root, scope) { store in
            guard !landed.isEmpty else { return }
            let current = try await open(store, scope: scope)
            let stops = current?.claims.filter { $0.claim.hasPrefix("landed@") }.count ?? 0
            let list = Experience.Claim(claim: "landed@\(stops + 1): " + landed.joined(separator: ","), evidence: [evidence])
            if let flow = current {
                try await store.append(cause.map { .cause($0) } + [.claim(list), .evidence(evidence),
                                       .face(.init(words: words, artifacts: []))], to: flow.id)
            } else {
                var flow = Experience(id: "flow:" + UUID().uuidString, kind: .run, cause: cause, evidence: [evidence],
                                      face: .init(words: words, artifacts: []), owes: ["finish": .init(to: "self")],
                                      claims: [.init(claim: "scope: " + scope, evidence: []), list])
                flow.addressedTo = ["self"]
                try await store.begin(flow)
            }
        }
    }

    @discardableResult
    public static func finished(_ root: URL, scope: String, evidence: Experience.Ref) -> Task<Void, Never> {
        write(root, scope) { store in
            if let flow = try await open(store, scope: scope) {
                try await store.append([.obligation(key: "finish", phase: .accepted, evidence: evidence)], to: flow.id)
            }
        }
    }

    @discardableResult
    public static func dropped(_ root: URL, scope: String) -> Task<Void, Never> {
        write(root, scope) { store in
            if let flow = try await open(store, scope: scope) {
                try await store.append([.letGo(key: "finish", reason: .abandoned)], to: flow.id)
            }
        }
    }
}
