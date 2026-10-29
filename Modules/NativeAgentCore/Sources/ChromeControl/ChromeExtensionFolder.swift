import Foundation
import PersistenceCore
import NativeAgentCore
import MacControl
import TrustCenter
import NativeAgentShared
// Blueprint: | `ChromeExtensionFolder.swift` | `ChromeExtensionFolder` enum; executable-closure completeness through ChromeExtensionFiles, staged replacement and registered-host refresh; incomplete bundles and copy failures name the defect and person recovery step, never a coding request |

public enum ChromeExtensionFolder {
    public static var bundled: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("NativeAgentChrome", isDirectory: true)
    }

    public static var visible: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(InstallPaths.current.name("NativeAgent") + " Chrome Extension", isDirectory: true)
    }

    public static func isComplete(_ folder: URL) -> Bool {
        var paths = Set<URL>()
        return (try? ChromeExtensionFiles.object(folder.appendingPathComponent("manifest.json")))
            .flatMap { ChromeExtensionFiles.codeDigest(folder: folder, manifest: $0, paths: &paths) } != nil
    }

    @discardableResult
    public static func prepare() throws -> URL {
        guard let bundled, isComplete(bundled) else {
            throw ToolFailureError("The bundled Chrome extension is incomplete.", effects: .none,
                owner: "NativeAgent app bundle / NativeAgentChrome",
                instruction: "Tell the person: this copy of NativeAgent has an incomplete bundled Chrome extension. Preserve saved data and all Trust and macOS grants.")
        }
        let fm = FileManager.default
        let destination = visible
        if isComplete(destination), fm.contentsEqual(atPath: bundled.path, andPath: destination.path) { return destination }
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent("." + destination.lastPathComponent + ".incoming-" + UUID().uuidString, isDirectory: true)
        do {
            try fm.copyItem(at: bundled, to: staging)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: destination)
            }
            return destination
        } catch {
            try? fm.removeItem(at: staging)
            throw ToolFailureError("Could not copy the Chrome extension: \(error.localizedDescription)", effects: .none,
                owner: destination.path,
                instruction: "Ask the person to repair file access from \(bundled.path) to \(destination.path), preserving existing bytes and all Trust and macOS grants; then run chrome.setup.")
        }
    }

    /// At launch: only refresh a copy the person already set up, so an app
    /// update reaches Chrome. Never creates the folder unasked. Both shipped
    /// installs share this folder, so only Chrome's registered host refreshes it.
    public static func refreshIfPresent() {
        guard FileManager.default.fileExists(atPath: visible.path),
              ChromeNativeHostRegistration.ownsOrUnclaimed() else { return }
        do { try prepare() }
        catch { nativeLog("[chrome] %@", error.localizedDescription) }
    }

    /// Setup uses the same hands and permission law as an ordinary Mac act.
    public static func setUp(chrome: ChromeControlRuntime, dataRoot: URL, origin: SecurityOriginContext) async throws -> URL {
        func require(_ reply: MacFourVerbsReply) throws {
            guard !reply.ok else { return }
            let remedy: [String: JSONValue] = if case .object(let value)? = reply.detail["remedy"] { value } else { [:] }
            let owner: String = if case .string(let value)? = remedy["owner"] { value } else { "Chrome / extensions setup" }
            let tap: String? = if case .string(let value)? = remedy["tap"] { value } else { nil }
            let next = remedy["next_call"] ?? .object(["tool": .string("app"), "input": .object([
                "action": .string("mac.look"), "args": .object(["app": .string("com.google.Chrome")])])])
            throw ToolFailureError(reply.text, effects: reply.detail["effects"] == .string("none") ? .none : .unknown, owner: owner,
                nextCall: try next.serialize(pretty: false), tap: tap,
                personDecides: remedy["kind"] == .string("person_decides"))
        }
        await chrome.reconcilePolicy()
        let status = await chrome.setupConnectionStatus()
        try require(.init(ok: status.enabled, text: "Chrome control is off or unavailable in Trust.",
            detail: ["remedy": status.diagnostics["remedy"] ?? .null, "effects": .string("none")]))
        let folder = try prepare()
        if status.state == .connected, status.diagnostics["extension_path"] == .string(folder.path),
           let shipped = status.diagnostics["extension_shipped_version"],
           shipped == status.diagnostics["extension_running_version"] { return folder }
        let current = MacDriverContext.binding
        let driver: MacDriverBinding
        if let current { driver = current }
        else { driver = await MacAttentionSessionStore.shared.bindDriver() }
        return try await MacDriverContext.$binding.withValue(driver) {
            defer { if current == nil { driver.cancel() } }
            let hands = MacFourVerbs(host: makeMacControl(
                policyProvider: TrustCenterMacControlPolicyProvider(dataRoot: dataRoot, operatorOrigin: origin),
                auditAppendPath: MacControlActionRoutes.auditPath(dataRoot: dataRoot)))
            func developerMode() async throws -> [String] {
                let seen = await hands.screen(app: "com.google.Chrome", structured: true)
                try require(seen)
                let rows: [JSONValue] = if case .object(let controls)? = seen.detail["controls"],
                    case .array(let rows)? = controls["affordances"] { rows } else { [] }
                return rows.compactMap { row -> String? in
                    guard case .object(let value) = row, value["label"] == .string("Developer mode"),
                          case .string(let state)? = value["state"] else { return nil }
                    return state
                }
            }
            try require(await hands.go("com.google.Chrome", front: true))
            var toggles = try await developerMode()
            // Open the page only when it isn't already showing: an open
            // Extensions window also lists itself under Window.
            if toggles.isEmpty {
                try require(await hands.act(verb: "click", target: "Window > Extensions", app: "com.google.Chrome"))
                try require(await hands.wait(until: "Developer mode", seconds: 15))
                toggles = try await developerMode()
            }
            guard toggles.count == 1, let state = toggles.first,
                  ["checked", "unchecked", "on", "off"].contains(state) else {
                throw ToolFailureError("Chrome did not report whether Developer mode is on.", effects: .occurred,
                    owner: "Chrome / extensions page", nextCall: ToolFailureError.call("app", [
                        "action": .string("mac.look"), "args": .object(["app": .string("com.google.Chrome")])]))
            }
            if state == "unchecked" || state == "off" {
                try require(await hands.act(verb: "click", target: "Developer mode", app: "com.google.Chrome"))
            }
            try require(await hands.act(verb: "click", target: "Load unpacked", app: "com.google.Chrome"))
            try require(await hands.act(verb: "key", target: "", app: "com.google.Chrome", steps: [
                .init(verb: "key", target: "cmd+shift+g"),
                .init(verb: "type", target: "focused field", text: folder.path),
                .init(verb: "key", target: "return"),
            ]))
            let selectedAt = Date()
            try require(await hands.act(verb: "click", target: "Select", app: "com.google.Chrome"))
            try await chrome.verifySetup(since: selectedAt)
            return folder
        }
    }
}
