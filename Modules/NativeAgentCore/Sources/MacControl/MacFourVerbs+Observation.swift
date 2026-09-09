import Foundation
import NativeAgentCore
import PersistenceCore

/// Call-local proof supplied by the canonical view capture, never by app-name
/// matching. A source that cannot bind pixels to this look is discarded.
final class MacSightCaptureBinding: @unchecked Sendable {
    @TaskLocal static var current: MacSightCaptureBinding?
    let frameID: String
    private let lock = NSLock()
    private var confirmed = false
    private var validate: (@Sendable () async -> Bool)?
    init(frameID: String) { self.frameID = frameID }
    func confirm(validate: @escaping @Sendable () async -> Bool = { true }) {
        lock.lock(); defer { lock.unlock() }
        confirmed = true
        self.validate = validate
    }
    var isConfirmed: Bool { lock.lock(); defer { lock.unlock() }; return confirmed }
    func isCurrent() async -> Bool {
        let check = lock.withLock { validate }
        return await check?() ?? false
    }
}

extension MacFourVerbs {
    // MARK: 1 — EYES

    /// A FRESH look, rendered in the one canonical structure.
    ///
    /// `part` zooms: "the list", "the toolbar", "the Send button". Same shape,
    /// scoped, more detail for that part. ORDINALS ARE NEVER RENUMBERED by a
    /// zoom — row 3 is row 3 whether or not the render is scoped, because an
    /// ordinal that means something different in a zoomed view is the same
    /// class of bookkeeping trap the handles were. So a zoom onto content shows
    /// the section WHOLE (its cap raised) and names which rows matched; a zoom
    /// onto controls, which carry no ordinals, filters them.
    ///
    /// fable51 item 32a — `app` GLANCES SIDEWAYS. Naming a running app reads
    /// ITS front window without activating it: no focus steal, no window flip
    /// on User's screen, no three-call `go there / look / go back` dance. What
    /// comes back says plainly that the window is not in front, because whether
    /// it is in front decides whether she may act on it: `act` and `go` are
    /// still frontmost verbs, and a background sighting is a LOOK, not a
    /// license.
    public func screen(part: String? = nil, app: String? = nil) async -> MacFourVerbsReply {
        switch await sight(part: part, app: app) {
        case .blind(let reply):
            return reply
        case .seen(let sighting):
            var lead = "Looking at " + sighting.place + "."
            if let part, let note = sighting.zoomNote {
                lead = "Zoomed on \"\(part)\" in " + sighting.place + ". " + note
            }
            if app != nil {
                lead += " I read it where it sits — nothing was brought to the front."
            }
            return MacFourVerbsReply(
                ok: true,
                text: lead + "\n" + sighting.render,
                detail: sighting.detail
            )
        }
    }

