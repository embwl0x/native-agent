import Foundation
import NativeAgentCore
import PersistenceCore
import Senses

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

    static func runningAppsLine(_ output: [String: JSONValue]) -> String {
        guard case .array(let running)? = output["running_apps"] else { return "" }
        let names = running.compactMap { value -> String? in
            let row = object(value)
            return string(row["name"]).map { $0 + (row["front"] == .bool(true) ? " (frontmost)" : "") }
        }
        let omitted = int(output["running_apps_omitted"]) ?? 0
        return "Running apps: " + names.joined(separator: ", ")
            + (omitted > 0 ? " (+\(omitted) more)" : "") + "\n"
    }

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
    public func screen(part: String? = nil, app: String? = nil, structured: Bool = false) async -> MacFourVerbsReply {
        // The menu bar belongs to the app, not the window, so the window read
        // never spends its budget there; `part: menu` reads it on purpose.
        if let part, ["menu", "menus", "menu bar"].contains(Self.normalize(part)) {
            var body: [String: JSONValue] = [:]
            if let app { body["app"] = .string(app) }
            guard let result = try? await host.dispatch(action: "menu", body: body), result.ok else {
                return MacFourVerbsReply(ok: false, text: "I couldn't read that app's menu bar.",
                                         detail: ["error": .string("menu_unavailable")])
            }
            let output = Self.object(result.output)
            let rows = Self.array(output["paths"]).compactMap { row -> String? in
                let item = Self.object(row)
                guard let path = Self.string(item["path"]) else { return nil }
                return path + (Self.bool(item["enabled"]) == false ? "  (greyed out)" : "")
            }
            let name = Self.string(Self.object(output["app"])["name"]) ?? "The app"
            return MacFourVerbsReply(
                ok: true,
                text: "\(name)'s menus, read without opening anything (press one with app mac.menu_press, or menu_press where that is your tool)"
                    + (output["enabled_state"] != nil ? "; which are greyed out is unknown until it's in front" : "")
                    + ":\n"
                    + rows.joined(separator: "\n"),
                detail: ["menu_items": .int(Int64(rows.count))]
            )
        }
        switch await sight(part: part, app: app) {
        case .blind(let reply):
            if reply.detail["status"] == .string("in_process_route"), case .array? = reply.detail["running_apps"] {
                let front = Self.string(Self.object(reply.detail["frontmost_app"])["name"]) ?? "unknown app"
                return MacFourVerbsReply(ok: true,
                    text: "MAC · \(front) in front\n" + Self.runningAppsLine(reply.detail)
                        + "NativeAgent's window is read in process; no accessibility capture was made.",
                    detail: reply.detail)
            }
            return reply
        case .seen(let sighting):
            let contentRoute = ["com.apple.mail": "mail.*", "com.apple.MobileSMS": "messages.*",
                                "com.apple.Notes": "notes.*"][sighting.bundleIdentifier ?? ""]
            var lead = "Looking at " + sighting.place + "."
            if let part, let note = sighting.zoomNote {
                lead = "Zoomed on \"\(part)\" in " + sighting.place + ". " + note
            }
            if app != nil {
                lead += " I read it where it sits — nothing was brought to the front."
            }
            return MacFourVerbsReply(
                ok: true,
                text: (sighting.detail["native_page"] != nil ? sighting.render : lead + "\n" + sighting.render)
                    + (contentRoute.map { "\nUse \($0) for content; this is only the on-screen view." } ?? ""),
                detail: structured
                    ? sighting.detail.merging(["controls": sighting.controls]) { _, new in new }
                    : sighting.detail.filter { $0.key != "native_page" }
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
            // In a batch, the text the step before typed is that step's change,
            // not this one's: a return that only "changed" that text did nothing.
            // Too short a text ("a") would match unrelated words: ignored then.
            let typedRaw = Self.typedJustBefore.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 ? $0 : nil }
            let typedBefore = typedRaw.map(Self.normalize)
            let withoutTyped: (String) -> String = { render in
                typedRaw.map { render.replacingOccurrences(of: $0, with: "") } ?? render
            }
            // A scoped post-action render is intentionally shaped differently
            // from the full pre-action screen. That difference is presentation,
            // not effect evidence; visible values and handler evidence remain
            // independently comparable.
            let structuralChanged = afterPart == nil
                ? before.map { withoutTyped($0.effectRender) != withoutTyped(after.effectRender) }
                : nil
            let textValueVerified = Self.bool(Self.object(result.output)["text_value_verified"])
            let handlerEvidence = Self.bool(Self.object(result.output)["verified"]) == true
            let changed = structuralChanged.map { $0 || handlerEvidence }
            let differingValues: Set<String> = {
                guard let before,
                      let beforeValues = Self.visionValueTexts(before.detail),
                      let afterValues = Self.visionValueTexts(after.detail) else { return [] }
                return beforeValues.symmetricDifference(afterValues)
            }()
            let onlyTypedChanged = typedBefore.map { typed in
                !differingValues.isEmpty && differingValues.map(Self.normalize).allSatisfy { $0.contains(typed) || ($0.count >= 3 && typed.contains($0)) }
            } ?? false
            let visibleValueChanged = !differingValues.isEmpty && !onlyTypedChanged
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
            else if onlyTypedChanged, !handlerEvidence {
                observation = " Nothing visibly happened after it: the only change on the fresh screen is the text typed just before."
            }
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
            if let textValueVerified {
                detail["verification"] = .string(textValueVerified
                    ? MotorVerificationState.satisfied.rawValue : MotorVerificationState.unverified.rawValue)
                detail["text_value_verified"] = .bool(textValueVerified)
                detail.removeValue(forKey: "verification_evidence")
                if textValueVerified { detail["verification_evidence"] = .string("focused_text_value_match") }
            } else if pointerTarget != nil {
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
        /// The screen's content alone — no running-apps, Act or provenance line,
        /// no frame id — so `wait` matches and compares what the app shows.
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
        /// Already-redacted canonical handles, used by the workspace to bind
        /// selections. Normal prose screen calls do not emit this extra data.
        let controls: JSONValue
        let detail: [String: JSONValue]
        /// Her-screen Phase 4 — the app in front when an ANCHORED look was
        /// taken (name, bundle id), so a `front:true` act can put it back.
        /// nil for an unanchored look, which is the front by construction.
        var frontmostApp: (name: String, pid: Int32, window: JSONValue?)? = nil
        /// Her-screen Phase 5 — the window's kind, the app map's key.
        var windowKind: String? = nil
        /// Where keyboard focus is in this read (same paths as targets' sourceAXPath).
        var focusPath: [Int]? = nil
        /// Handles of the editable fields in this read ("text" alone also covers labels).
        var editableHandles: Set<String> = []
        /// Keyboard focus may be (or is) a password field. Unknown counts as secure.
        var focusSecure: Bool = true
    }

    /// A resolvable thing on the screen. `label` is the DISPLAY text — what the
    /// renderer printed — so anything redaction withheld cannot be named.
    struct ActTarget: Equatable {
        var actions: [String]
        let settableAttributes: [String]
        let sourceAXPath: [Int]?
        let handle: String
        var label: String?
        /// Additional exact natural names for this SAME target. These never
        /// create a second address or carry a second handle; they let transient
        /// state such as keyboard focus name the element already in the model.
        let aliases: [String]
        let kind: String
        let secret: Bool
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
        /// An editable field's placeholder: a name it answers to after every
        /// exact label on the screen (Maps' "Apple Maps" field reads "Search Maps").
        var placeholder: String? = nil

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
            secret: Bool = false,
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
            sourceAXPath: [Int]? = nil,
            actions: [String] = [],
            settableAttributes: [String] = []
        ) {
            self.handle = handle
            self.actions = actions
            self.settableAttributes = settableAttributes
            self.sourceAXPath = sourceAXPath
            self.label = label
            self.aliases = aliases
            self.kind = kind
            self.secret = secret || MacCrossAppDrag.isSecureKind(kind)
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
    /// `seek`: a name the caller is about to act on. When the ordinary walk
    /// stops short of it, the look searches deeper and frames it (`seekScoped`).
    func sight(part: String?, app: String? = nil, seek: String? = nil) async -> Sighted {
        let continuation = MacWorkContinuation.current.flatMap { $0.isPending ? $0 : nil }
        let app = continuation?.app?.bundleIdentifier ?? continuation?.app?.name ?? app
        let result: MacControlResult
        do {
            // fable51 item 32a — when `app` is named, the look is ANCHORED to
            // that app's front window and nothing is activated. The dispatch
            // body is the only difference; everything downstream reads the same
            // percept shape, and `front` in the output tells the renderer the
            // truth about what it is describing.
            var body: [String: JSONValue] = ["grade": .string("look"), "app_map": .bool(true)]
            if let app { body["app"] = .string(app) }
            if let part { body["section"] = .string(part) }
            if let seek = seek ?? part, !seek.isEmpty { body["seek"] = .string(seek) }
            result = try await host.dispatch(action: "look", body: body)
        } catch {
            return .blind(MacFourVerbsReply(
                ok: false,
                text: "I can't see the screen right now: \(error).",
                detail: ["error": .string("\(error)")]
            ))
        }
        let output = Self.object(result.output)
        if result.error == "self_inspection_unsupported" {
            let route = Self.ownAppRoute()
            return .blind(MacFourVerbsReply(ok: route.ok, text: route.text,
                detail: route.detail.merging(["frontmost_app": output["frontmost_app"] ?? .null,
                    "running_apps": output["running_apps"] ?? .null,
                    "running_apps_omitted": output["running_apps_omitted"] ?? .int(0)]) { current, _ in current }))
        }
        guard result.ok, let frameId = Self.string(output["frame_id"]) else {
            let why = Self.string(output["message"])
                ?? Self.lookRefusalWords(result.error ?? Self.string(output["status"]) ?? "unknown")
            return .blind(MacFourVerbsReply(
                ok: false,
                text: Self.runningAppsLine(output) + "I can't see the screen right now. " + why,
                // The refusal's own words, unwrapped. A caller with a different
                // lead sentence (the cross-app drag: "I can't drop into Mail")
                // must not have to strip this one's off the front.
                detail: [
                    "error": .string(result.error ?? "look_failed"),
                    "message": .string(why),
                ].merging(output["frontmost_app"].map { ["frontmost_app": $0] } ?? [:]) { current, _ in current }
            ))
        }

        let percept = Self.percept(from: output)
        if percept.app?.bundleIdentifier == MacWakeGuard.loginWindowBundleID {
            return .blind(MacFourVerbsReply(
                ok: false,
                text: MacScreenLock.reply,
                detail: ["error": .string("display_obstructed")]
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
                secret: row.secret,
                ordinal: index + 1,
                roleOrdinal: roleOrdinal,
                enabled: row.enabled,
                frame: row.frame,
                viewId: nil,
                mark: nil,
                sourceAXPath: row.path
            ))
            targets[targets.count - 1].placeholder = row.placeholder
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
                secret: control.secret,
                ordinal: nil,
                roleOrdinal: roleOrdinal,
                enabled: control.enabled,
                frame: control.frame,
                viewId: nil,
                mark: nil,
                sourceAXPath: control.path
            ))
            targets[targets.count - 1].placeholder = control.placeholder
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
        var nativeAXSupplement: MacFourVerbsSupplement?
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
            nativeAXSupplement = supplement
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
                    var enriched = ActTarget(
                        handle: existing.handle,
                        label: mergedLabel,
                        aliases: (existing.aliases + candidate.aliases).reduce(into: []) {
                            if !$0.contains($1) { $0.append($1) }
                        },
                        kind: existing.kind,
                        secret: existing.secret || candidate.secret,
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
                        sourceAXPath: existing.sourceAXPath ?? candidate.sourceAXPath,
                        actions: sameAXElement ? candidate.actions : existing.actions,
                        settableAttributes: sameAXElement ? candidate.settableAttributes : existing.settableAttributes
                    )
                    enriched.placeholder = existing.placeholder
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
                    secret: candidate.secret,
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
                    sourceAXPath: candidate.sourceAXPath,
                    actions: candidate.actions,
                    settableAttributes: candidate.settableAttributes
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
        } else if supplement != nil {
            // Not this look's own window: nothing from that capture may leave.
            supplementalSource?.rejected()
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
                        secret: existing.secret,
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
                        sourceAXPath: existing.sourceAXPath,
                        actions: existing.actions,
                        settableAttributes: existing.settableAttributes
                    )
                    targets[index].placeholder = existing.placeholder
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
                        secret: existing.secret,
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
                        sourceAXPath: existing.sourceAXPath,
                        actions: existing.actions,
                        settableAttributes: existing.settableAttributes
                    )
                    targets[index].placeholder = existing.placeholder
                }
            } else {
                targets.append(ActTarget(
                    handle: handle,
                    label: label,
                    aliases: Self.editableKinds.contains(kind)
                        ? Self.focusedEditableAliases(kind: kind)
                        : [],
                    kind: kind,
                    secret: MacScreenViewBuilder.isSecretField(role: focus.role, subrole: nil, label: focus.label),
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
        let pointerLine: String? = {
            guard let pointer else { return nil }
            guard let frame = pointerFrame else { return "POINTER: observed; surface position unavailable." }
            guard pointer.isInside(frame) else { return "POINTER: outside the observed surface." }
            let x = Int(((pointer.x - frame.x) / frame.w * 100).rounded())
            let y = Int(((pointer.y - frame.y) / frame.h * 100).rounded())
            return "POINTER: \(x)%,\(y)% of the observed surface (system position)."
        }()
        let windowKind = Self.string(output["window_kind"])
        // A walk its caps cut must not read as the whole window: say so, and
        // how to reach the rest (a named act searches past the cut).
        let cutLine: String? = !percept.truncated ? nil
            : percept.truncationReasons.contains("ax_error")
            ? "partial: the app didn't answer every accessibility read; this is only the content read so far."
            : percept.truncationReasons.contains(where: { ["depth_cap", "node_cap", "time_budget"].contains($0) })
            ? "partial: budget reached; this is only the accessibility content read so far."
            : nil
        let rendererNote = Self.string(Self.object(output["seam"])["renderer_wait_note"])
        // The AX native page already represents its text, values and controls
        // together. The legacy render remains the independent pixel surface;
        // it must never be appended as a second copy of an AX document.
        guard let value = output["native_page"] else {
            return .blind(MacFourVerbsReply(ok: false,
                text: "raw view · accessibility · The look reader did not return a native screen page.",
                detail: ["error": .string("screen_page_unavailable")]))
        }
        var nativePage: NativePage
        do { nativePage = try JSONDecoder().decode(NativePage.self, from: value.serializedData(pretty: false)) }
        catch {
            return .blind(MacFourVerbsReply(ok: false,
                text: "raw view · accessibility · The native screen page could not be decoded: \(error.localizedDescription)",
                detail: ["error": .string("screen_page_unavailable")]))
        }
        // Resolve the names and presses the native page actually offers,
        // rather than a same-named decorative element from the raw percept.
        for thing in nativePage.things {
            guard let address = try? JSONValue.parse(Data(thing.address.utf8)),
                  let handle = Self.string(Self.object(address)["handle"]),
                  let index = targets.firstIndex(where: { $0.handle == handle }) else { continue }
            targets[index].label = thing.name
            if thing.verbs.contains("press") { targets[index].actions = ["AXPress"] }
        }
        var nativeBlocks = Self.array(output["native_page_blocks"]).map(Self.object)
        if let nativeAXSupplement {
            do { try Self.addingNativeAX(nativeAXSupplement, to: &nativePage, blocks: &nativeBlocks, targets: targets, frameID: frameId) }
            catch {
                return .blind(MacFourVerbsReply(ok: false,
                    text: "raw view · accessibility · The supplemental native surfaces could not be compiled: \(error.localizedDescription)",
                    detail: ["error": .string("screen_page_unavailable")]))
            }
        }
        let fullNativeText = nativePage.text
        var nativeZoomNote: String?
        if let part, Self.string(Self.object(output["seam"])["scope_name"]) == part {
            nativeZoomNote = "Read the named native section; its action addresses are unchanged."
        } else if let part {
            var page = nativePage
            let blocks = nativeBlocks
            var scopePaths: [[Int]] = []
            var scopeAddresses: Set<String> = []
            if case .hit(let target) = Self.resolve(part, among: targets) {
                if let path = target.sourceAXPath { scopePaths = [path] }
                else if let ordinal = target.roleOrdinal {
                    let selector = "\(target.kind) \(ordinal)"
                    for block in blocks where Self.string(block["target"]) == selector {
                        if let address = Self.string(block["address"]) { scopeAddresses.insert(address) }
                    }
                }
            } else if let zoom, zoom.scope == .controls {
                scopePaths = zoom.screen.controls.compactMap(\.sourceAXPath)
            } else if let zoom, zoom.scope == .readouts {
                let text = Set(zoom.screen.values.compactMap { $0.text.display })
                scopePaths = percept.readouts.filter { $0.displayText.map(text.contains) ?? false }.map(\.path)
            }
            if scopePaths.isEmpty {
                let needle = Self.normalize(part)
                scopePaths = blocks.compactMap { block in
                    guard let text = Self.string(block["text"]),
                          Self.normalize(text.trimmingCharacters(in: CharacterSet(charactersIn: "# \n"))) == needle else { return nil }
                    return Self.path(block["path"])
                }
            }
            if !scopePaths.isEmpty || !scopeAddresses.isEmpty {
                let selected = blocks.enumerated().filter { index, block in
                    if index < 2 { return true }
                    if let address = Self.string(block["address"]), scopeAddresses.contains(address) { return true }
                    let path = Self.path(block["path"])
                    return !path.isEmpty && scopePaths.contains { path.starts(with: $0) || $0.starts(with: path) }
                }.compactMap { Self.string($0.element["text"]) }
                page.text = selected.joined(separator: "\n")
                page.things = page.things.filter { page.text.contains("[" + SenseScreenThings.printed($0.address) + "]") }
                nativePage = page
                nativeZoomNote = "Read the named native section; its action addresses are unchanged."
            } else {
                if zoom?.scope == .visual {
                    page.text = blocks.prefix(2).compactMap { Self.string($0["text"]) }.joined(separator: "\n")
                    page.things = []
                    nativePage = page
                    nativeZoomNote = "Read the observed visual surface; its existing name and region targets are unchanged."
                } else {
                    nativeZoomNote = "No native section is named \"\(part)\"; this is the whole page."
                }
            }
        }
        let pixelText = MacScreenRender.pixelEvidence(zoom?.screen ?? full)
        let fullPixelText = MacScreenRender.pixelEvidence(full)
        let pageText = (nativeZoomNote.map { $0 + "\n" } ?? "") + nativePage.text + pixelText
        let renderedText = (rendererNote.map { $0 + "\n" } ?? "")
            + Self.runningAppsLine(output)
            + pageText
            + (cutLine.map { $0 + "\n" } ?? "") + (pointerLine.map { "\n" + $0 } ?? "")
        var pageDetail: [String: JSONValue] = [:]
        do {
            var page = nativePage
            page.text = renderedText
            do { pageDetail["native_page"] = try JSONValue.parse(JSONEncoder().encode(page)) }
            catch {
                return .blind(MacFourVerbsReply(ok: false,
                    text: "raw view · accessibility · The native screen page could not be encoded: \(error.localizedDescription)",
                    detail: ["error": .string("screen_page_unavailable")]))
            }
        }
        if let name = percept.app?.name {
            // A scroll bar's thumb is a raw position (Freeform · 0.3936617029400535 on
            // home, walk 6), not something the window says: home never shows it.
            sightRecorder?.record(app: name, kind: windowKind,
                                  readouts: percept.readouts.filter { $0.role != "AXValueIndicator" }.compactMap(\.displayText))
        }
        return .seen(Sighting(
            render: renderedText,
            effectRender: ([MacScreenPageCompiler.actLine(frameID: frameId), SenseScreenThings.accessibilityReadLine]
                .reduce(fullNativeText) { $0.replacingOccurrences(of: "\n" + $1, with: "") } + fullPixelText)
                .replacingOccurrences(of: frameId, with: "<frame>"),
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
            zoomNote: nativeZoomNote ?? zoom?.note,
            controls: .object([
                "frame_id": .string(frameId),
                "app": output["app"] ?? .null,
                "front": output["front"] ?? .bool(false),
                "affordances": output["affordances"] ?? .array([]),
                "affordances_truncated": output["affordances_truncated"] ?? .bool(false),
                "affordances_omitted": output["affordances_omitted"] ?? .int(0),
            ]),
            detail: [
                "partial": .bool(cutLine != nil),
                "truncation_reasons": .array(percept.truncationReasons.map(JSONValue.string)),
                "bytes": .int(Int64(renderedText.utf8.count)),
                "rows_dropped": .int(0),
                "controls_dropped": .int(0),
                "semantic_targets_omitted": .int(Int64(percept.affordancesOmitted)),
            ].merging(pageDetail) { _, new in new }
                .merging(rendererNote.map { ["renderer_wait_note": JSONValue.string($0)] } ?? [:]) { current, _ in current }
                .merging(supplementalDiagnostics) { current, _ in current },
            frontmostApp: {
                let front = Self.object(output["frontmost_app"])
                guard let name = Self.string(front["name"]),
                      let pid = Self.int(front["pid"]).flatMap(Int32.init(exactly:)), pid > 0 else { return nil }
                return (name, pid, front["window"])
            }(),
            windowKind: windowKind,
            focusPath: percept.focus?.path,
            editableHandles: {
                // Password fields never count, whatever their role says.
                let fieldRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
                let secure = Set(percept.affordances.filter {
                    $0.role == "AXSecureTextField" || $0.subrole == "AXSecureTextField"
                }.map(\.handle))
                var editable = Set(percept.affordances.filter {
                    fieldRoles.contains($0.role) || $0.subrole == "AXSearchField"
                }.map(\.handle)).subtracting(secure)
                if let focus = percept.focus, let handle = focus.handle,
                   fieldRoles.contains(focus.role), !secure.contains(handle) { editable.insert(handle) }
                return editable
            }(),
            focusSecure: {
                guard let focus = percept.focus else { return true }
                let read = percept.affordances.first { $0.path == focus.path }
                // A text field whose subrole this read never saw may be a password field.
                if read == nil, ["AXTextField", "AXComboBox"].contains(focus.role) { return true }
                return MacScreenViewBuilder.isSecretField(role: focus.role, subrole: nil, label: focus.label)
                    || read.map {
                        $0.secret || MacScreenViewBuilder.isSecretField(role: $0.role, subrole: $0.subrole, label: $0.label)
                    } == true
            }()
        ))
    }

    static func ownAppRoute(verb: String? = nil, target: String = "", text: String? = nil) -> MacFourVerbsReply {
        var input: [String: JSONValue] = ["page": .string("current")]
        let verb = verb?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var executable = verb == nil
        if verb == "type", ["composer", "message", "message box", "draft"].contains(target), let text {
            input = ["action": .string("chat.draft"), "args": .object(["value": .string(text)])]
            executable = true
        } else if let verb, ["click", "navigate", "open"].contains(verb) {
            // The app resolves page names against its canonical rail catalog.
            input = ["action": .string("page.show"), "args": .object(["page": .string(target)])]
            executable = true
            if ["send", "send button"].contains(target) {
                input = ["action": .string("chat.send")]
            } else if let card = ["trust", "model", "think", "context"].first(where: {
                target == $0 || target == "\($0) card"
            }) {
                input = ["action": .string("chat.open_card"), "args": .object(["card": .string(card)])]
            }
        }
        return MacFourVerbsReply(
            ok: false,
            text: "This is my own app. Use app with the input in next_action to \(executable ? "work in process" : "inspect its available controls; this gesture has no in-process equivalent").",
            detail: ["status": .string("in_process_route"),
                     "execute_in_process": .bool(executable),
                     "next_action": .object(["tool": .string("app"), "input": .object(input)])]
        )
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
