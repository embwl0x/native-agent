import Foundation
import MacControl
import ChatTurnContracts
import AgentWorkspace
import MemoryV2
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import ToolRegistry
import NativeAgentShared
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Dispatcher
import Senses
import AgentConversations
import StandingBots
// Blueprint: | `VisualContinuity.swift` | `VisionLiveSceneSnapshot` struct and `SwiftToolDispatcherFourVerbLiveScene` actor; dispatcher-owned temporal identities, motion hypotheses and occlusion tracking |

/// Dispatcher-local, rebuildable perception continuity, never canonical memory or authority.
/// Shared across four-verb observations; app/window keys keep identities separate.
struct VisionLiveSceneSnapshot: Sendable, Equatable {
    let identities: [VisionRect: VisionLiveRegionIdentity]
    let temporarilyNotVisible: [VisionLiveOccludedRegion]
}

actor SwiftToolDispatcherFourVerbLiveScene {
    private struct Track {
        let id: Int
        var frame: MacAXFrame
        var salience: Double
        var contrast: Double
        var colorName: String?
        var shapeName: String?
        var pointConfidence: Double
        var seenCount: Int
        var velocityX: Double
        var velocityY: Double
        // An appearance-only jump is not motion proof. Retain one bounded
        // hypothesis for association only; a third visible frame must confirm
        // its direction and speed before it can influence motor lead.
        var provisionalVelocityX: Double = 0
        var provisionalVelocityY: Double = 0
        var lastCapturedAt: Date
        var lastSeenGeneration: Int
        var lastSeenAt: Date
    }

    private struct Scene {
        var generation = 0
        var nextID = 1
        var tracks: [Track] = []
        var lastUpdated = Date.distantPast
    }

    private var scenes: [String: Scene] = [:]

    func identify(
        rows: [VisionAffordanceRow],
        frameSize: VisionSize,
        geometry: MacScreenViewGeometry,
        sceneKey: String,
        capturedAt: Date = Date(),
        now: Date = Date()
    ) -> VisionLiveSceneSnapshot {
        let origin = (x: geometry.bounds.x, y: geometry.bounds.y)
        let logicalSize = (width: geometry.bounds.w, height: geometry.bounds.h)

        let key = sceneKey.isEmpty ? "unknown-screen" : sceneKey
        if scenes[key] == nil, scenes.count >= 12,
           let oldest = scenes.min(by: { $0.value.lastUpdated < $1.value.lastUpdated })?.key {
            scenes.removeValue(forKey: oldest)
        }
        var scene = scenes[key] ?? Scene()
        scene.generation += 1
        scene.lastUpdated = now
        var usedTrackIDs: Set<Int> = []
        var identities: [VisionRect: VisionLiveRegionIdentity] = [:]
        let candidates = VisionPercept.physicalRowSelection(in: rows, frameSize: frameSize).eligible
            .map { rows[$0] }
            .sorted { lhs, rhs in
                let left = lhs.salience + (lhs.visualContrast ?? 0)
                let right = rhs.salience + (rhs.visualContrast ?? 0)
                return left == right ? lhs.rect.area > rhs.rect.area : left > right
            }

        let colorCounts = candidates.reduce(into: [String: Int]()) { counts, row in
            if let color = row.visualColor { counts[color, default: 0] += 1 }
        }
        for row in candidates {
            let frame = geometry.screenRect(row.rect)
            var bestIndex: Int?
            var bestScore = -Double.infinity
            var bestAppearanceOnly = false
            var bestPredictionConsistent = false
            for index in scene.tracks.indices {
                let track = scene.tracks[index]
                guard !usedTrackIDs.contains(track.id),
                      scene.generation - track.lastSeenGeneration <= 6 else { continue }
                if let currentColor = row.visualColor,
                   let trackedColor = track.colorName,
                   currentColor != trackedColor {
                    continue
                }
                if let currentShape = row.visualShape,
                   let trackedShape = track.shapeName,
                   currentShape != trackedShape {
                    continue
                }
                let distance = Self.centerDistance(frame, track.frame)
                let largestDimension = max(max(frame.w, frame.h), max(track.frame.w, track.frame.h))
                let reach = max(48, min(220, largestDimension * 1.5))
                let overlap = Self.intersectionOverUnion(frame, track.frame)
                let appearance = Self.appearanceSimilarity(row: row, frame: frame, track: track)
                let elapsed = capturedAt.timeIntervalSince(track.lastCapturedAt)
                let confirmedSpeed = hypot(track.velocityX, track.velocityY)
                let provisionalSpeed = hypot(track.provisionalVelocityX, track.provisionalVelocityY)
                let usesProvisional = confirmedSpeed < 3 && provisionalSpeed >= 3
                    && track.lastSeenGeneration == scene.generation - 1
                let predictionVelocityX = usesProvisional ? track.provisionalVelocityX : track.velocityX
                let predictionVelocityY = usesProvisional ? track.provisionalVelocityY : track.velocityY
                let speed = hypot(predictionVelocityX, predictionVelocityY)
                let predictedTravel = speed * elapsed
                let predictionConsistent: Bool = {
                    guard track.seenCount >= 2,
                          elapsed >= 0.05,
                          elapsed <= 1.5,
                          speed >= 3,
                          predictedTravel <= max(440, largestDimension * 6) else { return false }
                    let predictedCenterX = track.frame.x + track.frame.w / 2
                        + predictionVelocityX * elapsed
                    let predictedCenterY = track.frame.y + track.frame.h / 2
                        + predictionVelocityY * elapsed
                    let residual = hypot(
                        frame.x + frame.w / 2 - predictedCenterX,
                        frame.y + frame.h / 2 - predictedCenterY
                    )
                    guard residual <= reach else { return false }
                    if usesProvisional {
                        guard elapsed <= 0.75 else { return false }
                        let observedX = (frame.x + frame.w / 2 - track.frame.x - track.frame.w / 2) / elapsed
                        let observedY = (frame.y + frame.h / 2 - track.frame.y - track.frame.h / 2) / elapsed
                        let observedSpeed = hypot(observedX, observedY)
                        guard observedSpeed >= speed * 0.65, observedSpeed <= speed * 1.5 else { return false }
                        let alignment = (observedX * predictionVelocityX + observedY * predictionVelocityY)
                            / (observedSpeed * speed)
                        return alignment >= 0.85
                    }
                    return true
                }()
                // A successful click may make one game object teleport. Its
                // spatial identity is then gone but its visual signature is
                // still the strongest evidence available. Preserve identity
                // only for a close size/salience/contrast match; weaker shapes
                // still require ordinary overlap, bounded motion, or a short
                // continuation of an already measured trajectory.
                guard overlap >= 0.05 || distance <= reach
                    || predictionConsistent || appearance >= 0.86 else { continue }
                let score = overlap * 4
                    + max(0, 1 - distance / reach)
                    + appearance * 1.5
                    + (predictionConsistent ? 2 : 0)
                    - min(0.5, distance / 1_000)
                if score > bestScore {
                    bestScore = score
                    bestIndex = index
                    bestPredictionConsistent = predictionConsistent
                    bestAppearanceOnly = overlap < 0.05 && distance > reach
                        && !predictionConsistent
                }
            }

            if let bestIndex {
                let previous = scene.tracks[bestIndex].frame
                let id = scene.tracks[bestIndex].id
                let elapsed = capturedAt.timeIntervalSince(scene.tracks[bestIndex].lastCapturedAt)
                let displacement = Self.centerDistance(frame, previous)
                let largestDimension = max(max(frame.w, frame.h), max(previous.w, previous.h))
                let boundedMotion = !bestAppearanceOnly
                    && elapsed >= 0.05
                    && elapsed <= 5
                    && (displacement <= max(220, largestDimension * 3)
                        || (bestPredictionConsistent
                            && displacement <= max(440, largestDimension * 6)))
                let velocityX = boundedMotion
                    ? ((frame.x + frame.w / 2) - (previous.x + previous.w / 2)) / elapsed
                    : 0
                let velocityY = boundedMotion
                    ? ((frame.y + frame.h / 2) - (previous.y + previous.h / 2)) / elapsed
                    : 0
                let uniqueColor = row.visualColor.map { colorCounts[$0] == 1 } ?? false
                let provisionalMotion = bestAppearanceOnly && uniqueColor
                    && elapsed >= 0.05 && elapsed <= 0.75
                    && displacement <= max(440, largestDimension * 6)
                scene.tracks[bestIndex].provisionalVelocityX = provisionalMotion
                    ? ((frame.x + frame.w / 2) - (previous.x + previous.w / 2)) / elapsed : 0
                scene.tracks[bestIndex].provisionalVelocityY = provisionalMotion
                    ? ((frame.y + frame.h / 2) - (previous.y + previous.h / 2)) / elapsed : 0
                // A slow target can remain on the same sampled pixel for one
                // frame. Do not let that quantization erase an established
                // trajectory used for next-frame association and brief
                // occlusion, but decay it quickly so a genuinely stopped
                // object becomes stationary. Motor lead below still uses only
                // this frame's observed displacement.
                let priorVelocityX = scene.tracks[bestIndex].velocityX
                let priorVelocityY = scene.tracks[bestIndex].velocityY
                let priorSpeed = hypot(priorVelocityX, priorVelocityY)
                let undersampledContinuity = scene.tracks[bestIndex].seenCount >= 2
                    && elapsed > 0
                    && elapsed < 0.05
                    && priorSpeed >= 3
                let retainedVelocityX = undersampledContinuity
                    ? priorVelocityX * 0.85
                    : boundedMotion && displacement < 3 && elapsed <= 0.5
                        ? priorVelocityX * 0.75
                        : velocityX
                let retainedVelocityY = undersampledContinuity
                    ? priorVelocityY * 0.85
                    : boundedMotion && displacement < 3 && elapsed <= 0.5
                        ? priorVelocityY * 0.75
                        : velocityY
                // Lead through the already-spent perception time plus a small
                // dispatch allowance. A first two-frame estimate gets a
                // conservative cap; an independently corroborated fast track
                // may lead up to one measured frame's travel, still bounded by
                // surface scale. A measured reversal gets no lead this
                // frame rather than projecting through its old direction.
                let horizon = min(0.75, max(0, now.timeIntervalSince(capturedAt)) + 0.05)
                let speed = hypot(velocityX, velocityY)
                let corroboratedVelocity = boundedMotion && elapsed <= 0.75
                    && priorSpeed >= 3 && speed >= priorSpeed * 0.65 && speed <= priorSpeed * 1.5
                    && (velocityX * priorVelocityX + velocityY * priorVelocityY) / (speed * priorSpeed) >= 0.9
                // Two positions describe a direction, not yet a stable
                // trajectory. When perception delay can carry the object past
                // its own radius, spend the existing third-frame opportunity
                // instead of ending acquisition on that first estimate.
                let needsMotionConfirmation = boundedMotion
                    && speed * horizon > max(4, min(frame.w, frame.h) / 2)
                    && !corroboratedVelocity
                let reversing = scene.tracks[bestIndex].seenCount >= 2
                    && priorSpeed >= 3
                    && velocityX * priorVelocityX + velocityY * priorVelocityY <= 0
                let rawX = displacement >= 3 && !reversing ? velocityX * horizon : 0
                let rawY = displacement >= 3 && !reversing ? velocityY * horizon : 0
                let rawDistance = hypot(rawX, rawY)
                let leadWidths = scene.tracks[bestIndex].seenCount >= 2 ? 2.0 : 0.75
                let ordinaryMaxLead = max(frame.w, frame.h) * leadWidths
                let corroboratedTravel = bestPredictionConsistent && boundedMotion
                    && elapsed <= 0.75 && !reversing
                    ? min(displacement, hypot(logicalSize.width, logicalSize.height) * 0.12)
                    : 0
                // Extra motor lead requires a corroborated trajectory;
                // an appearance jump alone grants no extra motor authority.
                let maxLead = max(ordinaryMaxLead, corroboratedTravel)
                let leadScale = rawDistance > maxLead && rawDistance > 0 ? maxLead / rawDistance : 1
                let motionDescription: String? = {
                    if boundedMotion {
                        if let observed = Self.motion(
                            from: previous,
                            to: frame,
                            elapsed: elapsed,
                            logicalSize: logicalSize
                        ) {
                            return observed
                        }
                        if scene.tracks[bestIndex].seenCount >= 2,
                           priorSpeed < 3,
                           displacement < 3 {
                            return "stationary"
                        }
                        return nil
                    }
                    if undersampledContinuity {
                        return Self.motion(
                            velocityX: priorVelocityX,
                            velocityY: priorVelocityY,
                            logicalSize: logicalSize
                        )
                    }
                    let continuityReach = max(48, largestDimension * 1.5)
                    return elapsed >= 0.05 && elapsed <= 5 && displacement > continuityReach
                        ? "repositioned" : nil
                }()
                scene.tracks[bestIndex].frame = frame
                scene.tracks[bestIndex].salience = row.salience
                scene.tracks[bestIndex].contrast = row.visualContrast ?? 0
                scene.tracks[bestIndex].colorName = row.visualColor
                scene.tracks[bestIndex].shapeName = row.visualShape
                scene.tracks[bestIndex].pointConfidence = Self.pointConfidence(row)
                scene.tracks[bestIndex].seenCount += 1
                scene.tracks[bestIndex].velocityX = retainedVelocityX
                scene.tracks[bestIndex].velocityY = retainedVelocityY
                scene.tracks[bestIndex].lastCapturedAt = capturedAt
                scene.tracks[bestIndex].lastSeenGeneration = scene.generation
                scene.tracks[bestIndex].lastSeenAt = now
                usedTrackIDs.insert(id)
                identities[row.rect] = VisionLiveRegionIdentity(
                    id: id,
                    motion: motionDescription,
                    projectedX: rawX * leadScale,
                    projectedY: rawY * leadScale,
                    needsMotionConfirmation: needsMotionConfirmation
                )
            } else {
                let id = scene.nextID
                scene.nextID += 1
                scene.tracks.append(Track(
                    id: id,
                    frame: frame,
                    salience: row.salience,
                    contrast: row.visualContrast ?? 0,
                    colorName: row.visualColor,
                    shapeName: row.visualShape,
                    pointConfidence: Self.pointConfidence(row),
                    seenCount: 1,
                    velocityX: 0,
                    velocityY: 0,
                    lastCapturedAt: capturedAt,
                    lastSeenGeneration: scene.generation,
                    lastSeenAt: now
                ))
                usedTrackIDs.insert(id)
                identities[row.rect] = VisionLiveRegionIdentity(id: id)
            }
        }

        let temporarilyNotVisible = scene.tracks.compactMap { track -> VisionLiveOccludedRegion? in
            let missed = scene.generation - track.lastSeenGeneration
            guard !usedTrackIDs.contains(track.id),
                  missed >= 1,
                  missed <= 2,
                  track.seenCount >= 2,
                  track.pointConfidence >= 0.25,
                  now.timeIntervalSince(track.lastSeenAt) <= 3,
                  logicalSize.width > 0,
                  logicalSize.height > 0 else { return nil }
            let centerX = (track.frame.x + track.frame.w / 2 - origin.x) / logicalSize.width
            let centerY = (track.frame.y + track.frame.h / 2 - origin.y) / logicalSize.height
            let predictionElapsed = capturedAt.timeIntervalSince(track.lastCapturedAt)
            let predicted: (x: Int, y: Int)? = {
                let speed = hypot(track.velocityX, track.velocityY)
                let travel = speed * predictionElapsed
                guard track.seenCount >= 2,
                      predictionElapsed >= 0.05,
                      predictionElapsed <= 1.5,
                      speed >= 3,
                      travel <= max(track.frame.w, track.frame.h) * 3 else { return nil }
                let predictedCenterX = track.frame.x + track.frame.w / 2
                    + track.velocityX * predictionElapsed
                let predictedCenterY = track.frame.y + track.frame.h / 2
                    + track.velocityY * predictionElapsed
                return (
                    min(100, max(0, Int((((predictedCenterX - origin.x) / logicalSize.width) * 100).rounded()))),
                    min(100, max(0, Int((((predictedCenterY - origin.y) / logicalSize.height) * 100).rounded())))
                )
            }()
            return VisionLiveOccludedRegion(
                id: track.id,
                colorName: track.colorName,
                shapeName: track.shapeName,
                lastCenterXPercent: min(100, max(0, Int((centerX * 100).rounded()))),
                lastCenterYPercent: min(100, max(0, Int((centerY * 100).rounded()))),
                expectedCenterXPercent: predicted?.x,
                expectedCenterYPercent: predicted?.y,
                missedFrames: missed,
                confidence: track.pointConfidence * (missed == 1 ? 0.8 : 0.6)
            )
        }.sorted { $0.id < $1.id }
        scene.tracks.removeAll {
            scene.generation - $0.lastSeenGeneration > 8
                || now.timeIntervalSince($0.lastSeenAt) > 20
        }
        scenes[key] = scene
        return VisionLiveSceneSnapshot(
            identities: identities,
            temporarilyNotVisible: Array(temporarilyNotVisible.prefix(4))
        )
    }

    private static func pointConfidence(_ row: VisionAffordanceRow) -> Double {
        min(row.confidence.bounds, max(row.salience, row.visualContrast ?? 0))
    }

    private static func centerDistance(_ lhs: MacAXFrame, _ rhs: MacAXFrame) -> Double {
        let dx = (lhs.x + lhs.w / 2) - (rhs.x + rhs.w / 2)
        let dy = (lhs.y + lhs.h / 2) - (rhs.y + rhs.h / 2)
        return hypot(dx, dy)
    }

    private static func appearanceSimilarity(
        row: VisionAffordanceRow,
        frame: MacAXFrame,
        track: Track
    ) -> Double {
        func ratio(_ lhs: Double, _ rhs: Double) -> Double {
            guard lhs > 0, rhs > 0 else { return 0 }
            return min(lhs, rhs) / max(lhs, rhs)
        }
        let size = (ratio(frame.w, track.frame.w) + ratio(frame.h, track.frame.h)) / 2
        let salience = 1 - min(1, abs(row.salience - track.salience) / 0.25)
        let contrast = 1 - min(1, abs((row.visualContrast ?? 0) - track.contrast) / 0.25)
        let color: Double
        switch (row.visualColor, track.colorName) {
        case let (current?, previous?): color = current == previous ? 1 : 0
        case (nil, nil): color = 0.5
        default: color = 0.25
        }
        return size * 0.45 + salience * 0.20 + contrast * 0.15 + color * 0.20
    }

    private static func intersectionOverUnion(_ lhs: MacAXFrame, _ rhs: MacAXFrame) -> Double {
        let left = max(lhs.x, rhs.x)
        let top = max(lhs.y, rhs.y)
        let right = min(lhs.x + lhs.w, rhs.x + rhs.w)
        let bottom = min(lhs.y + lhs.h, rhs.y + rhs.h)
        let intersection = max(0, right - left) * max(0, bottom - top)
        guard intersection > 0 else { return 0 }
        let union = lhs.w * lhs.h + rhs.w * rhs.h - intersection
        return union > 0 ? intersection / union : 0
    }

    private static func motion(
        from previous: MacAXFrame,
        to current: MacAXFrame,
        elapsed: TimeInterval,
        logicalSize: (width: Double, height: Double)
    ) -> String? {
        let dx = (current.x + current.w / 2) - (previous.x + previous.w / 2)
        let dy = (current.y + current.h / 2) - (previous.y + previous.h / 2)
        guard hypot(dx, dy) >= 3 else { return nil }
        let horizontal = dx > 2 ? "right" : dx < -2 ? "left" : nil
        let vertical = dy > 2 ? "down" : dy < -2 ? "up" : nil
        let direction = [vertical, horizontal].compactMap { $0 }.joined(separator: "-")
        let normalizedSpeed: Double = {
            guard elapsed > 0, logicalSize.width > 0, logicalSize.height > 0 else { return 0 }
            return hypot(dx / logicalSize.width, dy / logicalSize.height) / elapsed
        }()
        let pace = normalizedSpeed >= 0.20 ? " quickly"
            : normalizedSpeed < 0.04 ? " slowly" : ""
        return direction.isEmpty ? "moving\(pace)" : "moving \(direction)\(pace)"
    }

    private static func motion(
        velocityX: Double,
        velocityY: Double,
        logicalSize: (width: Double, height: Double)
    ) -> String? {
        guard hypot(velocityX, velocityY) >= 3 else { return nil }
        let horizontal = velocityX > 3 ? "right" : velocityX < -3 ? "left" : nil
        let vertical = velocityY > 3 ? "down" : velocityY < -3 ? "up" : nil
        let direction = [vertical, horizontal].compactMap { $0 }.joined(separator: "-")
        let normalizedSpeed: Double = {
            guard logicalSize.width > 0, logicalSize.height > 0 else { return 0 }
            return hypot(
                velocityX / logicalSize.width,
                velocityY / logicalSize.height
            )
        }()
        let pace = normalizedSpeed >= 0.20 ? " quickly"
            : normalizedSpeed < 0.04 ? " slowly" : ""
        return direction.isEmpty ? "moving\(pace)" : "moving \(direction)\(pace)"
    }
}
