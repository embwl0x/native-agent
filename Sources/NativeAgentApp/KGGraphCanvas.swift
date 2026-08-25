import SwiftUI

// ---------------------------------------------------------------------------
// MARK: - KGGraphCanvas — node-link force-directed graph (F3)
// ---------------------------------------------------------------------------
//
// Hand-rolled spring-mass relaxation (Fruchterman-Reingold flavor): 10 fixed
// iterations, k=50, O(n²) repulsion + O(|E|) attraction. We deliberately do
// NOT pull in a graph-layout library — keep the dependency surface to what's
// in SwiftUI Canvas. Positions are cached by node-and-edge signature so a
// search filter that shrinks the displayed set doesn't re-shuffle everything,
// while relationship changes still refresh the attraction layout.
//
// Selection is via DragGesture(minimumDistance:0) hit-test (Canvas has no
// per-node tap hook) — `onEnded` checks the nearest node within hit radius.
//
// At >200 canonical nodes the parent view falls back to the list, and this
// canvas independently refuses layout because the relaxation loop is
// quadratic and the visual result gets meaningless.

struct KGGraphCanvas: View {
    let entities: [KGEntity]
    let edges: [KGEdge]
    @Binding var selectedId: String?

    @State private var positions: [String: CGPoint] = [:]
    @State private var lastSignature: String = ""
    @State private var lastSize: CGSize = .zero

    private let nodeRadius: CGFloat = 14
    private let hitRadius: CGFloat = 22

    /// One canonical graph slice drives drawing, hit testing, and force layout.
    /// This prevents duplicated/blank ids or edges outside the current filter
    /// from creating invisible physics participants.
    private var visibleEntities: [KGEntity] {
        KGGraphCanvasLayout.canonicalEntities(entities)
    }

    private var visibleEdges: [KGEdge] {
        KGGraphCanvasLayout.visibleEdges(edges, among: visibleEntities)
    }

    private var renderSafety: KGGraphCanvasLayout.RenderSafety {
        KGGraphCanvasLayout.renderSafety(for: entities)
    }

    var body: some View {
        GeometryReader { geo in
            Group {
                switch renderSafety {
                case .render:
                    ZStack {
                        Canvas { ctx, size in
                // Edges first so node circles overlay them.
                for edge in visibleEdges {
                    guard let p1 = positions[edge.from], let p2 = positions[edge.to] else { continue }
                    var path = Path()
                    path.move(to: p1)
                    path.addLine(to: p2)
                    ctx.stroke(path, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
                }
                for entity in visibleEntities {
                    guard let p = positions[entity.id] else { continue }
                    let color = KGEntityRow.typeColor(entity.type)
                    let isSelected = entity.id == selectedId
                    if isSelected {
                        ctx.fill(
                            Path(ellipseIn: CGRect(
                                x: p.x - nodeRadius - 4, y: p.y - nodeRadius - 4,
                                width: (nodeRadius + 4) * 2, height: (nodeRadius + 4) * 2
                            )),
                            with: .color(color.opacity(0.25))
                        )
                    }
                    ctx.fill(
                        Path(ellipseIn: CGRect(
                            x: p.x - nodeRadius, y: p.y - nodeRadius,
                            width: nodeRadius * 2, height: nodeRadius * 2
                        )),
                        with: .color(color)
                    )
                    // Label — only when there's room; >40 nodes drops to icon-only feel.
                    if visibleEntities.count <= 40 {
                        let text = Text(entity.name).font(.caption2).foregroundColor(.primary)
                        ctx.draw(text, at: CGPoint(x: p.x, y: p.y + nodeRadius + 8), anchor: .top)
                    }
                }
                        }
                        .background(Color.gray.opacity(0.04))
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { value in
                                    hitTest(at: value.location)
                                }
                        )
                        if visibleEntities.isEmpty {
                            ContentUnavailableView(
                                "No renderable graph nodes",
                                systemImage: "exclamationmark.triangle",
                                description: Text("The graph response did not contain valid node identifiers.")
                            )
                            .allowsHitTesting(false)
                        }
                    }
                case .tooLarge(let entityCount):
                    ContentUnavailableView(
                        "Graph is too large to render",
                        systemImage: "exclamationmark.triangle",
                        description: Text("\(entityCount) entities exceed the safe graph limit. Narrow the filters to render this view.")
                    )
                }
            }
            .onAppear {
                computeLayoutIfNeeded(in: geo.size)
            }
            .onChange(of: geo.size) { _, new in
                computeLayoutIfNeeded(in: new)
            }
            .onChange(of: graphSignature) { _, _ in
                computeLayoutIfNeeded(in: geo.size, force: true)
            }
        }
    }

