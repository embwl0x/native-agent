import Foundation
// Blueprint: | `VisionFourVerbAdapter.swift` | `VisionPercept.fourVerbSupplement`: additive screen contents, controls, values and physical targets with provenance and abstention |

extension VisionPercept {
    /// Uncertain, overlapping or destructive-looking evidence stays visible
    /// with an abstain reason and cannot become an act target.
    public func fourVerbSupplement(
        geometry: MacScreenViewGeometry,
        viewId: String? = nil,
        globalRegionOfInterest: MacAXFrame? = nil,
        liveRegionIdentities: [VisionRect: VisionLiveRegionIdentity] = [:],
        liveOccludedRegions: [VisionLiveOccludedRegion] = []
    ) -> MacFourVerbsSupplement {
        let origin = (x: geometry.bounds.x, y: geometry.bounds.y)
        let logicalSize = (width: geometry.bounds.w, height: geometry.bounds.h)
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
        var summarizedFragments: [String: Int] = [:]
        var summarizedFragmentConfidence = 0.0
        func insideRegionOfInterest(_ rect: VisionRect) -> Bool {
            guard let globalRegionOfInterest else { return true }
            let translated = geometry.screenRect(rect)
            let centerX = translated.x + translated.w / 2
            let centerY = translated.y + translated.h / 2
            return centerX >= globalRegionOfInterest.x
                && centerX <= globalRegionOfInterest.x + globalRegionOfInterest.w
                && centerY >= globalRegionOfInterest.y
                && centerY <= globalRegionOfInterest.y + globalRegionOfInterest.h
        }
        let perceivedRows = rows.filter { insideRegionOfInterest($0.rect) }
        let physicalRows = Self.physicalRowSelection(in: perceivedRows, frameSize: frameSize)
        let indicatorRender = Self.linearIndicatorValues(
            in: perceivedRows,
            indexes: physicalRows.indicators,
            frameSize: frameSize,
            readouts: readouts,
            recognizedText: recognizedText
        )

        // A pixel compiler can find dozens of decorative fragments. Publish a
        // small ranked physical vocabulary, not a wall of coordinate aliases.
        let spatialIndexes = Set(physicalRows.eligible
            .map { (offset: $0, element: perceivedRows[$0]) }
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
            if physicalRows.redundant.contains(rowIndex) { continue }
            if physicalRows.indicators.contains(rowIndex) {
                continue
            }
            let kind = MacScreenRender.kindName(role: row.roleGuess)
            // OCR occasionally binds a lone list/detection marker to an
            // otherwise uncertain visual fragment. The same glyph is already
            // rejected from readouts and recognized-text values; do not let a
            // row-label path resurrect it as an apparent object.
            let labelText: MacScreenText? = {
                guard let label = screenText(row.label) else { return nil }
                guard let display = label.display,
                      !Self.isStandaloneOCRNoise(display) else { return nil }
                return label
            }()
            let reason = abstainReason(row)
            let states = [
                ("selected", "not selected", row.state.selected),
                ("checked", "not checked", row.state.checked),
                ("disabled", "enabled", row.state.disabled),
            ].compactMap { positive, negative, flag -> String? in
                guard let flag else { return nil }
                return "\(flag.value ? positive : negative) guess \(Int((flag.confidence * 100).rounded()))%"
            }
            // Saliency can pin a bounded, prominent place while honestly
            // knowing nothing about its semantic role. Publish that place as
            // a numbered physical region, never as an invented button.
            let spatiallyAddressable = reason != nil && spatialIndexes.contains(rowIndex)
            let renderedConfidence = spatiallyAddressable
                ? Self.physicalPointConfidence(row)
                : row.confidence.target
            // A substantial muted region can be valuable scene/tracking
            // evidence before it is reliable enough to aim at. Keep the
            // numbered object visible, but require the same confidence floor
            // used by short occlusion memory before publishing a motor target.
            let motorAddressable = spatiallyAddressable && renderedConfidence >= 0.25
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
            let spatialDescription: [MacScreenText] = {
                guard spatiallyAddressable else { return [] }
                let horizontal = row.rect.centerX < frameSize.width / 3 ? "left"
                    : row.rect.centerX > frameSize.width * 2 / 3 ? "right" : "center"
                let vertical = row.rect.centerY < frameSize.height / 3 ? "upper"
                    : row.rect.centerY > frameSize.height * 2 / 3 ? "lower" : "middle"
                let contrast = row.visualContrast ?? 0
                let prominence = contrast >= 0.45 ? "high contrast"
                    : contrast >= 0.25 ? "visible contrast" : "low contrast"
                let motion = liveRegionIdentities[row.rect]?.motion
                let color = row.visualColor.map { "\($0), " } ?? ""
                func percent(_ value: Double, of total: Double) -> Int {
                    guard total > 0 else { return 0 }
                    return min(100, max(0, Int((value / total * 100).rounded())))
                }
                let centerX = percent(row.rect.centerX, of: frameSize.width)
                let centerY = percent(row.rect.centerY, of: frameSize.height)
                let width = max(1, percent(row.rect.w, of: frameSize.width))
                let height = max(1, percent(row.rect.h, of: frameSize.height))
                let geometry = "at \(centerX)%,\(centerY)%, size \(width)%x\(height)%"
                // Separate slots keep geometry and motion within the 40-character cap.
                let facts = ["\(color)\(prominence)", "\(vertical) \(horizontal)", geometry]
                    + (motion.map { [$0] } ?? [])
                return facts.map { MacScreenText($0, redacted: .string($0)) }
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
                    states: states + (reason == nil ? [] : ["uncertain"]),
                    provenance: .vision(renderedConfidence),
                    abstain: spatiallyAddressable ? nil : reason
                ))
            } else {
                if renderedLabel == nil, !spatiallyAddressable, let reason {
                    let category: String
                    if reason.contains("overlapping") { category = "overlapping" }
                    else if reason.contains("bounds confidence") { category = "low bounds confidence" }
                    else if reason.contains("target confidence") { category = "low target confidence" }
                    else if reason.contains("unlabeled") { category = "unlabeled" }
                    else { category = "other uncertainty" }
                    summarizedFragments[category, default: 0] += 1
                    summarizedFragmentConfidence = max(summarizedFragmentConfidence, row.confidence.target)
                    continue
                }
                rowOrdinal += 1
                let aspect = row.rect.h > 0 ? row.rect.w / row.rect.h : 1
                let physicalShape = row.visualShape ?? (aspect <= 0.70 ? "tall"
                    : aspect >= 1.45 ? "wide" : "compact")
                let physicalKind = spatiallyAddressable
                    ? "\(physicalShape) physical object" : kind
                contentRows.append(MacScreenRender.Row(
                    label: renderedLabel,
                    detail: [MacScreenText(physicalKind, redacted: .string(physicalKind))]
                        + spatialDescription
                        + states.map { MacScreenText($0, redacted: .string($0)) },
                    provenance: .vision(renderedConfidence),
                    abstain: motorAddressable ? nil : (spatiallyAddressable
                        ? "physical point confidence too low; observe again" : reason),
                    physicalOnly: motorAddressable
                ))
            }

