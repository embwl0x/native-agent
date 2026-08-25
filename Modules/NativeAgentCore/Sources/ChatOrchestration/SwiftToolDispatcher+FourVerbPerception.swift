import Foundation
import MacControl
import NativeAgentCore
import PersistenceCore
import VisionPerception

/// The app-assembly bridge between MacControl's live fused capture and the pure
/// VisionPerception compiler. MacControl stays independent of VisionPerception;
/// the four-verb surface receives one additive, source-neutral supplement.
struct SwiftToolDispatcherFourVerbPerceptionSource: MacFourVerbsSupplementalPerceptionSource {
    let host: any MacFourVerbsHost
    let liveScene: SwiftToolDispatcherFourVerbLiveScene

    init(
        host: any MacFourVerbsHost,
        liveScene: SwiftToolDispatcherFourVerbLiveScene = SwiftToolDispatcherFourVerbLiveScene()
    ) {
        self.host = host
        self.liveScene = liveScene
    }

    func observe() async -> MacFourVerbsSupplement? {
        let result: MacControlResult
        do {
            result = try await host.dispatch(action: "view", body: [
                "max_marks": .int(80),
                "max_text_items": .int(160),
                "semantic_raw_frame": .bool(true),
                "semantic_focus_visual_surface": .bool(true),
            ])
        } catch {
            return nil
        }
        guard result.ok, case .object(let output) = result.output else { return nil }

        let viewId = string(output["view"])
        let marks = array(output["marks"])
        let app = object(output["app"])
        let appName = string(app["name"])
        let bundleIdentifier = string(app["bundle_id"])
        let originObject = object(output["origin"])
        let logicalObject = object(output["logical_size"])
        let imageOriginObject = object(output["image_origin"])
        let imageLogicalObject = object(output["image_logical_size"])
        let visibleFrame: MacAXFrame? = {
            guard let x = number(originObject["x"]), let y = number(originObject["y"]),
                  let w = number(logicalObject["w"]), let h = number(logicalObject["h"]),
                  w > 0, h > 0 else { return nil }
            return MacAXFrame(x: x, y: y, w: w, h: h)
        }()
        let structural = structuralSupplement(
            marks: marks,
            viewId: viewId,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            visibleFrame: visibleFrame
        )

        // Pixel perception is the fallback for AX-sparse surfaces. Running OCR
        // over every richly semantic window would add latency and duplicate
        // evidence. Browser chrome can be richly semantic while the dominant
        // page body is one AXImage, so global mark count alone is not enough to
        // classify a canvas/game/custom renderer.
        let accessibilityTrusted = bool(output["accessibility_trusted"]) ?? false
        let dominantImageFrame: MacAXFrame? = frame(output["semantic_focus_frame"])
            ?? marks.compactMap { value in
                let mark = object(value)
                guard let role = string(mark["role"]),
                      role == "AXImage" || role == "AXCanvas" else { return nil }
                return frame(mark["frame"])
            }.max { lhs, rhs in lhs.w * lhs.h < rhs.w * rhs.h }
        let dominantImageFraction: Double? = {
            guard let visibleFrame, let dominantImageFrame else { return nil }
            let visibleArea = visibleFrame.w * visibleFrame.h
            guard visibleArea > 0 else { return nil }
            return min(1, (dominantImageFrame.w * dominantImageFrame.h) / visibleArea)
        }()
        guard Self.shouldCompilePixelPerception(
            accessibilityTrusted: accessibilityTrusted,
            markCount: marks.count,
            dominantImageFraction: dominantImageFraction
        ),
              let encoded = string(output["image"]),
              let data = Data(base64Encoded: encoded),
              let image = VisionImageDecoder.decode(data),
              let originX = number(imageOriginObject["x"] ?? originObject["x"]),
              let originY = number(imageOriginObject["y"] ?? originObject["y"]),
              let logicalW = number(imageLogicalObject["w"] ?? logicalObject["w"]),
              let logicalH = number(imageLogicalObject["h"] ?? logicalObject["h"]),
              logicalW > 0, logicalH > 0 else {
            return structural
        }

        #if canImport(Vision)
        do {
            let appName = string(object(output["app"])["name"])
            let title = displayText(output["window_title"])
            let crop = VisionImageCropper.crop(
                image,
                to: dominantImageFrame,
                origin: (originX, originY),
                logicalSize: (logicalW, logicalH)
            )
            let percept = try VisionPerceptionCompiler(
                config: VisionPerceptionConfig(
                    text: VisionTextLayerConfig(sparseRecoveryMaxBoxes: 3)
                ),
                salience: VisionKitSalienceProvider()
            ).compile(
                image: crop.image,
                using: VisionKitTextRecognizer(),
                appName: appName,
                windowTitle: title
            )
            let sceneKey = [bundleIdentifier, appName, title]
                .compactMap { $0 }
                .joined(separator: "|")
            let identities = await liveScene.identify(
                rows: percept.rows,
                frameSize: percept.frameSize,
                origin: crop.origin,
                logicalSize: crop.logicalSize,
                sceneKey: sceneKey
            )
            let vision = percept.fourVerbSupplement(
                origin: crop.origin,
                logicalSize: crop.logicalSize,
                viewId: viewId,
                liveRegionIdentities: identities
            )
            return MacFourVerbsSupplement(
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                visibleFrame: visibleFrame,
                contents: structural.contents + vision.contents,
                controls: structural.controls + vision.controls,
                values: structural.values + vision.values,
                targets: structural.targets + vision.targets,
                diagnostics: [
                    "vision_recognized_strings": .int(Int64(percept.recognizedStrings)),
                    "vision_text_tiled": .bool(percept.textTiled),
                    "vision_text_tiling_reason": .string(percept.textTilingReason),
                    "vision_frame_pixels": .object([
                        "w": .double(percept.frameSize.width),
                        "h": .double(percept.frameSize.height),
                    ]),
                    "vision_value_text": .array(vision.values.compactMap { value in
                        value.text.display.map { .string($0) }
                    }),
                    "capture_image_downscale": output["image_downscale"] ?? .null,
                    "capture_image_pixels": output["image_pixel_size"] ?? .null,
                ]
            )
        } catch {
            return structural
        }
        #else
        return structural
        #endif
    }