    private var graphSignature: String {
        // Relationships participate in force attraction, so an edge-only
        // refresh must invalidate the cached positions as well as a node edit.
        KGGraphCanvasLayout.signature(entities: visibleEntities, edges: visibleEdges)
    }

    private func hitTest(at point: CGPoint) {
        var best: (id: String, dist: CGFloat)?
        for (id, p) in positions {
            let dx = p.x - point.x
            let dy = p.y - point.y
            let d = (dx * dx + dy * dy).squareRoot()
            if d <= hitRadius, best == nil || d < best!.dist {
                best = (id, d)
            }
        }
        if let hit = best {
            selectedId = hit.id
        }
    }

    private func computeLayoutIfNeeded(in size: CGSize, force: Bool = false) {
        guard size.width > 1, size.height > 1 else { return }
        let sig = graphSignature
        if !force, sig == lastSignature, size == lastSize, !positions.isEmpty { return }
        lastSignature = sig
        lastSize = size
        positions = KGGraphCanvasLayout.positions(
            entities: visibleEntities,
            edges: visibleEdges,
            in: size,
            nodeRadius: nodeRadius
        )
    }

    /// `String.hashValue` is deliberately seeded per process, so it cannot
    /// back a stable graph layout across relaunch. This fixed FNV-1a digest is
    /// only a layout seed, never an identity or security primitive.
    static func stableSeed(for id: String) -> UInt64 {
        KGGraphCanvasLayout.stableSeed(for: id)
    }
}

/// The real graph-canvas layout owner. Keeping its inputs and output explicit
/// makes the renderer's safety boundary executable without a SwiftUI snapshot:
/// only unique, named nodes and edges whose two endpoints are on the canvas may
/// influence layout or selection geometry.
enum KGGraphCanvasLayout {
    /// The force layout is quadratic in nodes. This limit belongs to the
    /// canvas owner rather than only the parent picker, so a direct/future
    /// canvas caller cannot accidentally start an unbounded layout pass.
    static let maximumRenderableEntities = 200

    enum RenderSafety: Equatable {
        case render(entityCount: Int)
        case tooLarge(entityCount: Int)
    }

    static func renderSafety(for entities: [KGEntity]) -> RenderSafety {
        let entityCount = canonicalEntities(entities).count
        return entityCount <= maximumRenderableEntities
            ? .render(entityCount: entityCount)
            : .tooLarge(entityCount: entityCount)
    }