    func observedReply(
        result: MacControlResult,
        description: String,
        unverifiedDescription: String? = nil,
        before: Sighting?,
        allowGenericScreenChangeVerification: Bool = true,
        afterPart: String? = nil,
        pointerTarget: String? = nil
    ) async -> MacFourVerbsReply {
        switch await sight(part: afterPart) {
        case .blind(let reply):
            return MacFourVerbsReply(
                ok: true,
                text: (unverifiedDescription ?? description)
                    + " The input went out, but I couldn't take the confirming look. " + reply.text,
                detail: Self.operationDetail(result).merging(["observed_after": .bool(false)]) { current, _ in current }
            )
        case .seen(let after):
            // A scoped post-action render is intentionally shaped differently
            // from the full pre-action screen. That difference is presentation,
            // not effect evidence; visible values and handler evidence remain
            // independently comparable.
            let structuralChanged = afterPart == nil
                ? before.map { $0.effectRender != after.effectRender }
                : nil
            let handlerEvidence = Self.bool(Self.object(result.output)["verified"]) == true
            let changed = structuralChanged.map { $0 || handlerEvidence }
            let visibleValueChanged: Bool = {
                guard let before,
                      let beforeValues = Self.visionValueTexts(before.detail),
                      let afterValues = Self.visionValueTexts(after.detail) else { return false }
                return beforeValues != afterValues
            }()
            let pointerOnTarget: Bool? = {
                guard let pointerTarget, let before,
                      before.bundleIdentifier == after.bundleIdentifier,
                      before.appName == after.appName,
                      let pointer = after.pointer,
                      case .hit(let target) = Self.resolve(pointerTarget, among: after.targets),
                      let frame = target.observedFrame else { return nil }
                return pointer.isInside(frame) && !target.excludedFrames.contains { pointer.isInside($0) }
            }()
            let observation: String
            if pointerOnTarget == true { observation = " The system pointer is inside the target's freshly observed bounds." }
            else if pointerOnTarget == false { observation = " The system pointer is outside the target's freshly observed bounds." }
            else if visibleValueChanged { observation = " A value the fresh screen says changed after it." }
            else if structuralChanged == true { observation = " The fresh screen changed after it." }
            else if handlerEvidence && allowGenericScreenChangeVerification {
                observation = " The fresh fused view changed after it, although the structural words stayed the same."
            }
            else if changed == false { observation = " The fresh screen did not visibly change." }
            else { observation = " This is the fresh screen afterward." }
            var detail = Self.operationDetail(result)
            let mechanism = Self.object(result.output)
            if let neutral = Self.bool(mechanism["hand_neutral"]) {
                detail["hand_neutral"] = .bool(neutral)
            }
            detail["observed_after"] = .bool(true)
            detail["screen_changed"] = changed.map(JSONValue.bool) ?? .null
            // Physical input starts unverified because emitting HID is not
            // evidence. An immediate fresh fused screen delta is independent
            // evidence that the visible computer reacted, so settle THAT claim
            // (not the caller's larger goal). An unchanged screen remains
            // explicitly unverified.
            if pointerTarget != nil {
                detail["pointer_on_target"] = pointerOnTarget.map(JSONValue.bool) ?? .null
                detail["verification"] = .string(pointerOnTarget == true
                    ? MotorVerificationState.satisfied.rawValue : MotorVerificationState.unverified.rawValue)
                detail.removeValue(forKey: "verification_evidence")
                if pointerOnTarget == true {
                    detail["verification_evidence"] = .string("fresh_system_pointer_in_observed_target")
                    detail["verification_scope"] = .string("pointer_position_only")
                }
            } else if visibleValueChanged {
                detail["verification"] = .string(MotorVerificationState.satisfied.rawValue)
                detail["verification_evidence"] = .string("fresh_visible_value_change")
            } else if changed == true, allowGenericScreenChangeVerification {
                detail["verification"] = .string(MotorVerificationState.satisfied.rawValue)
                detail["verification_evidence"] = .string("fresh_visible_screen_change")
            } else if !allowGenericScreenChangeVerification {
                detail["verification"] = .string(MotorVerificationState.unverified.rawValue)
                detail.removeValue(forKey: "verification_evidence")
            }
            let truthfulDescription = visibleValueChanged
                    || (changed == true && allowGenericScreenChangeVerification)
                ? description
                : (unverifiedDescription ?? description)
            let neutralObservation = mechanism["holding"] != nil
                && mechanism["holding"] != .null
                && Self.bool(mechanism["hand_neutral"]) == true
                ? " The held keys were released and the hand returned neutral."
                : ""
            return MacFourVerbsReply(
                ok: true,
                text: truthfulDescription + observation + neutralObservation + "\n" + after.render,
                detail: detail
            )
        }
    }

    // MARK: - One sighting

    /// Everything ONE verb call needs from ONE look: the render she reads, the
    /// resolvable targets behind it, and the bookkeeping (frame id, handles)
    /// that stays on this side of the wall. Scratch for the duration of a single
    /// call — never stored, never carried across calls.
    /// A look either happened or it didn't, and a blind verb answers in words
    /// rather than throwing: "I can't see the screen right now" IS the reply.
    enum Sighted {
        case seen(Sighting)
        case blind(MacFourVerbsReply)
    }

    struct Sighting {
        let render: String
        let effectRender: String
        let pointer: MacPointerPosition?
        let place: String
        let appName: String?
        let bundleIdentifier: String?
        /// fable51 item 31 — the process `wait` installs its AX observer on.
        /// nil when the look could not name one, which the wait reports as "no
        /// observer" rather than installing on a guess.
        let pid: Int32?
        /// fable51 item 32a/b — whether the window this sighting DESCRIBES is
        /// the one in front. Always true for an unanchored look; a measured
        /// fact for an anchored one, and the fact the cross-app drag's raise
        /// decision turns on.
        let isFront: Bool
        let visibleFrame: MacAXFrame?
        /// fable51 item 32b (gpt-5.5 review) — the frame of the WINDOW this
        /// sighting describes, as the look's own anchor reported it. nil when
        /// the host published none. Distinct from `visibleFrame`, which is the
        /// screen's usable area, and from the union of `targets` frames, which
        /// is only what was READ inside the window: a window's title bar,
        /// toolbar and blank areas belong to the window and to neither of
        /// those. The cross-app drag's coverage guard turns on this.
        let windowFrame: MacAXFrame?
        let targets: [ActTarget]
        let frameId: String
        let zoomNote: String?
        let detail: [String: JSONValue]
    }