    static func shouldCompilePixelPerception(
        accessibilityTrusted: Bool,
        markCount: Int,
        dominantImageFraction: Double?
    ) -> Bool {
        !accessibilityTrusted
            || markCount <= 6
            || (dominantImageFraction ?? 0) >= 0.03
    }

    private func structuralSupplement(
        marks: [JSONValue],
        viewId: String?,
        appName: String?,
        bundleIdentifier: String?,
        visibleFrame: MacAXFrame?
    ) -> MacFourVerbsSupplement {
        let rowRoles: Set<String> = ["AXRow", "AXCell", "AXOutlineRow", "AXListItem"]
        var rows: [MacScreenRender.Row] = []
        var controls: [MacScreenRender.Control] = []
        var targets: [MacFourVerbsSupplementalTarget] = []
        var unnamedByKind: [String: Int] = [:]

        for markValue in marks {
            let mark = object(markValue)
            guard let role = string(mark["role"]),
                  let frame = frame(mark["frame"]),
                  let number = integer(mark["mark"]) else { continue }
            let kind = MacScreenRender.kindName(role: role)
            let published = screenText(mark["label"])
            let label: MacScreenText = {
                if let published { return published }
                let ordinal = (unnamedByKind[kind] ?? 0) + 1
                unnamedByKind[kind] = ordinal
                let synthetic = "\(kind) \(ordinal)"
                return MacScreenText(synthetic, redacted: .string(synthetic))
            }()
            let enabled = bool(mark["enabled"]) ?? true
            let isRow = rowRoles.contains(role)
            if isRow {
                rows.append(MacScreenRender.Row(
                    label: label,
                    detail: [MacScreenText(kind, redacted: .string(kind))],
                    provenance: .ax
                ))
            } else {
                controls.append(MacScreenRender.Control(
                    label: label,
                    kind: kind,
                    states: enabled ? (published == nil ? ["unnamed"] : []) : ["disabled"],
                    provenance: .ax
                ))
            }
            guard enabled else { continue }
            targets.append(MacFourVerbsSupplementalTarget(
                label: label,
                kind: kind,
                frame: frame,
                provenance: .ax,
                viewId: viewId,
                mark: Int(number),
                ordinal: isRow ? rows.count : nil
            ))
        }

        let contents = rows.isEmpty ? [] : [MacScreenRender.Content(
            kind: .list,
            rows: rows,
            totalRows: rows.count,
            scrollable: true
        )]
        return MacFourVerbsSupplement(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            visibleFrame: visibleFrame,
            contents: contents,
            controls: controls,
            targets: targets
        )
    }

    private func object(_ value: JSONValue?) -> [String: JSONValue] {
        guard case .object(let object)? = value else { return [:] }
        return object
    }

    private func array(_ value: JSONValue?) -> [JSONValue] {
        guard case .array(let values)? = value else { return [] }
        return values
    }

    private func string(_ value: JSONValue?) -> String? {
        guard case .string(let value)? = value else { return nil }
        return value
    }

    private func bool(_ value: JSONValue?) -> Bool? {
        guard case .bool(let value)? = value else { return nil }
        return value
    }

    private func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .int(let value)?: return Double(value)
        case .double(let value)? where value.isFinite: return value
        default: return nil
        }
    }

    private func integer(_ value: JSONValue?) -> Int64? {
        switch value {
        case .int(let value)?: return value
        case .double(let value)? where value.isFinite && value == value.rounded(): return Int64(value)
        default: return nil
        }
    }

    private func frame(_ value: JSONValue?) -> MacAXFrame? {
        let object = object(value)
        guard let x = number(object["x"]), let y = number(object["y"]),
              let w = number(object["w"]), let h = number(object["h"]),
              w > 0, h > 0 else { return nil }
        return MacAXFrame(x: x, y: y, w: w, h: h)
    }

    private func displayText(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }

    private func screenText(_ value: JSONValue?) -> MacScreenText? {
        switch value {
        case .string(let clear)?: return MacScreenText(clear, redacted: .string(clear))
        case .object?: return MacScreenText("⟨withheld⟩", redacted: value)
        default: return nil
        }
    }
}

