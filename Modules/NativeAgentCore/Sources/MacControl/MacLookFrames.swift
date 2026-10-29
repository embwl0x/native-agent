import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(AppKit)
import AppKit
import os
import CoreGraphics
import UserNotifications
import Senses
import Experiences
import CryptoKit
import CoreText
import ScreenCaptureKit
#endif
// Blueprint: | `MacLookFrames.swift` | Retained frame values and task-scoped frame store |
/// What a handle resolves back to.
public struct MacLookFrameEntry: Sendable, Equatable {
    public let handle: String
    public let path: [Int]
    public let role: String
    public let label: String?
    public let frame: MacAXFrame?
    /// The BEFORE side of the effect diff. `mac_act`
    /// compares the recorded value/enabled against the post-action percept, so
    /// "the checkbox became checked" is answerable without a second look.
    public let value: String?
    public let enabled: Bool
    /// The act echoes whether the handle was position-derived; drift checks still apply.
    public let ambiguous: Bool
    /// Preserve cohort size for `identityDrift`: removing a sibling can leave token and rect unchanged.
    public let ambiguityNote: String?
    /// Raw text serves identity checks; outbound diffs/acted_element use full-context redacted JSON.
    public let labelJSON: JSONValue?
    public let valueJSON: JSONValue?
    /// The compile did NOT hand this element's text out verbatim — either the
    /// role is a secure field or the redactor's caption/enclosing-group tests
    /// fired (the unlabeled box inside a group titled "CVV"). Carried so the
    /// POST-act read — which has no compile context at all — is redacted on
    /// the same judgement rather than on a context-free second opinion.
    public let secret: Bool
    public init(
        handle: String,
        path: [Int],
        role: String,
        label: String?,
        frame: MacAXFrame?,
        value: String? = nil,
        enabled: Bool = true,
        ambiguous: Bool = false,
        ambiguityNote: String? = nil,
        labelJSON: JSONValue? = nil,
        valueJSON: JSONValue? = nil,
        secret: Bool = false
    ) {
        self.ambiguous = ambiguous
        self.ambiguityNote = ambiguityNote
        self.labelJSON = labelJSON
        self.valueJSON = valueJSON
        self.secret = secret
        self.handle = handle
        self.path = path
        self.role = role
        self.label = label
        self.frame = frame
        self.value = value
        self.enabled = enabled
    }
}
/// The BEFORE side of a readout diff. Keyed by handle when the
/// readout has one, by path otherwise, so "the display now says 390" is
/// answerable from the act's own result.
public struct MacLookReadoutRecord: Sendable, Equatable {
    public let handle: String?
    public let path: [Int]
    public let role: String
    public let text: String?
    /// Diff raw text to detect secret changes; emit only the full-context compile redaction.
    public let textJSON: JSONValue?
    /// The compile declined to hand this text out verbatim.
    public let secret: Bool
    public init(
        handle: String?,
        path: [Int],
        role: String,
        text: String?,
        textJSON: JSONValue? = nil,
        secret: Bool = false
    ) {
        self.handle = handle
        self.path = path
        self.role = role
        self.text = text
        self.textJSON = textJSON
        self.secret = secret
    }
    /// Handle when there is one; the path otherwise. A readout with no handle
    /// is still diffable — it just cannot survive a re-layout, which is the
    /// same honesty the affordance path fallback carries.
    public static func key(handle: String?, path: [Int]) -> String {
        if let handle, !handle.isEmpty { return handle }
        return "path:" + path.map(String.init).joined(separator: ",")
    }
    public var key: String { Self.key(handle: handle, path: path) }
}
/// Compile bounds establish whether affordance censuses are comparable; cap churn is not navigation.
public struct MacLookCompileCaps: Sendable, Equatable {
    /// The walk itself stopped early (node cap, depth cap, unreadable element).
    public let truncated: Bool
    public let maxAffordances: Int?
    public let maxNodes: Int?
    public let maxDepth: Int?
    public init(
        truncated: Bool,
        maxAffordances: Int? = nil,
        maxNodes: Int? = nil,
        maxDepth: Int? = nil
    ) {
        self.truncated = truncated
        self.maxAffordances = maxAffordances
        self.maxNodes = maxNodes
        self.maxDepth = maxDepth
    }
    public func toJSON() -> JSONValue {
        var object: [String: JSONValue] = ["truncated": .bool(truncated)]
        if let maxAffordances { object["max_affordances"] = .int(Int64(maxAffordances)) }
        if let maxNodes { object["max_nodes"] = .int(Int64(maxNodes)) }
        if let maxDepth { object["max_depth"] = .int(Int64(maxDepth)) }
        return .object(object)
    }
}
public struct MacLookFrame: Sendable, Equatable {
    public let frameId: String
    public let capturedAt: Date
    public let appName: String?
    public let bundleId: String?
    public let windowTitle: String?
    public let entries: [String: MacLookFrameEntry]
    // Unrecorded before-state cannot support claims of change.
    /// The target app's pid, so the closed loop can install its AXObserver on
    /// the app she actually looked at rather than whatever is frontmost by the
    /// time the verb runs.
    public let pid: Int32?
    public let focusHandle: String?
    public let hasModal: Bool
    /// Path of the modal recorded in this frame, used to scope `dismiss` to the
    /// sheet's OWN buttons.
    public let modalPath: [Int]?
    /// Before-readouts keyed by handle or path; absent records cannot establish readout changes.
    public let readouts: [String: MacLookReadoutRecord]
    /// Act resolution and post-act reads target this window or refuse; nil leaves only the pid anchor.
    public let windowIdentity: MacAXWindowIdentity?
    /// The bounds THIS frame's compile ran under. nil ⇒ the frame predates the
    /// record (its diff simply cannot claim incomparability rather than
    /// inventing one).
    public let caps: MacLookCompileCaps?
    /// Identity revalidation and post-action reads retain the sight's scope.
    public let completeWindow: Bool
    public init(
        frameId: String,
        capturedAt: Date,
        appName: String?,
        bundleId: String?,
        windowTitle: String?,
        entries: [String: MacLookFrameEntry],
        pid: Int32? = nil,
        focusHandle: String? = nil,
        hasModal: Bool = false,
        modalPath: [Int]? = nil,
        readouts: [String: MacLookReadoutRecord] = [:],
        windowIdentity: MacAXWindowIdentity? = nil,
        caps: MacLookCompileCaps? = nil,
        completeWindow: Bool = false
    ) {
        self.windowIdentity = windowIdentity
        self.readouts = readouts
        self.caps = caps
        self.completeWindow = completeWindow
        self.frameId = frameId
        self.capturedAt = capturedAt
        self.appName = appName
        self.bundleId = bundleId
        self.windowTitle = windowTitle
        self.entries = entries
        self.pid = pid
        self.focusHandle = focusHandle
        self.hasModal = hasModal
        self.modalPath = modalPath
    }
    /// - Parameter rendered: how many affordance rows the caller actually
    ///   SHOWED (the byte budget may have trimmed the tail). Only shown rows
    ///   mint handles — "handles valid for this frame_id" must mean the handles
    ///   she saw, not rows dropped on the way out. nil ⇒ every affordance;
    ///   a glance mints them all and says that `look` lists the addressable controls.
    /// A redaction object carries a secret verdict; a shortened string does not.
    /// The post-act read must inherit only the secret verdict.
    static func withheld(_ json: JSONValue?) -> Bool {
        if case .object = json { return true }
        return false
    }
    public static func entries(
        from percept: MacLookPercept,
        rendered: Int? = nil
    ) -> [String: MacLookFrameEntry] {
        var out: [String: MacLookFrameEntry] = [:]
        let shown = rendered.map { Array(percept.affordances.prefix(max(0, $0))) } ?? percept.affordances
        for affordance in shown where !affordance.handle.isEmpty {
            out[affordance.handle] = MacLookFrameEntry(
                handle: affordance.handle,
                path: affordance.path,
                role: affordance.role,
                label: affordance.label,
                frame: affordance.frame,
                value: affordance.value,
                enabled: affordance.enabled,
                ambiguous: affordance.handleAmbiguous,
                ambiguityNote: affordance.handleAmbiguity,
                labelJSON: affordance.labelJSON,
                valueJSON: affordance.valueJSON,
                secret: affordance.secret
                    || withheld(affordance.labelJSON)
                    || withheld(affordance.valueJSON)
            )
        }
        if let focus = percept.focus, let handle = focus.handle, out[handle] == nil {
            out[handle] = MacLookFrameEntry(
                handle: handle,
                path: focus.path,
                role: focus.role,
                label: focus.label,
                frame: nil,
                // Focus-derived entries carry the compile verdict into outbound removal diffs.
                labelJSON: focus.labelJSON,
                secret: withheld(focus.labelJSON)
            )
        }
        return out
    }
    /// The readouts as they were, so the next act can say what the
    /// display CHANGED TO. Every readout is recorded (a readout is not an act
    /// target, so the "only rows she saw mint handles" rule that governs
    /// `entries` does not apply — this is diff state, not authority).
    public static func readoutRecords(from percept: MacLookPercept) -> [String: MacLookReadoutRecord] {
        var out: [String: MacLookReadoutRecord] = [:]
        for readout in percept.readouts {
            let record = MacLookReadoutRecord(
                handle: readout.handle,
                path: readout.path,
                role: readout.role,
                text: readout.text,
                // The readout diff inherits the compile's full-context verdict.
                textJSON: readout.textJSON,
                secret: withheld(readout.textJSON)
            )
            if out[record.key] == nil { out[record.key] = record }
        }
        return out
    }
    /// Record entries and focus/modal/window state together so effect diffs have a complete frame.
    public static func from(
        percept: MacLookPercept,
        frameId: String,
        capturedAt: Date,
        windowTitle: String?,
        rendered: Int? = nil,
        windowIdentity: MacAXWindowIdentity? = nil,
        caps: MacLookCompileCaps? = nil,
        completeWindow: Bool = false
    ) -> MacLookFrame {
        MacLookFrame(
            frameId: frameId,
            capturedAt: capturedAt,
            appName: percept.app?.name,
            bundleId: percept.app?.bundleIdentifier,
            windowTitle: windowTitle,
            entries: entries(from: percept, rendered: rendered),
            pid: percept.app?.processIdentifier,
            focusHandle: percept.focus?.handle,
            hasModal: percept.modal != nil,
            modalPath: percept.modal?.path,
            readouts: readoutRecords(from: percept),
            windowIdentity: windowIdentity,
            // The walk's own truncation always travels with the frame; the
            // caller adds the caps it asked for (a compile that ran under a
            // lowered max_affordances/max_nodes/max_depth is not comparable
            // with one that did not).
            caps: caps ?? MacLookCompileCaps(truncated: percept.truncated),
            completeWindow: completeWindow
        )
    }
}
public extension MacPerceptionCompiler {
    /// Full-snapshot redaction keyed by path keeps bulk summaries consistent with percept text.
    static func redactedNodeTextMap(_ snapshot: MacAXTreeSnapshot) -> [[Int]: JSONValue] {
        let secretContext = MacScreenViewTextRedaction.nodeSecretContext(snapshot.nodes)
        var out: [[Int]: JSONValue] = [:]
        for node in snapshot.nodes {
            guard let text = node.attributes.title ?? node.attributes.value else { continue }
            if node.attributes.title == nil, MacScreenViewBuilder.isSecretField(
                role: node.attributes.role,
                subrole: node.attributes.subrole,
                label: node.attributes.title
            ) {
                out[node.path] = MacInjectionResultRedaction.redactedSecret(text)
                continue
            }
            out[node.path] = MacScreenViewTextRedaction.redactedNodeString(
                text,
                valueChars: affordanceValueChars,
                frame: node.attributes.frame,
                // A node's own title is its caption for its own value; a node
                // whose TEXT is the title has no caption above itself.
                under: node.attributes.title == text ? nil : node.attributes.title,
                enclosing: MacScreenViewTextRedaction.enclosingKinds(
                    forNodeAt: node.attributes.frame,
                    path: node.path,
                    among: secretContext.enclosingCaptions
                ),
                context: secretContext
            )
        }
        return out
    }
}
/// The task-scoped perceptual frame, modelled exactly on `MacScreenViewStore`
/// and carrying the same three properties:
///
///  • SINGLE SLOT PER SOURCE — "the last look" is the only look whose handles
///    can still be trusted; holding several ids cannot be reasoned around. The
///    workspace and direct `screen`/`act` each have one.
///  • TTL — 180 s. A frame older than that is not a description of the screen.
///  • NO AUTHORITY — `resolve` returns a path and a rect. Action verbs sit
///    behind the same gates the injection tools already clear; a handle can
///    only ever redirect an already-approved act at a better target.
///
/// It is also NOT resident: nothing writes here except a `mac_look` call, and
/// an expired frame is simply refused (and cleared on the next look) rather
/// than being swept by a timer.
@MainActor
public final class MacLookFrameStore {
    public nonisolated static let shared = MacLookFrameStore()
    /// Shared lifetime of semantic handles and fused-view marks.
    public nonisolated static let ttlSeconds: TimeInterval = 180
    public enum ResolveFailure: String, Sendable, Equatable, Error {
        case noFrame = "no_frame"
        case staleFrame = "stale_frame"
        case frameExpired = "frame_expired"
        case unknownHandle = "unknown_handle"
        public var guidance: String {
            switch self {
            case .noFrame:
                return "No screen frame exists. Use mac.look."
            case .staleFrame:
                // Actions return fresh frames; prefer their handles before requesting another look.
                return "That frame is stale. Use the latest frame_id and handles returned by the previous action, or mac.look if none were returned."
            case .frameExpired:
                return "That frame is older than \(Int(MacLookFrameStore.ttlSeconds))s. Use mac.look."
            case .unknownHandle:
                return "That handle is absent from the latest frame. Use a handle from its controls or inspect with mac.look."
            }
        }
    }
    /// Workspace and direct calls have independent slots; every act re-resolves the frame's pid/window.
    @TaskLocal public nonisolated static var source = "direct"
    private var latestBySource: [String: MacLookFrame] = [:]
    private var latest: MacLookFrame? { latestBySource[Self.source] }
    private var publications: [String: LatestRead] = [:]
    public nonisolated init() {}
    private func publication(for source: String) -> LatestRead {
        if let read = publications[source] { return read }
        let read = LatestRead()
        publications[source] = read
        return read
    }
    public func read(
        _ load: @Sendable () async -> (MacControlResult, MacLookFrame?)
    ) async -> MacControlResult {
        let source = Self.source
        do {
            let result = try await publication(for: source).read({
                let result = await load()
                guard result.0.ok, result.1 != nil else { throw MacSnapshotUnavailable(result: result.0) }
                return result
            }) { result in
                if let frame = result.1 { latestBySource[source] = frame }
            }
            return result.0
        } catch { return MacSnapshotUnavailable.result(for: error) }
    }
    /// An act's committed post-effect frame advances the publication boundary.
    public func record(_ frame: MacLookFrame) {
        let source = Self.source
        publication(for: source).write { latestBySource[source] = frame }
    }
    public func latestFrameId() -> String? { latest?.frameId }
    /// The frame with this id if it is the latest of ANY source (ids are UUIDs).
    public func frame(frameId: String) -> MacLookFrame? {
        latestBySource.values.first { $0.frameId == frameId }
    }
    /// True when no held frame is within its TTL — the signal the live seam uses
    /// to decide the Chromium enhanced-AX flag's lifetime is over.
    public func isExpired(now: Date) -> Bool {
        !latestBySource.values.contains { now.timeIntervalSince($0.capturedAt) <= Self.ttlSeconds }
    }
    public func resolve(
        handle: String,
        frameId: String,
        now: Date
    ) -> Result<MacLookFrameEntry, ResolveFailure> {
        guard !latestBySource.isEmpty else { return .failure(.noFrame) }
        guard let latest = frame(frameId: frameId) else { return .failure(.staleFrame) }
        guard now.timeIntervalSince(latest.capturedAt) <= Self.ttlSeconds else {
            return .failure(.frameExpired)
        }
        guard let entry = latest.entries[handle] else { return .failure(.unknownHandle) }
        return .success(entry)
    }
    /// Physical user input or a completed motor action may have moved
    /// everything. Same safety invalidation the view store carries.
    /// A dead frame may sit in either slot; clear both (rare path, safe side).
    public func invalidate() {
        for read in publications.values { read.write {} }
        latestBySource = [:]
    }
}
