import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
#if canImport(AppKit)
import AppKit
import ApplicationServices
#endif
// Blueprint: | `MacAppActGate.swift` | The owner's saved Write switch decides every act in its app, Full Mac included (User 10-31); explicit offs and target/authority failures retain their causes; media discovery carries typed failure evidence through admission and execution receipts; named-app admission never waits for a cold index; held chords and System Events retain target checks |

public struct MacAppActRefusal: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public let integration: String?
    public var remedy: JSONValue? = nil
    public var targetDiscovery: JSONValue? = nil

    public var errorDescription: String? { message }
    public var fields: [String: JSONValue] {
        var fields: [String: JSONValue] = ["status": .string("denied"), "reason": .string(code),
            "error": .string(code), "message": .string(message)]
        if let integration {
            fields["integration"] = .string(integration)
            fields["mode"] = .string("write")
            if code == "integration_permission_unavailable" {
                fields["remedy"] = Repair.why(owner: "security/mac_integration_permissions.json", tap: "Trust > Mac",
                    instruction: "Preserve the saved permission bytes and repair the authority before continuing.")
            } else {
                fields["remedy"] = Repair.why(owner: "security/mac_integration_permissions.json \(integration).write",
                    tap: "Trust > Mac > Apps and features > \(MacIntegrationID.displayName(for: integration)) > Write",
                    instruction: "Only the owner can enable this switch.")
            }
        }
        if let remedy { fields["remedy"] = remedy }
        if let targetDiscovery {
            fields["target_discovery"] = targetDiscovery
            fields["effects"] = .string("none")
            fields["status"] = .string("failed")
        }
        return fields
    }
    public func result(action: String) -> MacControlResult {
        MacControlResult(ok: false, action: action, output: .object(fields), error: code, durationMs: 0, httpStatus: targetDiscovery == nil ? 403 : 503)
    }
}

public enum MacAppActGate {
    @TaskLocal public static var dataRoot: URL = defaultDataRoot()
    @TaskLocal public static var fullMacAdmitted = false
    @TaskLocal static var looking = false

    /// Bind the security owner's checked decision for this concrete call.
    public static func withAdmission<T>(origin: SecurityOriginContext, dataRoot: URL,
                                        operation: () async throws -> T) async throws -> T {
        let authority = await SwiftNativeSecurityCenter(dataRoot: dataRoot).fullMacYoloAuthority(origin: origin)
        guard authority.state != .unavailable else { throw SavedTrustPolicyAuthority.unavailable(authority.reason) }
        return try await $dataRoot.withValue(dataRoot) {
            try await $fullMacAdmitted.withValue(authority.admitted, operation: operation)
        }
    }

    /// Modifier-only scrolling can still read; holding an ordinary key can
    /// invoke a command independently of the scroll. Use the executor's parser.
    static func holdingAllowsLooking(_ input: [String: JSONValue]) -> Bool {
        guard let holding = input["holding"], holding != .null else { return true }
        guard let text = holding.stringValue else { return false }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        guard let held = try? MacKeySyntax.parseHeldKeys(text) else { return false }
        return held.keys.isEmpty
    }

    /// A served screen address has one binding for admission and execution.
    public static func unwrappingScreenAddress(_ input: [String: JSONValue]) -> [String: JSONValue] {
        let address: [String: JSONValue]
        switch input["target"] {
        case .object(let fields)?: address = fields
        case .string(let text)? where text.hasPrefix("{"):
            guard case .object(let fields)? = try? JSONValue.parse(Data(text.utf8)) else { return input }
            address = fields
        default: return input
        }
        var input = input
        if case .string? = address["handle"], case .string? = address["frame_id"] {
            input["target"] = nil
            input["handle"] = address["handle"]
            input["frame_id"] = address["frame_id"]
        } else if case .string? = address["target"], case .string? = address["app"],
                  case .string? = address["__sense_screen_frame"] {
            input["target"] = address["target"]
            input["app"] = address["app"]
            input["__sense_native_surface"] = .bool(true)
            input["__sense_native_label"] = address["label"]
        }
        return input
    }

    /// Read-only preflight, before any permission/approval card. This is only
    /// an early answer; the actual event/element is checked again at emission.
    /// The saved Write switch is final here and at emission; Full Mac never widens it (User 10-31: "Look, don't act").
    public static func requestRefusal(tool: String, input: [String: JSONValue], dataRoot: URL) async throws(CancellationError) -> MacAppActRefusal? {
        try await requestRefusalBody(tool: tool, input: input, dataRoot: dataRoot)
    }