/// One dispatcher-owned temporal scene. It is deliberately in-memory and
/// rebuildable: stable target identity is perception continuity, not canonical
/// memory or authority. The same tracker instance is shared by every four-verb
/// observation from one chat dispatcher, while app/window keys keep unrelated
/// screens from borrowing identities.
actor SwiftToolDispatcherFourVerbLiveScene {
    private struct Track {
        let id: Int
        var frame: MacAXFrame
        var salience: Double
        var contrast: Double
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
        origin: (x: Double, y: Double),
        logicalSize: (width: Double, height: Double),
        sceneKey: String,
        now: Date = Date()
    ) -> [VisionRect: VisionLiveRegionIdentity] {
        let scaleX = frameSize.width > 0 ? logicalSize.width / frameSize.width : 1
        let scaleY = frameSize.height > 0 ? logicalSize.height / frameSize.height : 1
        func global(_ rect: VisionRect) -> MacAXFrame {
            MacAXFrame(
                x: origin.x + rect.x * scaleX,
                y: origin.y + rect.y * scaleY,
                w: rect.w * scaleX,
                h: rect.h * scaleY
            )
        }

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
        let candidates = rows
            .filter(VisionPercept.isPhysicalRegionCandidate)
            .sorted { lhs, rhs in
                let left = lhs.salience + (lhs.visualContrast ?? 0)
                let right = rhs.salience + (rhs.visualContrast ?? 0)
                return left == right ? lhs.rect.area > rhs.rect.area : left > right
            }

        for row in candidates {
            let frame = global(row.rect)
            var bestIndex: Int?
            var bestScore = -Double.infinity
            for index in scene.tracks.indices {
                let track = scene.tracks[index]
                guard !usedTrackIDs.contains(track.id),
                      scene.generation - track.lastSeenGeneration <= 6 else { continue }
                let distance = Self.centerDistance(frame, track.frame)
                let largestDimension = max(max(frame.w, frame.h), max(track.frame.w, track.frame.h))
                let reach = max(48, min(220, largestDimension * 1.5))
                let overlap = Self.intersectionOverUnion(frame, track.frame)
                let appearance = Self.appearanceSimilarity(row: row, frame: frame, track: track)
                // A successful click may make one game object teleport. Its
                // spatial identity is then gone but its visual signature is
                // still the strongest evidence available. Preserve identity
                // only for a close size/salience/contrast match; weaker shapes
                // still require ordinary overlap or bounded motion.
                guard overlap >= 0.05 || distance <= reach || appearance >= 0.86 else { continue }
                let score = overlap * 4
                    + max(0, 1 - distance / reach)
                    + appearance * 1.5
                    - min(0.5, distance / 1_000)
                if score > bestScore {
                    bestScore = score
                    bestIndex = index
                }
            }

            if let bestIndex {
                let previous = scene.tracks[bestIndex].frame
                let id = scene.tracks[bestIndex].id
                scene.tracks[bestIndex].frame = frame
                scene.tracks[bestIndex].salience = row.salience
                scene.tracks[bestIndex].contrast = row.visualContrast ?? 0
                scene.tracks[bestIndex].lastSeenGeneration = scene.generation
                scene.tracks[bestIndex].lastSeenAt = now
                usedTrackIDs.insert(id)
                identities[row.rect] = VisionLiveRegionIdentity(
                    id: id,
                    motion: Self.motion(from: previous, to: frame)
                )
            } else {
                let id = scene.nextID
                scene.nextID += 1
                scene.tracks.append(Track(
                    id: id,
                    frame: frame,
                    salience: row.salience,
                    contrast: row.visualContrast ?? 0,
                    lastSeenGeneration: scene.generation,
                    lastSeenAt: now
                ))
                usedTrackIDs.insert(id)
                identities[row.rect] = VisionLiveRegionIdentity(id: id)
            }
        }

        scene.tracks.removeAll {
            scene.generation - $0.lastSeenGeneration > 8
                || now.timeIntervalSince($0.lastSeenAt) > 20
        }
        scenes[key] = scene
        return identities
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
        return size * 0.55 + salience * 0.25 + contrast * 0.20
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

    private static func motion(from previous: MacAXFrame, to current: MacAXFrame) -> String? {
        let dx = (current.x + current.w / 2) - (previous.x + previous.w / 2)
        let dy = (current.y + current.h / 2) - (previous.y + previous.h / 2)
        guard hypot(dx, dy) >= 3 else { return nil }
        let horizontal = dx > 2 ? "right" : dx < -2 ? "left" : nil
        let vertical = dy > 2 ? "down" : dy < -2 ? "up" : nil
        let direction = [vertical, horizontal].compactMap { $0 }.joined(separator: "-")
        return direction.isEmpty ? "moving" : "moving \(direction)"
    }
}
