import Foundation
import CoreGraphics
import CoreMedia
import Experiences
import NativeAgentCore
import PersistenceCore
import ScreenCaptureKit
import Senses
import Synchronization
// Blueprint: | `VisionVisualObjects.swift` | `VisionLiveRegionIdentity`, `VisionLiveOccludedRegion`; `VisionPercept`: physical admission, indicator values, shape aliases and spatial relations |

/// The live scene owns continuity and motion; the compiler owns region meaning.
public struct VisionLiveRegionIdentity: Sendable, Equatable {
    public let id: Int
    public let motion: String?
    /// Bounded motor lead in global points; rendering keeps the observed location.
    public let projectedX: Double
    public let projectedY: Double
    /// Direction is readable; motor lead needs another frame in bounded act acquisition.
    public let needsMotionConfirmation: Bool

    public init(
        id: Int,
        motion: String? = nil,
        projectedX: Double = 0,
        projectedY: Double = 0,
        needsMotionConfirmation: Bool = false
    ) {
        self.id = id
        self.motion = motion
        self.projectedX = projectedX
        self.projectedY = projectedY
        self.needsMotionConfirmation = needsMotionConfirmation
    }
}

public struct VisionLiveOccludedRegion: Sendable, Equatable {
    public let id: Int
    public let colorName: String?
    public let shapeName: String?
    public let lastCenterXPercent: Int
    public let lastCenterYPercent: Int
    public let expectedCenterXPercent: Int?
    public let expectedCenterYPercent: Int?
    public let missedFrames: Int
    public let confidence: Double

    public init(
        id: Int,
        colorName: String?,
        shapeName: String? = nil,
        lastCenterXPercent: Int,
        lastCenterYPercent: Int,
        expectedCenterXPercent: Int? = nil,
        expectedCenterYPercent: Int? = nil,
        missedFrames: Int,
        confidence: Double
    ) {
        self.id = id
        self.colorName = colorName
        self.shapeName = shapeName
        self.lastCenterXPercent = lastCenterXPercent
        self.lastCenterYPercent = lastCenterYPercent
        self.expectedCenterXPercent = expectedCenterXPercent
        self.expectedCenterYPercent = expectedCenterYPercent
        self.missedFrames = missedFrames
        self.confidence = confidence
    }
}

struct VisionLinearIndicatorRender {
    let values: [MacScreenRender.Value]
    let effectValueTexts: [String]
    let claimedReadoutHandles: Set<String>
    let claimedRecognizedKeys: Set<String>
}

private struct VisionSpatialNode {
    let id: Int
    let color: String?
    let shape: String?
    let rect: VisionRect
    let confidence: Double
}

extension VisionPercept {
    /// Physical admission over the caller's row scope, before consumer ranking.
    public static func physicalRowSelection(in rows: [VisionAffordanceRow], frameSize: VisionSize)
        -> (eligible: [Int], redundant: Set<Int>, indicators: Set<Int>) {
        let redundant = redundantColorlessHaloIndexes(in: rows, frameSize: frameSize)
            .union(redundantSameColorRegionIndexes(in: rows, frameSize: frameSize))
        let indicators = linearIndicatorIndexes(in: rows, frameSize: frameSize)
        let eligible = rows.indices.filter {
            !redundant.contains($0) && !indicators.contains($0)
                && isPhysicalRegionCandidate(rows[$0], frameSize: frameSize)
        }
        return (eligible, redundant, indicators)
    }

