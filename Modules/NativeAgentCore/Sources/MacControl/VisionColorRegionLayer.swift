import Foundation
import CoreGraphics
// Blueprint: | `VisionColorRegionLayer.swift` | `VisionColorRegionResult`, `VisionPixelGrid`, `VisionColorRegionLayer` |

// MARK: - ELEMENT LAYER (a): structure from pixels, no model

public struct VisionColorRegionResult: Sendable, Equatable {
    public let candidates: [VisionCandidate]
    /// Expose background colour so disabled-state guesses share the candidate detector’s reference.
    public let backgroundLuminance: Double
    /// Report candidate caps so incomplete evidence cannot look complete.
    public let capped: Bool

    public init(candidates: [VisionCandidate], backgroundLuminance: Double, capped: Bool) {
        self.candidates = candidates
        self.backgroundLuminance = backgroundLuminance
        self.capped = capped
    }
}

/// Share one decoded coarse grid across region and state heuristics.
public struct VisionPixelGrid: Sendable {
    public let columns: Int
    public let rows: Int
    public let stepX: Double
    public let stepY: Double
    public let imageSize: VisionSize
    public let samples: [SIMD3<Double>]

    public init(
        columns: Int,
        rows: Int,
        stepX: Double,
        stepY: Double,
        imageSize: VisionSize,
        samples: [SIMD3<Double>]
    ) {
        self.columns = columns
        self.rows = rows
        self.stepX = stepX
        self.stepY = stepY
        self.imageSize = imageSize
        self.samples = samples
    }

    public func color(column: Int, row: Int) -> SIMD3<Double> {
        samples[row * columns + column]
    }

    public func rect(fromColumn c0: Int, toColumn c1: Int, fromRow r0: Int, toRow r1: Int) -> VisionRect {
        let x = Double(c0) * stepX
        let y = Double(r0) * stepY
        let right = min(imageSize.width, Double(c1 + 1) * stepX)
        let bottom = min(imageSize.height, Double(r1 + 1) * stepY)
        return VisionRect(x: x, y: y, w: max(0, right - x), h: max(0, bottom - y))
    }

    /// Rec. 709 luminance over the coarse grid is sufficient for approximate greyed-control comparison.
    public func meanLuminance(in rect: VisionRect) -> Double? {
        let c0 = max(0, Int(rect.x / stepX))
        let c1 = min(columns - 1, Int((rect.maxX - 1) / stepX))
        let r0 = max(0, Int(rect.y / stepY))
        let r1 = min(rows - 1, Int((rect.maxY - 1) / stepY))
        guard c0 <= c1, r0 <= r1 else { return nil }
        var total = 0.0
        var count = 0
        for row in r0...r1 {
            for column in c0...c1 {
                let rgb = color(column: column, row: row)
                total += 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return total / Double(count)
    }

    /// Caption luminance spread distinguishes live contrast from greyed text; mean brightness cannot.
    public func luminanceSpread(in rect: VisionRect) -> Double? {
        let c0 = max(0, Int(rect.x / stepX))
        let c1 = min(columns - 1, Int((rect.maxX - 1) / stepX))
        let r0 = max(0, Int(rect.y / stepY))
        let r1 = min(rows - 1, Int((rect.maxY - 1) / stepY))
        guard c0 <= c1, r0 <= r1 else { return nil }
        var lowest = Double.greatestFiniteMagnitude
        var highest = -Double.greatestFiniteMagnitude
        for row in r0...r1 {
            for column in c0...c1 {
                let rgb = color(column: column, row: row)
                let luminance = 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
                lowest = min(lowest, luminance)
                highest = max(highest, luminance)
            }
        }
        guard highest >= lowest else { return nil }
        return highest - lowest
    }

    /// Decode once per frame so every heuristic sees the same grid.
    public static func sample(
        image: CGImage,
        longAxisSamples: Int
    ) -> VisionPixelGrid? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let longAxis = max(width, height)
        let stride = max(1, Int((Double(longAxis) / Double(max(1, longAxisSamples))).rounded()))
        let columns = max(1, width / stride)
        let rows = max(1, height / stride)

        // Normalize into RGBA8 before reading bytes; CGImage providers may use arbitrary colour spaces, depths and alpha layouts.
        let bytesPerRow = columns * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * rows)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: columns,
                      height: rows,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: space,
                      bitmapInfo: info
                  ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
            return true
        }
        guard drawn else { return nil }

        var samples = [SIMD3<Double>](repeating: .zero, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let offset = row * bytesPerRow + column * 4
                samples[row * columns + column] = SIMD3(
                    Double(buffer[offset]) / 255,
                    Double(buffer[offset + 1]) / 255,
                    Double(buffer[offset + 2]) / 255
                )
            }
        }
        return VisionPixelGrid(
            columns: columns,
            rows: rows,
            stepX: Double(width) / Double(columns),
            stepY: Double(height) / Double(rows),
            imageSize: VisionSize(width: Double(width), height: Double(height)),
            samples: samples
        )
    }
}