    /// A resolvable thing on the screen. `label` is the DISPLAY text — what the
    /// renderer printed — so anything redaction withheld cannot be named.
    struct ActTarget: Equatable {
        let sourceAXPath: [Int]?
        let handle: String
        let label: String?
        /// Additional exact natural names for this SAME target. These never
        /// create a second address or carry a second handle; they let transient
        /// state such as keyboard focus name the element already in the model.
        let aliases: [String]
        let kind: String
        /// The content-row ordinal the render printed.
        let ordinal: Int?
        /// A stable one-based ordinal within this target's visible kind. This
        /// is how repeated unnamed controls remain addressable as `button 2`
        /// without pretending that one of them is uniquely named.
        let roleOrdinal: Int?
        let enabled: Bool
        let frame: MacAXFrame?
        let observedFrame: MacAXFrame?
        let excludedFrames: [MacAXFrame]
        let viewId: String?
        let mark: Int?
        let regionOnly: Bool
        let physicalOnly: Bool
        let motionUncertain: Bool

        // A semantic look handle remains the preferred semantic route even
        // after fusion enriches it with a physical frame/mark. Only a target
        // that has no look handle is supplemental-only. This keeps the closed
        // loop's destination/read-back verification while giving the same
        // target a physical point for hover, drag, hold, and movement.
        var isSupplemental: Bool { handle.isEmpty }

        init(
            handle: String,
            label: String?,
            aliases: [String] = [],
            kind: String,
            ordinal: Int?,
            roleOrdinal: Int? = nil,
            enabled: Bool,
            frame: MacAXFrame? = nil,
            observedFrame: MacAXFrame? = nil,
            excludedFrames: [MacAXFrame] = [],
            viewId: String? = nil,
            mark: Int? = nil,
            regionOnly: Bool = false,
            physicalOnly: Bool = false,
            motionUncertain: Bool = false,
            sourceAXPath: [Int]? = nil
        ) {
            self.handle = handle
            self.sourceAXPath = sourceAXPath
            self.label = label
            self.aliases = aliases
            self.kind = kind
            self.ordinal = ordinal
            self.roleOrdinal = roleOrdinal
            self.enabled = enabled
            self.frame = frame
            self.observedFrame = observedFrame ?? frame
            self.excludedFrames = excludedFrames
            self.viewId = viewId
            self.mark = mark
            self.regionOnly = regionOnly
            self.physicalOnly = physicalOnly
            self.motionUncertain = motionUncertain
        }
    }

    // Module-internal so paired perception fixtures can inspect the same
    // private target/render compilation used by screen and act.
    func sight(part: String?, app: String? = nil) async -> Sighted {
        await sight(part: part, app: app, wakeAttemptsRemaining: 2)
    }

