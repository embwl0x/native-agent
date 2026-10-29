import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MacFourVerbs+PhysicalActions.swift` | `MacFourVerbs`: `performPhysical`, `performPointer`, `performAtPlace` |

extension MacFourVerbs {
    enum PhysicalVerb: String, CaseIterable {
        case hover
        case drag
        case hold
        case key
        case move
        /// A real double-click (click count 2 on both events) at the named thing.
        case doubleClick = "double_click"
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
        attention: BurstAttention?,
        /// A read already taken for this act; nil reads afresh.
        carried: Sighting? = nil
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
            let before: Sighting?
            var observedPid = Self.requiredFrontPid
            let sighted: Sighted = if let carried { .seen(carried) } else { await sight(part: nil) }
            switch sighted {
            case .blind(let reply):
                // The front app with every window closed still takes keys
                // (cmd+n is how a window comes back).
                guard Self.string(reply.detail["error"]) == "no_frontmost_window" else { return reply }
                before = nil
                observedPid = observedPid ?? Self.int(Self.object(reply.detail["frontmost_app"])["pid"]).flatMap(Int32.init(exactly:))
            case .seen(let seen): before = seen; observedPid = observedPid ?? seen.pid
            }
            var body: [String: JSONValue] = [
                "gesture": .string(verb == .hold ? "hold_key" : "key"),
                "keys": .string(spec),
            ]
            if let seconds { body["seconds"] = .double(seconds) }
            if let holding { body["holding"] = .string(holding) }
            return await Self.$requiredFrontPid.withValue(observedPid) { await performHand(
                body: body,
                description: verb == .hold ? "Held \(target)." : "Pressed \(target).",
                attention: attention,
                before: before
            ) }
        }

        var before: Sighting
        let sighted: Sighted = if let carried { .seen(carried) } else { await sight(part: nil) }
        switch sighted {
        case .blind(let reply): return reply
        case .seen(let seen): before = seen
        }
        let acquisition = await reacquireSight(for: target, sighting: &before) {
            if case .none = Self.resolve(target, among: $0) { return true }
            return false
        }
        if let reply = acquisition.reply { return reply }
        var reobservedAfterTransientMiss = acquisition.samples > 0
        if !reobservedAfterTransientMiss,
           verb == .drag,
           // A cross-app destination resolves in its own anchored sight, not a refreshed source window.
           destinationApp == nil,
           let destination {
            // A drag needs two current points. If only its moving destination
            // dropped out, refresh the entire sight and resolve both ends
            // again so an old source coordinate is never paired with a fresh
            // destination.
            let acquisition = await reacquireSight(for: destination, sighting: &before) {
                guard case .hit = Self.resolve(target, among: $0),
                      case .none = Self.resolve(destination, among: $0) else { return false }
                return true
            }
            if let reply = acquisition.reply { return reply }
            reobservedAfterTransientMiss = acquisition.samples > 0
        }
        let source: ActTarget
        switch Self.resolve(target, among: before.targets) {
        case .hit(let hit): source = hit
        case .none(let nearest):
            return unresolvedPhysical(target, nearest: nearest, screen: before.render)
        case .ambiguous(let candidates):
            return ambiguousPhysical(target, candidates: candidates, screen: before.render)
        }
        guard source.enabled else {
            return MacFourVerbsReply(ok: false, text: "\(Self.name(source)) is disabled.\n" + before.render)
        }
        // These are explicitly physical gestures, so a visible region is a
        // valid pointer-hold target just as it is a drag target. Semantic
        // clicks still require an inner object in actOnce; point/path safety
        // and balanced release remain the same for every physical gesture.
        guard let sourceFrame = Self.visiblePortion(of: source.frame, within: before.visibleFrame) else {
            return MacFourVerbsReply(
                ok: false,
                text: "I can name \(Self.name(source)), but this screen did not publish a safe physical point for it.\n"
                    + before.render,
                detail: ["error": .string("target_has_no_physical_point")]
            )
        }
        guard let start = Self.safeAimPoint(for: source, in: sourceFrame,
            describedBy: target) else {
            return Self.obstructedPointReply(screen: before.render)
        }
        let spokenSource = Self.spokenName(source, requestedAs: target)
        if verb == .drag, source.secret {
            return MacFourVerbsReply(
                ok: false, text: "I can't drag from a password field. No input was sent.",
                detail: ["error": .string(MacCrossAppDrag.secureCrossingReason)]
            )
        }

        // Resolve the destination in its named app without changing focus; retain the source anchor.
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

        var end: MacPointerPosition?
        var spokenEnd: String?
        var excluded: [MacAXFrame] = []
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
            if endTarget.secret {
                return MacFourVerbsReply(
                    ok: false,
                    text: MacCrossAppDrag.destinationIsSecureWords(
                        destination: Self.spokenName(endTarget, requestedAs: destination)
                    ),
                    detail: ["error": .string(MacCrossAppDrag.secureCrossingReason)]
                )
            }
            guard let endFrame = Self.visiblePortion(of: endTarget.frame, within: before.visibleFrame) else {
                return MacFourVerbsReply(
                    ok: false,
                    text: "I can name \(Self.name(endTarget)), but it has no safe physical point.\n" + before.render,
                    detail: ["error": .string("destination_has_no_physical_point")]
                )
            }
            guard let point = Self.safeAimPoint(for: endTarget, in: endFrame,
                describedBy: destination) else {
                return Self.obstructedPointReply(screen: before.render)
            }
            end = point
            spokenEnd = Self.spokenName(endTarget, requestedAs: destination)
            excluded = source.excludedFrames + endTarget.excludedFrames
        }
        return await performPointer(
            verb.rawValue, at: start, to: end, saying: spokenSource, destination: spokenEnd,
            before: before, excluding: excluded, seconds: seconds, holding: holding, button: button,
            attention: attention, physicalOnly: source.physicalOnly,
            pointerTarget: (verb == .hover || verb == .move) ? target : nil,
            receipt: reobservedAfterTransientMiss ? ["dynamic_reobserved": .bool(true)] : [:]
        )
    }

    /// The one physical tail, once both ends are screen points, for a named
    /// act, a place on an image and a watch's frame alike: a drag's line clear
    /// of password fields, both ends and the line clear of anything covering
    /// the window, then the hand, with what it did said in words. A watch
    /// passes the secret fields where they are now and `confirm: false`: its
    /// stream is the observation, so no confirming look follows the hand.
    func performPointer(
        _ gesture: String, at start: MacPointerPosition, to end: MacPointerPosition?,
        saying source: String, destination: String?, before: Sighting, excluding excluded: [MacAXFrame] = [],
        seconds: Double?, holding: String?, button: String?, attention: BurstAttention?,
        physicalOnly: Bool = false, pointerTarget: String? = nil, receipt: [String: JSONValue] = [:],
        secrets: [MacAXFrame]? = nil, confirm: Bool = true, pressed: ActTarget? = nil, described: String? = nil
    ) async -> MacFourVerbsReply {
        // A refusal carries the receipt too: what already happened (a raise)
        // stays on record when the pointer itself sends nothing.
        func refused(_ reply: MacFourVerbsReply) -> MacFourVerbsReply {
            MacFourVerbsReply(ok: false, text: reply.text, detail: reply.detail.merging(receipt) { current, _ in current })
        }
        if let end, !MacRegionAim.pathIsClear(from: start, to: end, excluding: secrets ?? before.targets.filter(\.secret).compactMap(\.frame)) {
            return refused(MacFourVerbsReply(
                ok: false,
                text: MacCrossAppDrag.pathCrossesSecureWords(destinationApp: before.appName ?? "this window",
                                                             raised: receipt["raised"] == .bool(true) ? before.appName : nil),
                detail: ["error": .string(MacCrossAppDrag.secureCrossingReason)]
            ))
        }
        guard MacRegionAim.pathIsClear(from: start, to: end ?? start, excluding: excluded + before.obstructions) else {
            return refused(Self.obstructedPointReply(screen: confirm ? before.render : ""))
        }
        var body: [String: JSONValue] = [
            "gesture": .string(gesture),
            "x": .double(start.x),
            "y": .double(start.y),
        ]
        if let end {
            body["to_x"] = .double(end.x)
            body["to_y"] = .double(end.y)
        }
        if gesture == PhysicalVerb.drag.rawValue {
            body["travel_seconds"] = .double(seconds ?? 0)
        } else if let seconds { body["seconds"] = .double(seconds) }
        if let holding { body["holding"] = .string(holding) }
        if let button { body["button"] = .string(button) }
        let right = button == "right"
        let generic = switch gesture {
        case "drag": "\(right ? "Right-dragged" : "Dragged") \(source) to \(destination ?? "there")."
        case "hover": "Hovered over \(source)."
        case "hold": right ? "Held the right button on \(source)." : "Held \(source)."
        case "move": "Moved to \(source)."
        case "double_click": (right ? "Double-right-clicked " : "Double-clicked ") + source + "."
        case "click": (right ? "Right-clicked " : "Clicked ") + source + "."
        default: "Used \(source)."
        }
        let description = described ?? generic
        let reply = await performHand(
            body: body,
            description: description,
            attention: attention,
            before: confirm ? before : nil,
            afterPart: physicalOnly ? "visual surface" : nil,
            pointerTarget: pointerTarget,
            pressed: pressed,
            confirm: confirm
        )
        var detail = reply.detail.merging(receipt) { _, new in new }
        if let button { detail["button"] = .string(button) }
        return MacFourVerbsReply(ok: reply.ok, text: reply.text, detail: detail)
    }

    /// A place on an image she was handed: the image's own frame turns its
    /// pixels into screen points, which must lie in the window in front; then
    /// the same physical tail as a named act. The receipt names the image and
    /// the screen points used.
    func performAtPlace(
        _ place: MacImagePlace, verb: String, seconds: Double?, holding: String?, button: String?,
        before carried: Sighting?, attention: BurstAttention?
    ) async -> MacFourVerbsReply {
        func refused(_ words: String, _ error: String, screen: String? = nil) -> MacFourVerbsReply {
            MacFourVerbsReply(ok: false, text: words + " Nothing was sent." + (screen.map { "\n" + $0 } ?? ""),
                              detail: ["error": .string(error)])
        }
        guard verb == "click" || PhysicalVerb(rawValue: verb).map({ $0 != .key }) == true,
              (place.to != nil) == (verb == PhysicalVerb.drag.rawValue) else {
            return refused("A point takes click, double_click, right_click, hover, hold or move with at:{x,y}, or drag with from:{x,y} and to:{x,y}.",
                           "invalid_point_act")
        }
        guard let frame = MacImageFrames.frame(place.image) else {
            return refused(place.image.map { "I don't hold image \($0) (only this session's last few are kept); look again with screen pixels and point into that." }
                ?? "No image has been handed to me in this session yet; take screen with pixels:true first and point into it.", "unknown_image")
        }
        let geometry = frame.geometry
        guard let start = geometry.screenPoint(imageX: place.at.x, imageY: place.at.y),
              place.to.map({ geometry.screenPoint(imageX: $0.x, imageY: $0.y) != nil }) != false else {
            return refused("That point is outside image \(frame.id), which is \(geometry.pixelWidth)×\(geometry.pixelHeight) px.", "point_outside_image")
        }
        let end = place.to.flatMap { geometry.screenPoint(imageX: $0.x, imageY: $0.y) }
        func spoken(_ point: MacPointerPosition) -> String { "screen point (\(Int(point.x.rounded())), \(Int(point.y.rounded())))" }
        let before: Sighting
        if let carried { before = carried } else {
            switch await sight(part: nil) {
            case .blind(let reply): return reply
            case .seen(let seen): before = seen
            }
        }
        guard let window = before.windowFrame ?? before.visibleFrame else {
            return refused("I can't tell where the window in front is, so I won't point into it.", "front_window_unknown", screen: before.render)
        }
        guard start.isInside(window), end?.isInside(window) != false else {
            return refused("That lands at \(spoken(start))\(end.map { " to " + spoken($0) } ?? ""), outside the window in front (\(before.appName ?? "unknown")), where I haven't looked.",
                           "point_outside_front_window", screen: before.render)
        }
        var receipt: [String: JSONValue] = ["image": .string(frame.id), "screen_point": start.json]
        receipt["screen_to"] = end?.json
        return await performPointer(
            verb, at: start, to: end, saying: spoken(start) + " of " + frame.id, destination: end.map(spoken),
            before: before, seconds: seconds, holding: holding, button: button, attention: attention, receipt: receipt
        )
    }
}
