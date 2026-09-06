// MacCrossAppDrag.swift — TWO ANCHORS, ONE DRAG (fable51 item 32b).
//
// A drag has always resolved BOTH of its endpoints among the targets of ONE
// sighting — the frontmost window (`MacFourVerbs.performPhysical`). So "drag
// this file from Finder into the Mail compose window" could not be SAID, let
// alone done: the only way to reach Mail was `go Mail`, which steals focus and
// destroys the sighting the source was named in.
//
// Item 32a gave the eyes a second anchor (`screen(app:)` reads a named app's
// front window without activating it). This is the hands catching up: the
// DESTINATION endpoint of a drag may be resolved in a NAMED app's front window
// through that same background sight, and the drag then runs across the two.
//
// WHAT THIS FILE IS: the pure decisions. Pure so every one of them is testable
// without a window server, and so each refusal is a SENTENCE rather than an
// empty result:
//
//   • the RAISE decision — whether the destination app has to come forward for
//     the drop to land, and the words that say so. Focus moving on User's
//     screen is a real cost; it is never silent and never incidental.
//   • the COVERAGE refusal — raising the destination over the source point
//     would bury the very thing the drag has to pick up. Better to say that
//     than to press the mouse down on the wrong window.
//   • the SECURE-INPUT refusal — a drag whose path crosses a password field
//     is a drag that can drop a payload into a credential box, or spring-load
//     one open on the way past. Same boundary `MacActClosedLoop` draws for
//     `type`, drawn again for the pointer.
//
// NOT HERE: clipboard-shaped copying. `clipboard_read`/`clipboard_write`
// already carry text across apps (item 30) and this must not become a second,
// worse route to the same place. This is about POINTER DRAGS of targets
// accessibility can name — a file onto a compose window, a layer onto a
// canvas — which no clipboard can express.
//
// NO NEW VERBS. `drag` is the verb; `to_app` names whose window the `to`
// target lives in. Copy-versus-move stays where macOS itself puts it — the
// modifier held during the drag — which `act`'s existing `holding` already
// carries, and which composes with this for free.

import Foundation
import NativeAgentCore
import PersistenceCore

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

    /// The rectangle everything visible in a window occupies, as the union of
    /// its targets' frames. A FLOOR under the window's real rectangle, derived
    /// from what was actually read — used only when the look could not publish
    /// the window's own frame, and only ever to REFUSE, never to aim.
    ///
    /// gpt-5.5 review — this union is NOT the window. A window with a title bar,
    /// a toolbar, or blank space over the source point has no target there, so
    /// the union misses it, the guard passes, and the post-raise mouse-down
    /// lands on the destination window instead of on the thing being picked up.
    /// `Sighting.windowFrame` now carries the anchored window's OWN rectangle
    /// and is what the guard asks first; this remains the fallback for a host
    /// that publishes no window frame.
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
        "I brought \(destinationApp) forward for the drop and its window landed over \(source) — "
            + "so pressing the mouse down would have hit \(destinationApp), not the thing I was "
            + "asked to pick up. I stopped there: focus moved, no input was sent and nothing was "
            + "dragged. Move the windows so both are visible at once and ask me again."
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

    public static func destinationIsSecureWords(destination: String) -> String {
        "\(destination) is a password field. I don't drop anything into a credential box — that one "
            + "is yours to fill. I haven't raised anything or sent input."
    }

    public static func pathCrossesSecureWords(destinationApp: String) -> String {
        "The straight line this drag would travel passes over a password field on the way to "
            + "\(destinationApp), and a drag that crosses one can spring it open or drop into it. "
            + "I haven't raised anything or sent input. Move the windows apart, or close that "
            + "field, and ask me again."
    }

    // MARK: - Refusals the two anchors can produce

    // gpt-5.5 review — WHAT A CROSS-APP REFUSAL MAY SAY.
    //
    // These refusals are about a window User did NOT bring forward and may not
    // even be able to see. They used to append the anchored render — the whole
    // window, its rows, its readouts, its values — plus an unbounded near-miss
    // list, which turned "drop this onto a thing that isn't there" into a way
    // to READ any running app's front window by naming a target that cannot
    // match. The line these draw now:
    //
    //   • the APP and its WINDOW may be named — the caller named the app, and
    //     the window title is what `screen(app:)` already answers with;
    //   • a DISAMBIGUATION list may be returned, capped and names only, because
    //     a refusal a model cannot recover from is a refusal it retries forever;
    //   • nothing else. No render, no values, no readouts, no frames.

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
