import Foundation
import NativeAgentCore
import PersistenceCore

extension MacFourVerbs {
    enum PhysicalVerb: String, CaseIterable {
        case hover
        case drag
        case hold
        case key
        case move
    }

    static let physicalScrollKinds: Set<String> = [
        "web area", "scroll area", "scroll bar", "table", "outline", "list", "collection",
    ]

    func performPhysical(
        _ verb: PhysicalVerb,
        target: String,
        destination: String?,
        destinationApp: String? = nil,
        seconds: Double?,
        holding: String?,
        button: String?,
        attention: BurstAttention?
    ) async -> MacFourVerbsReply {
        if verb == .hold, Self.keySpec(target) != nil, holding != nil {
            return MacFourVerbsReply(
                ok: false,
                text: "A keyboard hold already keeps its key set down; include all keys in that target instead of a second held-key set.",
                detail: ["error": .string("nested_hold_not_supported")]
            )
        }
        // Keys are physical but not on-screen targets. A key spec uses the same
        // syntax as mac_keystroke: `w`, `space`, `cmd+s`, `shift+1`.
        if verb == .key || (verb == .hold && Self.keySpec(target) != nil) {
            let spec = Self.keySpec(target) ?? target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spec.isEmpty else {
                return MacFourVerbsReply(ok: false, text: "Which key or chord should I use?")
            }
            let before: Sighting
            switch await sight(part: nil) {
            case .blind(let reply): return reply
            case .seen(let seen): before = seen
            }
            var body: [String: JSONValue] = [
                "gesture": .string(verb == .hold ? "hold_key" : "key"),
                "keys": .string(spec),
            ]
            if let seconds { body["seconds"] = .double(seconds) }
            if let holding { body["holding"] = .string(holding) }
            return await performHand(
                body: body,
                description: verb == .hold ? "Held \(target)." : "Pressed \(target).",
                attention: attention,
                before: before
            )
        }

        var before: Sighting
        switch await sight(part: nil) {
        case .blind(let reply): return reply
        case .seen(let seen): before = seen
        }
        var resolution = Self.resolve(target, among: before.targets)
        var reobservedAfterTransientMiss = false
        if case .none = resolution, Self.isPotentialDynamicVisualReference(target) {
            let temporal = Self.hasTemporalQualifier(target)
            let sampledApp = before.bundleIdentifier ?? before.appName
            var previousTargets = before.targets
            for sample in 0..<(temporal ? 3 : 1) {
                guard case .none = resolution else { break }
                if sample == 2, !Self.canConfirmTemporalTurn(target, previous: previousTargets, current: before.targets) { break }
                switch await resampleSight(temporal: temporal, expectedApp: sampledApp) {
                case .blind(let reply): return reply
                case .seen(let refreshed):
                    previousTargets = before.targets
                    before = refreshed
                    resolution = Self.resolve(target, among: before.targets)
                    reobservedAfterTransientMiss = true
                }
            }
        }
        if !reobservedAfterTransientMiss,
           verb == .drag,
           // fable51 item 32b — a cross-app destination is NOT expected in this
           // window, so "it dropped out of the frontmost sighting" is not a
           // transient miss to chase. Its own anchored sight resolves it.
           destinationApp == nil,
           let destination,
           case .hit = resolution,
           case .none = Self.resolve(destination, among: before.targets),
           Self.isPotentialDynamicVisualReference(destination) {
            // A drag needs two current points. If only its moving destination
            // dropped out, refresh the entire sight and resolve both ends
            // again so an old source coordinate is never paired with a fresh
            // destination.
            let temporal = Self.hasTemporalQualifier(destination)
            let sampledApp = before.bundleIdentifier ?? before.appName
            var previousTargets = before.targets
            for sample in 0..<(temporal ? 3 : 1) {
                guard case .hit = resolution,
                      case .none = Self.resolve(destination, among: before.targets) else { break }
                if sample == 2, !Self.canConfirmTemporalTurn(destination, previous: previousTargets, current: before.targets) { break }
                switch await resampleSight(temporal: temporal, expectedApp: sampledApp) {
                case .blind(let reply): return reply
                case .seen(let refreshed):
                    previousTargets = before.targets
                    before = refreshed
                    resolution = Self.resolve(target, among: before.targets)
                    reobservedAfterTransientMiss = true
                }
            }
        }
        let source: ActTarget
        switch resolution {
        case .hit(let hit): source = hit
        case .none(let nearest):
            return unresolvedPhysical(target, nearest: nearest, screen: before.render)
        case .ambiguous(let candidates):
            return ambiguousPhysical(target, candidates: candidates, screen: before.render)
        }
        guard source.enabled else {
            return MacFourVerbsReply(ok: false, text: "\(Self.name(source)) is disabled.\n" + before.render)
        }
        if source.regionOnly, verb != .hover, verb != .move, verb != .drag {
            return MacFourVerbsReply(
                ok: false,
                text: "\(Self.name(source)) is a region rather than an object I can \(verb.rawValue). I can move to it, hover over it, or drag across it; name a visible thing inside it for other gestures.",
                detail: ["error": .string("region_needs_inner_target")]
            )
        }
        guard let sourceFrame = Self.visiblePortion(of: source.frame, within: before.visibleFrame) else {
            return MacFourVerbsReply(
                ok: false,
                text: "I can name \(Self.name(source)), but this screen did not publish a safe physical point for it.\n"
                    + before.render,
                detail: ["error": .string("target_has_no_physical_point")]
            )
        }
        let exactSourceAlias = source.aliases.contains {
            Self.normalize($0) == Self.normalize(target)
        }
        guard let start = Self.safeAimPoint(for: source, in: sourceFrame,
            describedBy: exactSourceAlias ? "" : target) else {
            return Self.obstructedPointReply(screen: before.render)
        }
        let spokenSource = Self.spokenName(source, requestedAs: target)

        // fable51 item 32b — TWO ANCHORS. The source has just been resolved in
        // the frontmost window; when `to_app` names somebody else's window the
        // destination is resolved THERE, without focus, and the whole drag is
        // handled below. Nothing above this line changed, and with `to_app`
        // absent nothing below it runs.
        if verb == .drag, let destinationApp, let destination {
            return await performCrossAppDrag(
                source: source,
                spokenSource: spokenSource,
                start: start,
                destination: destination,
                destinationApp: destinationApp,
                seconds: seconds,
                holding: holding,
                button: button,
                attention: attention,
                before: before
            )
        }

        var body: [String: JSONValue] = [
            "gesture": .string(verb.rawValue),
            "x": .double(start.x),
            "y": .double(start.y),
        ]
        if verb == .drag {
            body["travel_seconds"] = .double(seconds ?? 0)
        } else if let seconds { body["seconds"] = .double(seconds) }
        if let holding { body["holding"] = .string(holding) }
        if let button { body["button"] = .string(button) }
        var description: String
        if verb == .drag {
            guard let destination, !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return MacFourVerbsReply(ok: false, text: "Where should I drag \(spokenSource) to?")
            }
            let endTarget: ActTarget
            switch Self.resolve(destination, among: before.targets) {
            case .hit(let hit): endTarget = hit
            case .none(let nearest):
                return unresolvedPhysical(destination, nearest: nearest, screen: before.render)
            case .ambiguous(let candidates):
                return ambiguousPhysical(destination, candidates: candidates, screen: before.render)
            }
            guard let endFrame = Self.visiblePortion(of: endTarget.frame, within: before.visibleFrame) else {
                return MacFourVerbsReply(
                    ok: false,
                    text: "I can name \(Self.name(endTarget)), but it has no safe physical point.\n" + before.render,
                    detail: ["error": .string("destination_has_no_physical_point")]
                )
            }
            let exactDestinationAlias = endTarget.aliases.contains {
                Self.normalize($0) == Self.normalize(destination)
            }
            guard let end = Self.safeAimPoint(for: endTarget, in: endFrame,
                describedBy: exactDestinationAlias ? "" : destination) else {
                return Self.obstructedPointReply(screen: before.render)
            }
            guard MacRegionAim.pathIsClear(from: start, to: end,
                excluding: source.excludedFrames + endTarget.excludedFrames) else {
                return Self.obstructedPointReply(screen: before.render)
            }
            body["to_x"] = .double(end.x)
            body["to_y"] = .double(end.y)
            description = "\(button == "right" ? "Right-dragged" : "Dragged") \(spokenSource) to \(Self.spokenName(endTarget, requestedAs: destination))."
        } else {
            switch verb {
            case .hover: description = "Hovered over \(spokenSource)."
            case .hold: description = button == "right" ? "Held the right button on \(spokenSource)." : "Held \(spokenSource)."
            case .move: description = "Moved to \(spokenSource)."
            case .drag, .key: description = "Used \(spokenSource)."
            }
        }
        let reply = await performHand(
            body: body,
            description: description,
            attention: attention,
            before: before,
            allowGenericScreenChangeVerification: !source.physicalOnly,
            afterPart: source.physicalOnly ? "visual surface" : nil,
            pointerTarget: (verb == .hover || verb == .move) ? target : nil
        )
        var detail = reply.detail
        if reobservedAfterTransientMiss { detail["dynamic_reobserved"] = .bool(true) }
        if let button { detail["button"] = .string(button) }
        return MacFourVerbsReply(ok: reply.ok, text: reply.text, detail: detail)
    }

    // MARK: - fable51 item 32b — the two-anchor drag

    /// `act(drag, target:, to:, to_app:)` — the source in the window in front,
    /// the destination in a NAMED app's front window, and one drag across the
    /// two. The order of operations is the whole design:
    ///
    ///   1. RESOLVE the destination through the background sight. No focus
    ///      moves for a resolution, so a refusal here — not running, ambiguous,
    ///      our own process, no such thing in that window — costs User nothing
    ///      and leaves his screen exactly as it was.
    ///   2. REFUSE what must not be dragged: a password field at either end of
    ///      the line, or on it.
    ///   3. RAISE, once, only if the drop needs it, and SAY SO. A window behind
    ///      another cannot receive a drop; that is the reason focus moved, it
    ///      goes in the sentence and on the receipt, and if raising would bury
    ///      the source instead this refuses before anything moves.
    ///   4. DRAG, once.
    ///
    /// The pre-drag reading of the DESTINATION window is what the post-act look
    /// is compared against — so "did the drop land" is judged against the
    /// window that received it, not against the source window we left behind.
    private func performCrossAppDrag(
        source: ActTarget,
        spokenSource: String,
        start: MacPointerPosition,
        destination: String,
        destinationApp: String,
        seconds: Double?,
        holding: String?,
        button: String?,
        attention: BurstAttention?,
        before: Sighting
    ) async -> MacFourVerbsReply {
        // 1. THE SECOND ANCHOR. `sight(app:)` walks that app's front window and
        //    activates nothing; the look handler already answers not-running,
        //    ambiguous and self-process in MacBackgroundSight's own words.
        let anchored: Sighting
        switch await sight(part: nil, app: destinationApp) {
        case .seen(let seen): anchored = seen
        case .blind(let reply):
            let why = Self.string(reply.detail["message"])
            return MacFourVerbsReply(
                ok: false,
                text: "I can't drop into \(destinationApp). "
                    + (why ?? reply.text)
                    + " I haven't raised anything or sent input.",
                detail: reply.detail
            )
        }
        let destinationAppName = anchored.appName ?? destinationApp

        // gpt-5.5 review — EVERY refusal below is about a window User did not
        // bring forward. None of them may print `anchored.render`: that is the
        // whole background window — its rows, its readouts, its values — and
        // appending it to "there is nothing called X here" made a target that
        // cannot match into a way to read any running app's front window.
        // `MacCrossAppDrag` owns the bound; these say the app, the window, and
        // at most a capped list of names.
        let endTarget: ActTarget
        switch Self.resolve(destination, among: anchored.targets) {
        case .hit(let hit): endTarget = hit
        case .none(let nearest):
            return MacFourVerbsReply(
                ok: false,
                text: MacCrossAppDrag.unresolvedDestinationWords(
                    destination, in: destinationAppName, nearest: nearest
                ),
                detail: [
                    "error": .string(MacCrossAppDrag.unresolvedDestinationReason),
                    "destination_app": .string(destinationAppName),
                ]
            )
        case .ambiguous(let candidates):
            return MacFourVerbsReply(
                ok: false,
                text: MacCrossAppDrag.ambiguousDestinationWords(
                    destination, in: destinationAppName,
                    candidates: candidates.map(Self.recoveryName)
                ),
                detail: [
                    "error": .string(MacCrossAppDrag.ambiguousDestinationReason),
                    "destination_app": .string(destinationAppName),
                ]
            )
        }
        guard let endFrame = Self.visiblePortion(of: endTarget.frame, within: anchored.visibleFrame) else {
            return MacFourVerbsReply(
                ok: false,
                text: MacCrossAppDrag.destinationNoPointWords(
                    Self.spokenName(endTarget, requestedAs: destination), in: destinationAppName
                ),
                detail: [
                    "error": .string(MacCrossAppDrag.destinationNoPointReason),
                    "destination_app": .string(destinationAppName),
                ]
            )
        }
        let exactDestinationAlias = endTarget.aliases.contains {
            Self.normalize($0) == Self.normalize(destination)
        }
        guard let end = Self.safeAimPoint(for: endTarget, in: endFrame,
            describedBy: exactDestinationAlias ? "" : destination) else {
            return MacFourVerbsReply(
                ok: false,
                text: MacCrossAppDrag.destinationObstructedWords(in: destinationAppName),
                detail: [
                    "error": .string(MacCrossAppDrag.destinationObstructedReason),
                    "destination_app": .string(destinationAppName),
                ]
            )
        }

        // 2. SECURE INPUT. Dropping into a credential box is the same boundary
        //    `type` refuses at, and a drag that merely CROSSES one can
        //    spring-load it open on the way past. Both ends and the line
        //    between them, before anything is raised.
        if MacCrossAppDrag.isSecureKind(endTarget.kind) {
            return MacFourVerbsReply(
                ok: false,
                text: MacCrossAppDrag.destinationIsSecureWords(
                    destination: Self.spokenName(endTarget, requestedAs: destination)
                ),
                detail: ["error": .string(MacCrossAppDrag.secureCrossingReason)]
            )
        }
        let secureFrames = (before.targets + anchored.targets)
            .filter { MacCrossAppDrag.isSecureKind($0.kind) }
            .compactMap(\.frame)
        guard MacRegionAim.pathIsClear(from: start, to: end, excluding: secureFrames) else {
            return MacFourVerbsReply(
                ok: false,
                text: MacCrossAppDrag.pathCrossesSecureWords(destinationApp: destinationAppName),
                detail: ["error": .string(MacCrossAppDrag.secureCrossingReason)]
            )
        }
        guard MacRegionAim.pathIsClear(from: start, to: end,
            excluding: source.excludedFrames + endTarget.excludedFrames) else {
            return MacFourVerbsReply(
                ok: false,
                text: MacCrossAppDrag.destinationObstructedWords(in: destinationAppName),
                detail: [
                    "error": .string(MacCrossAppDrag.destinationObstructedReason),
                    "destination_app": .string(destinationAppName),
                ]
            )
        }

        // 3. THE RAISE. Measured, not assumed: `anchored.isFront` is the fact
        //    the look published about the window it actually read.
        let raise = MacCrossAppDrag.raise(
            destinationApp: destinationAppName,
            destinationIsFront: anchored.isFront
        )
        var raiseDetail: [String: JSONValue] = [
            "cross_app_drag": .bool(true),
            "destination_app": .string(destinationAppName),
            "destination_resolved_without_focus": .bool(true),
            "raise_reason": .string(raise.reason),
        ]
        if let bundle = anchored.bundleIdentifier {
            raiseDetail["destination_app_bundle"] = .string(bundle)
        }
        // What the drag actually lets go of, and where. Re-derived after the
        // raise (below) because raising re-lays a window: the pre-raise point
        // is a resolution, not yet an aim.
        var dropPoint = end
        var dropTarget = endTarget
        var anchoredAfterRaise = anchored
        if raise.needed {
            // gpt-5.5 review — WHAT COVERS THE SOURCE IS THE WINDOW, not the
            // union of the elements read inside it. A window whose title bar,
            // toolbar or blank body sits over `start` publishes no target there,
            // so the union missed it, this guard passed, and the post-raise
            // mouse-down landed on the destination window instead of on the
            // thing being picked up. Ask the window's own frame first.
            guard !MacCrossAppDrag.raiseWouldCoverSource(
                start,
                destinationBounds: MacCrossAppDrag.coverageBounds(
                    windowFrame: anchored.windowFrame,
                    targetFrames: anchored.targets.compactMap(\.frame)
                )
            ) else {
                return MacFourVerbsReply(
                    ok: false,
                    text: MacCrossAppDrag.coveredSourceWords(
                        source: spokenSource, destinationApp: destinationAppName
                    ),
                    detail: raiseDetail.merging([
                        "raised": .bool(false),
                        "error": .string(MacCrossAppDrag.coveredSourceReason),
                    ]) { current, _ in current }
                )
            }
            let focused: MacControlResult
            do {
                focused = try await host.dispatch(
                    action: "focus_app",
                    body: ["app": .string(destinationAppName)]
                )
            } catch {
                return MacFourVerbsReply(
                    ok: false,
                    text: MacCrossAppDrag.raiseFailedWords(destinationAppName, because: "\(error)"),
                    detail: raiseDetail.merging([
                        "raised": .bool(false),
                        "error": .string(MacCrossAppDrag.raiseFailedReason),
                    ]) { current, _ in current }
                )
            }
            guard focused.ok else {
                return MacFourVerbsReply(
                    ok: false,
                    text: MacCrossAppDrag.raiseFailedWords(destinationAppName, because: focused.error),
                    detail: raiseDetail.merging([
                        "raised": .bool(false),
                        "error": .string(MacCrossAppDrag.raiseFailedReason),
                    ]) { current, _ in current }
                )
            }

            // gpt-5.5 review — LOOK AGAIN BEFORE AIMING. Everything above was
            // resolved against a window that was BEHIND another one. Bringing it
            // forward is a layout event: the window can move, resize, or arrive
            // somewhere it was not, and a point computed before that is a point
            // about a screen that no longer exists. So the destination window is
            // re-read once, the endpoint re-resolved in it, and the coverage
            // question asked again of the frame it actually landed on — and if
            // any of those answers changed, this stops rather than pressing the
            // mouse down on a guess. Focus has moved by then, and each refusal
            // says so.
            let reread: Sighting
            switch await sight(part: nil, app: destinationAppName) {
            case .seen(let seen): reread = seen
            case .blind(let reply):
                return MacFourVerbsReply(
                    ok: false,
                    text: MacCrossAppDrag.destinationMovedWords(destination, in: destinationAppName),
                    detail: raiseDetail.merging([
                        "raised": .bool(true),
                        "raised_app": .string(destinationAppName),
                        "reread_after_raise": .bool(true),
                        "error": .string(MacCrossAppDrag.destinationMovedReason),
                        "reread_error": reply.detail["error"] ?? .string("look_failed"),
                    ]) { current, _ in current }
                )
            }
            anchoredAfterRaise = reread

            func movedRefusal() -> MacFourVerbsReply {
                MacFourVerbsReply(
                    ok: false,
                    text: MacCrossAppDrag.destinationMovedWords(destination, in: destinationAppName),
                    detail: raiseDetail.merging([
                        "raised": .bool(true),
                        "raised_app": .string(destinationAppName),
                        "reread_after_raise": .bool(true),
                        "error": .string(MacCrossAppDrag.destinationMovedReason),
                    ]) { current, _ in current }
                )
            }

            guard case .hit(let rereadTarget) = Self.resolve(destination, among: reread.targets) else {
                return movedRefusal()
            }
            guard let rereadFrame = Self.visiblePortion(
                of: rereadTarget.frame, within: reread.visibleFrame
            ) else { return movedRefusal() }
            let rereadExactAlias = rereadTarget.aliases.contains {
                Self.normalize($0) == Self.normalize(destination)
            }
            guard let rereadPoint = Self.safeAimPoint(
                for: rereadTarget, in: rereadFrame,
                describedBy: rereadExactAlias ? "" : destination
            ) else { return movedRefusal() }

            // The window is in front NOW. If its real frame covers the pick-up
            // point, the mouse-down would land on it — the exact failure the
            // pre-raise guard exists to prevent, asked again of the truth.
            guard !MacCrossAppDrag.raiseWouldCoverSource(
                start,
                destinationBounds: MacCrossAppDrag.coverageBounds(
                    windowFrame: reread.windowFrame,
                    targetFrames: reread.targets.compactMap(\.frame)
                )
            ) else {
                return MacFourVerbsReply(
                    ok: false,
                    text: MacCrossAppDrag.coveredSourceAfterRaiseWords(
                        source: spokenSource, destinationApp: destinationAppName
                    ),
                    detail: raiseDetail.merging([
                        "raised": .bool(true),
                        "raised_app": .string(destinationAppName),
                        "reread_after_raise": .bool(true),
                        "error": .string(MacCrossAppDrag.coveredSourceAfterRaiseReason),
                    ]) { current, _ in current }
                )
            }

            // The secure boundary is re-drawn on the line that will actually be
            // travelled: a raise can bring a password field onto it.
            let rereadSecureFrames = (before.targets + reread.targets)
                .filter { MacCrossAppDrag.isSecureKind($0.kind) }
                .compactMap(\.frame)
            if MacCrossAppDrag.isSecureKind(rereadTarget.kind) {
                return MacFourVerbsReply(
                    ok: false,
                    text: MacCrossAppDrag.destinationIsSecureWords(
                        destination: Self.spokenName(rereadTarget, requestedAs: destination)
                    ),
                    detail: raiseDetail.merging([
                        "raised": .bool(true),
                        "raised_app": .string(destinationAppName),
                        "reread_after_raise": .bool(true),
                        "error": .string(MacCrossAppDrag.secureCrossingReason),
                    ]) { current, _ in current }
                )
            }
            guard MacRegionAim.pathIsClear(
                from: start, to: rereadPoint, excluding: rereadSecureFrames
            ) else {
                return MacFourVerbsReply(
                    ok: false,
                    text: MacCrossAppDrag.pathCrossesSecureWords(destinationApp: destinationAppName),
                    detail: raiseDetail.merging([
                        "raised": .bool(true),
                        "raised_app": .string(destinationAppName),
                        "reread_after_raise": .bool(true),
                        "error": .string(MacCrossAppDrag.secureCrossingReason),
                    ]) { current, _ in current }
                )
            }

            dropTarget = rereadTarget
            dropPoint = rereadPoint
            raiseDetail["reread_after_raise"] = .bool(true)
        }
        raiseDetail["raised"] = .bool(raise.needed)
        if raise.needed { raiseDetail["raised_app"] = .string(destinationAppName) }

        // 4. ONE DRAG.
        var body: [String: JSONValue] = [
            "gesture": .string(PhysicalVerb.drag.rawValue),
            "x": .double(start.x),
            "y": .double(start.y),
            "to_x": .double(dropPoint.x),
            "to_y": .double(dropPoint.y),
            "travel_seconds": .double(seconds ?? 0),
        ]
        if let holding { body["holding"] = .string(holding) }
        if let button { body["button"] = .string(button) }
        let spokenDestination = Self.spokenName(dropTarget, requestedAs: destination)
        let description = "\(button == "right" ? "Right-dragged" : "Dragged") \(spokenSource) "
            + "into \(destinationAppName) — onto \(spokenDestination). \(raise.words)"
        // The pre-act reading passed here is the DESTINATION window's, taken
        // after the raise when there was one: the post-act look lands on that
        // same window, so the comparison is drop evidence rather than the noise
        // of the window order having changed underneath it.
        let reply = await performHand(
            body: body,
            description: description,
            attention: attention,
            before: anchoredAfterRaise,
            allowGenericScreenChangeVerification: !dropTarget.physicalOnly
        )
        var detail = reply.detail
        for (key, value) in raiseDetail { detail[key] = value }
        if let button { detail["button"] = .string(button) }
        return MacFourVerbsReply(ok: reply.ok, text: reply.text, detail: detail)
    }

}
