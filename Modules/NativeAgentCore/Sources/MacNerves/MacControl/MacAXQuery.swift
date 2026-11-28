import ApplicationServices
import AppKit
import CoreFoundation
import Foundation
import NativeAgentCore
import PersistenceCore
import SenseCore
// Blueprint: | `MacAXQuery.swift` | Passive, bounded part AX query over the shared strict walk and redacted legend |

package struct MacAXQuery: Sendable {
    package static let operation = "ax.query"
    private static let attributes: Set<String> = [
        "role", "subrole", "title", "description", "value", "placeholder", "help",
        "enabled", "focused", "selected", "frame", "identifier", "path",
    ]
    private static let credentialApps: Set<String> = [
        "com.apple.passwords", "com.apple.keychainaccess", "com.apple.securityagent",
        "com.apple.localauthentication.uiagent", "com.apple.authenticationservicescore.authenticationservicesagent",
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "org.keepassxc.keepassxc", "com.dashlane.dashlane",
        "com.lastpass.lastpass", "com.lastpass.lastpassmacdesktop",
    ]
    package let bundleID: String
    private let windowIndex: Int?
    private let titleContains: String?
    private let roles: Set<String>?
    private let fields: Set<String>
    private let limits: MacAXLimits
    private let textChars: Int

    package init(_ arguments: JSONValue) throws {
        func invalid() -> SenseFailure {
            SenseFailure(code: "invalid_args", message: """
                host.ax.query takes {bundle_id, window?:{index?,title_contains?}, roles?, attributes?, max_depth?, max_nodes?, max_text_chars?}.
                Use a bundle ID, a zero-based window index, string arrays and integer limits.
                """)
        }
        guard case .object(let args) = arguments,
              Set(args.keys).isSubset(of: ["bundle_id", "window", "roles", "attributes", "max_depth", "max_nodes", "max_text_chars"]),
              case .string(let id)? = args["bundle_id"], id.utf8.count <= 255,
              let bundleID = OpenURLClassification.normalizedBundleID(id), Keyring.names(in: arguments).isEmpty else { throw invalid() }
        func selection(_ value: JSONValue?) throws -> Set<String>? {
            guard let value else { return nil }
            guard case .array(let entries) = value, entries.count <= 200 else { throw invalid() }
            return try Set(entries.map { entry in
                guard case .string(let name) = entry, !name.isEmpty, name.utf8.count <= 255 else { throw invalid() }
                return name
            })
        }
        func limit(_ name: String, _ defaultValue: Int, _ range: ClosedRange<Int64>) throws -> Int {
            guard let value = args[name] else { return defaultValue }
            guard case .int(let n) = value else { throw invalid() }
            return Int(min(range.upperBound, max(range.lowerBound, n)))
        }
        var index: Int?, title: String?
        if let window = args["window"] {
            guard case .object(let selectors) = window, Set(selectors.keys).isSubset(of: ["index", "title_contains"]) else { throw invalid() }
            if let provided = selectors["index"] {
                guard case .int(let n) = provided, (0..<200).contains(n) else { throw invalid() }
                index = Int(n)
            }
            if let provided = selectors["title_contains"] {
                guard case .string(let fragment) = provided, !fragment.isEmpty, fragment.utf8.count <= 512 else { throw invalid() }
                title = fragment
            }
        }
        let fields = try selection(args["attributes"])
        guard fields?.isSubset(of: Self.attributes) != false else {
            throw SenseFailure(code: "unsupported_ax_attribute", message: "Use only the documented AX legend attributes.")
        }
        if Self.credentialApps.contains(bundleID) || bundleID == MacWakeGuard.loginWindowBundleID
            || Bundle.main.bundleIdentifier.flatMap(OpenURLClassification.normalizedBundleID) == bundleID {
            throw SenseFailure(code: "sensitive_app_blocked", message: "This app's accessibility content is protected.")
        }
        self.bundleID = bundleID
        self.fields = fields ?? Self.attributes.union(["selected_text"])
        windowIndex = index
        titleContains = title
        roles = try selection(args["roles"])
        limits = MacAXLimits(maxNodes: try limit("max_nodes", 100, 1...200), maxDepth: try limit("max_depth", 6, 1...12))
        textChars = try limit("max_text_chars", 256, 32...512)
    }

    package func declaresApp(_ grants: Set<PartReachGrant>) -> Bool {
        grants.contains {
            switch $0 {
            case .appRead(let id), .appWrite(let id): OpenURLClassification.normalizedBundleID(id) == bundleID
            default: false
            }
        }
    }

    package func read(context: MacOperationContext, watch: MacScreenWatch.AXQueryScope?, watchOnly: Bool,
                      scrub: @escaping @Sendable (String) -> String) async throws -> JSONValue {
        guard !watchOnly || watch != nil else { return Self.status("withheld", "watch_scope_changed") }
        guard let deadline = context.wallDate else { return Self.status("withheld", "time_budget", truncated: true) }
        var passive = context
        passive.observationMode = .passive
        passive.seesAsPerson = false
        passive.readDeadline = deadline
        return try await MacAccessibilityReader.read(context: passive) { context in
            try Task.checkCancellation()
            if Date() >= deadline { return Self.status("withheld", "time_budget", truncated: true) }
            let source = SystemMacAXElementSource()
            guard source.isTrusted() else { return Self.status("unavailable", "accessibility_denied") }
            let matches = NSWorkspace.shared.runningApplications.filter {
                !$0.isTerminated && $0.bundleIdentifier.flatMap(OpenURLClassification.normalizedBundleID) == bundleID
                    && (watch == nil || $0.processIdentifier == watch?.pid)
            }
            guard !matches.isEmpty else { return Self.status("unavailable", "app_not_running") }
            guard matches.count == 1, let app = matches.first, let launch = app.launchDate else {
                return Self.status("unavailable", "ambiguous_app")
            }
            let pid = app.processIdentifier
            guard !PersonOnlyWindows.isOwnProcess(pid) else {
                throw SenseFailure(code: "sensitive_app_blocked", message: "This app's accessibility content is protected.")
            }
            guard !MacSecureEventInput.isEnabled() else { return Self.status("withheld", "secure_input_active") }
            let value: JSONValue
            do {
                value = try readWindows(source: source, pid: pid, watch: watch, watchOnly: watchOnly,
                    deadline: deadline, context: context, scrub: scrub)
            } catch {
                try Task.checkCancellation()
                if Date() >= deadline { return Self.status("withheld", "time_budget", truncated: true) }
                return Self.status("withheld", "redaction_coverage_unavailable")
            }
            try Task.checkCancellation()
            if Date() >= deadline { return Self.status("withheld", "time_budget", truncated: true) }
            guard !MacSecureEventInput.isEnabled(), !app.isTerminated,
                  NSRunningApplication(processIdentifier: pid)?.launchDate == launch else {
                return Self.status("withheld", "app_or_secure_input_changed")
            }
            return value
        }
    }

    private func readWindows(source: SystemMacAXElementSource, pid: Int32, watch: MacScreenWatch.AXQueryScope?, watchOnly: Bool,
                             deadline: Date, context: MacOperationContext, scrub: (String) -> String) throws -> JSONValue {
        let application = AXUIElementCreateApplication(pid)
        let listed = try MacAXAttributeRead.checkedElementArray(application, kAXWindowsAttribute, limit: 201, context: context)
        var candidates = Array(listed.prefix(200).enumerated())
        if let watch {
            guard listed.count <= 200 else { return Self.status("withheld", "window_cap", truncated: true) }
            let watched = candidates.filter { CFEqual($0.element, watch.identity.element) }
            guard watched.count == 1, let match = watched.first,
                  MacAXWindowIdentity.rectsMatch(try MacAXAttributeRead.checkedFrame(match.element, context: context), watch.window) else {
                return Self.status("withheld", "watch_window_unverified")
            }
            if watchOnly { candidates = watched }
        }
        if let windowIndex { candidates = candidates.filter { $0.offset == windowIndex } }
        else if titleContains == nil { candidates = Array(candidates.prefix(1)) }
        for (_, window) in candidates {
            let watched = watch.flatMap { CFEqual(window, $0.identity.element) ? $0 : nil }
            let snapshot = MacAccessibilityReader.walk(source: source, root: source.mint(window), limits: limits, strict: true,
                read: { try source.checkedQueryAttributes(of: $0, pid: pid, context: $1) },
                deadline: deadline, stopAtCut: true, context: context)
            if snapshot.truncated {
                let reason = snapshot.truncationReasons.contains("protected_content") ? "protected_content"
                    : snapshot.truncationReasons.first ?? "redaction_coverage_unavailable"
                return Self.status("withheld", reason, truncated: true)
            }
            guard let root = snapshot.nodes.first, let frame = root.attributes.frame,
                  [frame.x, frame.y, frame.w, frame.h].allSatisfy(\.isFinite), frame.w > 0, frame.h > 0,
                  let masks = MacScreenViewTextRedaction.secretFrames(nodes: snapshot.nodes,
                    geometry: MacScreenViewGeometry(bounds: frame, pixelWidth: 1, pixelHeight: 1), deadline: deadline, strict: true, context: context)
            else { return Self.status("withheld", "redaction_coverage_unavailable") }
            if let watched, !MacAXWindowIdentity.rectsMatch(frame, watched.window) {
                return Self.status("withheld", "watch_window_unverified")
            }
            let captions = MacScreenViewTextRedaction.nodeSecretContext(snapshot.nodes)
            let strictMasks = masks + (watched.map { Array($0.masks) } ?? [])
            func legend(_ node: MacAXNode, cap: Int, scrub: (String) -> String) -> [String: JSONValue] {
                MacScreenViewTextRedaction.redactedNodeFields(node, valueChars: cap, context: captions,
                    strictMasks: strictMasks, dataRoot: context.dataRoot, scrub: scrub)
            }
            let windowFields = legend(root, cap: 512, scrub: scrub)
            if let titleContains {
                guard windowFields["redacted"] != .bool(true), !watchOnly || watched.map({ $0.region == $0.window }) == true else {
                    return Self.status("withheld", "window_title_protected")
                }
                guard let title = windowFields["title"]?.stringValue, title.contains(titleContains) else { continue }
            }
            let kind = (windowFields["role"]?.stringValue).map {
                MacAppMaps.windowKind(role: $0, subrole: windowFields["subrole"]?.stringValue)
            }.flatMap { scrub($0) == $0 ? $0 : nil }
            var rows: [JSONValue] = [], redacted = 0, truncated = false, bytes = 512
            for node in snapshot.nodes {
                guard Date() < deadline else { return Self.status("withheld", "time_budget", truncated: true) }
                if watchOnly, let watched {
                    guard let frame = node.attributes.frame,
                          frame.x >= watched.region.x, frame.y >= watched.region.y,
                          frame.x + frame.w <= watched.region.x + watched.region.w,
                          frame.y + frame.h <= watched.region.y + watched.region.h else { continue }
                }
                var scrubbedAttributes = 0
                let row = legend(node, cap: textChars) { raw in
                    let cleaned = scrub(raw)
                    if cleaned != raw { scrubbedAttributes += 1 }
                    return cleaned
                }
                let secure = node.attributes.queryFields?["redacted"] == .bool(true)
                if let roles {
                    let role = secure && scrub(node.attributes.role) == node.attributes.role
                        ? node.attributes.role : row["role"]?.stringValue
                    guard role.map(roles.contains) == true else { continue }
                }
                let projected = JSONValue.object(row.filter { fields.contains($0.key) || $0.key == "redacted" })
                bytes += try projected.serializedData(pretty: false).count + 1
                if bytes > 64 * 1_024 { truncated = true; break }
                rows.append(projected)
                redacted += secure ? 1 : scrubbedAttributes
            }
            var output: [String: JSONValue] = [
                "status": .string("ok"), "data_trust": .string("untrusted_app_ui"), "bundle_id": .string(bundleID),
                "pid": .int(Int64(pid)), "redacted_count": .int(Int64(redacted)), "truncated": .bool(truncated), "nodes": .array(rows),
            ]
            output["window_kind"] = kind.map(JSONValue.string)
            if truncated { output["reason"] = .string("response_cap") }
            let response = JSONValue.object(output)
            return try response.serializedData(pretty: false).count <= 64 * 1_024 ? response
                : Self.status("withheld", "response_cap", truncated: true)
        }
        if listed.count > 200, titleContains != nil, windowIndex == nil {
            return Self.status("withheld", "window_cap", truncated: true)
        }
        return Self.status("unavailable", "window_not_found")
    }

    package static func status(_ status: String, _ reason: String, truncated: Bool = false) -> JSONValue {
        .object(["status": .string(status), "reason": .string(reason), "truncated": .bool(truncated)])
    }
}
