// MacCrossAppDrag.swift — two anchors, one drag.
// `to_app` resolves the destination in that app's window; `holding` carries macOS copy/move modifiers.
// Raising is explicit and must not cover the source; secure fields refuse the drag path.
// This owner decides bounded pointer-drag refusals; clipboard transfer uses the clipboard actions.

import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `MacCrossAppDrag.swift` | `MacCrossAppDrag`, `MacFourVerbs.performCrossAppDrag`: two-anchor drag resolution, destination raising and secure/obstructed path refusals with actual-effect evidence |

public enum MacCrossAppDrag {
    // MARK: - The raise

    /// Whether the destination app must be brought forward, and why — decided
    /// ONCE, spoken out loud, and recorded on the receipt.
    ///
    /// Bounded to a single raise on purpose. A drag that needed to reorder
    /// windows twice is not a drag a person could have done either.
    public struct Raise: Sendable, Equatable {
        /// False when the destination app is ALREADY frontmost: then nothing
        /// moves, and the receipt says nothing moved.
        public let needed: Bool
        /// Machine-readable, for the receipt.
        public let reason: String
        /// The sentence User reads when his focus moved.
        public let words: String

        public init(needed: Bool, reason: String, words: String) {
            self.needed = needed
            self.reason = reason
            self.words = words
        }
    }

    public static let raiseReasonAlreadyFront = "destination_already_frontmost"
    public static let raiseReasonDropNeedsWindow = "drop_needs_destination_window_in_front"

    /// `destinationIsFront` is MEASURED — it is the `front` fact the anchored
    /// look published, not an assumption from having named an app.
    public static func raise(destinationApp: String, destinationIsFront: Bool) -> Raise {
        guard !destinationIsFront else {
            return Raise(
                needed: false,
                reason: raiseReasonAlreadyFront,
                words: "\(destinationApp) was already in front, so nothing was raised and focus did not move."
            )
        }
        return Raise(
            needed: true,
            reason: raiseReasonDropNeedsWindow,
            words: "I brought \(destinationApp) to the front for the drop — a window that is behind "
                + "another one cannot receive what is dropped on it — so that is why focus moved."
        )
    }

    // MARK: - Would the raise bury the source?

