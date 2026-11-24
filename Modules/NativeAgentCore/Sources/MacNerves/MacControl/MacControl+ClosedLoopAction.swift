import Foundation
import NativeAgentShared
import NativeAgentCore
import DeskCore
import PersistenceCore
import AppKit
import ApplicationServices
import CoreGraphics
import UserNotifications
// Blueprint: | `MacControl+ClosedLoopAction.swift` | `SwiftNativeMacControl.handleAct`, `MacClosedLoopAct`, `MacActGate`: Same-window live identity and per-step declared effects; the act's outline over its admission gates and effect stages, and the state they share |

extension SwiftNativeMacControl {
    struct MacActPerformed {
        var ok: Bool
        var method: String
        var requestedAction: String

        var error: String?
        /// Dismissal acts on the modal button, which can differ from the handle originally named.
        var target: MacAXActTarget
        var postState: MacAXActTarget?
        var actedHandle: String
        var extra: [String: JSONValue] = [:]
        var expectedText: String? = nil
        var textBeforeWrite: String? = nil
    }

    /// What one `act` call asked for, its fields parsed.
    struct MacActRequest {
        let verb: MacActVerb
        let handle: String
        let frameId: String
        let text: String?
        let typeMode: MacTypeMode
        let direction: MacActScrollDirection
        let scrollAmount: Int
        let waitMs: Int
        let background: Bool
    }

    /// An admission gate of `handleAct` either refuses the act or hands on what it admitted.
    enum MacActGate<Admitted> {
        case refused(MacControlResult)
        case admitted(Admitted)
    }

    /// One `act` call's living state once its target is admitted: the request, the frame, window and live target it acts on, the effect
    /// baseline and observer, then the settled read and the receipt being written. The effect stages read and write it; it lives for one call
    /// and never crosses isolation.
    final class MacClosedLoopAct {
        let body: [String: JSONValue]
        let started: Date
        let verb: MacActVerb
        let handle: String
        let text: String?
        let typeMode: MacTypeMode
        let direction: MacActScrollDirection
        let scrollAmount: Int
        let waitMs: Int
        let background: Bool
        let frontBefore: MacAXAppInfo?
        let entry: MacLookFrameEntry
        let frame: MacLookFrame
        let framePid: Int32
        let actWindows: [MacAXWindowRef]
        let actWindow: MacAXWindowRef
        let identityScoped: MacAXRead
        let live: MacLookAffordance
        let target: MacAXActTarget
        let placement: MacSavePanelPlacement?
        let entrySecret: Bool
        let effectAffordanceCap: Int
        let effectBefore: MacLookFrame
        let collector = MacAXEffectCollector()
        var observation: (any MacAXEffectObservation)?
        var observerInstalled = false
        var read: MacAXRead?
        var postEffect: (percept: MacLookPercept, diff: MacActClosedLoop.EffectDiff, caps: MacLookCompileCaps)?
        var seam: [String: JSONValue] = [:]
        var postAnchor: MacAnchoredRead?
        var menuLeftOpen: Bool?
        var settledTarget: MacAXActTarget?
        var settledVerdict = MacActClosedLoop.ActClassification(status: "acted_unobserved", reason: "effect_unreadable")
        var effect: [String: JSONValue] = [:]
        var output: [String: JSONValue] = [:]

        init(body: [String: JSONValue], started: Date, request: MacActRequest, frontBefore: MacAXAppInfo?, entry: MacLookFrameEntry,
             frame: MacLookFrame, framePid: Int32, actWindows: [MacAXWindowRef], actWindow: MacAXWindowRef, identityScoped: MacAXRead,
             live: MacLookAffordance, target: MacAXActTarget, placement: MacSavePanelPlacement?, entrySecret: Bool, effectAffordanceCap: Int,
             effectBefore: MacLookFrame) {
            self.body = body
            self.started = started
            self.verb = request.verb
            self.handle = request.handle
            self.text = request.text
            self.typeMode = request.typeMode
            self.direction = request.direction
            self.scrollAmount = request.scrollAmount
            self.waitMs = request.waitMs
            self.background = request.background
            self.frontBefore = frontBefore
            self.entry = entry
            self.frame = frame
            self.framePid = framePid
            self.actWindows = actWindows
            self.actWindow = actWindow
            self.identityScoped = identityScoped
            self.live = live
            self.target = target
            self.placement = placement
            self.entrySecret = entrySecret
            self.effectAffordanceCap = effectAffordanceCap
            self.effectBefore = effectBefore
        }
    }