    private static func requestRefusalBody(tool: String, input: [String: JSONValue], dataRoot: URL) async throws(CancellationError) -> MacAppActRefusal? {
        if tool == "app" {
            if case .array(let calls)? = input["actions"] {
                for case .object(let call) in calls {
                    if let refusal = try await requestRefusalBody(tool: "app", input: call, dataRoot: dataRoot) { return refusal }
                }
            }
            guard let action = input["action"]?.stringValue else { return nil }
            let args = input["args"]?.objectValue ?? [:]
            return try await requestRefusalBody(tool: action, input: args, dataRoot: dataRoot)
        }
        let operation = tool.hasPrefix("mac.") ? String(tool.dropFirst(4)) : tool
        let input = operation == "act" ? unwrappingScreenAddress(input) : input
        if looking, ["act", "hand"].contains(operation), holdingAllowsLooking(input) { return nil }
        if operation == "media" || operation == "mac_media" {
            do {
                guard let pid = try await MacMediaTarget.currentPID() else { return nil }
                return refusal(pid: pid, dataRoot: dataRoot)
            } catch let failure as MacMediaTarget.Failure { return failure.refusal }
            catch { throw CancellationError() } // The discovery owner throws only Failure or cancellation.
        }
        if ["apps.call", "applescript"].contains(operation) {
            guard let bundle = input["bundle_id"]?.stringValue, !bundle.isEmpty else { return unavailable() }
            guard !AuthoredToolEffects.appReadOnly(input) else { return nil }
            return refusal(bundleID: bundle, throughAppleEvents: true, dataRoot: dataRoot)
        }
        // A part's hand targets its held watch, checked by that owner before
        // approval. Its arguments do not name a frontmost-app operation.
        guard ["act", "menu_press", "hand", "click", "keystroke", "ax_act", "quit_app"].contains(operation) else { return nil }
        if case .array(let steps)? = input["steps"] {
            for raw in steps {
                var step: [String: JSONValue]
                switch raw {
                case .object(let fields): step = fields
                case .string: step = ["verb": .string("click")]
                default: return unavailable()
                }
                if step["app"] == nil { step["app"] = input["app"] }
                for key in ["frame_id", "image"] where step[key] == nil { step[key] = input[key] }
                if let refusal = try await requestRefusalBody(tool: "act", input: step, dataRoot: dataRoot) { return refusal }
            }
            if !steps.isEmpty { return nil }
        }
        if let destination = input["to_app"]?.stringValue,
           let refusal = try await requestRefusalBody(tool: "act", input: ["verb": .string("click"), "app": .string(destination)], dataRoot: dataRoot) {
            return refusal
        }
        let verb = input["verb"]?.stringValue?.lowercased() ?? input["gesture"]?.stringValue?.lowercased() ?? ""
        if operation == "act" && MacFourVerbs.parseVerb(verb).0 == "scroll"
            || operation == "hand" && verb == "scroll" {
            if holdingAllowsLooking(input) { return nil }
            // A named act uses that app (raising it first for front:true).
            // A native hand retains the executor's required foreground pid.
            // Neither sends the chord to an unrelated app currently in front.
            #if canImport(AppKit)
            if operation == "act", let name = input["app"]?.stringValue,
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return namedAppRefusal(name, dataRoot: dataRoot)
            }
            if operation == "hand", let pid = input["require_front_pid"]?.integerValue.flatMap(Int32.init(exactly:)) {
                return refusal(pid: pid, dataRoot: dataRoot)
            }
            return refusal(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier, dataRoot: dataRoot)
            #else
            return unavailable()
            #endif
        }
        // Frame/mark ownership is resolved by its owner at execution, not
        // guessed from whichever app happens to be in front during preflight.
        if let id = input["frame_id"]?.stringValue, input["handle"] != nil {
            let frame = await MacLookFrameStore.shared.frame(frameId: id)
            return refusal(pid: frame?.pid, dataRoot: dataRoot)
        }
        if let id = input["view"]?.stringValue {
            let view = await MacScreenViewStore.shared.snapshot(viewId: id)
            return refusal(pid: view?.windowIdentity?.pid, dataRoot: dataRoot)
        }
        #if canImport(AppKit)
        func coordinates(_ value: JSONValue?) -> (Double, Double)? {
            guard let fields = value?.objectValue,
                  let x = fields["x"]?.numberValue(coercingStrings: false, finiteOnly: true),
                  let y = fields["y"]?.numberValue(coercingStrings: false, finiteOnly: true) else { return nil }
            return (x, y)
        }
        let endpoints = [coordinates(input["at"] ?? input["from"]), coordinates(input["to"])].compactMap { $0 }
        if !endpoints.isEmpty {
            for (x, y) in endpoints {
                let screenX: Double, screenY: Double
                if operation == "act" {
                    guard let frame = MacImageFrames.frame(input["frame_id"]?.stringValue ?? input["image"]?.stringValue),
                          let point = frame.geometry.screenPoint(imageX: x, imageY: y) else { return unavailable() }
                    screenX = point.x; screenY = point.y
                } else { screenX = x; screenY = y }
                if let refusal = MacAppActGate.$dataRoot.withValue(dataRoot, operation: { pointRefusal(x: screenX, y: screenY) }) { return refusal }
            }
            return nil
        }
        if let bundle = input["bundle_id"]?.stringValue { return refusal(bundleID: bundle, dataRoot: dataRoot) }
        if let name = input["app"]?.stringValue, !name.isEmpty {
            return namedAppRefusal(name, dataRoot: dataRoot)
        }
        if let pid = input["pid"]?.integerValue.flatMap(Int32.init(exactly:)) { return refusal(pid: pid, dataRoot: dataRoot) }
        if let x = input["x"]?.numberValue(coercingStrings: false, finiteOnly: true),
           let y = input["y"]?.numberValue(coercingStrings: false, finiteOnly: true) {
            return MacAppActGate.$dataRoot.withValue(dataRoot) { pointRefusal(x: x, y: y) }
        }
        return refusal(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier, dataRoot: dataRoot)
        #else
        return unavailable()
        #endif
    }

    /// Looking never asks for Write. Missing/corrupt authority throws through
    /// the same disk reader used by the switch; it is never read as permission.
    public static func refusal(bundleID: String, looking: Bool = false, throughAppleEvents: Bool = false, dataRoot: URL? = nil) -> MacAppActRefusal? {
        guard !looking else { return nil }
        guard !bundleID.isEmpty else { return unavailable() }
        // System Events can relay GUI mutations to another process. Its own
        // bundle is not evidence of the affected app; native hands resolve it.
        if throughAppleEvents, bundleID == "com.apple.systemevents" { return unavailable() }
        guard let integration = MacIntegrationID.owning(appBundleID: bundleID) else { return nil }
        do {
            let snapshot = try MacIntegrationPermissionStore(dataRoot: dataRoot ?? self.dataRoot).snapshotNowChecked()
            if let message = snapshot.readiness.refusal(integration: integration, mode: .write) {
                return MacAppActRefusal(code: "operator_permission_off",
                    message: message, integration: integration)
            }
            // The owner's Write switch governs her hands in the app even under Full Mac.
            guard snapshot.allows(integration, mode: .write) else {
                return MacAppActRefusal(code: "integration_permission_denied",
                    message: "\(MacIntegrationID.displayName(for: integration)) Write is off: I can look at it but not act in it, Full Mac included. No app action was admitted.", integration: integration)
            }
            return nil
        } catch {
            return MacAppActRefusal(code: "integration_permission_unavailable",
                message: "The saved app permissions are unavailable: \(error.localizedDescription) No app action was admitted.", integration: integration)
        }
    }

    public static func refusal(pid: Int32?, looking: Bool = false, throughAppleEvents: Bool = false, dataRoot: URL? = nil) -> MacAppActRefusal? {
        guard !looking else { return nil }
        #if canImport(AppKit)
        guard let pid, pid > 0, let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated, let bundle = app.bundleIdentifier else { return unavailable() }
        return refusal(bundleID: bundle, throughAppleEvents: throughAppleEvents, dataRoot: dataRoot)
        #else
        return unavailable()
        #endif
    }

    static func unavailable() -> MacAppActRefusal {
        MacAppActRefusal(code: "app_action_target_unavailable",
            message: "I can't establish which app this input would reach. Use native hands on an observed app or a named player's action; this input was not admitted.", integration: nil)
    }

    /// Retain a refusal as the act's outcome, never as a permission cache.
    @discardableResult static func admit(_ refusal: MacAppActRefusal?) -> Bool {
        guard let refusal else { return true }
        MacDriverContext.binding?.noteAppActRefusal(refusal)
        return false
    }

    #if canImport(AppKit)
    private static func namedAppRefusal(_ name: String, dataRoot: URL) -> MacAppActRefusal? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && ($0.bundleIdentifier?.caseInsensitiveCompare(name) == .orderedSame
                || $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
                || $0.bundleURL?.path == name)
        }
        if matches.count == 1 { return refusal(pid: matches[0].processIdentifier, dataRoot: dataRoot) }
        // A named stopped app can still have a known owner; no launch is needed.
        do {
            if let url = try MacApplications.installedApplicationURL(named: name),
               let bundle = Bundle(url: url)?.bundleIdentifier {
                return refusal(bundleID: bundle, dataRoot: dataRoot)
            }
        } catch {
            return MacAppActRefusal(code: "app_action_target_unavailable",
                message: "The installed app could not be resolved: \(error.localizedDescription) Repair the app inventory before continuing; this input was not admitted.", integration: nil,
                remedy: Repair.remedy(owner: "macOS Spotlight app index", nextCall: nil, tap: "System Settings > Spotlight",
                    instruction: "Repair the app inventory before naming this target again."))
        }
        return unavailable()
    }

    static func frontRefusal() -> MacAppActRefusal? {
        if looking { return nil }
        return refusal(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }
    static func pointRefusal(x: Double, y: Double) -> MacAppActRefusal? {
        if looking { return nil }
        // The AX hit supplies a process, not a named control. Canvases need no label.
        let hit = SystemMacVisualObstructionProbe.hitPID(x: x, y: y)
        let window = SystemMacVisualObstructionProbe.topmost(in: SystemMacVisualObstructionProbe.windows(), x: x, y: y)
        // AX can hit her pass-through Shotgun overlay. The window inventory
        // excludes it, just as actual agent input passes through it.
        let pid = hit == getpid() ? window?.ownerPID : hit ?? window?.ownerPID
        return refusal(pid: pid)
    }
    static func elementRefusal(_ element: AXUIElement) -> MacAppActRefusal? {
        if looking { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return unavailable() }
        return refusal(pid: pid)
    }
    #endif
}
