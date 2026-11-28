import Foundation
import NativeAgentCore

// Blueprint: | `ContextAssociationGraph.swift` | Generation-held memory associations, masked transitions and per-seed PageRank |

package protocol ContextAssociationProjecting: Sendable {
    func associationGraph(in generation: ContextStoredGeneration) async throws -> ContextAssociationGraph
}

package struct ContextAssociationGraph: Sendable {
    package enum Node: Hashable, Sendable {
        case memory(ContextAtomID)
        case entity(String, source: ContextAtomID)

        var source: ContextAtomID {
            switch self {
            case .memory(let id), .entity(_, let id): id
            }
        }
    }

    package struct Edge: Equatable, Sendable {
        let from: Node
        let to: Node
        let witness: ContextAtomID
        let weight: Double
        let relation: ContextAtomID?

        package init(_ from: Node, _ to: Node, witness: ContextAtomID, weight: Double, relation: ContextAtomID? = nil) {
            self.from = from
            self.to = to
            self.witness = witness
            self.weight = weight
            self.relation = relation
        }
    }

    package let records: [String: ContextAtomID]
    let edges: [Edge]
    private let nodes: [Node]
    private let indices: [Node: Int]
    private let offsets: [Int]
    private let columns: [Int]
    private let weights: [Double]
    private let edgeIndices: [Int]

    package init(_ edges: [Edge], records: [String: ContextAtomID] = [:]) {
        self.records = records
        self.edges = edges
        var nodes: [Node] = [], indices: [Node: Int] = [:]
        func index(_ node: Node) -> Int {
            if let i = indices[node] { return i }
            let i = nodes.count
            indices[node] = i
            nodes.append(node)
            return i
        }
        var incoming: [Int: [(from: Int, weight: Double, edge: Int)]] = [:]
        var out: [Int: Double] = [:]
        for (i, edge) in edges.enumerated() where edge.weight.isFinite && edge.weight > 0 {
            let from = index(edge.from), to = index(edge.to)
            incoming[to, default: []].append((from, edge.weight, i))
            out[from, default: 0] += edge.weight
        }
        var offsets = [0], columns: [Int] = [], weights: [Double] = [], edgeIndices: [Int] = []
        for row in nodes.indices {
            for edge in incoming[row] ?? [] {
                columns.append(edge.from)
                weights.append(edge.weight / out[edge.from, default: 0])
                edgeIndices.append(edge.edge)
            }
            offsets.append(columns.count)
        }
        self.nodes = nodes
        self.indices = indices
        self.offsets = offsets
        self.columns = columns
        self.weights = weights
        self.edgeIndices = edgeIndices
    }

    func walk(seeds: [ContextAtomID], partitions: [ContextAtomID: Set<String>], relations: Set<ContextAtomID>, studio: Set<ContextAtomID>, indirect: [ContextAtomID])
        -> [(atom: ContextAtomID, seed: ContextAtomID)] {
        let starts = seeds.compactMap { id in partitions[id] == nil ? nil : indices[.memory(id)] }
        guard !starts.isEmpty, indirect.count >= 3 else { return [] }
        let zero = Array(repeating: 0.0, count: nodes.count)
        var outgoing = zero, masked = Array(repeating: false, count: nodes.count)
        var transitions = Array(repeating: 0.0, count: columns.count)
        func partition(_ id: ContextAtomID) -> Set<String>? { studio.contains(id) ? [] : partitions[id] }
        for row in nodes.indices {
            let destination = partition(nodes[row].source)
            for edge in offsets[row]..<offsets[row + 1] {
                let from = columns[edge]
                let evidence = edges[edgeIndices[edge]]
                guard let destination, partition(nodes[from].source) == destination, partition(evidence.witness) == destination,
                      evidence.relation.map(relations.contains) != false else {
                    masked[from] = true
                    continue
                }
                outgoing[from] += evidence.weight
                transitions[edge] = evidence.weight
            }
        }
        for edge in transitions.indices where transitions[edge] > 0 {
            let source = columns[edge]
            transitions[edge] = masked[source] ? transitions[edge] / outgoing[source] : weights[edge]
        }
        let share = 1 / Double(starts.count)
        var ranks = starts.map { start in
            var rank = zero
            rank[start] = share
            return rank
        }
        var mass = zero
        for start in starts { mass[start] = share }
        for _ in 0..<12 {
            var total = zero
            for (s, start) in starts.enumerated() {
                let prior = ranks[s]
                var next = zero
                next[start] = 0.25 * share
                for row in nodes.indices {
                    var received = outgoing[row] == 0 ? prior[row] : 0
                    for edge in offsets[row]..<offsets[row + 1] {
                        received += transitions[edge] * prior[columns[edge]]
                    }
                    next[row] += 0.75 * received
                    total[row] += next[row]
                }
                ranks[s] = next
            }
            let change = mass.indices.reduce(0.0) { $0 + abs(total[$1] - mass[$1]) }
            mass = total
            if change < 1e-4 { break }
        }
        let values = indirect.map { indices[.memory($0)].map { mass[$0] } ?? 0 }
        let standings = VectorMath.standout(values)
        return indirect.indices.filter { values[$0] > 0 && (standings[$0] ?? 0) >= 2.5 }.sorted {
            values[$0] == values[$1] ? indirect[$0] < indirect[$1] : values[$0] > values[$1]
        }.compactMap { i in
            guard let node = indices[.memory(indirect[i])],
                  let best = starts.indices.max(by: { ranks[$0][node] < ranks[$1][node] }) else { return nil }
            return (indirect[i], nodes[starts[best]].source)
        }
    }
}