    /// A screen saver is an obstruction to perception, not a destination Agent
    /// should reason about. Clear it with the already-gated wake organ and then
    /// start the read again. Two attempts cover the observed macOS teardown
    /// delay without creating an unbounded input loop.
    private func sight(part: String?, app: String?, wakeAttemptsRemaining: Int) async -> Sighted {
        let result: MacControlResult
        do {
            // fable51 item 32a — when `app` is named, the look is ANCHORED to
            // that app's front window and nothing is activated. The dispatch
            // body is the only difference; everything downstream reads the same
            // percept shape, and `front` in the output tells the renderer the
            // truth about what it is describing.
            var body: [String: JSONValue] = ["grade": .string("look")]
            if let app { body["app"] = .string(app) }
            result = try await host.dispatch(action: "look", body: body)
        } catch {
            return .blind(MacFourVerbsReply(
                ok: false,
                text: "I can't see the screen right now: \(error).",
                detail: ["error": .string("\(error)")]
            ))
        }
        let output = Self.object(result.output)
        guard result.ok, let frameId = Self.string(output["frame_id"]) else {
            let why = Self.string(output["message"])
                ?? Self.lookRefusalWords(result.error ?? Self.string(output["status"]) ?? "unknown")
            return .blind(MacFourVerbsReply(
                ok: false,
                text: "I can't see the screen right now. " + why,
                // The refusal's own words, unwrapped. A caller with a different
                // lead sentence (the cross-app drag: "I can't drop into Mail")
                // must not have to strip this one's off the front.
                detail: [
                    "error": .string(result.error ?? "look_failed"),
                    "message": .string(why),
                ]
            ))
        }

        let percept = Self.percept(from: output)
        if percept.app?.bundleIdentifier == MacWakeGuard.loginWindowBundleID {
            guard wakeAttemptsRemaining > 0 else {
                return .blind(MacFourVerbsReply(
                    ok: false,
                    text: "The screensaver is still covering the desktop after I nudged it, so I can't see or use the apps underneath yet.",
                    detail: ["error": .string("display_obstructed")]
                ))
            }

            let wake: MacControlResult
            do {
                wake = try await host.dispatch(action: "wake", body: ["settle_ms": .int(1_000)])
            } catch {
                return .blind(MacFourVerbsReply(
                    ok: false,
                    text: "The screensaver is covering the desktop, and I couldn't send the safe wake nudge: \(error).",
                    detail: ["error": .string("display_obstructed")]
                ))
            }

            let wakeOutput = Self.object(wake.output)
            let wakeReceipt = Self.object(wakeOutput["wake"] ?? .null)
            if wake.ok || wakeReceipt["still_obstructed"] == .bool(true) {
                return await sight(part: part, app: app, wakeAttemptsRemaining: wakeAttemptsRemaining - 1)
            }
            return .blind(MacFourVerbsReply(
                ok: false,
                text: "The screensaver is covering the desktop, and the safe wake nudge was refused before anything moved.",
                detail: Self.operationDetail(wake).merging([
                    "error": .string("display_obstructed")
                ]) { current, _ in current }
            ))
        }

        // An UNANCHORED look is frontmost-anchored by construction, so FRONT is
        // a fact there rather than a guess; how many OTHER windows exist is not
        // something this read can tell, and an unknown is omitted, never zeroed
        // into a claim.
        //
        // fable51 item 32a — an ANCHORED look is a different case: the window
        // it describes is usually BEHIND whatever User is using, and printing
        // "in front" over it would be the render lying about the one fact that
        // decides whether she may act on it. The handler publishes `front`;
        // this reads it, and only falls back to `true` when the field is absent
        // (an older host, where every look really was frontmost).
        let isFront = Self.bool(output["front"]) ?? true
        var full = MacScreenRender.screen(from: percept, isFront: isFront)
        let (rows, controls) = Self.partition(percept)
        var targets: [ActTarget] = []
        var rowRoleOrdinals: [String: Int] = [:]
        // Render limits keep the model's reply bounded; they must never become
        // an input limit. A control or row revealed by a prior zoom remains a
        // valid natural target even when the next full-screen render elides it.
        for (index, row) in rows.enumerated() {
            let kind = MacScreenRender.kindName(role: row.role)
            let roleOrdinal = (rowRoleOrdinals[kind] ?? 0) + 1
            rowRoleOrdinals[kind] = roleOrdinal
            targets.append(ActTarget(
                handle: row.handle,
                label: MacScreenText(row.label, redacted: row.labelJSON).display,
                kind: kind,
                ordinal: index + 1,
                roleOrdinal: roleOrdinal,
                enabled: row.enabled,
                frame: row.frame,
                viewId: nil,
                mark: nil,
                sourceAXPath: row.path
            ))
        }
        let controlOrdinals = MacScreenRender.controlRoleOrdinals(for: controls)
        for control in controls {
            let kind = MacScreenRender.kindName(role: control.role)
            let display = MacScreenText(control.label, redacted: control.labelJSON).display
            let roleOrdinal = controlOrdinals[control.handle]
            targets.append(ActTarget(
                handle: control.handle,
                label: display,
                kind: kind,
                ordinal: nil,
                roleOrdinal: roleOrdinal,
                enabled: control.enabled,
                frame: control.frame,
                viewId: nil,
                mark: nil,
                sourceAXPath: control.path
            ))
        }

        // Structural regions are addresses too. They are not click targets—
        // clicking the centre of a sidebar would select an arbitrary row—but
        // they are safe, useful destinations for scroll, move and hover. This
        // closes the gap where SCREEN said WHERE=sidebar and ACT could not name
        // that same visible region.
        var landmarkRoleOrdinals: [String: Int] = [:]
        for landmark in percept.landmarks {
            guard let frame = landmark.frame, frame.w > 0, frame.h > 0 else { continue }
            let label = MacScreenText(
                landmark.label ?? landmark.kind,
                redacted: landmark.labelJSON ?? .string(landmark.kind)
            ).display
            let roleOrdinal = (landmarkRoleOrdinals[landmark.kind] ?? 0) + 1
            landmarkRoleOrdinals[landmark.kind] = roleOrdinal
            targets.append(ActTarget(
                handle: "",
                label: label,
                kind: landmark.kind,
                ordinal: nil,
                roleOrdinal: roleOrdinal,
                enabled: true,
                frame: frame,
                regionOnly: true,
                sourceAXPath: landmark.path
            ))
        }

        var visibleFrame: MacAXFrame?
        var pointer: MacPointerPosition?
        var pointerFrame: MacAXFrame?
        var supplementalDiagnostics: [String: JSONValue] = [:]
        let captureBinding = MacSightCaptureBinding(frameID: frameId)
        let supplement = await MacSightCaptureBinding.$current.withValue(captureBinding) {
            await supplementalSource?.observe(app: app)
        }
        if let supplement, await captureBinding.isCurrent(),
           Self.sameApp(percept: percept, supplement: supplement) {
            visibleFrame = supplement.visibleFrame
            pointer = supplement.pointer
            pointerFrame = supplement.pointerFrame ?? supplement.visibleFrame
            supplementalDiagnostics = supplement.diagnostics
            var addedTargets: [ActTarget] = []
            var mergedAXPaths: Set<[Int]> = []
            var addedAXOrdinals: [[Int]: Int] = [:]
            for candidate in supplement.targets {
                let display = candidate.label?.display
                let combined = targets + addedTargets
                let duplicateIndex = Self.supplementalDuplicateIndex(candidate, among: combined)
                if let duplicateIndex {
                    if let path = candidate.sourceAXPath { mergedAXPaths.insert(path) }
                    // The semantic `look` lane intentionally keeps coordinates
                    // private, while the fused view carries the same element's
                    // frame and mark. Do not discard that richer address merely
                    // because the label already exists: that was why Chrome's
                    // visible link could be named but not hovered. Enrich the
                    // semantic target in place so every visible mark has both
                    // its stable AX handle and a safe physical point.
                    let existing = combined[duplicateIndex]
                    let mergedLabel = existing.label ?? display
                    let mergedFrame = existing.frame ?? candidate.frame
                    // A containing row and its filename are one named item,
                    // but their marks still address DIFFERENT AX elements.
                    // Keep the semantic leaf handle; never donate the row mark.
                    let sameAXElement = existing.sourceAXPath == nil || candidate.sourceAXPath == nil
                        || existing.sourceAXPath == candidate.sourceAXPath
                    let mergedViewId = existing.viewId ?? (sameAXElement ? candidate.viewId : nil)
                    let mergedMark = existing.mark ?? (sameAXElement ? candidate.mark : nil)
                    let enriched = ActTarget(
                        handle: existing.handle,
                        label: mergedLabel,
                        aliases: (existing.aliases + candidate.aliases).reduce(into: []) {
                            if !$0.contains($1) { $0.append($1) }
                        },
                        kind: existing.kind,
                        ordinal: existing.ordinal,
                        roleOrdinal: existing.roleOrdinal,
                        enabled: existing.enabled,
                        frame: mergedFrame,
                        observedFrame: existing.observedFrame ?? candidate.observedFrame,
                        excludedFrames: existing.excludedFrames + candidate.excludedFrames,
                        viewId: mergedViewId,
                        mark: mergedMark,
                        regionOnly: existing.regionOnly,
                        physicalOnly: existing.physicalOnly || candidate.physicalOnly,
                        motionUncertain: candidate.motionUncertain,
                        sourceAXPath: existing.sourceAXPath ?? candidate.sourceAXPath
                    )
                    if duplicateIndex < targets.count {
                        targets[duplicateIndex] = enriched
                    } else {
                        addedTargets[duplicateIndex - targets.count] = enriched
                    }
                    continue
                }
                let roleOrdinal = candidate.ordinal ?? Self.nextRoleOrdinal(
                    for: candidate.kind, among: targets + addedTargets
                )
                if let path = candidate.sourceAXPath { addedAXOrdinals[path] = roleOrdinal }
                addedTargets.append(ActTarget(
                    handle: "",
                    label: display,
                    aliases: candidate.aliases,
                    kind: candidate.kind,
                    ordinal: rows.isEmpty ? candidate.ordinal : nil,
                    roleOrdinal: roleOrdinal,
                    enabled: candidate.enabled,
                    frame: candidate.frame,
                    observedFrame: candidate.observedFrame,
                    excludedFrames: candidate.excludedFrames,
                    viewId: candidate.viewId,
                    mark: candidate.mark,
                    regionOnly: candidate.regionOnly,
                    physicalOnly: candidate.physicalOnly,
                    motionUncertain: candidate.motionUncertain,
                    sourceAXPath: candidate.sourceAXPath
                ))
            }
            targets.append(contentsOf: addedTargets)
            let supplementalControls = supplement.controls.compactMap { control -> MacScreenRender.Control? in
                guard let path = control.sourceAXPath else { return control }
                guard !mergedAXPaths.contains(path) else { return nil }
                return MacScreenRender.Control(
                    label: control.label, kind: control.kind,
                    ordinal: addedAXOrdinals[path] ?? control.ordinal,
                    value: control.value, states: control.states, provenance: control.provenance,
                    abstain: control.abstain, sourceAXPath: path
                )
            }
            let supplementalContents = supplement.contents.map { content in
                MacScreenRender.Content(
                    kind: content.kind, noun: content.noun,
                    rows: content.rows.filter { row in
                        row.sourceAXPath.map { !mergedAXPaths.contains($0) } ?? true
                    },
                    totalRows: content.totalRows, scrollable: content.scrollable, canvas: content.canvas
                )
            }
            full = Self.adding(
                contents: supplementalContents,
                controls: supplementalControls,
                values: supplement.values,
                to: full
            )
        }

        // A focused empty text area has no title or value, so it is not an AX
        // affordance — but the look frame deliberately minted a safe handle for
        // it. Make that existing address visible as a role ordinal. This is the
        // Notes case Agent found, expressed by shape rather than app name.
        if let focus = percept.focus, let handle = focus.handle {
            let kind = MacScreenRender.kindName(role: focus.role)
            let label = focus.displayLabel ?? "focused \(kind)"
            if let index = targets.firstIndex(where: { $0.handle == handle }) {
                // A text area can already be an interactive affordance despite
                // having no label. Focus gives that same safe handle a natural
                // name; otherwise the duplicate target would leave it visible
                // yet impossible to address by the focused label.
                let existing = targets[index]
                if existing.label == nil {
                    targets[index] = ActTarget(
                        handle: existing.handle,
                        label: label,
                        aliases: Self.editableKinds.contains(kind)
                            ? Self.focusedEditableAliases(kind: kind)
                            : [],
                        kind: existing.kind,
                        ordinal: existing.ordinal,
                        roleOrdinal: existing.roleOrdinal,
                        enabled: existing.enabled,
                        frame: existing.frame,
                        observedFrame: existing.observedFrame,
                        excludedFrames: existing.excludedFrames,
                        viewId: existing.viewId,
                        mark: existing.mark,
                        regionOnly: existing.regionOnly,
                        physicalOnly: existing.physicalOnly,
                        motionUncertain: existing.motionUncertain,
                        sourceAXPath: existing.sourceAXPath
                    )
                    full = Self.adding(
                        controls: [MacScreenRender.Control(
                            label: MacScreenText(label, redacted: .string(label)),
                            kind: kind,
                            states: ["focused", "unnamed"],
                            provenance: .ax
                        )],
                        to: full
                    )
                } else if Self.editableKinds.contains(kind) {
                    targets[index] = ActTarget(
                        handle: existing.handle,
                        label: existing.label,
                        aliases: Self.focusedEditableAliases(kind: kind),
                        kind: existing.kind,
                        ordinal: existing.ordinal,
                        roleOrdinal: existing.roleOrdinal,
                        enabled: existing.enabled,
                        frame: existing.frame,
                        observedFrame: existing.observedFrame,
                        excludedFrames: existing.excludedFrames,
                        viewId: existing.viewId,
                        mark: existing.mark,
                        regionOnly: existing.regionOnly,
                        physicalOnly: existing.physicalOnly,
                        motionUncertain: existing.motionUncertain,
                        sourceAXPath: existing.sourceAXPath
                    )
                }
            } else {
                targets.append(ActTarget(
                    handle: handle,
                    label: label,
                    aliases: Self.editableKinds.contains(kind)
                        ? Self.focusedEditableAliases(kind: kind)
                        : [],
                    kind: kind,
                    ordinal: nil,
                    roleOrdinal: Self.nextRoleOrdinal(for: kind, among: targets),
                    enabled: true,
                    frame: nil,
                    viewId: nil,
                    mark: nil,
                    sourceAXPath: focus.path
                ))
                full = Self.adding(
                    controls: [MacScreenRender.Control(
                        label: MacScreenText(label, redacted: .string(label)),
                        kind: kind,
                        states: ["focused", "unnamed"],
                        provenance: .ax
                    )],
                    to: full
                )
            }
        }

        let zoom = part.flatMap { Self.zoom(full, part: $0, options: options) }
        let rendering = MacScreenRender.rendering(zoom?.screen ?? full, options: zoom?.options ?? options)
        let pointerLine: String = {
            guard let pointer else { return "POINTER: position unavailable." }
            guard let frame = pointerFrame else { return "POINTER: observed; surface position unavailable." }
            guard pointer.isInside(frame) else { return "POINTER: outside the observed surface." }
            let x = Int(((pointer.x - frame.x) / frame.w * 100).rounded())
            let y = Int(((pointer.y - frame.y) / frame.h * 100).rounded())
            return "POINTER: \(x)%,\(y)% of the observed surface (system position)."
        }()
        let renderedText = rendering.text + "\n" + pointerLine
        return .seen(Sighting(
            render: renderedText,
            effectRender: rendering.text,
            pointer: pointer,
            place: Self.place(percept),
            appName: percept.app?.name,
            bundleIdentifier: percept.app?.bundleIdentifier,
            pid: percept.app.map(\.processIdentifier).flatMap { $0 == 0 ? nil : $0 },
            isFront: isFront,
            visibleFrame: visibleFrame,
            windowFrame: Self.frame(output["window_frame"]),
            targets: targets,
            frameId: frameId,
            zoomNote: zoom?.note,
            detail: [
                "bytes": .int(Int64(renderedText.utf8.count)),
                "rows_dropped": .int(Int64(rendering.rowsDropped)),
                "controls_dropped": .int(Int64(rendering.controlsDropped)),
                "semantic_targets_omitted": .int(Int64(percept.affordancesOmitted)),
            ].merging(supplementalDiagnostics) { current, _ in current }
        ))
    }

