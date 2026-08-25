import CoreGraphics
import Foundation
import ImageIO
import MacControl

/// Decode the screenshot bytes owned by the fused Mac view without teaching
/// ChatOrchestration about ImageIO.
public enum VisionImageDecoder {
    public static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

public struct VisionImageCrop {
    public let image: CGImage
    public let origin: (x: Double, y: Double)
    public let logicalSize: (width: Double, height: Double)
}

/// Focus the expensive pixel compiler on the visual surface AX located while
/// preserving the same global hand coordinate space. Saliency over an entire
/// browser window naturally prefers tabs and badges; saliency over the page's
/// canvas describes the world the agent is actually trying to manipulate.
public enum VisionImageCropper {
    public static func crop(
        _ image: CGImage,
        to globalFrame: MacAXFrame?,
        origin: (x: Double, y: Double),
        logicalSize: (width: Double, height: Double)
    ) -> VisionImageCrop {
        guard let globalFrame,
              logicalSize.width > 0,
              logicalSize.height > 0 else {
            return VisionImageCrop(image: image, origin: origin, logicalSize: logicalSize)
        }
        let scaleX = Double(image.width) / logicalSize.width
        let scaleY = Double(image.height) / logicalSize.height
        let requested = CGRect(
            x: (globalFrame.x - origin.x) * scaleX,
            y: (globalFrame.y - origin.y) * scaleY,
            width: globalFrame.w * scaleX,
            height: globalFrame.h * scaleY
        ).integral
        let available = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = requested.intersection(available)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1,
              let cropped = image.cropping(to: clipped) else {
            return VisionImageCrop(image: image, origin: origin, logicalSize: logicalSize)
        }
        let cropOrigin = (
            x: origin.x + clipped.minX / scaleX,
            y: origin.y + clipped.minY / scaleY
        )
        let cropSize = (
            width: clipped.width / scaleX,
            height: clipped.height / scaleY
        )
        return VisionImageCrop(image: cropped, origin: cropOrigin, logicalSize: cropSize)
    }
}

/// The persistent identity and temporal state assigned by the live semantic
/// screen. It is additive evidence: the vision compiler still owns what a
/// region is, while the live scene owns whether this is the same region seen
/// on the prior observation and how it moved.
public struct VisionLiveRegionIdentity: Sendable, Equatable {
    public let id: Int
    public let motion: String?

