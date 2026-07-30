import SwiftUI

// ---------------------------------------------------------------------------
// MARK: - KGGraphCanvas — node-link force-directed graph (F3)
// ---------------------------------------------------------------------------
//
// Hand-rolled spring-mass relaxation (Fruchterman-Reingold flavor): 10 fixed
// iterations, k=50, O(n²) repulsion + O(|E|) attraction. We deliberately do
// NOT pull in a graph-layout library — keep the dependency surface to what's
// in SwiftUI Canvas. Positions are cached by entity-id signature so a search
// filter that shrinks the displayed set doesn't re-shuffle everything.
//
// Selection is via DragGesture(minimumDistance:0) hit-test (Canvas has no
// per-node tap hook) — `onEnded` checks the nearest node within hit radius.
//
// At >200 nodes the parent view falls back to the list because the relaxation
// loop is quadratic and the canvas gets visually meaningless.

struct KGGraphCanvas: View {
    let entities: [KGEntity]
    let edges: [KGEdge]
    @Binding var selectedId: String?

    @State private var positions: [String: CGPoint] = [:]
    @State private var lastSignature: String = ""
    @State private var lastSize: CGSize = .zero

    private let nodeRadius: CGFloat = 14
    private let hitRadius: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                // Edges first so node circles overlay them.
                let entIds = Set(entities.map { $0.id })
                for edge in edges where entIds.contains(edge.from) && entIds.contains(edge.to) {
                    guard let p1 = positions[edge.from], let p2 = positions[edge.to] else { continue }
                    var path = Path()
                    path.move(to: p1)
                    path.addLine(to: p2)
                    ctx.stroke(path, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
                }
                for entity in entities {
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
                    if entities.count <= 40 {
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
            .onAppear {
                computeLayoutIfNeeded(in: geo.size)
            }
            .onChange(of: geo.size) { _, new in
                computeLayoutIfNeeded(in: new)
            }
            .onChange(of: entitySignature) { _, _ in
                computeLayoutIfNeeded(in: geo.size, force: true)
            }
        }
    }

    private var entitySignature: String {
        // Cheap signature — id-set membership is what matters for layout.
        entities.map { $0.id }.sorted().joined(separator: "|")
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
        let sig = entitySignature
        if !force, sig == lastSignature, size == lastSize, !positions.isEmpty { return }
        lastSignature = sig
        lastSize = size
        positions = computeForceDirected(in: size)
    }

    /// Fruchterman-Reingold-ish: random init, 10 iterations of repulsion +
    /// attraction with cooling. k = sqrt(area / n) capped to 50 so a small
    /// graph doesn't sprawl into the corners.
    private func computeForceDirected(in size: CGSize) -> [String: CGPoint] {
        let n = entities.count
        guard n > 0 else { return [:] }
        let area = Double(size.width) * Double(size.height)
        let k = min(50.0, (area / Double(max(n, 1))).squareRoot())
        // Deterministic pseudo-random init: hash the id to a fixed point so the
        // layout is stable across re-renders (avoids hopping every refresh).
        var pos: [String: CGPoint] = [:]
        for entity in entities {
            let h = entity.id.hashValue
            let x = Double((h & 0xFFFF)) / 65535.0
            let y = Double(((h >> 16) & 0xFFFF)) / 65535.0
            pos[entity.id] = CGPoint(
                x: CGFloat(x) * size.width * 0.8 + size.width * 0.1,
                y: CGFloat(y) * size.height * 0.8 + size.height * 0.1
            )
        }
        let ids = entities.map { $0.id }
        let idSet = Set(ids)
        let liveEdges = edges.filter { idSet.contains($0.from) && idSet.contains($0.to) }
        var temperature = max(size.width, size.height) / 10.0
        let iterations = 10
        for iter in 0..<iterations {
            var disp: [String: CGPoint] = Dictionary(uniqueKeysWithValues: ids.map { ($0, .zero) })
            // Repulsion — every pair.
            for i in 0..<ids.count {
                let id1 = ids[i]
                let p1 = pos[id1]!
                for j in (i + 1)..<ids.count {
                    let id2 = ids[j]
                    let p2 = pos[id2]!
                    var dx = Double(p1.x - p2.x)
                    var dy = Double(p1.y - p2.y)
                    var d = (dx * dx + dy * dy).squareRoot()
                    if d < 0.01 {
                        // Jitter coincident nodes deterministically.
                        dx = 0.1; dy = 0.1; d = 0.1414
                    }
                    let force = (k * k) / d
                    let ux = dx / d, uy = dy / d
                    let d1 = disp[id1]!
                    disp[id1] = CGPoint(x: d1.x + CGFloat(ux * force), y: d1.y + CGFloat(uy * force))
                    let d2 = disp[id2]!
                    disp[id2] = CGPoint(x: d2.x - CGFloat(ux * force), y: d2.y - CGFloat(uy * force))
                }
            }
            // Attraction — along each edge.
            for edge in liveEdges {
                guard let p1 = pos[edge.from], let p2 = pos[edge.to] else { continue }
                let dx = Double(p1.x - p2.x)
                let dy = Double(p1.y - p2.y)
                let d = max(0.01, (dx * dx + dy * dy).squareRoot())
                let force = (d * d) / k
                let ux = dx / d, uy = dy / d
                let d1 = disp[edge.from]!
                disp[edge.from] = CGPoint(x: d1.x - CGFloat(ux * force), y: d1.y - CGFloat(uy * force))
                let d2 = disp[edge.to]!
                disp[edge.to] = CGPoint(x: d2.x + CGFloat(ux * force), y: d2.y + CGFloat(uy * force))
            }
            // Apply with cooling + viewport clamp.
            for id in ids {
                let d = disp[id]!
                let mag = (Double(d.x) * Double(d.x) + Double(d.y) * Double(d.y)).squareRoot()
                guard mag > 0.01 else { continue }
                let limited = min(mag, Double(temperature))
                let nx = Double(pos[id]!.x) + (Double(d.x) / mag) * limited
                let ny = Double(pos[id]!.y) + (Double(d.y) / mag) * limited
                pos[id] = CGPoint(
                    x: CGFloat(max(nodeRadius, min(Double(size.width) - Double(nodeRadius), nx))),
                    y: CGFloat(max(nodeRadius, min(Double(size.height) - Double(nodeRadius), ny)))
                )
            }
            // Linear cooling.
            temperature *= (1.0 - Double(iter + 1) / Double(iterations + 1))
        }
        return pos
    }
}