    /// Each acquisition loop keeps its own budget and target-resolution rules.
    /// The observation step shares the delay and foreground-app identity check.
    func resampleSight(temporal: Bool, expectedApp: String?) async -> Sighted {
        if temporal { await clock.sleep(seconds: 0.06) }
        let observed = await sight(part: nil)
        if case .seen(let refreshed) = observed,
           (refreshed.bundleIdentifier ?? refreshed.appName) != expectedApp {
            return .blind(Self.motionAppChangedReply(screen: refreshed.render))
        }
        return observed
    }

    private static func motionAppChangedReply(screen: String) -> MacFourVerbsReply {
        MacFourVerbsReply(ok: false,
            text: "The foreground app changed while I was observing motion. I haven't sent input.\n" + screen,
            detail: ["error": .string("motion_sampling_app_changed")])
    }


    /// A screenshot supplement is useful only when it describes the same app
    /// as the semantic look it augments. The two captures are separate system
    /// calls, so a foreground change between them must discard the supplement
    /// rather than manufacture one mixed screen.
    static func sameApp(percept: MacLookPercept, supplement: MacFourVerbsSupplement) -> Bool {
        if let lookID = percept.app?.bundleIdentifier, let viewID = supplement.bundleIdentifier {
            return lookID == viewID
        }
        guard let lookName = percept.app?.name, let viewName = supplement.appName else { return false }
        return normalize(lookName) == normalize(viewName)
    }

}