    public init(id: Int, motion: String? = nil) {
        self.id = id
        self.motion = motion
    }
}

extension VisionPercept {
    /// Translate pixel evidence into the same additive screen/target contract
    /// the AX lane uses. Confidence is not decoration: uncertain, overlapping,
    /// or destructive-looking rows remain visible with an abstain reason but
    /// do not become act targets.
    public func fourVerbSupplement(
        origin: (x: Double, y: Double),
        logicalSize: (width: Double, height: Double),
        viewId: String? = nil,
        globalRegionOfInterest: MacAXFrame? = nil,
        liveRegionIdentities: [VisionRect: VisionLiveRegionIdentity] = [:]
    ) -> MacFourVerbsSupplement {
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
        func screenText(_ label: VisionRedactedText?) -> MacScreenText? {
            guard let label else { return nil }
            return MacScreenText(label.raw, redacted: label.json)
        }
        func abstainReason(_ row: VisionAffordanceRow) -> String? {
            if let ambiguous = row.ambiguous { return ambiguous }
            if row.destructiveRisk { return "destructive-looking pixel target needs semantic confirmation" }
            if row.confidence.bounds < 0.55 { return "bounds confidence below physical-action floor" }
            if row.confidence.target < 0.55 { return "target confidence below physical-action floor" }
            return nil
        }

        var contentRows: [MacScreenRender.Row] = []
        var controls: [MacScreenRender.Control] = []
        var targets: [MacFourVerbsSupplementalTarget] = []
        var rowOrdinal = 0
        var unnamedOrdinalByKind: [String: Int] = [:]
        var visualRegionOrdinal = 0
        func insideRegionOfInterest(_ rect: VisionRect) -> Bool {
            guard let globalRegionOfInterest else { return true }
            let translated = global(rect)
            let centerX = translated.x + translated.w / 2
            let centerY = translated.y + translated.h / 2
            return centerX >= globalRegionOfInterest.x
                && centerX <= globalRegionOfInterest.x + globalRegionOfInterest.w
                && centerY >= globalRegionOfInterest.y
                && centerY <= globalRegionOfInterest.y + globalRegionOfInterest.h
        }
        let perceivedRows = rows.filter { insideRegionOfInterest($0.rect) }

        // A pixel compiler can find dozens of decorative fragments. Publish a
        // small ranked physical vocabulary, not a wall of coordinate aliases.
        let spatialIndexes = Set(perceivedRows.enumerated()
            .filter { Self.isPhysicalRegionCandidate($0.element) }
            .sorted { lhs, rhs in
                let left = lhs.element.salience * 3
                    + (lhs.element.visualContrast ?? 0) * 2
                    + min(1, lhs.element.rect.area / max(1, frameSize.width * frameSize.height) * 20)
                let right = rhs.element.salience * 3
                    + (rhs.element.visualContrast ?? 0) * 2
                    + min(1, rhs.element.rect.area / max(1, frameSize.width * frameSize.height) * 20)
                return left == right ? lhs.offset < rhs.offset : left > right
            }
            .prefix(8)
            .map(\.offset))

        for (rowIndex, row) in perceivedRows.enumerated() {
            let kind = MacScreenRender.kindName(role: row.roleGuess)
            let labelText = screenText(row.label)
            let reason = abstainReason(row)
            // Saliency can pin a bounded, prominent place while honestly
            // knowing nothing about its semantic role. Publish that place as
            // a numbered physical region, never as an invented button.
            let spatiallyAddressable = reason != nil && spatialIndexes.contains(rowIndex)
            let spatialLabel: MacScreenText? = {
                guard spatiallyAddressable else { return nil }
                let identity = liveRegionIdentities[row.rect]
                let number: Int
                if let identity {
                    number = identity.id
                } else {
                    visualRegionOrdinal += 1
                    number = visualRegionOrdinal
                }
                let label = "visual region \(number)"
                return MacScreenText(label, redacted: .string(label))
            }()
            let renderedLabel = labelText ?? spatialLabel
            let spatialDescription: MacScreenText? = {
                guard spatiallyAddressable else { return nil }
                let horizontal = row.rect.centerX < frameSize.width / 3 ? "left"
                    : row.rect.centerX > frameSize.width * 2 / 3 ? "right" : "center"
                let vertical = row.rect.centerY < frameSize.height / 3 ? "upper"
                    : row.rect.centerY > frameSize.height * 2 / 3 ? "lower" : "middle"
                let prominence = (row.visualContrast ?? 0) >= 0.45 ? "high contrast" : "visually prominent"
                let motion = liveRegionIdentities[row.rect]?.motion.map { ", \($0)" } ?? ""
                let text = "\(prominence), \(vertical) \(horizontal)\(motion)"
                return MacScreenText(text, redacted: .string(text))
            }()
            // A spatial fallback is a region even when the role guess says
            // checkbox/button. Rendering that uncertain guess as a control
            // both invents semantics and pushes the region behind rich AX
            // chrome under the control cap.
            let isControl = !spatiallyAddressable
                && MacPerceptionCompiler.controlRoles.contains(row.roleGuess)
            if isControl {
                controls.append(MacScreenRender.Control(
                    label: renderedLabel ?? MacScreenText("unnamed \(kind)", redacted: .string("unnamed \(kind)")),
                    kind: kind,
                    states: reason == nil ? [] : (spatiallyAddressable ? ["spatial", "role uncertain"] : ["uncertain"]),
                    provenance: .vision(row.confidence.target),
                    abstain: spatiallyAddressable ? nil : reason
                ))
            } else {
                rowOrdinal += 1
                contentRows.append(MacScreenRender.Row(
                    label: renderedLabel,
                    detail: [MacScreenText(kind, redacted: .string(kind))]
                        + (spatialDescription.map { [$0] } ?? []),
                    provenance: .vision(row.confidence.target),
                    abstain: spatiallyAddressable ? "physical region; semantic role uncertain" : reason
                ))
            }

            guard reason == nil || spatiallyAddressable else { continue }
            let ordinal: Int? = isControl ? nil : rowOrdinal
            let targetLabel: MacScreenText = {
                if let renderedLabel { return renderedLabel }
                let number = (unnamedOrdinalByKind[kind] ?? 0) + 1
                unnamedOrdinalByKind[kind] = number
                let synthetic = "visual \(kind) \(number)"
                return MacScreenText(synthetic, redacted: .string(synthetic))
            }()
            targets.append(MacFourVerbsSupplementalTarget(
                label: targetLabel,
                kind: spatiallyAddressable ? "visual region" : kind,
                frame: global(row.rect),
                provenance: .vision(row.confidence.target),
                viewId: viewId,
                ordinal: ordinal,
                physicalOnly: spatiallyAddressable
            ))
        }

        var contents: [MacScreenRender.Content] = []
        if !contentRows.isEmpty {
            contents.append(MacScreenRender.Content(
                kind: .grid,
                rows: contentRows,
                totalRows: contentRows.count + abstain.droppedBeyondCap,
                scrollable: true
            ))
        }
        // The captured image's own extent is exact even when OCR finds no
        // rows—the common canvas/game/video case. Row confidence describes
        // objects inside it, not whether the visual surface itself exists.
        let canvasConfidence = 1.0
        let fullCanvasRect = VisionRect(x: 0, y: 0, w: frameSize.width, h: frameSize.height)
        let canvasFrame = globalRegionOfInterest ?? global(fullCanvasRect)
        contents.append(MacScreenRender.Content(
            kind: .canvas,
            canvas: MacScreenRender.Canvas(
                description: "visual surface",
                width: canvasFrame.w,
                height: canvasFrame.h,
                provenance: .vision(canvasConfidence)
            )
        ))
        if canvasConfidence >= 0.55, canvasFrame.w > 0, canvasFrame.h > 0 {
            targets.append(MacFourVerbsSupplementalTarget(
                label: MacScreenText("visual surface", redacted: .string("visual surface")),
                kind: "canvas",
                frame: canvasFrame,
                provenance: .vision(canvasConfidence),
                viewId: viewId,
                regionOnly: true
            ))
        }

        var values = readouts.filter { insideRegionOfInterest($0.rect) }.map {
            MacScreenRender.Value(
                text: MacScreenText($0.text.raw, redacted: $0.text.json),
                provenance: .vision($0.confidence.text)
            )
        }
        // The affordance compiler intentionally promotes only one contained
        // string to a row label and reserves standalone readouts for prominent
        // text. A canvas HUD needs neither filter: every recognized, already-
        // redacted string is something the screen SAYS. Publish the bounded
        // set here so counters such as Hits/Misses cannot disappear merely
        // because a larger title shares their text band.
        var valueKeys = Set(values.compactMap { $0.text.display?.lowercased() })
        for recognized in recognizedText {
            guard values.count < 16,
                  let label = screenText(recognized.text),
                  let display = label.display else { continue }
            let key = display.lowercased()
            guard !valueKeys.contains(key) else { continue }
            valueKeys.insert(key)
            values.append(MacScreenRender.Value(
                text: label,
                provenance: .vision(recognized.confidence)
            ))
        }
        return MacFourVerbsSupplement(
            contents: contents,
            controls: controls,
            values: values,
            targets: targets
        )
    }

    /// One shared physical-region admission rule for both the live tracker and
    /// the screen adapter. Tracking a decorative fragment the adapter will
    /// never publish would consume stable ids and make the agent's screen feel
    /// discontinuous even though the same compiler produced both views.
    public static func isPhysicalRegionCandidate(_ row: VisionAffordanceRow) -> Bool {
        let roleUnknown = row.ambiguous == nil
            || row.ambiguous?.contains("unlabeled region with no role guess") == true
        guard row.displayLabel == nil, roleUnknown, !row.destructiveRisk else { return false }
        let salient = row.evidence.contains(.saliency)
            && row.confidence.bounds >= 0.30
            && row.salience >= 0.45
        let boundedColor = row.evidence.contains(.colorRegion)
            && row.confidence.bounds >= 0.82
            && (row.visualContrast ?? 0) >= 0.25
        return salient || boundedColor
    }
}