    /// The tracker and screen adapter admit the same physical regions.
    public static func isPhysicalRegionCandidate(
        _ row: VisionAffordanceRow,
        frameSize: VisionSize? = nil
    ) -> Bool {
        let roleUnknown = row.ambiguous == nil
            || row.ambiguous?.contains("unlabeled region with no role guess") == true
        guard row.displayLabel == nil, roleUnknown, !row.destructiveRisk else { return false }
        let saliencyAreaIsTargetSized: Bool = {
            guard let frameSize else { return true }
            let frameArea = frameSize.width * frameSize.height
            return frameArea > 0 && row.rect.area / frameArea <= 0.12
        }()
        let salient = row.evidence.contains(.saliency)
            && row.confidence.bounds >= 0.30
            && row.salience >= 0.45
            && saliencyAreaIsTargetSized
        let boundedColor = row.evidence.contains(.colorRegion)
            && row.confidence.bounds >= 0.82
            && {
                let contrast = row.visualContrast ?? 0
                guard contrast < 0.25 else { return true }
                guard contrast >= 0.10, let frameSize else { return false }
                let frameArea = frameSize.width * frameSize.height
                // Substantial bounded muted regions qualify; tiny fragments do not.
                return frameArea > 0 && row.rect.area / frameArea >= 0.001
            }()
        return salient || boundedColor
    }

    /// Suppress only a colorless saliency halo near a strongly bounded colour core of comparable scale.
    public static func redundantColorlessHaloIndexes(
        in rows: [VisionAffordanceRow],
        frameSize: VisionSize? = nil
    ) -> Set<Int> {
        var redundant: Set<Int> = []
        for (index, row) in rows.enumerated() {
            guard row.visualColor == nil,
                  row.evidence == [.saliency],
                  Self.isPhysicalRegionCandidate(row, frameSize: frameSize),
                  row.rect.area > 0 else { continue }
            let duplicate = rows.enumerated().contains { otherIndex, other in
                guard otherIndex != index,
                      other.visualColor != nil,
                      other.evidence.contains(.colorRegion),
                      other.confidence.bounds >= 0.75,
                      Self.isPhysicalRegionCandidate(other, frameSize: frameSize),
                      other.rect.area > 0 else { return false }
                let dx = row.rect.centerX - other.rect.centerX
                let dy = row.rect.centerY - other.rect.centerY
                let distance = hypot(dx, dy)
                let reach = max(48, max(other.rect.w, other.rect.h) * 1.5)
                let areaRatio = max(row.rect.area, other.rect.area)
                    / min(row.rect.area, other.rect.area)
                return distance <= reach && areaRatio <= 25
            }
            if duplicate { redundant.insert(index) }
        }
        return redundant
    }

    /// Keep the better pinned overlapping same-colour row; nearby objects remain separate.
    public static func redundantSameColorRegionIndexes(
        in rows: [VisionAffordanceRow],
        frameSize: VisionSize? = nil
    ) -> Set<Int> {
        var redundant: Set<Int> = []
        for leftIndex in rows.indices {
            guard !redundant.contains(leftIndex),
                  let color = rows[leftIndex].visualColor,
                  Self.isPhysicalRegionCandidate(rows[leftIndex], frameSize: frameSize),
                  rows[leftIndex].rect.area > 0 else { continue }
            for rightIndex in rows.indices where rightIndex > leftIndex {
                guard !redundant.contains(rightIndex),
                      rows[rightIndex].visualColor == color,
                      Self.isPhysicalRegionCandidate(rows[rightIndex], frameSize: frameSize),
                      rows[rightIndex].rect.area > 0 else { continue }
                let left = rows[leftIndex]
                let right = rows[rightIndex]
                let dx = left.rect.centerX - right.rect.centerX
                let dy = left.rect.centerY - right.rect.centerY
                let distance = hypot(dx, dy)
                let largestDimension = max(
                    max(left.rect.w, left.rect.h),
                    max(right.rect.w, right.rect.h)
                )
                let areaRatio = max(left.rect.area, right.rect.area)
                    / min(left.rect.area, right.rect.area)
                let duplicate = left.rect.iou(right.rect) >= 0.35
                    || (distance <= largestDimension * 0.25 && areaRatio <= 1.75)
                guard duplicate else { continue }
                func score(_ row: VisionAffordanceRow) -> Double {
                    row.confidence.bounds * 2
                        + (row.visualContrast ?? 0)
                        + row.salience
                }
                if score(right) > score(left) {
                    redundant.insert(leftIndex)
                    break
                } else {
                    redundant.insert(rightIndex)
                }
            }
        }
        return redundant
    }