            guard reason == nil || motorAddressable else { continue }
            let ordinal: Int? = isControl ? nil : rowOrdinal
            let targetLabel: MacScreenText = {
                if let renderedLabel { return renderedLabel }
                let number = (unnamedOrdinalByKind[kind] ?? 0) + 1
                unnamedOrdinalByKind[kind] = number
                let synthetic = "visual \(kind) \(number)"
                return MacScreenText(synthetic, redacted: .string(synthetic))
            }()
            let appearanceAliases: [String] = {
                guard spatiallyAddressable else { return [] }
                var aliases: [String]
                switch (row.visualShape, row.visualColor) {
                case let (shape?, color?):
                    aliases = [
                        "\(shape) \(color) object",
                        "\(color) \(shape) object",
                        "\(color) object",
                    ]
                case let (nil, color?):
                    aliases = ["\(color) object"]
                case let (shape?, nil):
                    aliases = ["\(shape) object"]
                case (nil, nil):
                    aliases = []
                }
                let base = aliases.last
                // Measured silhouettes accept ordinary shape nouns; unknown shapes get none.
                let naturalBases = Self.naturalShapeNames(row)
                aliases.append(contentsOf: naturalBases)
                let horizontal = row.rect.centerX < frameSize.width / 3 ? "left"
                    : row.rect.centerX > frameSize.width * 2 / 3 ? "right" : "center"
                let vertical = row.rect.centerY < frameSize.height / 3 ? "upper"
                    : row.rect.centerY > frameSize.height * 2 / 3 ? "lower" : "middle"
                for spatialBase in [base].compactMap({ $0 }) + naturalBases {
                    aliases.append("\(horizontal) \(spatialBase)")
                    aliases.append("\(vertical) \(spatialBase)")
                    aliases.append("\(spatialBase) at \(vertical) \(horizontal)")
                    if horizontal != "center" {
                        aliases.append("\(spatialBase) on the \(horizontal)")
                    }
                }
                let temporalBases = Array(Set([base, aliases.first].compactMap { $0 } + naturalBases)).sorted()
                if let motion = liveRegionIdentities[row.rect]?.motion,
                   motion.hasPrefix("moving ") {
                    aliases.append("moving object")
                    if let shape = row.visualShape {
                        aliases.append("moving \(shape) object")
                    }
                    for temporalBase in temporalBases {
                        aliases.append("moving \(temporalBase)")
                        aliases.append("\(motion) \(temporalBase)")
                        aliases.append("\(temporalBase) \(motion)")
                    }
                } else if liveRegionIdentities[row.rect]?.motion == "stationary" {
                    aliases.append("stationary object")
                    if let shape = row.visualShape {
                        aliases.append("stationary \(shape) object")
                    }
                    for temporalBase in temporalBases {
                        aliases.append("stationary \(temporalBase)")
                        aliases.append("\(temporalBase) stationary")
                    }
                }
                let nearest = spatialIndexes
                    .filter { $0 != rowIndex && liveRegionIdentities[perceivedRows[$0].rect] != nil }
                    .compactMap { index -> (row: VisionAffordanceRow, distance: Double)? in
                        let other = perceivedRows[index]
                        guard other.visualColor != nil || other.visualShape != nil else { return nil }
                        let dx = (other.rect.centerX - row.rect.centerX) / max(1, frameSize.width)
                        let dy = (other.rect.centerY - row.rect.centerY) / max(1, frameSize.height)
                        return (other, hypot(dx, dy))
                    }
                    .min { $0.distance < $1.distance }?.row
                if let base, let nearest {
                    let direction = Self.spatialDirection(from: row.rect, to: nearest.rect, frameSize: frameSize)
                    let relation = direction == "overlaps" ? "overlapping" : direction
                    let otherBase = nearest.visualColor.map { "\($0) object" }
                        ?? nearest.visualShape.map { "\($0) object" }
                    if let otherBase {
                        // The same measured relation must accept the natural
                        // shape nouns published for both participants. These
                        // stay private aliases; no new relation is inferred.
                        for subject in [base] + naturalBases {
                            for object in [otherBase] + Self.naturalShapeNames(nearest) {
                                aliases.append("\(subject) \(relation) \(object)")
                            }
                        }
                    }
                }
                return aliases
            }()
            targets.append(MacFourVerbsSupplementalTarget(
                label: targetLabel,
                aliases: appearanceAliases,
                kind: spatiallyAddressable ? "visual region" : kind,
                frame: {
                    let observed = geometry.screenRect(row.rect)
                    guard spatiallyAddressable,
                          let identity = liveRegionIdentities[row.rect] else { return observed }
                    return MacAXFrame(
                        x: min(
                            max(origin.x, observed.x + identity.projectedX),
                            origin.x + logicalSize.width - observed.w
                        ),
                        y: min(
                            max(origin.y, observed.y + identity.projectedY),
                            origin.y + logicalSize.height - observed.h
                        ),
                        w: observed.w,
                        h: observed.h
                    )
                }(),
                observedFrame: geometry.screenRect(row.rect),
                provenance: .vision(renderedConfidence),
                viewId: viewId,
                ordinal: ordinal,
                physicalOnly: motorAddressable,
                motionUncertain: motorAddressable
                    && (liveRegionIdentities[row.rect]?.needsMotionConfirmation == true
                        || (liveRegionIdentities[row.rect]?.motion != "stationary"
                            && liveRegionIdentities[row.rect]?.motion?.hasPrefix("moving ") != true)),
                enabled: row.state.disabled?.value != true
            ))
        }

        let summarizedCount = summarizedFragments.values.reduce(0, +)
        if summarizedCount > 0 {
            let categories = summarizedFragments.keys.sorted().map {
                "\(summarizedFragments[$0] ?? 0) \($0)"
            }.joined(separator: ", ")
            let label = "\(summarizedCount) uncertain visual fragment"
                + (summarizedCount == 1 ? "" : "s")
            contentRows.append(MacScreenRender.Row(
                label: MacScreenText(label, redacted: .string(label)),
                detail: [MacScreenText("not separately addressable", redacted: .string("not separately addressable"))],
                provenance: .vision(summarizedFragmentConfidence),
                abstain: "summarized non-addressable regions: \(categories)"
            ))
        }

        var contents: [MacScreenRender.Content] = []
        if !contentRows.isEmpty {
            contents.append(MacScreenRender.Content(
                kind: .grid,
                rows: contentRows
            ))
        }
        // The captured image's own extent is exact even when OCR finds no
        // rows—the common canvas/game/video case. Row confidence describes
        // objects inside it, not whether the visual surface itself exists.
        let canvasConfidence = 1.0
        let fullCanvasRect = VisionRect(x: 0, y: 0, w: frameSize.width, h: frameSize.height)
        let canvasFrame = globalRegionOfInterest ?? geometry.screenRect(fullCanvasRect)
        contents.append(MacScreenRender.Content(
            kind: .canvas,
            canvas: MacScreenRender.Canvas(
                description: "visual surface",
                width: canvasFrame.w,
                height: canvasFrame.h,
                provenance: .vision(canvasConfidence),
                hasPerceptualEvidence: !rows.isEmpty || !recognizedText.isEmpty || !readouts.isEmpty,
                hasRegionTarget: canvasFrame.w > 0 && canvasFrame.h > 0
            )
        ))
        if canvasConfidence >= 0.55, canvasFrame.w > 0, canvasFrame.h > 0 {
            targets.append(MacFourVerbsSupplementalTarget(
                label: MacScreenText("visual surface", redacted: .string("visual surface")),
                aliases: ["canvas", "viewport", "world"],
                kind: "canvas",
                frame: canvasFrame,
                provenance: .vision(canvasConfidence),
                viewId: viewId,
                regionOnly: true
            ))
        }

        var values = indicatorRender.values + readouts.filter {
            insideRegionOfInterest($0.rect)
                && !indicatorRender.claimedReadoutHandles.contains($0.handle)
                && !($0.text.display.map(Self.isStandaloneOCRNoise) ?? false)
        }.map {
            MacScreenRender.Value(
                text: MacScreenText($0.text.raw, redacted: $0.text.json),
                provenance: .vision($0.confidence)
            )
        }
        // Publish bounded redacted OCR values independently of row-label and readout ranking.
        var valueKeys = Set(values.compactMap { $0.text.display?.lowercased() })
        for recognized in recognizedText {
            guard values.count < 16,
                  let label = screenText(recognized.text),
                  let display = label.display else { continue }
            let key = display.lowercased()
            guard !valueKeys.contains(key),
                  !indicatorRender.claimedRecognizedKeys.contains(key),
                  !Self.isStandaloneOCRNoise(display) else { continue }
            valueKeys.insert(key)
            values.append(MacScreenRender.Value(
                text: label,
                provenance: .vision(recognized.confidence)
            ))
        }
        // Only HUD/readout/OCR values may prove that an action had a visible
        // effect. Occlusion memory and scene relations naturally change while
        // objects move, even when an input did nothing.
        let effectValueTexts = indicatorRender.effectValueTexts
            + values.dropFirst(indicatorRender.values.count).compactMap(\.text.display)
        for occluded in liveOccludedRegions.prefix(max(0, 16 - values.count)) {
            let appearance = [occluded.shapeName, occluded.colorName]
                .compactMap { $0 }
                .joined(separator: " ")
            let prefix = appearance.isEmpty ? "" : "\(appearance) "
            let frameWord = occluded.missedFrames == 1 ? "frame" : "frames"
            var text = "\(prefix)visual region \(occluded.id) temporarily not visible; last seen at \(occluded.lastCenterXPercent)%,\(occluded.lastCenterYPercent)% (\(occluded.missedFrames) \(frameWord) ago)"
            if let x = occluded.expectedCenterXPercent,
               let y = occluded.expectedCenterYPercent {
                text += "; expected near \(x)%,\(y)% if motion continued"
            }
            values.append(MacScreenRender.Value(
                text: MacScreenText(text, redacted: .string(text)),
                provenance: .vision(occluded.confidence)
            ))
        }
        let spatialValues = Self.spatialRelationValues(
            in: perceivedRows,
            indexes: spatialIndexes,
            frameSize: frameSize,
            identities: liveRegionIdentities
        )
        values.append(contentsOf: spatialValues.prefix(max(0, 16 - values.count)))
        return MacFourVerbsSupplement(
            contents: contents,
            controls: controls,
            values: values,
            targets: targets,
            diagnostics: [
                "vision_effect_value_text": .array(effectValueTexts.map { .string($0) })
            ]
        )
    }

}