public enum VisionColorRegionLayer {
    static let gridLongAxisSamples: Int = 320
    /// Squared RGB distance defines approximate shared fill colour.
    private static let colorTolerance: Double = 0.02
    /// Require fill contrast against the background before emitting a candidate.
    private static let backgroundTolerance: Double = 0.006
    private static let minAreaFraction: Double = 0.00015
    /// Exclude window backgrounds and full-bleed panels from control candidates.
    private static let maxAreaFraction: Double = 0.5
    private static let minSidePixels: Double = 8
    /// Accept majority fill so caption glyphs cannot stop growth at the first text row.
    private static let growMatchFraction: Double = 0.65
    /// Merge substantial overlap so border and interior do not become duplicate controls.
    private static let dedupeIoU: Double = 0.55
    /// Cap texture-heavy scenes and report truncation rather than implying thousands of fragments are complete.
    static let maxCandidates: Int = 200

    static func distanceSquared(_ lhs: SIMD3<Double>, _ rhs: SIMD3<Double>) -> Double {
        // Fixed RGB operations avoid costly generic SIMD element access in installed development builds.
        let red = lhs.x - rhs.x
        let green = lhs.y - rhs.y
        let blue = lhs.z - rhs.z
        return red * red + green * green + blue * blue
    }

    /// Text bands cover rows whose pixels lack fill contrast.
    public static func candidates(
        grid: VisionPixelGrid
    ) -> VisionColorRegionResult {
        let frameArea = grid.imageSize.width * grid.imageSize.height
        guard frameArea > 0 else {
            return VisionColorRegionResult(candidates: [], backgroundLuminance: 0, capped: false)
        }

        // Use modal quantized colour rather than a corner that may belong to a sidebar or full-bleed image.
        var histogram: [SIMD3<Int>: Int] = [:]
        for sample in grid.samples {
            let key = SIMD3(Int(sample.x * 16), Int(sample.y * 16), Int(sample.z * 16))
            histogram[key, default: 0] += 1
        }
        let dominant = histogram.max { lhs, rhs in
            lhs.value == rhs.value
                ? (lhs.key.x, lhs.key.y, lhs.key.z) > (rhs.key.x, rhs.key.y, rhs.key.z)
                : lhs.value < rhs.value
        }?.key ?? SIMD3(0, 0, 0)
        let background = SIMD3(
            (Double(dominant.x) + 0.5) / 16,
            (Double(dominant.y) + 0.5) / 16,
            (Double(dominant.z) + 0.5) / 16
        )
        let backgroundLuminance = 0.2126 * background.x + 0.7152 * background.y + 0.0722 * background.z
        // Compute the frame-local background centroid once because growth revisits boundary cells.
        let backgroundDistances = grid.samples.map { distanceSquared($0, background) }

        // Grow rectangles so candidate bounds and action points share a box with observed edges.
        var visited = [Bool](repeating: false, count: grid.columns * grid.rows)
        var raw: [VisionCandidate] = []
        var capped = false

        for row in 0..<grid.rows {
            for column in 0..<grid.columns {
                let index = row * grid.columns + column
                if visited[index] { continue }
                let seed = grid.color(column: column, row: row)
                guard backgroundDistances[index] > backgroundTolerance else {
                    visited[index] = true
                    continue
                }

                var c0 = column, c1 = column, r0 = row, r1 = row
                // Majority fill lets growth cross caption glyphs while genuine boundaries still stop it. Require both seed proximity and greater closeness to
                // seed than background so tolerant light fills cannot absorb the whole window.
                func belongs(_ column: Int, _ row: Int) -> Bool {
                    let cellIndex = row * grid.columns + column
                    let cell = grid.samples[cellIndex]
                    let toSeed = distanceSquared(cell, seed)
                    guard toSeed <= colorTolerance else { return false }
                    return toSeed < backgroundDistances[cellIndex]
                }
                func matchFraction(rowIndex r: Int, from a: Int, to b: Int) -> Double {
                    var matches = 0
                    for c in a...b where belongs(c, r) { matches += 1 }
                    return Double(matches) / Double(b - a + 1)
                }
                func matchFraction(columnIndex c: Int, from a: Int, to b: Int) -> Double {
                    var matches = 0
                    for r in a...b where belongs(c, r) { matches += 1 }
                    return Double(matches) / Double(b - a + 1)
                }
                func rowMatches(_ r: Int, from a: Int, to b: Int) -> Bool {
                    guard r >= 0, r < grid.rows else { return false }
                    return matchFraction(rowIndex: r, from: a, to: b) >= growMatchFraction
                }
                func columnMatches(_ c: Int, from a: Int, to b: Int) -> Bool {
                    guard c >= 0, c < grid.columns else { return false }
                    return matchFraction(columnIndex: c, from: a, to: b) >= growMatchFraction
                }
                var growing = true
                while growing {
                    growing = false
                    if columnMatches(c1 + 1, from: r0, to: r1) { c1 += 1; growing = true }
                    if columnMatches(c0 - 1, from: r0, to: r1) { c0 -= 1; growing = true }
                    if rowMatches(r1 + 1, from: c0, to: c1) { r1 += 1; growing = true }
                    if rowMatches(r0 - 1, from: c0, to: c1) { r0 -= 1; growing = true }
                }
                for r in r0...r1 {
                    for c in c0...c1 { visited[r * grid.columns + c] = true }
                }

                let rect = grid.rect(fromColumn: c0, toColumn: c1, fromRow: r0, toRow: r1)
                guard rect.w >= minSidePixels, rect.h >= minSidePixels else { continue }
                let areaFraction = rect.area / frameArea
                guard areaFraction >= minAreaFraction,
                      areaFraction <= maxAreaFraction else { continue }

                // Interior stopping edges earn confidence; touching the frame edge may indicate cropping and must lower it.
                let touchesEdge = c0 == 0 || r0 == 0 || c1 == grid.columns - 1 || r1 == grid.rows - 1
                let contrast = min(1, backgroundDistances[index] / 0.08)
                let boundsConfidence = (touchesEdge ? 0.45 : 0.75) + 0.2 * contrast
                let luminance = 0.2126 * seed.x + 0.7152 * seed.y + 0.0722 * seed.z
                // Rectangular bounds cannot distinguish disks from squares; inspect the connected component for a conservative silhouette only.
                let visualShape: String? = {
                    var queue: [(column: Int, row: Int)] = [(column, row)]
                    var cursor = 0
                    var component: Set<Int> = [index]
                    var minColumn = column, maxColumn = column
                    var minRow = row, maxRow = row
                    while cursor < queue.count, component.count <= 10_000 {
                        let cell = queue[cursor]
                        cursor += 1
                        let neighbors = [
                            (cell.column - 1, cell.row), (cell.column + 1, cell.row),
                            (cell.column, cell.row - 1), (cell.column, cell.row + 1),
                        ]
                        for (nextColumn, nextRow) in neighbors {
                            guard nextColumn >= 0, nextColumn < grid.columns,
                                  nextRow >= 0, nextRow < grid.rows,
                                  belongs(nextColumn, nextRow) else { continue }
                            let nextIndex = nextRow * grid.columns + nextColumn
                            guard component.insert(nextIndex).inserted else { continue }
                            queue.append((nextColumn, nextRow))
                            minColumn = min(minColumn, nextColumn)
                            maxColumn = max(maxColumn, nextColumn)
                            minRow = min(minRow, nextRow)
                            maxRow = max(maxRow, nextRow)
                        }
                    }
                    guard component.count <= 10_000 else { return nil }
                    let componentWidth = maxColumn - minColumn + 1
                    let componentHeight = maxRow - minRow + 1
                    guard componentWidth >= 3, componentHeight >= 3 else { return nil }
                    let aspect = Double(componentWidth) / Double(componentHeight)
                    guard aspect >= 0.75, aspect <= 1.33 else { return nil }
                    let boxCells = componentWidth * componentHeight
                    let occupancy = Double(component.count) / Double(boxCells)
                    let corners = [
                        minRow * grid.columns + minColumn,
                        minRow * grid.columns + maxColumn,
                        maxRow * grid.columns + minColumn,
                        maxRow * grid.columns + maxColumn,
                    ].filter { component.contains($0) }.count
                    if occupancy >= 0.90, corners >= 3 { return "square" }
                    if occupancy >= 0.45, occupancy <= 0.90, corners <= 1 { return "round" }
                    return nil
                }()
                raw.append(VisionCandidate(
                    rect: rect,
                    sources: [.colorRegion],
                    boundsConfidence: boundsConfidence,
                    fillLuminance: luminance,
                    fillColor: VisionColorSample(red: seed.x, green: seed.y, blue: seed.z),
                    visualShape: visualShape
                ))
            }
        }

        // Merge largest first so bordered fields retain their outer control bounds.
        var kept: [VisionCandidate] = []
        for candidate in raw.sorted(by: { $0.rect.area > $1.rect.area }) {
            let duplicate = kept.contains { existing in
                existing.rect.iou(candidate.rect) >= dedupeIoU
                    || candidate.rect.coverage(by: existing.rect) >= 0.9
            }
            if duplicate { continue }
            if kept.count >= maxCandidates { capped = true; break }
            kept.append(candidate)
        }

        return VisionColorRegionResult(
            candidates: readingOrder(kept),
            backgroundLuminance: backgroundLuminance,
            capped: capped
        )
    }

    /// Deterministic reading order keeps identical scenes from changing handles.
    static func readingOrder(_ candidates: [VisionCandidate]) -> [VisionCandidate] {
        VisionRect.readingOrder(candidates, rect: \.rect, tolerance: 2, geometryPrecedes: geometryPrecedes) {
            $0.rect.area == $1.rect.area ? geometryPrecedes($0, $1) : $0.rect.area > $1.rect.area
        }
    }

    private static func geometryPrecedes(_ lhs: VisionCandidate, _ rhs: VisionCandidate) -> Bool {
        if lhs.rect.y != rhs.rect.y { return lhs.rect.y < rhs.rect.y }
        if lhs.rect.x != rhs.rect.x { return lhs.rect.x < rhs.rect.x }
        if lhs.rect.w != rhs.rect.w { return lhs.rect.w < rhs.rect.w }
        return lhs.rect.h < rhs.rect.h
    }

}