    /// Extreme bounded colour strips are indicators, with no inferred meaning or point target.
    public static func linearIndicatorIndexes(
        in rows: [VisionAffordanceRow],
        frameSize: VisionSize
    ) -> Set<Int> {
        let frameArea = frameSize.width * frameSize.height
        guard frameArea > 0 else { return [] }
        return Set(rows.enumerated().compactMap { index, row in
            guard row.visualColor != nil,
                  row.evidence.contains(.colorRegion),
                  row.confidence.bounds >= 0.75,
                  row.rect.w > 0,
                  row.rect.h > 0 else { return nil }
            let long = max(row.rect.w, row.rect.h)
            let short = min(row.rect.w, row.rect.h)
            let longTotal = row.rect.w >= row.rect.h ? frameSize.width : frameSize.height
            let shortTotal = row.rect.w >= row.rect.h ? frameSize.height : frameSize.width
            guard long / short >= 5,
                  short / shortTotal <= 0.025,
                  long / longTotal <= 0.60 else { return nil }
            return index
        })
    }

    /// Join touching aligned colour strips to expose proportions without guessing meaning.
    static func linearIndicatorValues(
        in rows: [VisionAffordanceRow],
        indexes: Set<Int>,
        frameSize: VisionSize,
        readouts: [VisionReadoutRow],
        recognizedText: [VisionRecognizedText]
    ) -> VisionLinearIndicatorRender {
        var remaining = indexes
        var groups: [[Int]] = []
        while let seed = remaining.first {
            remaining.remove(seed)
            var group = [seed]
            var expanded = true
            while expanded {
                expanded = false
                for candidate in remaining {
                    let joins = group.contains { member in
                        let left = rows[member].rect
                        let right = rows[candidate].rect
                        let horizontal = left.w >= left.h
                        guard horizontal == (right.w >= right.h) else { return false }
                        let crossDistance = horizontal
                            ? abs(left.centerY - right.centerY)
                            : abs(left.centerX - right.centerX)
                        let crossSize = horizontal
                            ? max(left.h, right.h)
                            : max(left.w, right.w)
                        let leftEnd = horizontal ? left.x + left.w : left.y + left.h
                        let rightStart = horizontal ? right.x : right.y
                        let rightEnd = horizontal ? right.x + right.w : right.y + right.h
                        let leftStart = horizontal ? left.x : left.y
                        let gap = max(0, max(rightStart - leftEnd, leftStart - rightEnd))
                        return crossDistance <= crossSize && gap <= max(4, crossSize * 2)
                    }
                    if joins {
                        group.append(candidate)
                        remaining.remove(candidate)
                        expanded = true
                        break
                    }
                }
            }
            groups.append(group)
        }

        var values: [MacScreenRender.Value] = []
        var effectValueTexts: [String] = []
        var claimedReadoutHandles: Set<String> = []
        var claimedRecognizedKeys: Set<String> = []
        for group in groups {
            let horizontal = rows[group[0]].rect.w >= rows[group[0]].rect.h
            let ordered = group.sorted {
                horizontal ? rows[$0].rect.x < rows[$1].rect.x : rows[$0].rect.y < rows[$1].rect.y
            }
            let minX = ordered.map { rows[$0].rect.x }.min() ?? 0
            let minY = ordered.map { rows[$0].rect.y }.min() ?? 0
            let maxX = ordered.map { rows[$0].rect.x + rows[$0].rect.w }.max() ?? 0
            let maxY = ordered.map { rows[$0].rect.y + rows[$0].rect.h }.max() ?? 0
            let totalLength = horizontal ? maxX - minX : maxY - minY
            let centerX = frameSize.width > 0
                ? Int(((minX + maxX) / 2 / frameSize.width * 100).rounded()) : 0
            let centerY = frameSize.height > 0
                ? Int(((minY + maxY) / 2 / frameSize.height * 100).rounded()) : 0
            let longTotal = horizontal ? frameSize.width : frameSize.height
            let length = longTotal > 0
                ? max(1, Int((totalLength / longTotal * 100).rounded())) : 0
            let prefix: String
            var segmentProportions: [Int] = []
            if ordered.count == 1 {
                let color = rows[ordered[0]].visualColor.map { "\($0) " } ?? ""
                prefix = color + (horizontal ? "horizontal" : "vertical") + " indicator"
            } else {
                let segments = ordered.map { index -> String in
                    let row = rows[index]
                    let segmentLength = horizontal ? row.rect.w : row.rect.h
                    let proportion = totalLength > 0
                        ? Int((segmentLength / totalLength * 100).rounded()) : 0
                    segmentProportions.append(proportion)
                    return "\(row.visualColor ?? "unknown") \(proportion)%"
                }.joined(separator: ", ")
                prefix = (horizontal ? "horizontal" : "vertical")
                    + " segmented indicator (\(segments))"
            }
            let geometry = "\(prefix) at \(centerX)%,\(centerY)%, length \(length)%"
            func closeEnough(_ rect: VisionRect) -> Bool {
                let horizontalGap = max(0, max(minX - rect.maxX, rect.x - maxX))
                let verticalGap = max(0, max(minY - rect.maxY, rect.y - maxY))
                return hypot(horizontalGap, verticalGap) <= max(80, totalLength * 0.5)
            }
            let nearbyReadout: VisionReadoutRow? = ordered.count > 1
                ? readouts.filter { readout in
                    guard !claimedReadoutHandles.contains(readout.handle),
                          let display = readout.text.display,
                          let percent = Self.visiblePercent(in: display),
                          segmentProportions.contains(where: { abs($0 - percent) <= 3 }) else {
                        return false
                    }
                    return closeEnough(readout.rect)
                }.min { lhs, rhs in
                    let left = hypot(lhs.rect.centerX - (minX + maxX) / 2,
                                     lhs.rect.centerY - (minY + maxY) / 2)
                    let right = hypot(rhs.rect.centerX - (minX + maxX) / 2,
                                      rhs.rect.centerY - (minY + maxY) / 2)
                    return left < right
                }
                : nil
            let nearbyRecognized: VisionRecognizedText? = nearbyReadout == nil && ordered.count > 1
                ? recognizedText.filter { recognized in
                    guard let display = recognized.text.display,
                          !claimedRecognizedKeys.contains(display.lowercased()),
                          let rect = recognized.rect,
                          let percent = Self.visiblePercent(in: display),
                          segmentProportions.contains(where: { abs($0 - percent) <= 3 }) else {
                        return false
                    }
                    return closeEnough(rect)
                }.min { lhs, rhs in
                    guard let leftRect = lhs.rect, let rightRect = rhs.rect else { return false }
                    let left = hypot(leftRect.centerX - (minX + maxX) / 2,
                                     leftRect.centerY - (minY + maxY) / 2)
                    let right = hypot(rightRect.centerX - (minX + maxX) / 2,
                                      rightRect.centerY - (minY + maxY) / 2)
                    return left < right
                }
                : nil
            let text: String
            let valueText: String
            if let nearbyReadout, let display = nearbyReadout.text.display {
                claimedReadoutHandles.insert(nearbyReadout.handle)
                text = "\(display) — \(geometry)"
                valueText = "\(display) — \(prefix), length \(length)%"
            } else if let nearbyRecognized, let display = nearbyRecognized.text.display {
                claimedRecognizedKeys.insert(display.lowercased())
                text = "\(display) — \(geometry)"
                valueText = "\(display) — \(prefix), length \(length)%"
            } else {
                text = geometry
                valueText = "\(prefix), length \(length)%"
            }
            effectValueTexts.append(valueText)
            let confidence = ordered.map { Self.physicalPointConfidence(rows[$0]) }.max() ?? 0
            values.append(MacScreenRender.Value(
                text: MacScreenText(text, redacted: .string(text)),
                provenance: .vision(confidence)
            ))
        }
        return VisionLinearIndicatorRender(
            values: values,
            effectValueTexts: effectValueTexts,
            claimedReadoutHandles: claimedReadoutHandles,
            claimedRecognizedKeys: claimedRecognizedKeys
        )
    }