    /// Return the declared-effect verdict with fresh perception; notifications only wake reads. Frame handles grant no authority, and explicit replays still
    /// consume a body-bound capability after normal admission.
    func handleAct(_ body: [String: JSONValue], turn: Turn, context: MacOperationContext) async -> MacControlResult {
        let started = now()

        // Admission (MacControl+ClosedLoopAction+Admission.swift): each gate refuses before anything is touched.
        let request: MacActRequest
        switch parseActRequest(body) {
        case .refused(let refusal): return refusal
        case .admitted(let admitted): request = admitted
        }
        let frontBefore = accessibilitySource(context: context).frontmostApp()

        let anchor: (entry: MacLookFrameEntry, frame: MacLookFrame, framePid: Int32)
        switch await anchorActFrame(body, handle: request.handle, frameId: request.frameId, started: started, turn: turn, context: context) {
        case .refused(let refusal): return refusal
        case .admitted(let admitted): anchor = admitted
        }
        let windows: (actWindows: [MacAXWindowRef], actWindow: MacAXWindowRef)
        switch matchActWindow(handle: request.handle, frame: anchor.frame, framePid: anchor.framePid, context: context) {
        case .refused(let refusal): return refusal
        case .admitted(let admitted): windows = admitted
        }
        let identity: (identityLimits: MacAXLimits, identityRead: MacAXRead, identityScoped: MacAXRead, identityPercept: MacLookPercept)
        switch await readActIdentity(body, handle: request.handle, frame: anchor.frame, framePid: anchor.framePid, context: context) {
        case .refused(let refusal): return refusal
        case .admitted(let admitted): identity = admitted
        }
        let resolved: (live: MacLookAffordance, target: MacAXActTarget)
        switch resolveActTarget(entry: anchor.entry, handle: request.handle, frame: anchor.frame, framePid: anchor.framePid,
                                actWindow: windows.actWindow, identityScoped: identity.identityScoped, identityPercept: identity.identityPercept,
                                verb: request.verb, context: context) {
        case .refused(let refusal): return refusal
        case .admitted(let admitted): resolved = admitted
        }
        let fresh: (placement: MacSavePanelPlacement?, entrySecret: Bool, entry: MacLookFrameEntry)
        switch refreshActEntry(anchor.entry, verb: request.verb, text: request.text, handle: request.handle, target: resolved.target,
                               identityPercept: identity.identityPercept) {
        case .refused(let refusal): return refusal
        case .admitted(let admitted): fresh = admitted
        }

        // Effect (MacControl+ClosedLoopAction+Effect.swift): baseline, observer, one actuation, the settle, the receipt.
        let baseline = actEffectBaseline(body, started: started, frame: anchor.frame, framePid: anchor.framePid, actWindow: windows.actWindow,
            identityLimits: identity.identityLimits, identityRead: identity.identityRead, identityScoped: identity.identityScoped,
            identityPercept: identity.identityPercept)
        let loop = MacClosedLoopAct(body: body, started: started, request: request, frontBefore: frontBefore, entry: fresh.entry,
            frame: anchor.frame, framePid: anchor.framePid, actWindows: windows.actWindows, actWindow: windows.actWindow,
            identityScoped: identity.identityScoped, live: resolved.live, target: resolved.target, placement: fresh.placement,
            entrySecret: fresh.entrySecret, effectAffordanceCap: baseline.effectAffordanceCap, effectBefore: baseline.effectBefore)
        defer { loop.observation?.stop() }
        if let refusal = installActObserver(loop) { return refusal }

        // Capture pre-input field value so readback can distinguish a change from unchanged state.
        let textBeforeInput = loop.verb == .type ? accessibilityActSource(context: context).reread(loop.target, context: context)?.value : nil
        let performedAt = now()
        let expect: MacBodyNerve.ExpectationKind = loop.verb == .dismiss ? .dismiss : loop.placement != nil ? .sheet : .elementOrSurface
        let held = await MacBodyNerve.holding(loop.actWindow.identity, turn: turn, context: context, background: loop.background,
                                              expect: expect) { () -> (MacActPerformed, Int, MacAXLimits)? in
            guard let performed = await actuateAct(loop, turn: turn, context: context) else { return nil }
            let (signals, effectWaitMs, limits) = await settleActEffect(loop, performed: performed, textBeforeInput: textBeforeInput,
                performedAt: performedAt, turn: turn, context: context)
            signals.stop()
            return (performed, effectWaitMs, limits)
        }
        guard let (performed, effectWaitMs, limits) = held.value else { return actMechanismRefusal(loop) }
        composeActReceipt(loop, performed: performed, performedAt: performedAt, effectWaitMs: effectWaitMs, context: context)
        loop.output.merge(held.receipt) { _, new in new }
        let modal = loop.postEffect?.percept.modal
        let isSheet = modal?.role == kAXSheetRole || modal?.subrole == kAXSheetRole
        if held.receipt["sheet_appeared"] == .bool(true) || (loop.postEffect?.diff.modalAppeared == true && isSheet) {
            loop.output["sheet_appeared"] = .bool(true)
            loop.output["modal_appeared"] = .bool(true)
            if isSheet { loop.output["modal"] = modal?.toJSON(valueChars: limits.valueChars) }
        }

        guard let read = loop.read, let postEffect = loop.postEffect, loop.seam["window_minimized"] != .bool(true) else {
            return await reportActWithoutFrame(loop, performed: performed)
        }
        return await reportActFreshFrame(loop, performed: performed, read: read, postEffect: postEffect, limits: limits, context: context)
    }
}
