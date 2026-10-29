import SwiftUI
import MemoryV2
// Blueprint: | `KGGraphCanvas.swift` | `KGGraphCanvas` struct |

// ---------------------------------------------------------------------------
// MARK: - KGGraphCanvas — node-link force-directed graph
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
    let entities: [KnowledgeGraphEntity]
    let edges: [KnowledgeGraphEdge]
    @Binding var selectedId: String?

    @State private var positions: [String: CGPoint] = [:]

    private let nodeRadius: CGFloat = 14
    private let hitRadius: CGFloat = 22

    var body: some View {
        // One canonical slice serves drawing, accessibility and layout inputs.
        let nodes = KGGraphCanvasLayout.canonicalEntities(entities)
        let links = KGGraphCanvasLayout.visibleEdges(edges, among: nodes)
        let signature = KGGraphCanvasLayout.signature(entities: nodes, edges: links)
        GeometryReader { geo in
            Group {
                switch KGGraphCanvasLayout.renderSafety(entityCount: nodes.count) {
                case .render:
                    ZStack {
                        Canvas { ctx, size in
                let labels = KGGraphCanvasLayout.labelFrames(
                    entities: nodes, positions: positions, in: size,
                    selectedID: selectedId, nodeRadius: nodeRadius
                )
                // Edges first so node circles overlay them.
                for edge in links {
                    guard let p1 = positions[edge.from], let p2 = positions[edge.to] else { continue }
                    var path = Path()
                    path.move(to: p1)
                    path.addLine(to: p2)
                    ctx.stroke(path, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
                }
                for entity in nodes {
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
                    if let frame = labels[entity.id] {
                        let text = Text(KGGraphCanvasLayout.compactLabel(entity.name))
                            .font(.caption2).foregroundColor(.primary)
                        var labelContext = ctx
                        labelContext.clip(to: Path(frame))
                        labelContext.draw(text, in: frame)
                    }
                }
                        }
                        .background(Color.gray.opacity(0.04))
                        .accessibilityLabel("Knowledge graph")
                        .accessibilityChildren {
                            ForEach(nodes) { accessibleNode($0) }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { value in
                                    hitTest(at: value.location)
                                }
                        )
                        if nodes.isEmpty {
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
            .task(id: "\(signature):\(geo.size)") {
                let size = geo.size
                guard size.width > 1, size.height > 1 else { return }
                let radius = nodeRadius
                let worker = Task.detached(priority: .userInitiated) {
                    KGGraphCanvasLayout.positions(entities: nodes, edges: links, in: size, nodeRadius: radius)
                }
                let layout = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled else { return }
                positions = layout
            }
        }
    }

    private func accessibleNode(_ entity: KnowledgeGraphEntity) -> some View {
        let selectionValue = selectedId == entity.id ? "Selected" : ""
        return Button(action: { selectedId = entity.id }) {
            Text(verbatim: entity.name)
        }
        .accessibilityValue(Text(verbatim: selectionValue))
    }

    private func hitTest(at point: CGPoint) {
        var best: (id: String, dist: CGFloat)?
        for (id, p) in positions {
            let dx = p.x - point.x
            let dy = p.y - point.y
            let d = (dx * dx + dy * dy).squareRoot()
            if d <= hitRadius, best.map({ d < $0.dist }) ?? true {
                best = (id, d)
            }
        }
        if let hit = best {
            selectedId = hit.id
        }
    }

}

/// Only unique, named nodes and edges with visible endpoints influence layout.
enum KGGraphCanvasLayout {
    static func compactLabel(_ name: String) -> String {
        let normalized = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return normalized.count > 18 ? String(normalized.prefix(18)) + "…" : normalized
    }

    /// At most forty candidates; selected nodes win, then stable ID order.
    /// O(n²) rectangle checks remain bounded and run only during a draw.
    static func labelFrames(
        entities: [KnowledgeGraphEntity], positions: [String: CGPoint], in size: CGSize,
        selectedID: String?, nodeRadius: CGFloat
    ) -> [String: CGRect] {
        guard entities.count <= 40, size.width >= 24, size.height >= 20 else { return [:] }
        let width = min(100, size.width - 8)
        let height: CGFloat = 16
        let ordered = entities.sorted {
            if ($0.id == selectedID) != ($1.id == selectedID) { return $0.id == selectedID }
            return $0.id < $1.id
        }
        var frames: [String: CGRect] = [:]
        for entity in ordered {
            guard let point = positions[entity.id] else { continue }
            let x = min(max(4, point.x - width / 2), size.width - width - 4)
            // Try below, then above. Never cover another node to make room.
            for y in [point.y + nodeRadius + 6, point.y - nodeRadius - height - 6] {
                let frame = CGRect(x: x, y: y, width: width, height: height)
                guard frame.minY >= 2, frame.maxY <= size.height - 2 else { continue }
                guard !frames.values.contains(where: { $0.insetBy(dx: -3, dy: -2).intersects(frame) }) else { continue }
                guard !positions.values.contains(where: {
                    CGRect(x: $0.x - nodeRadius, y: $0.y - nodeRadius,
                           width: nodeRadius * 2, height: nodeRadius * 2).intersects(frame)
                }) else { continue }
                frames[entity.id] = frame
                break
            }
        }
        return frames
    }

    /// The force layout is quadratic in nodes. This limit belongs to the
    /// canvas owner rather than only the parent picker, so a direct/future
    /// canvas caller cannot accidentally start an unbounded layout pass.
    static let maximumRenderableEntities = 200

    enum RenderSafety: Equatable {
        case render(entityCount: Int)
        case tooLarge(entityCount: Int)
    }

    static func renderSafety(entityCount: Int) -> RenderSafety {
        return entityCount <= maximumRenderableEntities
            ? .render(entityCount: entityCount)
            : .tooLarge(entityCount: entityCount)
    }

    static func canonicalEntities(_ entities: [KnowledgeGraphEntity]) -> [KnowledgeGraphEntity] {
        var seen = Set<String>()
        return entities
            .filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.id < $1.id }
    }

    static func visibleEdges(_ edges: [KnowledgeGraphEdge], among entities: [KnowledgeGraphEntity]) -> [KnowledgeGraphEdge] {
        let ids = Set(entities.map(\.id))
        var seen = Set<String>()
        return edges
            .filter { ids.contains($0.from) && ids.contains($0.to) }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.id < $1.id }
    }

    static func signature(entities: [KnowledgeGraphEntity], edges: [KnowledgeGraphEdge]) -> String {
        let nodePart = entities.map(\.id).joined(separator: "|")
        let edgePart = edges.map(\.id).joined(separator: "|")
        return "\(nodePart)#\(edgePart)"
    }

    /// Fruchterman-Reingold-ish: deterministic initialization plus ten rounds
    /// of repulsion and visible-edge attraction. The final clamp guarantees
    /// every reported node center stays inside the drawable canvas.
    static func positions(
        entities: [KnowledgeGraphEntity],
        edges: [KnowledgeGraphEdge],
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
            for (index, firstID) in ids.enumerated() {
                guard !Task.isCancelled else { return [:] }
                guard let first = positions[firstID] else { continue }
                for secondID in ids.dropFirst(index + 1) {
                    guard let second = positions[secondID],
                          let firstDisplacement = displacement[firstID],
                          let secondDisplacement = displacement[secondID] else { continue }
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
                    displacement[firstID] = CGPoint(
                        x: firstDisplacement.x + CGFloat(ux * force),
                        y: firstDisplacement.y + CGFloat(uy * force)
                    )
                    displacement[secondID] = CGPoint(
                        x: secondDisplacement.x - CGFloat(ux * force),
                        y: secondDisplacement.y - CGFloat(uy * force)
                    )
                }
            }
            for edge in liveEdges {
                guard let first = positions[edge.from], let second = positions[edge.to],
                      let firstDisplacement = displacement[edge.from],
                      let secondDisplacement = displacement[edge.to] else { continue }
                let dx = Double(first.x - second.x)
                let dy = Double(first.y - second.y)
                let distance = max(0.01, (dx * dx + dy * dy).squareRoot())
                let force = (distance * distance) / k
                let ux = dx / distance
                let uy = dy / distance
                displacement[edge.from] = CGPoint(
                    x: firstDisplacement.x - CGFloat(ux * force),
                    y: firstDisplacement.y - CGFloat(uy * force)
                )
                displacement[edge.to] = CGPoint(
                    x: secondDisplacement.x + CGFloat(ux * force),
                    y: secondDisplacement.y + CGFloat(uy * force)
                )
            }
            for id in ids {
                guard let delta = displacement[id], let position = positions[id] else { continue }
                let magnitude = (Double(delta.x) * Double(delta.x) + Double(delta.y) * Double(delta.y)).squareRoot()
                guard magnitude > 0.01 else { continue }
                let limited = min(magnitude, Double(temperature))
                let x = Double(position.x) + Double(delta.x) / magnitude * limited
                let y = Double(position.y) + Double(delta.y) / magnitude * limited
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