    static func naturalShapeNames(_ row: VisionAffordanceRow) -> [String] {
        let noun: String? = switch row.visualShape {
        case "square": "square"
        case "round": "circle"
        default: nil
        }
        guard let noun else { return [] }
        return row.visualColor.map { ["\($0) \(noun)", noun] } ?? [noun]
    }

    static func visiblePercent(in text: String) -> Int? {
        guard let marker = text.firstIndex(of: "%") else { return nil }
        let prefix = text[..<marker]
        let digits = prefix.reversed().prefix { $0.isNumber }.reversed()
        guard !digits.isEmpty else { return nil }
        return Int(String(digits))
    }

    static func isStandaloneOCRNoise(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let markers: Set<Character> = ["•", "·", "●", "○", "▪", "▫"]
        let compact = trimmed.filter { !$0.isWhitespace }
        return !compact.isEmpty && compact.allSatisfy { markers.contains($0) }
    }

    /// Bounded minimum-spanning relations use stable live identities; HUD values keep priority.
    static func spatialRelationValues(
        in rows: [VisionAffordanceRow],
        indexes: Set<Int>,
        frameSize: VisionSize,
        identities: [VisionRect: VisionLiveRegionIdentity]
    ) -> [MacScreenRender.Value] {
        let nodes = indexes.compactMap { index -> VisionSpatialNode? in
            let row = rows[index]
            guard let identity = identities[row.rect] else { return nil }
            return VisionSpatialNode(
                id: identity.id,
                color: row.visualColor,
                shape: row.visualShape,
                rect: row.rect,
                confidence: Self.physicalPointConfidence(row)
            )
        }.sorted { $0.id < $1.id }
        guard nodes.count >= 2, frameSize.width > 0, frameSize.height > 0 else { return [] }

        var connected: Set<Int> = [0]
        var remaining = Set(1..<nodes.count)
        var values: [MacScreenRender.Value] = []
        while !remaining.isEmpty, values.count < 4 {
            var best: (from: Int, to: Int, distance: Double)?
            for from in connected.sorted() {
                for to in remaining.sorted() {
                    let dx = (nodes[to].rect.centerX - nodes[from].rect.centerX) / frameSize.width
                    let dy = (nodes[to].rect.centerY - nodes[from].rect.centerY) / frameSize.height
                    let distance = hypot(dx, dy)
                    if let previous = best, distance >= previous.distance { continue }
                    best = (from, to, distance)
                }
            }
            guard let best else { break }
            let source = nodes[best.from]
            let target = nodes[best.to]
            let direction = spatialDirection(from: source.rect, to: target.rect, frameSize: frameSize)
            let overlap = direction == "overlaps"
            let proximity = !overlap && best.distance <= 0.18 ? "near and " : ""
            func label(_ node: VisionSpatialNode) -> String {
                let appearance = [node.shape, node.color].compactMap { $0 }.joined(separator: " ")
                return appearance.isEmpty
                    ? "visual region \(node.id)"
                    : "\(appearance) visual region \(node.id)"
            }
            let relation = overlap ? direction : "is \(proximity)\(direction)"
            let text = "\(label(source)) \(relation) \(label(target))"
            values.append(MacScreenRender.Value(
                text: MacScreenText(text, redacted: .string(text)),
                provenance: .vision(min(source.confidence, target.confidence))
            ))
            connected.insert(best.to)
            remaining.remove(best.to)
        }
        return values
    }

    static func spatialDirection(from source: VisionRect, to target: VisionRect, frameSize: VisionSize) -> String {
        if source.iou(target) >= 0.05
            || source.coverage(by: target) >= 0.15
            || target.coverage(by: source) >= 0.15 { return "overlaps" }
        let dx = (target.centerX - source.centerX) / max(1, frameSize.width)
        let dy = (target.centerY - source.centerY) / max(1, frameSize.height)
        return abs(dx) >= abs(dy) ? (dx >= 0 ? "left of" : "right of")
            : (dy >= 0 ? "above" : "below")
    }

    /// Physical-only confidence measures the visible point, without semantic role or label uncertainty.
    static func physicalPointConfidence(_ row: VisionAffordanceRow) -> Double {
        min(row.confidence.bounds, max(row.salience, row.visualContrast ?? 0))
    }
}
