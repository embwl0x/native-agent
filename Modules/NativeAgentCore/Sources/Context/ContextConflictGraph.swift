import Foundation
import NativeAgentCore
// Blueprint: | `ContextConflictGraph.swift` | `ContextSelector` conflict connected components, resolution validation and receipt projection; selection retains atomic admission |

extension ContextSelector {
    struct ConflictGroup {
        let id: String
        let memberAtomIDs: Set<ContextAtomID>
        let resolvedAtomID: ContextAtomID?
        let provenance: [String]
    }

    func conflictGroups(
        for need: NeedSignal,
        generation: ContextStoredGeneration
    ) throws -> [ConflictGroup] {
        var adjacency: [ContextAtomID: Set<ContextAtomID>] = [:]
        var relationshipProvenance: [(members: Set<ContextAtomID>, value: String)] = []
        var explicitByID: [String: ContextConflictDefinition] = [:]

        for definition in need.explicitConflicts.sorted(by: { $0.id < $1.id }) {
            guard definition.memberAtomIDs.count >= 2 else { continue }
            if let resolved = definition.resolvedAtomID,
               !definition.memberAtomIDs.contains(resolved) {
                throw ContextSelectionError.invalidConflictResolution(
                    conflictID: definition.id,
                    atomID: resolved
                )
            }
            explicitByID[definition.id] = definition
            connect(definition.memberAtomIDs, adjacency: &adjacency)
        }
        for relationship in generation.relationships.sorted(by: { $0.draft.id < $1.draft.id })
            where Self.isConflictKind(relationship.draft.kind) {
            let pair: Set<ContextAtomID> = [
                relationship.draft.sourceAtomID,
                relationship.draft.targetAtomID,
            ]
            connect(pair, adjacency: &adjacency)
            relationshipProvenance.append((pair, relationship.draft.provenance))
        }

        var visited = Set<ContextAtomID>()
        var groups: [ConflictGroup] = []
        for start in adjacency.keys.sorted() where !visited.contains(start) {
            var stack = [start]
            var members = Set<ContextAtomID>()
            while let current = stack.popLast() {
                guard visited.insert(current).inserted else { continue }
                members.insert(current)
                stack.append(contentsOf: (adjacency[current] ?? []).sorted(by: >))
            }
            let matchingDefinitions = explicitByID.values.filter {
                !$0.memberAtomIDs.isDisjoint(with: members)
            }.sorted { $0.id < $1.id }
            let resolutions = Set(matchingDefinitions.compactMap(\.resolvedAtomID))
            if resolutions.count > 1, let conflicting = resolutions.sorted().last {
                throw ContextSelectionError.invalidConflictResolution(
                    conflictID: matchingDefinitions.map(\.id).joined(separator: "+"),
                    atomID: conflicting
                )
            }
            let exactDefinition = matchingDefinitions.first { $0.memberAtomIDs == members }
            let id = exactDefinition?.id ?? "conflict:" + ContextStableID.digest(
                parts: members.map(\.rawValue).sorted()
            )
            var provenance = matchingDefinitions.map(\.provenance)
            provenance.append(contentsOf: relationshipProvenance.compactMap { edge in
                edge.members.isSubset(of: members) ? edge.value : nil
            })
            groups.append(ConflictGroup(
                id: id,
                memberAtomIDs: members,
                resolvedAtomID: resolutions.first,
                provenance: Array(Set(provenance)).sorted()
            ))
        }
        return groups.sorted { $0.id < $1.id }
    }

    private func connect(
        _ members: Set<ContextAtomID>,
        adjacency: inout [ContextAtomID: Set<ContextAtomID>]
    ) {
        let sorted = members.sorted()
        for atom in sorted where adjacency[atom] == nil { adjacency[atom] = [] }
        guard let first = sorted.first else { return }
        for atom in sorted.dropFirst() {
            adjacency[first, default: []].insert(atom)
            adjacency[atom, default: []].insert(first)
        }
    }

    func conflictSet(
        _ group: ConflictGroup,
        generationID: Int64,
        atomByID: [ContextAtomID: ContextStoredAtom],
        eligibleIDs: Set<ContextAtomID>,
        candidateIDs: Set<ContextAtomID>,
        selectedIDs: Set<ContextAtomID>,
        omittedConflictIDs: Set<String>
    ) -> ContextConflictSet {
        let eligibleMembers = group.memberAtomIDs.intersection(eligibleIDs)
        let claims = eligibleMembers.compactMap { atomByID[$0] }
            .sorted { $0.draft.id < $1.draft.id }
            .map { ContextAtomPointer(atom: $0, generationID: generationID) }
        let handling: ContextConflictHandling
        if let resolved = group.resolvedAtomID {
            handling = eligibleIDs.contains(resolved) ? .resolved : .ineligible
        } else if eligibleMembers.count != group.memberAtomIDs.count {
            handling = .ineligible
        } else if group.memberAtomIDs.isSubset(of: selectedIDs) {
            handling = .includedUncertainty
        } else if omittedConflictIDs.contains(group.id)
            || !group.memberAtomIDs.intersection(candidateIDs).isEmpty {
            handling = .omittedBudget
        } else {
            handling = .omittedIrrelevant
        }
        return ContextConflictSet(
            id: group.id,
            claims: claims,
            resolvedAtomID: group.resolvedAtomID,
            provenance: group.provenance,
            handling: handling
        )
    }

    private static func isConflictKind(_ kind: String) -> Bool {
        let normalized = kind.lowercased().replacingOccurrences(of: "-", with: "_")
        return normalized == "conflict" || normalized == "conflicts"
            || normalized == "contradicts" || normalized == "contradiction"
    }
}