    /// The union of read target frames is only a lower bound on window coverage.
    /// Use the anchored window frame first; the union may refuse a drag but never aim one.
    public static func bounds(of frames: [MacAXFrame]) -> MacAXFrame? {
        let usable = frames.filter {
            $0.x.isFinite && $0.y.isFinite && $0.w.isFinite && $0.h.isFinite && $0.w > 0 && $0.h > 0
        }
        guard let first = usable.first else { return nil }
        var minX = first.x, minY = first.y
        var maxX = first.x + first.w, maxY = first.y + first.h
        for frame in usable.dropFirst() {
            minX = min(minX, frame.x)
            minY = min(minY, frame.y)
            maxX = max(maxX, frame.x + frame.w)
            maxY = max(maxY, frame.y + frame.h)
        }
        return MacAXFrame(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
    }

    public static let coveredSourceReason = "raise_would_cover_the_source"

    /// True when raising the destination would put its window over the point
    /// the drag has to press down on. `nil` bounds ⇒ false: an unknown must
    /// not become a refusal, and the post-act look still reports what happened.
    public static func raiseWouldCoverSource(
        _ source: MacPointerPosition,
        destinationBounds: MacAXFrame?
    ) -> Bool {
        guard let destinationBounds else { return false }
        return source.isInside(destinationBounds)
    }

    /// The rectangle the coverage guard must test: the destination WINDOW's own
    /// frame when the look published one, and only otherwise the union of what
    /// was read inside it. Written once, here, so both the pre-raise refusal and
    /// the post-raise re-check ask the same question of the same rectangle.
    public static func coverageBounds(
        windowFrame: MacAXFrame?,
        targetFrames: [MacAXFrame]
    ) -> MacAXFrame? {
        windowFrame ?? bounds(of: targetFrames)
    }

    public static let coveredSourceAfterRaiseReason = "raise_covered_the_source"

    public static func coveredSourceAfterRaiseWords(
        source: String,
        destinationApp: String
    ) -> String {
        "Bringing \(destinationApp) forward covered \(source), so dragging stopped. Focus moved; no input was sent or drag performed. Move the windows so both are visible before continuing."
    }

    public static let destinationMovedReason = "destination_moved_during_raise"

    public static func destinationMovedWords(
        _ destination: String,
        in app: String
    ) -> String {
        "After I brought \(app) forward, \"\(destination)\" was no longer where it had been in that "
            + "window, so I did not drag onto a point I could no longer vouch for. Focus moved; no "
            + "input was sent."
    }

    public static func coveredSourceWords(
        source: String,
        destinationApp: String
    ) -> String {
        "\(destinationApp)'s window sits over \(source), so bringing it forward would cover the very "
            + "thing I have to pick up — and I would press the mouse down on \(destinationApp) instead. "
            + "I haven't raised anything or sent input. Move the windows so both are visible at once "
            + "and ask me again."
    }

    // MARK: - Secure input on the path

    /// Reuses `MacActClosedLoop`'s name for the same boundary, so a receipt
    /// reads the same whether typing or the pointer ran into it.
    public static var secureCrossingReason: String { MacActClosedLoop.secureFieldReason }

    /// The rendered kind a secure text field carries. Derived from the renderer
    /// rather than spelled out, so the two cannot drift apart.
    public static var secureKind: String { MacScreenRender.kindName(role: "AXSecureTextField") }

    public static func isSecureKind(_ kind: String) -> Bool { kind == secureKind }

    /// What this refusal already did, said as it is: a raise that happened
    /// is never denied.
    static func effectsSoFar(raised app: String?) -> String {
        app.map { "I brought \($0) to the front; I sent no input." } ?? "I haven't raised anything or sent input."
    }

    public static func destinationIsSecureWords(destination: String, raised: String? = nil) -> String {
        "\(destination) is a password field. I don't drop anything into a credential box — that one "
            + "is yours to fill. " + effectsSoFar(raised: raised)
    }

    public static func pathCrossesSecureWords(destinationApp: String, raised: String? = nil) -> String {
        "The straight line this drag would travel passes over a password field on the way to "
            + "\(destinationApp), and a drag that crosses one can spring it open or drop into it. "
            + effectsSoFar(raised: raised) + " Move the windows apart, or close that "
            + "field, and ask me again."
    }

    // MARK: - Refusals the two anchors can produce

    // Cross-app refusals may name the app/window and a capped names-only disambiguation list.
    // They must not disclose the background render, values, readouts or frames.

    /// How many names a cross-app destination refusal may read back.
    public static let maxDisclosedNames = 5
    /// How long one of those names may be before it is cut.
    public static let maxDisclosedNameChars = 60

    /// Names ONLY, trimmed, de-duplicated, cut to length, capped in number.
    /// Every cross-app destination refusal passes its list through this, so the
    /// bound is one function rather than a habit at four call sites.
    public static func disclosableNames(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for raw in names {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let cut = trimmed.count > maxDisclosedNameChars
                ? String(trimmed.prefix(maxDisclosedNameChars)) + "…"
                : trimmed
            guard seen.insert(cut).inserted else { continue }
            out.append(cut)
            if out.count >= maxDisclosedNames { break }
        }
        return out
    }

    public static let unresolvedDestinationReason = "destination_not_in_named_app"

    public static func unresolvedDestinationWords(
        _ destination: String,
        in app: String,
        nearest: [String]
    ) -> String {
        var line = "Nothing in \(app)'s front window is called \"\(destination)\"."
        let names = disclosableNames(nearest)
        if !names.isEmpty {
            line += " Things there I could have dropped onto include: "
                + names.joined(separator: " · ") + "."
        }
        return line + " I haven't raised anything or sent input."
    }

    public static let ambiguousDestinationReason = "destination_ambiguous_in_named_app"

    public static func ambiguousDestinationWords(
        _ destination: String,
        in app: String,
        candidates: [String]
    ) -> String {
        let names = disclosableNames(candidates)
        return "More than one thing in \(app)'s front window matches \"\(destination)\": "
            + names.joined(separator: ", ")
            + ". Which one? I haven't raised anything or sent input."
    }

    public static let destinationNoPointReason = "destination_has_no_physical_point"

    public static func destinationNoPointWords(
        _ destination: String,
        in app: String
    ) -> String {
        "\(app)'s front window names \"\(destination)\" but publishes no safe point on it, so there "
            + "is nowhere for me to let go. I haven't raised anything or sent input."
    }

    public static let destinationObstructedReason = "destination_point_obstructed"

    public static func destinationObstructedWords(in app: String) -> String {
        "The point I would drop on in \(app)'s front window is covered by something in front of it, "
            + "so I haven't raised anything or sent input. Move the obstruction, or name a clear "
            + "part of that window, and ask me again."
    }

    public static let raiseFailedReason = "destination_raise_failed"

    public static func raiseFailedWords(_ app: String, because reason: String?) -> String {
        "I couldn't bring \(app) forward"
            + (reason.map { ": \($0)" } ?? "")
            + ", so I didn't start the drag. Nothing was picked up."
    }

    public static let verbNotDraggableReason = "to_app_needs_drag"

    public static func verbNotDraggableWords(_ verb: String) -> String {
        "`to_app` names the app the DROP lands in, so it only means anything on a drag — not on "
            + "\(verb). Say drag, with `to` naming what to drop onto, or drop `to_app`."
    }

    public static let missingDestinationReason = "to_app_needs_to"

    public static func missingDestinationWords(_ app: String) -> String {
        "You told me which app to drop into (\(app)) but not what to drop onto. Name the thing in "
            + "\(app)'s window with `to`."
    }
}

extension MacFourVerbs {
    // MARK: - Two-anchor drag