    static func canonicalEntities(_ entities: [KGEntity]) -> [KGEntity] {
        var seen = Set<String>()
        return entities
            .filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.id < $1.id }
    }

    static func visibleEdges(_ edges: [KGEdge], among entities: [KGEntity]) -> [KGEdge] {
        let ids = Set(entities.map(\.id))
        var seen = Set<String>()
        return edges
            .filter { ids.contains($0.from) && ids.contains($0.to) }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.id < $1.id }
    }

    static func signature(entities: [KGEntity], edges: [KGEdge]) -> String {
        let nodePart = entities.map(\.id).joined(separator: "|")
        let edgePart = edges.map(\.id).joined(separator: "|")
        return "\(nodePart)#\(edgePart)"
    }

    /// Fruchterman-Reingold-ish: deterministic initialization plus ten rounds
    /// of repulsion and visible-edge attraction. The final clamp guarantees
    /// every reported node center stays inside the drawable canvas.
    static func positions(
        entities: [KGEntity],
        edges: [KGEdge],
        in size: CGSize,
        nodeRadius: CGFloat
    ) -> [String: CGPoint] {
        let nodes = canonicalEntities(entities)
        guard !nodes.isEmpty,
              nodes.count <= maximumRenderableEntities,
              size.width > 1,
              size.height > 1 else { return [:] }
        let liveEdges = visibleEdges(edges, among: nodes)
        let ids = nodes.map(\.id)
        let area = Double(size.width) * Double(size.height)
        let k = min(50.0, (area / Double(ids.count)).squareRoot())
        var positions: [String: CGPoint] = [:]
        for id in ids {
            let hash = stableSeed(for: id)
            let x = Double(hash & 0xFFFF) / 65535.0
            let y = Double((hash >> 16) & 0xFFFF) / 65535.0
            positions[id] = CGPoint(
                x: CGFloat(x) * size.width * 0.8 + size.width * 0.1,
                y: CGFloat(y) * size.height * 0.8 + size.height * 0.1
            )
        }

        var temperature = max(size.width, size.height) / 10
        let iterations = 10
        for iteration in 0..<iterations {
            var displacement: [String: CGPoint] = Dictionary(
                uniqueKeysWithValues: ids.map { ($0, .zero) }
            )
            for index in 0..<ids.count {
                let firstID = ids[index]
                let first = positions[firstID]!
                for otherIndex in (index + 1)..<ids.count {
                    let secondID = ids[otherIndex]
                    let second = positions[secondID]!
                    var dx = Double(first.x - second.x)
                    var dy = Double(first.y - second.y)
                    var distance = (dx * dx + dy * dy).squareRoot()
                    if distance < 0.01 {
                        dx = 0.1
                        dy = 0.1
                        distance = 0.1414
                    }
                    let force = (k * k) / distance
                    let ux = dx / distance
                    let uy = dy / distance
                    let firstDisplacement = displacement[firstID]!
                    displacement[firstID] = CGPoint(
                        x: firstDisplacement.x + CGFloat(ux * force),
                        y: firstDisplacement.y + CGFloat(uy * force)
                    )
                    let secondDisplacement = displacement[secondID]!
                    displacement[secondID] = CGPoint(
                        x: secondDisplacement.x - CGFloat(ux * force),
                        y: secondDisplacement.y - CGFloat(uy * force)
                    )
                }
            }
            for edge in liveEdges {
                guard let first = positions[edge.from], let second = positions[edge.to] else { continue }
                let dx = Double(first.x - second.x)
                let dy = Double(first.y - second.y)
                let distance = max(0.01, (dx * dx + dy * dy).squareRoot())
                let force = (distance * distance) / k
                let ux = dx / distance
                let uy = dy / distance
                let firstDisplacement = displacement[edge.from]!
                displacement[edge.from] = CGPoint(
                    x: firstDisplacement.x - CGFloat(ux * force),
                    y: firstDisplacement.y - CGFloat(uy * force)
                )
                let secondDisplacement = displacement[edge.to]!
                displacement[edge.to] = CGPoint(
                    x: secondDisplacement.x + CGFloat(ux * force),
                    y: secondDisplacement.y + CGFloat(uy * force)
                )
            }
            for id in ids {
                let delta = displacement[id]!
                let magnitude = (Double(delta.x) * Double(delta.x) + Double(delta.y) * Double(delta.y)).squareRoot()
                guard magnitude > 0.01 else { continue }
                let limited = min(magnitude, Double(temperature))
                let x = Double(positions[id]!.x) + Double(delta.x) / magnitude * limited
                let y = Double(positions[id]!.y) + Double(delta.y) / magnitude * limited
                positions[id] = CGPoint(
                    x: CGFloat(max(nodeRadius, min(Double(size.width) - Double(nodeRadius), x))),
                    y: CGFloat(max(nodeRadius, min(Double(size.height) - Double(nodeRadius), y)))
                )
            }
            temperature *= 1 - Double(iteration + 1) / Double(iterations + 1)
        }
        return positions
    }

    static func stableSeed(for id: String) -> UInt64 {
        id.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}
