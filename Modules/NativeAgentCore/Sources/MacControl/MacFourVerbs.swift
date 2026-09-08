import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - THE FOUR VERBS — screen · act · go · wait (docs/build_plans/four-verbs.md)
//
// User, verbatim: "she needs a live screen to look at and hands to use it, in a
// native LLM way… give her exactly that, that's it nothing more."
//
// Ten acceptance rounds proved the snapshot model wrong. `mac_look` hands back a
// `frame_id` and opaque handle tokens; `mac_act` demands both back; and nearly
// every failure lived in that bookkeeping — `stale_frame`, `handle_drifted`,
// `window_not_key` — rather than in the work she was doing. THIS FILE IS THE
// REPLACEMENT SURFACE, and its whole contract is stated in one line:
//
//     SHE NEVER SEES a frame id, a handle token, a drift code, or a refusal she
//     cannot act on.
//
// EYES `screen(part:)` · HANDS `act(verb:target:text:)` · LEGS `go(name:)` ·
// PATIENCE `wait(until:seconds:)`. Nothing else.
//
// ORCHESTRATION, NOT REIMPLEMENTATION. Every one of these four calls the organs
// that already exist, through the client's own public `dispatch`:
//
//   screen → `look` + fused AX/view/vision perception → MacScreenRender
//   act    → semantic `act` when AX can name the target, otherwise the existing
//            hand repertoire aimed at a fused screen region; then a fresh screen
//   go     → `focus_app` or canonical `open_target`; then screen
//   wait   → screen, on a bounded loop against an injectable clock
//
// So there is NO new gate, NO new guard, NO new verdict class and NO second
// resolver here. The honesty and safety layers live BELOW this file and every
// call passes straight through them. What this file adds is exactly two things
// the layers below deliberately do not do: RESOLVE A NAME AGAINST THE SCREEN AT
// THE MOMENT OF ACTING, and SAY THE ANSWER IN WORDS.
//
// NO APP-SPECIFIC LOGIC. Not one branch here tests what app it is looking at
// (feedback_build_the_general_capability). A game is simply a screen whose
// dominant content types as CANVAS.
//
// REDACTION IS NOT RE-IMPLEMENTED HERE, and cannot be bypassed here. Every
// SCREEN-DERIVED string this file prints comes out of `MacScreenRender` via
// `MacScreenText`, carrying the compiler's own redaction verdict (the
// `label`/`value`/`text` JSON the look emitted). A withheld string prints as
// `⟨redacted⟩` and — this is the part that matters for the hands — CANNOT BE
// NAMED: resolution matches only against `display` text, so a control whose
// label redaction withheld is unaddressable by name rather than addressable by
// a secret. The other reply strings are the caller's own target/destination
// and fixed operation guidance; typed text is never echoed.
//
// THE PHYSICAL TIER IS INTERNAL. `act` can move, hover, hold, drag, press keys,
// and aim at regions discovered by the fused screen. Coordinates, view ids, and
// mark ids remain private implementation details; uncertain vision rows stay
// visible but are deliberately not promoted to actionable targets.

// MARK: - The four verbs

public struct MacFourVerbs: Sendable {
    let host: any MacFourVerbsHost
    let clock: any MacFourVerbsClock
    let supplementalSource: (any MacFourVerbsSupplementalPerceptionSource)?
    let options: MacScreenRender.Options
    let namedLocationRoots: [URL]
    /// fable51 item 31 — the two subscriptions `wait` ends on. They are seams
    /// here rather than inside the client because `wait` is the only caller and
    /// because the WAITING is paced by `clock`, which is a seam of this type:
    /// a host that blocked on real time would take the fake clock out of the
    /// loop and make a 60-second budget cost 60 real seconds in a test.
    ///
    /// AUTHORITY, explicitly: subscribing is not perception. Nothing is
    /// installed until the first `sight()` has SUCCEEDED, and that sight goes
    /// through `host.dispatch("look")`, which runs the full gate pre-flight
    /// (accessibility category + an active Full Mac window). A refused look
    /// returns blind before a single observer exists.
    let effectObserverSource: any MacAXEffectObserverSource
    let appActivationSource: any MacAppActivationObserverSource

    public init(
        host: any MacFourVerbsHost,
        clock: any MacFourVerbsClock = SystemMacFourVerbsClock(),
        supplementalSource: (any MacFourVerbsSupplementalPerceptionSource)? = nil,
        options: MacScreenRender.Options = .default,
        namedLocationRoots: [URL]? = nil,
        effectObserverSource: any MacAXEffectObserverSource = defaultMacAXEffectObserverSource(),
        appActivationSource: any MacAppActivationObserverSource = defaultMacAppActivationObserverSource()
    ) {
        self.host = host
        self.clock = clock
        self.supplementalSource = supplementalSource
        self.options = options
        self.namedLocationRoots = namedLocationRoots ?? Self.commonHomeLocationRoots()
        self.effectObserverSource = effectObserverSource
        self.appActivationSource = appActivationSource
    }

}