    /// Resolve both anchors without focus, refuse unsafe paths, raise once with authority,
    /// revalidate the raised destination, then drag once. Judge the drop against that
    /// destination's pre-drag sight and preserve every focus effect in the receipt.
    func performCrossAppDrag(
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

        // The window itself is a drop target: by its title (resolve already
        // names windows), or by the app's name / "window" when nothing inside
        // is called that.
        func resolveDrop(_ targets: [ActTarget]) -> Resolution {
            let resolved = Self.resolve(destination, among: targets)
            guard case .none = resolved,
                  [destinationApp, anchored.appName ?? destinationApp, "window", "front window"].map(Self.normalize)
                      .contains(Self.normalize(destination)),
                  let window = targets.first(where: { $0.kind == "window" }) else { return resolved }
            return .hit(window)
        }
        // Use `MacCrossAppDrag`'s bounded refusals; disclosing `anchored.render` would expose the background window.
        let endTarget: ActTarget
        switch resolveDrop(anchored.targets) {
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
        guard let end = Self.safeAimPoint(for: endTarget, in: endFrame,
            describedBy: destination) else {
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
        if endTarget.secret {
            return MacFourVerbsReply(
                ok: false,
                text: MacCrossAppDrag.destinationIsSecureWords(
                    destination: Self.spokenName(endTarget, requestedAs: destination)
                ),
                detail: ["error": .string(MacCrossAppDrag.secureCrossingReason)]
            )
        }
        let secureFrames = (before.targets + anchored.targets)
            .filter(\.secret)
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
            guard Self.foregroundRequested else {
                return MacFourVerbsReply(
                    ok: false,
                    text: "I need the screen because the drop needs \(destinationAppName) in front. Nothing was raised or dragged. "
                        + "Only use front:true when the task explicitly asks to bring it forward.",
                    detail: raiseDetail.merging([
                        "error": .string("needs_front"), "status": .string("needs_front"),
                        "needs_front_reason": .string(raise.reason),
                        "raised": .bool(false), "owner_front_changed": .bool(false),
                    ]) { _, new in new }
                )
            }
            // Check the window's own frame: its title bar or blank areas can cover the source without publishing a target.
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

            // Raising can change layout; reread once, resolve the endpoint and recheck coverage before mouse-down.
            // A refusal after focus moved must say so.
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

            guard case .hit(let rereadTarget) = resolveDrop(reread.targets) else {
                return movedRefusal()
            }
            guard let rereadFrame = Self.visiblePortion(
                of: rereadTarget.frame, within: reread.visibleFrame
            ) else { return movedRefusal() }
            guard let rereadPoint = Self.safeAimPoint(
                for: rereadTarget, in: rereadFrame,
                describedBy: destination
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
                .filter(\.secret)
                .compactMap(\.frame)
            if rereadTarget.secret {
                return MacFourVerbsReply(
                    ok: false,
                    text: MacCrossAppDrag.destinationIsSecureWords(
                        destination: Self.spokenName(rereadTarget, requestedAs: destination), raised: destinationAppName
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
                    text: MacCrossAppDrag.pathCrossesSecureWords(destinationApp: destinationAppName, raised: destinationAppName),
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

        // 4. ONE DRAG, through the one pointer tail: the line checked against
        //    the scene its events land in (the destination as raised, and
        //    whatever covers the source), exactly as an ordinary drag is.
        let spokenDestination = Self.spokenName(dropTarget, requestedAs: destination)
        let description = "\(button == "right" ? "Right-dragged" : "Dragged") \(spokenSource) "
            + "into \(destinationAppName) — onto \(spokenDestination). \(raise.words)"
        // The pre-act reading passed here is the DESTINATION window's, taken
        // after the raise when there was one: the post-act look lands on that
        // same window, so the comparison is drop evidence rather than the noise
        // of the window order having changed underneath it.
        // The destination coming forward is part of this drag: once it was
        // raised, IT is the app that must stay in front while the drag posts
        // (any third app taking the front stops the hand).
        let dragFront = raise.needed ? anchoredAfterRaise.pid : Self.requiredFrontPid ?? before.pid
        if raise.needed, dragFront == nil {
            return MacFourVerbsReply(
                ok: false,
                text: "I can't tell which process \(destinationAppName) is after bringing it forward, so I didn't drag.",
                detail: raiseDetail.merging(["raised": .bool(true), "error": .string("front_unknown")]) { current, _ in current }
            )
        }
        return await Self.$requiredFrontPid.withValue(dragFront) {
            await performPointer(
                PhysicalVerb.drag.rawValue, at: start, to: dropPoint, saying: spokenSource, destination: spokenDestination,
                before: anchoredAfterRaise,
                excluding: source.excludedFrames + dropTarget.excludedFrames + before.obstructions,
                seconds: seconds, holding: holding, button: button, attention: attention,
                physicalOnly: dropTarget.physicalOnly, receipt: raiseDetail,
                secrets: (before.targets + anchoredAfterRaise.targets).filter(\.secret).compactMap(\.frame),
                described: description
            )
        }
    }
}
