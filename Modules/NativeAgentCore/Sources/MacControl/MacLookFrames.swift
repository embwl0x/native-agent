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
// Blueprint: | `MacLookFrames.swift` | LatestRead frame publication, explicit compile bounds and batch snapshots retaining original TTL |
public struct MacLookFrameEntry: Sendable, Equatable {
    public let handle: String
    public let path: [Int]
    public let role: String
    public let label: String?
    public let frame: MacAXFrame?
    /// Retain pre-action values and enabled state so the act reports observed changes without another look.
    public let value: String?
    public let enabled: Bool?
    /// The act echoes whether the handle was position-derived; drift checks still apply.
    public let ambiguous: Bool
    /// Preserve cohort size for `identityDrift`: removing a sibling can leave token and rect unchanged.
    public let ambiguityNote: String?
    /// Raw text serves identity checks; outbound diffs/acted_element use full-context redacted JSON.
    public let labelJSON: JSONValue?
    public let valueJSON: JSONValue?
    /// Carry the full-context secret verdict into post-action reads, which cannot reconstruct compiler context.
    public let secret: Bool
    public init(
        handle: String,
        path: [Int],
        role: String,
        label: String?,
        frame: MacAXFrame?,
        value: String? = nil,
        enabled: Bool? = nil,
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
/// Key pre-action readouts by handle or path so the act itself reports display changes.
public struct MacLookReadoutRecord: Sendable, Equatable {
    public let handle: String?
    public let path: [Int]
    public let role: String
    public let text: String?
    /// Diff raw text to detect secret changes; emit only the full-context compile redaction.
    public let textJSON: JSONValue?
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
    /// Path-only readouts are diffable within observed topology but cannot survive relayout.
    public static func key(handle: String?, path: [Int]) -> String {
        if let handle, !handle.isEmpty { return handle }
        return "path:" + path.map(String.init).joined(separator: ",")
    }
    public var key: String { Self.key(handle: handle, path: path) }
}
/// Compile bounds establish whether affordance censuses are comparable; cap churn is not navigation.
public struct MacLookCompileCaps: Sendable, Equatable {
    /// Early walk termination limits what absence can establish.
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
    // Unrecorded state cannot prove change; retain the observed pid so the act subscribes to the app actually read.
    public let pid: Int32?
    public let focusHandle: String?
    public let hasModal: Bool
    /// Scope dismiss to the recorded modal’s own buttons.
    public let modalPath: [Int]?
    /// Before-readouts keyed by handle or path; absent records cannot establish readout changes.
    public let readouts: [String: MacLookReadoutRecord]
    /// Act resolution and post-act reads target this window or refuse; nil leaves only the pid anchor.
    public let windowIdentity: MacAXWindowIdentity?
    public let caps: MacLookCompileCaps
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
        caps: MacLookCompileCaps,
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
    /// Only rendered affordances mint handles; dropped rows grant no address. A glance mints all and directs callers to look. Only secret verdicts carry into
    /// post-action redaction; shortened strings are not such verdicts.
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
    /// Record every readout for effect diffs; readout history is evidence rather than act authority.
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
        caps: MacLookCompileCaps,
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
            // Compare censuses only under matching walk and compile bounds; lower caps do not prove navigation.
            caps: caps,
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
                // A node’s title captions its value, but title text cannot caption itself.
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
/// One slot per source keeps only the latest look addressable; frames expire after 180 seconds. Handles supply identity, never motor authority; expired frames
/// refuse without a resident timer.
@MainActor
public final class MacLookFrameStore {
    public nonisolated static let shared = MacLookFrameStore()
    /// Semantic handles and fused marks must expire together.
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

    private var latestBySource: [String: MacLookFrame] = [:]
    private func latest(context: MacOperationContext) -> MacLookFrame? { latestBySource[context.frameSource] }
    private var publications: [String: LatestRead] = [:]
    public nonisolated init() {}
    private func publication(for source: String) -> LatestRead {
        if let read = publications[source] { return read }
        let read = LatestRead()
        publications[source] = read
        return read
    }
    public func read(
        context: MacOperationContext, _ load: @Sendable () async -> (MacControlResult, MacLookFrame?)) async -> MacControlResult {
        let source = context.frameSource
        var published = false
        do {
            let result = try await publication(for: source).read({
                let result = await load()
                guard result.0.ok, result.1 != nil else { throw MacSnapshotUnavailable(result: result.0) }
                return result
            }) { result in
                if let frame = result.1 { latestBySource[source] = frame; published = true }
            }
            guard published else {
                return MacControlResult(ok: false, action: result.0.action,
                    output: .object([
                        "frame_id": .null, "frame_current": .bool(false),
                        "message": .string("This look was superseded or invalidated while in flight. Take a fresh look before acting."),
                    ]), error: "look_capture_superseded", durationMs: result.0.durationMs)
            }
            return result.0
        } catch { return MacSnapshotUnavailable.result(for: error) }
    }
    /// An act's committed post-effect frame advances the publication boundary.
    public func record(_ frame: MacLookFrame, context: MacOperationContext) {
        let source = context.frameSource
        publication(for: source).write { latestBySource[source] = frame }
    }
    public func latestFrameId(context: MacOperationContext) -> String? { latest(context: context)?.frameId }
    public func frame(frameId: String, context: MacOperationContext) -> MacLookFrame? {
        if let held = context.batchFrames?[frameId] { return held }
        return latestBySource.values.first { $0.frameId == frameId }
    }
    public func resolve(
        handle: String,
        frameId: String,
        now: Date,
        context: MacOperationContext
    ) -> Result<MacLookFrameEntry, ResolveFailure> {
        guard !latestBySource.isEmpty || context.batchFrames?.isEmpty == false else { return .failure(.noFrame) }
        guard let latest = frame(frameId: frameId, context: context) else { return .failure(.staleFrame) }
        guard now.timeIntervalSince(latest.capturedAt) <= Self.ttlSeconds else {
            return .failure(.frameExpired)
        }
        guard let entry = latest.entries[handle] else { return .failure(.unknownHandle) }
        return .success(entry)
    }
    /// Physical input or completed motor work can invalidate either source; clear both slots.
    public func invalidate() {
        for read in publications.values { read.write {} }
        latestBySource = [:]
    }
}
