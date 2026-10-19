import Foundation
import NativeAgentCore
import PersistenceCore
import Senses
import TrustCenter
#if canImport(Darwin)
import Darwin
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(AppKit)
import AppKit
import Carbon
import OSAKit
import os
#endif

// MARK: - Adapter results

/// What the notification adapter can prove after a post request returns.
///
/// UserNotifications acknowledges that it accepted a request for delivery; it
/// does not provide a receipt that the user saw, heard, or acted on it. Keep
/// those facts separate so a successful API call never becomes a fabricated
/// external effect.
public enum NotificationPostDisposition: String, Sendable, Equatable {
    case acceptedForDelivery = "accepted_for_delivery"
}

public enum NotificationAuthorizationDisposition: String, Sendable, Equatable {
    case authorized
    case provisional
    /// A non-system adapter accepted the request but does not expose a
    /// platform authorization query. This is deliberately not `authorized`.
    case adapterManaged = "adapter_managed"
}

public struct NotificationPostReceipt: Sendable, Equatable {
    public let disposition: NotificationPostDisposition
    public let authorization: NotificationAuthorizationDisposition
    public let requestIdentifier: String?

    public init(
        disposition: NotificationPostDisposition = .acceptedForDelivery,
        authorization: NotificationAuthorizationDisposition,
        requestIdentifier: String? = nil
    ) {
        self.disposition = disposition
        self.authorization = authorization
        self.requestIdentifier = requestIdentifier
    }
}

public protocol NotificationCenterAdapter: Sendable {
    func postNotification(title: String, message: String, soundName: String?) async throws
    func postNotificationReceipt(
        title: String,
        message: String,
        soundName: String?
    ) async throws -> NotificationPostReceipt
}

public extension NotificationCenterAdapter {
    /// Compatibility receipt for injectable adapters which can submit a
    /// notification but cannot query platform authorization or delivery.
    func postNotificationReceipt(
        title: String,
        message: String,
        soundName: String?
    ) async throws -> NotificationPostReceipt {
        try await postNotification(title: title, message: message, soundName: soundName)
        return NotificationPostReceipt(authorization: .adapterManaged)
    }
}

public struct ProcessRunResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool
    public let stdoutTruncated: Bool
    public let stderrTruncated: Bool
    public init(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        timedOut: Bool = false,
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
    }
}

public struct AppControlRunResult: Sendable, Equatable {
    public let requestedName: String
    public let matchedName: String?
    public let bundleIdentifier: String?
    public let processIdentifier: Int32?
    public let launched: Bool
    public let activated: Bool
    public let terminated: Bool
    public let alreadyInDesiredState: Bool

    public init(
        requestedName: String,
        matchedName: String?,
        bundleIdentifier: String?,
        processIdentifier: Int32?,
        launched: Bool,
        activated: Bool,
        terminated: Bool,
        alreadyInDesiredState: Bool = false
    ) {
        self.requestedName = requestedName
        self.matchedName = matchedName
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.launched = launched
        self.activated = activated
        self.terminated = terminated
        self.alreadyInDesiredState = alreadyInDesiredState
    }
}

// MARK: - System adapters (production impls)

public final class SystemAppleScriptAdapter: OwnedAppCalling, Sendable {
    public init() {}

    public enum AppleScriptError: Error {
        case permissionDenied(app: String)
    }

    public static let appleScriptOutcomeUnknownCode = -1002

    public static func automationTarget(_ permission: String) -> String? {
        switch permission {
        case "notes": return "com.apple.Notes"
        case "mail": return "com.apple.mail"
        case "music": return "com.apple.Music"
        default: break
        }
        guard let prefix = ["applescript:", "jxa:"].first(where: permission.hasPrefix),
              permission.count > prefix.count else { return nil }
        return String(permission.dropFirst(prefix.count))
    }

    public static func checkAppScript(_ args: [String: JSONValue]) throws {
        guard let script = args["script"] else { return }
        guard case .string(let source) = script, !source.isEmpty,
              Set(args.keys).isSubset(of: ["bundle_id", "script"]) else {
            throw SenseFailure(code: "bad_input", message: "Pass {bundle_id,script} with an AppleScript body for the declared app.")
        }
        // Validate syntax that can change the execution environment, not app
        // commands. Strings/comments are data; quoted identifiers remain code.
        let characters = Array(source)
        var index = 0, depth = 0, quoted = false, code = ""
        while index < characters.count {
            let c = characters[index], next = index + 1 < characters.count ? characters[index + 1] : nil
            if quoted {
                if c == "\\" { index += 1 }
                else if c == "\"" { quoted = false }
            } else if c == "(", next == "*" {
                depth += 1; index += 1; code += " "
            } else if depth > 0 {
                if c == "*", next == ")" { depth -= 1; index += 1 }
            } else if c == "\"" {
                quoted = true; code += " "
            } else if c == "#" || c == "-" && next == "-" {
                while index < characters.count, characters[index] != "\n", characters[index] != "\r" { index += 1 }
                code += "\n"
            } else { code.append(c) }
            index += 1
        }
        let words = code.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).map(String.init)
        let importsTerms = words.indices.contains { words[$0] == "using" && words.dropFirst($0 + 1).prefix(2) == ["terms", "from"] }
        let tellsApp = words.indices.contains { words[$0] == "tell" && ["app", "application"].contains(words.dropFirst($0 + 1).first ?? "") }
        let currentApp = words.indices.contains { words[$0] == "current" && ["app", "application"].contains(words.dropFirst($0 + 1).first ?? "") }
        guard !words.contains("use"), !importsTerms, !words.contains("script"),
              !tellsApp, !currentApp, !words.contains("me"), !words.contains("my"), !code.contains("«") else {
            throw SenseFailure(code: "undeclared_target", message: "The runner owns the script environment and app target. Resource imports (use / using terms from), script objects (including load script / run script), explicit app tells, self references and raw code terms are refused.")
        }
        var tells = 0
        let lines = code.replacingOccurrences(of: "¬[ \\t]*[\\r\\n]+", with: " ", options: .regularExpression)
        for line in lines.split(whereSeparator: { $0.isNewline }) {
            let tokens = line.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
            for index in tokens.indices where tokens[index] == "tell" {
                if index > 0, tokens[index - 1] == "end" { tells -= 1 }
                else if !tokens.dropFirst(index + 1).contains("to") { tells += 1 }
            }
            guard tells >= 0, tokens != ["end"] else {
                throw SenseFailure(code: "undeclared_target", message: "The script body must not close the runner's app tell. Use explicit end statements for its own blocks.")
            }
        }
    }

    public static func automationPermission(bundleID: String, ask: Bool = false) async -> JSONValue {
        #if canImport(AppKit)
        guard let url = await MainActor.run(body: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }) else {
            return .object(["bundle_id": .string(bundleID), "state": .string("unavailable"),
                            "detail": .string("No installed app resolves this bundle id.")])
        }
        let pid: pid_t?
        do {
            // A stopped target cannot present consent. Only the owner's ask
            // opens it, without activating it, through the execution owner.
            pid = ask ? try await appProcess(at: url) : await MainActor.run { runningApp(at: url)?.processIdentifier }
        } catch {
            return .object(["bundle_id": .string(bundleID), "app_path": .string(url.path),
                            "state": .string("unavailable"), "detail": .string(error.localizedDescription)])
        }
        // The consent check waits like any Apple Event (ask:true can wait on the person): on the one queue.
        return (try? await onAppleScriptQueue { _ in permission(bundleID: bundleID, url: url, pid: pid, ask: ask) })
            ?? .object(["bundle_id": .string(bundleID), "app_path": .string(url.path), "state": .string("unavailable"),
                        "detail": .string("The consent check was cancelled before it ran.")])
        #else
        return .object(["state": .string("unavailable")])
        #endif
    }

    #if canImport(AppKit)
    // OSA permits background execution (AppleScript 10.6 release notes). One serial
    // queue owns dictionary reads, consent checks, scripts and their reply waits, so a
    // blocked app parks this thread, never a Swift cooperative worker. Work cancelled
    // while queued never sends; a running script reads the flag at each event.
    private static let appleScriptQueue = DispatchQueue(label: "NativeAgent.AppleScript", qos: .userInitiated)

    private static func onAppleScriptQueue<Value: Sendable>(
        _ operation: @escaping @Sendable (OSAllocatedUnfairLock<Bool>) throws -> Value
    ) async throws -> Value {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                appleScriptQueue.async {
                    continuation.resume(with: Result {
                        guard !cancelled.withLock({ $0 }) else { throw CancellationError() }
                        return try autoreleasepool { try operation(cancelled) }
                    })
                }
            }
        } onCancel: { cancelled.withLock { $0 = true } }
    }

    @MainActor private static func runningApp(at url: URL) -> NSRunningApplication? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath()
        return NSWorkspace.shared.runningApplications.first {
            !$0.isTerminated && $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == path
        }
    }

    @MainActor private static func appProcess(at url: URL) async throws -> pid_t {
        try Task.checkCancellation()
        if let app = runningApp(at: url) { return app.processIdentifier }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        try Task.checkCancellation()
        guard app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath(),
              !app.isTerminated else {
            throw SenseFailure(code: "app_unavailable", message: "Launch Services did not open the resolved app at \(url.path).")
        }
        return app.processIdentifier
    }

    private static func permission(bundleID: String, url: URL, pid: pid_t?, ask: Bool = false) -> JSONValue {
        let target = pid.map { NSAppleEventDescriptor(processIdentifier: $0) } ?? NSAppleEventDescriptor(applicationURL: url)
        let code = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
        let state = code == 0 ? "allowed" : code == -1744 ? "needs_consent" : code == -1743 ? "denied" : "unavailable"
        return .object(["bundle_id": .string(bundleID), "app_path": .string(url.path), "code": .int(Int64(code)),
                        "state": .string(state), "detail": .string(code == -1743
                            ? "Automation was denied by the owner; only the owner can change it in System Settings › Privacy & Security › Automation."
                            : code == -1744 ? "macOS Automation consent is still not asked for this app. Allow the permission card to ask macOS."
                            : code == -600 ? "Open \(url.path), then request Automation consent again." : state)])
    }
    #endif

    public func callApp(_ arguments: JSONValue, targets: [String: String]) async throws -> JSONValue {
        guard case .object(let args) = arguments, case .string(let bundleID)? = args["bundle_id"],
              let access = targets[bundleID], ["read", "write"].contains(access) else {
            throw SenseFailure(code: "undeclared_target", message: "Declare read or write reach for this app's bundle id.")
        }
        let read = AuthoredToolEffects.appReadOnly(args)
        guard access == "write" || read else {
            throw SenseFailure(code: "read_only", message: "A read-declared app refuses modifying or unclassified events.")
        }
        try Self.checkAppScript(args)
        #if canImport(AppKit)
        guard let url = await MainActor.run(body: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }) else {
            throw SenseFailure(code: "app_unavailable", message: "No installed app resolves \(bundleID).")
        }
        if args["dictionary"] == .bool(true), args["script"] == nil {
            return try await Self.onAppleScriptQueue { _ in
                var definition: Unmanaged<CFData>?
                let code = OSACopyScriptingDefinitionFromURL(url as CFURL, 0, &definition)
                guard code == 0, let data = definition?.takeRetainedValue(),
                      let text = String(data: data as Data, encoding: .utf8) else {
                    throw SenseFailure(code: "dictionary_unavailable", message: "Scripting dictionary unavailable for \(url.path) (\(code)).")
                }
                return .object(["bundle_id": .string(bundleID), "app_path": .string(url.path), "read_only": .bool(true), "sdef": .string(text)])
            }
        }
        let pid = try await Self.appProcess(at: url)
        return try await Self.onAppleScriptQueue { cancelled in
            let permission = Self.permission(bundleID: bundleID, url: url, pid: pid)
            guard case .object(let consent) = permission, consent["state"] == .string("allowed") else { return permission }
            var effects: String?
            do {
                let value: NSAppleEventDescriptor?
                if case .string(let source)? = args["script"] {
                    let target = bundleID.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                    let program = "use AppleScript version \"2.4\"\ntell application id \"\(target)\"\n\(source)\nend tell"
                    value = try Self.scriptValue(program, pid: pid, authored: true, cancelled: cancelled, effects: &effects)
                } else {
                    let event = NSAppleEventDescriptor.appleEvent(withEventClass: try Self.fourCode(args["event_class"]),
                        eventID: try Self.fourCode(args["event_id"]), targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
                        returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
                    if let value = args["parameters"] {
                        guard case .object(let parameters) = value else { throw Self.badEvent() }
                        for (key, value) in parameters { event.setParam(try Self.descriptor(value), forKeyword: try Self.fourCode(.string(key))) }
                    }
                    // Bound each reply with the Apple Event Manager's standard timeout.
                    let options: NSAppleEventDescriptor.SendOptions = [.waitForReply, .neverInteract,
                        .init(rawValue: UInt(kAEDoNotPromptForUserConsent))]
                    // A cancel that arrived during the preflight stops the event before it is sent.
                    guard !cancelled.withLock({ $0 }) else {
                        throw NSError(domain: "NativeAgentAppleEvent", code: -128,
                                      userInfo: [NSLocalizedDescriptionKey: "The call was cancelled before its event was sent."])
                    }
                    let reply = try event.sendEvent(options: options, timeout: TimeInterval(kAEDefaultTimeout))
                    let code = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value ?? 0
                    guard code == 0 else {
                        throw NSError(domain: "NativeAgentAppleEvent", code: Int(code), userInfo: [NSLocalizedDescriptionKey:
                            reply.paramDescriptor(forKeyword: keyErrorString)?.stringValue ?? "Apple Event failed (\(code))."])
                    }
                    value = reply.paramDescriptor(forKeyword: keyDirectObject)
                }
                var done: [String: JSONValue] = ["bundle_id": .string(bundleID), "app_path": .string(url.path), "read_only": .bool(read),
                                                 "code": .int(0), "value": Self.json(value)]
                // Only a script's events are observed; a single event's effects follow its class.
                done["effects"] = effects.map(JSONValue.string)
                return .object(done)
            } catch {
                let error = Self.appError(error, pid: pid, app: url.deletingPathExtension().lastPathComponent) as NSError
                let code = error.userInfo["apple_event_code"] as? Int ?? error.code
                var failed: [String: JSONValue] = ["bundle_id": .string(bundleID), "app_path": .string(url.path), "read_only": .bool(read),
                    "code": .int(Int64(code)), "state": .string(error.userInfo["state"] as? String
                        ?? (code == -1744 ? "needs_consent" : code == -1743 ? "denied" : "failed")),
                    "message": .string(error.localizedDescription),
                    "detail": .string(error.userInfo["state"] != nil ? error.localizedDescription
                        : code == -1743 ? "Automation was denied by the owner; only the owner can change it in System Settings › Privacy & Security › Automation."
                        : error.localizedDescription)]
                failed["effects"] = effects.map(JSONValue.string)
                return .object(failed)
            }
        }
        #else
        throw SenseFailure(code: "unavailable", message: "App events require macOS.")
        #endif
    }

    #if canImport(AppKit)
    public static func runIntegrationScript(_ source: String, bundleID: String) async throws -> String {
        try Task.checkCancellation()
        guard let url = await MainActor.run(body: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }) else {
            throw NSError(domain: "NativeAgentAppleEvent", code: -600,
                          userInfo: [NSLocalizedDescriptionKey: "No installed app resolves \(bundleID)."])
        }
        let pid = try await appProcess(at: url)
        return try await onAppleScriptQueue { cancelled in
            let consent = permission(bundleID: bundleID, url: url, pid: pid)
            guard case .object(let fields) = consent, fields["state"] == .string("allowed") else {
                if case .object(let fields) = consent, case .int(let code)? = fields["code"], ![-1743, -1744].contains(code) {
                    throw NSError(domain: "NativeAgentAppleScript", code: Int(code),
                                  userInfo: [NSLocalizedDescriptionKey: "Automation preflight failed for \(url.path) (\(code))."])
                }
                throw AppleScriptError.permissionDenied(app: url.deletingPathExtension().lastPathComponent)
            }
            let path = url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let program = source.replacingOccurrences(of: "tell application \"__NativeAgentApp__\"", with: "tell application \"\(path)\"")
            let value: NSAppleEventDescriptor
            var effects: String?
            do { value = try scriptValue(program, pid: pid, authored: false, cancelled: cancelled, effects: &effects) }
            catch { throw appError(error, pid: pid, app: url.deletingPathExtension().lastPathComponent) }
            guard let text = value.stringValue else {
                throw NSError(domain: "NativeAgentAppleScript", code: -1700,
                              userInfo: [NSLocalizedDescriptionKey: "The integration script did not return text."])
            }
            return text
        }
    }

    private static func appError(_ error: Error, pid: pid_t, app: String) -> Error {
        let ns = error as NSError
        guard (ns.userInfo["apple_event_code"] as? Int ?? ns.code) == -1712 else { return error }
        var state = "app_timeout"
        let observation = MacAXLimits.$readDeadline.withValue(Date().addingTimeInterval(MacAXLimits.readSeconds)) {
            let source = SystemMacAXElementSource()
            guard source.isTrusted() else { return "Accessibility permission is unavailable, so a dialog could not be checked." }
            for window in source.windowRoots(pid: pid) {
                let snapshot = MacAccessibilityReader.walk(source: source, root: window.ref)
                if let dialog = snapshot.nodes.first(where: {
                    MacPerceptionCompiler.modalSubroles.contains($0.attributes.role)
                        || MacPerceptionCompiler.modalSubroles.contains($0.attributes.subrole ?? "")
                }) {
                    state = "blocked_by_dialog"
                    let label = MacPerceptionCompiler.safeDisplay(dialog.attributes.title ?? dialog.attributes.value ?? "")
                    let kind = dialog.attributes.role == "AXSheet" || dialog.attributes.subrole == "AXSheet" ? "sheet" : "dialog"
                    return "Accessibility observed a \(kind)\(label.map { ": \($0)" } ?? "")."
                }
            }
            return "No sheet or dialog was observed in the bounded Accessibility read."
        }
        var info = ns.userInfo
        info["state"] = state
        info["observation"] = observation
        info[NSLocalizedDescriptionKey] = "\(app) didn't answer in time — it may be showing a dialog or still busy. \(observation) "
            + (ns.code == appleScriptOutcomeUnknownCode ? ns.localizedDescription : "Observe before retrying.")
        return NSError(domain: ns.domain, code: ns.code, userInfo: info)
    }

    /// `effects` is what the script's events did: none when it sent only reads,
    /// occurred when the app accepted another event, unknown when the app answered one with an error.
    private static func scriptValue(_ source: String, pid: pid_t, authored: Bool, cancelled: OSAllocatedUnfairLock<Bool>,
                                    effects: inout String?) throws -> NSAppleEventDescriptor {
        guard let language = OSALanguage(forName: "AppleScript") else {
            throw SenseFailure(code: "unavailable", message: "AppleScript language is unavailable.")
        }
        let instance = OSALanguageInstance(language: language)
        typealias Target = (pid: pid_t, authored: Bool, refused: Bool, wrote: Bool, attempted: Bool, cancelled: OSAllocatedUnfairLock<Bool>)
        var target: Target = (pid, authored, false, false, false, cancelled)
        return try withUnsafeMutablePointer(to: &target) { pointer in
            // A private component confines even computed targets and nested tells;
            // every send keeps the raw primitive's consent, interaction and reply policy,
            // and the reply wait the script itself declared (`with timeout`, else the default).
            let sendCode = OSASetSendProc(instance.componentInstance, { event, reply, _, _, timeout, _, _, refCon in
                guard let event, let reply, let refCon else { return OSErr(-50) }
                let target = refCon.assumingMemoryBound(to: Target.self)
                var pid: pid_t = 0
                var size = 0
                let addressCode = AEGetAttributePtr(event, keyAddressAttr, typeKernelProcessID, nil, &pid,
                                                  MemoryLayout<pid_t>.size, &size)
                guard addressCode == 0, size == MemoryLayout<pid_t>.size,
                      pid == target.pointee.pid || !target.pointee.authored && pid == getpid() else {
                    target.pointee.refused = true
                    return OSErr(-1743)
                }
                if target.pointee.cancelled.withLock({ $0 }) { return OSErr(-128) }
                // Each event is judged by the raw app call's own read rule.
                var eventClass: OSType = 0, eventID: OSType = 0
                AEGetAttributePtr(event, keyEventClassAttr, typeType, nil, &eventClass, MemoryLayout<OSType>.size, &size)
                AEGetAttributePtr(event, keyEventIDAttr, typeType, nil, &eventID, MemoryLayout<OSType>.size, &size)
                let read = AuthoredToolEffects.appReadOnly(["event_class": .string(SystemAppleScriptAdapter.codeText(eventClass)),
                                                            "event_id": .string(SystemAppleScriptAdapter.codeText(eventID))])
                let sent = OSErr(AESendMessage(event, reply, AESendMode(kAEWaitReply | kAENeverInteract | kAEDoNotPromptForUserConsent),
                                               Int(timeout)))
                // Another event wrote only when the app accepted it; an error reply or failed send leaves it
                // unconfirmed. One macOS refused for want of consent never reached the app.
                if !read, ![-1743, -1744].contains(sent) {
                    var number: Int32 = 0
                    let errorReply = AEGetParamPtr(reply, keyErrorNumber, typeSInt32, nil, &number, MemoryLayout<Int32>.size, &size) == noErr && number != 0
                    if sent == noErr, !errorReply { target.pointee.wrote = true } else { target.pointee.attempted = true }
                }
                return sent
            }, pointer)
            let activeCode = OSASetActiveProc(instance.componentInstance, { refCon in
                guard let refCon else { return OSErr(-50) }
                return refCon.assumingMemoryBound(to: Target.self).pointee.cancelled.withLock { $0 } ? OSErr(-128) : 0
            }, pointer)
            defer {
                effects = pointer.pointee.attempted ? "unknown" : pointer.pointee.wrote ? "occurred" : "none"
                OSASetSendProc(instance.componentInstance, nil, nil)
                OSASetActiveProc(instance.componentInstance, nil, nil)
            }
            guard sendCode == 0, activeCode == 0 else {
                throw NSError(domain: "NativeAgentAppleEvent", code: Int(sendCode == 0 ? activeCode : sendCode),
                              userInfo: [NSLocalizedDescriptionKey: "AppleScript target enforcement could not be configured."])
            }
            // AppleScript Language Guide, use (scripting additions): any use
            // disables OSAX unless use/using terms from explicitly enables it.
            // https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/reference/ASLR_control_statements.html
            let script = OSAScript(source: source, from: nil, languageInstance: instance, using: [])
            var error: NSDictionary?
            let value = script.compileAndReturnError(&error) ? script.executeAndReturnError(&error) : nil
            if pointer.pointee.refused {
                throw NSError(domain: "NativeAgentAppleEvent", code: -1743, userInfo: ["state": "undeclared_target",
                    NSLocalizedDescriptionKey: "The script must target only the declared app process \(pid)."])
            }
            let number = cancelled.withLock({ $0 }) ? -128 : error?[OSAScriptErrorNumber] as? Int ?? 0
            guard number == 0, let value else {
                let unknown = (pointer.pointee.wrote || pointer.pointee.attempted) && [ -128, -1712 ].contains(number)
                if !authored, [-1743, -1744].contains(number) {
                    throw AppleScriptError.permissionDenied(app: "the declared app")
                }
                var message = error?[OSAScriptErrorMessage] as? String ?? "AppleScript failed."
                if authored, let range = (error?[OSAScriptErrorRange] as? NSValue)?.rangeValue,
                   range.location <= (source as NSString).length {
                    let prefix = (source as NSString).substring(to: range.location)
                    let line = prefix.replacingOccurrences(of: "\r\n", with: "\n").filter { $0.isNewline }.count - 1
                    message += " (line \(max(1, line)) of your script)"
                }
                throw NSError(domain: "NativeAgentAppleScript", code: unknown ? appleScriptOutcomeUnknownCode : number == 0 ? -1 : number,
                    userInfo: ["apple_event_code": number, NSLocalizedDescriptionKey: unknown
                        ? "AppleScript stopped after sending an event; its outcome is unknown. Observe before retrying — a retry may repeat it."
                        : message])
            }
            return value
        }
    }

    private static func badEvent() -> SenseFailure {
        SenseFailure(code: "bad_input", message: "Use four-character event codes and JSON descriptors: string, bool, int, double, list, or {type}, {enum}, {record}, {object:{want,form,seld,from}}.")
    }

    private static func fourCode(_ value: JSONValue?) throws -> OSType {
        guard case .string(let text)? = value, text.utf8.count == 4, text.utf8.allSatisfy({ $0 < 128 }) else { throw badEvent() }
        return text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func descriptor(_ value: JSONValue, depth: Int = 0) throws -> NSAppleEventDescriptor {
        guard depth < 32 else { throw badEvent() }
        switch value {
        case .null: return .null()
        case .string(let text): return NSAppleEventDescriptor(string: text)
        case .bool(let value): return NSAppleEventDescriptor(boolean: value)
        case .int(let value):
            guard let number = NSAppleEventDescriptor(string: String(value)).coerce(toDescriptorType: typeSInt64) else { throw badEvent() }
            return number
        case .double(let value): return NSAppleEventDescriptor(double: value)
        case .array(let values):
            let list = NSAppleEventDescriptor.list()
            for (index, value) in values.enumerated() { list.insert(try descriptor(value, depth: depth + 1), at: index + 1) }
            return list
        case .object(let fields):
            guard fields.count == 1 else { throw badEvent() }
            if let value = fields["type"] { return NSAppleEventDescriptor(typeCode: try fourCode(value)) }
            if let value = fields["enum"] { return NSAppleEventDescriptor(enumCode: try fourCode(value)) }
            let record = NSAppleEventDescriptor.record()
            if case .object(let object)? = fields["object"] {
                guard Set(object.keys).isSubset(of: ["want", "form", "seld", "from"]), let selected = object["seld"] else { throw badEvent() }
                record.setDescriptor(NSAppleEventDescriptor(typeCode: try fourCode(object["want"])), forKeyword: AEKeyword(keyAEDesiredClass))
                record.setDescriptor(NSAppleEventDescriptor(enumCode: try fourCode(object["form"])), forKeyword: AEKeyword(keyAEKeyForm))
                record.setDescriptor(try descriptor(selected, depth: depth + 1), forKeyword: AEKeyword(keyAEKeyData))
                record.setDescriptor(try descriptor(object["from"] ?? .null, depth: depth + 1), forKeyword: AEKeyword(keyAEContainer))
                guard let specifier = record.coerce(toDescriptorType: DescType(typeObjectSpecifier)) else { throw badEvent() }
                return specifier
            }
            guard case .object(let entries)? = fields["record"] else { throw badEvent() }
            for (key, value) in entries { record.setDescriptor(try descriptor(value, depth: depth + 1), forKeyword: try fourCode(.string(key))) }
            return record
        }
    }

    private static func json(_ value: NSAppleEventDescriptor?) -> JSONValue {
        guard let value else { return .null }
        switch value.descriptorType {
        case typeNull: return .null
        case typeBoolean: return .bool(value.booleanValue)
        case typeSInt16, typeSInt32: return .int(Int64(value.int32Value))
        case typeSInt64:
            if let text = value.coerce(toDescriptorType: typeUnicodeText)?.stringValue, let number = Int64(text) { return .int(number) }
        case typeIEEE64BitFloatingPoint: return .double(value.doubleValue)
        case typeType: return .object(["type": .string(codeText(value.typeCodeValue))])
        case typeEnumerated: return .object(["enum": .string(codeText(value.enumCodeValue))])
        case typeAEList: return .array((0..<value.numberOfItems).compactMap { value.atIndex($0 + 1) }.map { json($0) })
        case DescType(typeObjectSpecifier):
            return .object(["object": .object([
                "want": .string(codeText(value.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue ?? 0)),
                "form": .string(codeText(value.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue ?? 0)),
                "seld": json(value.forKeyword(AEKeyword(keyAEKeyData))), "from": json(value.forKeyword(AEKeyword(keyAEContainer)))])])
        default: break
        }
        if value.isRecordDescriptor {
            var fields: [String: JSONValue] = [:]
            for index in 0..<value.numberOfItems { fields[codeText(value.keywordForDescriptor(at: index + 1))] = json(value.atIndex(index + 1)) }
            return .object(["record": .object(fields)])
        }
        if let text = value.stringValue { return .string(text) }
        return .object(["descriptor_type": .int(Int64(value.descriptorType)), "base64": .string(value.data.base64EncodedString())])
    }

    private static func codeText(_ code: OSType) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, as: UTF8.self)
    }
    #endif
    public func run(script: String) async throws -> String {
        #if canImport(AppKit)
        let result = try await SystemProcessAdapter().run(
            executable: "/usr/bin/osascript",
            arguments: ["-"],
            currentDirectory: nil,
            environment: nil,
            standardInput: Data(script.utf8),
            timeoutSeconds: 30
        )
        guard !result.timedOut else {
            throw MacControlError.applescriptFailed("AppleScript timed out after 30 seconds")
        }
        guard !result.stdoutTruncated, !result.stderrTruncated else {
            throw MacControlError.applescriptFailed("AppleScript output exceeded the capture limit; the result is incomplete")
        }
        guard result.exitCode == 0 else {
            throw MacControlError.applescriptFailed(result.stderr.trimmingCharacters(in: .newlines))
        }
        var output = result.stdout
        if output.hasSuffix("\n") { output.removeLast() }
        return output
        #else
        throw MacControlError.applescriptFailed("AppKit unavailable on this platform")
        #endif
    }

}

public final class SystemProcessAdapter: Sendable {
    public static let defaultOutputByteLimit = 1_048_576

    public init() {}
    final class _Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private let byteLimit: Int
        private var data = Data()
        private var droppedBytes = 0

        init(byteLimit: Int?) {
            self.byteLimit = max(0, byteLimit ?? SystemProcessAdapter.defaultOutputByteLimit)
        }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            let room = max(0, byteLimit - data.count)
            if room > 0 { data.append(chunk.prefix(room)) }
            droppedBytes += max(0, chunk.count - room)
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }

        var truncated: Bool {
            lock.lock()
            defer { lock.unlock() }
            return droppedBytes > 0
        }
    }

    /// Bridges Process.terminationHandler to async/await without blocking a
    /// cooperative executor thread. The child may exit before or after the
    /// continuation is installed, so both paths meet behind this one-shot lock.
    private final class _ProcessCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait(_ continuation: CheckedContinuation<Void, Never>) {
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func finish() {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
        }
    }

    /// Owns process-tree termination for timeout and parent Task cancellation.
    /// Timeout gets a cooperative SIGTERM -> SIGKILL window; explicit user
    /// cancellation SIGKILLs immediately so descendants cannot continue side
    /// effects after cancellation has been acknowledged.
    private final class _ProcessTermination: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private let initialTree: ProcessTreeSnapshot
        private let onSettled: @Sendable () -> Void
        private var requested = false
        private var timeoutRequested = false
        private var cancelEscalationRequested = false
        private var activeTerminationTree: ProcessTreeSnapshot?
        private var finished = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private let cancelEscalationSignal = DispatchSemaphore(value: 0)

        init(
            process: Process,
            initialTree: ProcessTreeSnapshot,
            onSettled: @escaping @Sendable () -> Void
        ) {
            self.process = process
            self.initialTree = initialTree
            self.onSettled = onSettled
        }

        func request(timedOut: Bool) {
            lock.lock()
            if requested {
                // A deadline may already own the graceful TERM window when the
                // parent Task is explicitly cancelled. Cancellation is the
                // stronger motor instruction: wake the existing termination
                // worker so it freezes, rescans, and KILLs the identity-bound
                // tree immediately instead of allowing side effects to continue
                // through the rest of the grace period. The original worker
                // remains the only owner of waitUntilExit/finish.
                let shouldEscalate = !timedOut
                    && timeoutRequested
                    && !finished
                    && !cancelEscalationRequested
                let escalationTree = shouldEscalate ? activeTerminationTree : nil
                if shouldEscalate {
                    cancelEscalationRequested = true
                }
                lock.unlock()
                if shouldEscalate {
                    cancelEscalationSignal.signal()
                    if let escalationTree {
                        // Do the motor stop on the cancellation caller that is
                        // already running. Merely waking the timeout worker can
                        // leave it CPU-starved under machine load. This path
                        // performs signals only; the original worker remains
                        // the sole owner of waitUntilExit and finish/resume.
                        let refreshed = ProcessTreeReaper.snapshot(
                            rootPID: escalationTree.rootPID,
                            retaining: escalationTree
                        )
                        _ = ProcessTreeReaper.quiesceAndKill(refreshed)
                    }
                }
                return
            }
            requested = true
            timeoutRequested = timedOut
            let pid = process.processIdentifier
            lock.unlock()
            guard pid > 0 else {
                finish()
                return
            }

            // Snapshot descendants before signaling the shell. Once the root
            // exits, a surviving grandchild may be reparented and disappear
            // from a later parent-only traversal.
            let terminationTree = Self.captureTree(rootPID: pid, retaining: initialTree)
            lock.lock()
            activeTerminationTree = terminationTree
            let cancellationAlreadyEscalated = cancelEscalationRequested
            lock.unlock()
            if cancellationAlreadyEscalated {
                let refreshed = ProcessTreeReaper.snapshot(
                    rootPID: terminationTree.rootPID,
                    retaining: terminationTree
                )
                _ = ProcessTreeReaper.quiesceAndKill(refreshed)
            }
            let worker = Thread { [self, process] in
                // User cancellation is not a graceful-shutdown request: it is
                // an instruction that no descendant may continue producing
                // side effects. Freeze the tree before the kill/rescan so a
                // shell cannot fork a job-control child between enumeration
                // and its own death. Timeout retains the cooperative TERM window.
                if !timedOut {
                    let frozenTree = ProcessTreeReaper.quiesceAndKill(terminationTree)
                    if process.isRunning { process.waitUntilExit() }
                    let settledTree = ProcessTreeReaper.snapshot(
                        rootPID: pid,
                        retaining: frozenTree
                    )
                    if ProcessTreeReaper.hasLiveDescendant(in: settledTree) {
                        ProcessTreeReaper.signal(settledTree, signal: SIGKILL)
                    }
                    finish()
                    return
                }
                ProcessTreeReaper.signal(terminationTree, signal: SIGTERM)

                // Preserve the established two-second graceful shutdown
                // budget, but finish immediately once the identity-bound tree
                // and direct Process have actually settled.
                let deadline = DispatchTime.now() + .seconds(2)
                while DispatchTime.now() < deadline {
                    let refreshed = ProcessTreeReaper.snapshot(
                        rootPID: pid,
                        retaining: terminationTree
                    )
                    if !process.isRunning
                        && !ProcessTreeReaper.hasLiveDescendant(in: refreshed) {
                        break
                    }
                    if cancellationEscalationWasRequested() {
                        // Rescan from the original identity-bound snapshot
                        // before freezing/KILLing. This retains descendants that
                        // were reparented after the root received SIGTERM while
                        // still refusing PID-reuse matches.
                        let escalationTree = ProcessTreeReaper.snapshot(
                            rootPID: pid,
                            retaining: terminationTree
                        )
                        _ = ProcessTreeReaper.quiesceAndKill(escalationTree)
                        if process.isRunning { process.waitUntilExit() }
                        finish()
                        return
                    }
                    _ = cancelEscalationSignal.wait(timeout: .now() + .milliseconds(5))
                }

                let killTree = ProcessTreeReaper.snapshot(
                    rootPID: pid,
                    retaining: terminationTree
                )
                if process.isRunning || ProcessTreeReaper.hasLiveDescendant(in: killTree) {
                    _ = ProcessTreeReaper.quiesceAndKill(killTree)
                }
                if process.isRunning { process.waitUntilExit() }
                finish()
            }
            worker.qualityOfService = .userInitiated
            worker.start()
        }

        static func captureTree(rootPID: Int32, retaining prior: ProcessTreeSnapshot? = nil) -> ProcessTreeSnapshot {
            let tree = ProcessTreeReaper.snapshot(rootPID: rootPID, retaining: prior)
            #if canImport(Darwin)
            // A shell may have exited and reparented its pipe-owning children.
            // Capture group members at launch even if the root has already
            // exited. Later scans retain those identities and reject a reused
            // root PID; signals never rely on a naked process-group id.
            guard rootPID > 0 else { return tree }
            if let prior {
                if let liveRoot = ProcessTreeReaper.snapshot(rootPID: rootPID).rootIdentity,
                   liveRoot != prior.rootIdentity { return tree }
                guard prior.rootIdentity != nil || !prior.descendants.isEmpty else { return tree }
            }
            let earliest = prior?.rootIdentity ?? tree.rootIdentity ?? prior?.descendants.min {
                ($0.startSeconds, $0.startMicroseconds) < ($1.startSeconds, $1.startMicroseconds)
            }
            let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(rootPID), nil, 0)
            guard bytes > 0 else { return tree }
            var pids = [Int32](repeating: 0, count: Int(bytes) / MemoryLayout<Int32>.stride + 16)
            let used = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(rootPID), &pids,
                                    Int32(pids.count * MemoryLayout<Int32>.stride))
            var identities = tree.descendants
            for pid in pids.prefix(max(0, Int(used)) / MemoryLayout<Int32>.stride) where pid > 0 && pid != rootPID {
                var info = proc_bsdinfo()
                let size = Int32(MemoryLayout<proc_bsdinfo>.size)
                guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                      info.pbi_pgid == UInt32(rootPID)
                else { continue }
                if let earliest,
                   (info.pbi_start_tvsec, info.pbi_start_tvusec) < (earliest.startSeconds, earliest.startMicroseconds) {
                    continue
                }
                let identity = ProcessTreeIdentity(pid: pid, startSeconds: info.pbi_start_tvsec,
                                                   startMicroseconds: info.pbi_start_tvusec)
                if !identities.contains(identity) { identities.append(identity) }
            }
            return ProcessTreeSnapshot(rootPID: tree.rootPID, rootIdentity: tree.rootIdentity, descendants: identities)
            #else
            return tree
            #endif
        }

        private func cancellationEscalationWasRequested() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelEscalationRequested
        }

        func waitIfRequested() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if !requested || finished {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters.append(continuation)
                lock.unlock()
            }
        }

        private func finish() {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            activeTerminationTree = nil
            let pending = waiters
            waiters.removeAll()
            lock.unlock()
            pending.forEach { $0.resume() }
            onSettled()
        }

        var didTimeOut: Bool {
            lock.lock()
            defer { lock.unlock() }
            return timeoutRequested
        }
    }

    /// Native deadline waiter for process timeouts. It is independent of the
    /// cooperative Swift executor (which can be saturated during the full Core
    /// suite) and is wakeable, so normal completion/cancellation leaves no
    /// sleeping timeout thread behind.
    private final class _ProcessDeadline: @unchecked Sendable {
        private let lock = NSLock()
        private let wake = DispatchSemaphore(value: 0)
        private var cancelled = false

        func start(seconds: TimeInterval, action: @escaping @Sendable () -> Void) {
            let boundedMilliseconds = max(1, Int((max(0.001, seconds) * 1_000).rounded(.up)))
            let thread = Thread { [weak self] in
                guard let self else { return }
                let result = wake.wait(timeout: .now() + .milliseconds(boundedMilliseconds))
                lock.lock()
                let shouldFire = result == .timedOut && !cancelled
                lock.unlock()
                if shouldFire { action() }
            }
            thread.qualityOfService = .userInitiated
            thread.start()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
            wake.signal()
        }
    }

    public func run(executable: String, arguments: [String], timeoutSeconds: Int) async throws -> ProcessRunResult {
        try await run(
            executable: executable,
            arguments: arguments,
            currentDirectory: nil,
            environment: nil,
            standardInput: nil,
            timeoutSeconds: TimeInterval(timeoutSeconds),
            outputByteLimit: nil
        )
    }

    /// Shared event-driven subprocess seam for app and core callers that need
    /// a working directory, an exact environment, or stdin. This remains the
    /// same lifecycle owner as the instance entry point above: pipe
    /// draining, cancellation, timeout escalation, and process-tree reaping
    /// must not be reimplemented by each feature.
    public func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?,
        standardInput: Data?,
        timeoutSeconds: TimeInterval?,
        outputByteLimit: Int? = nil,
        launchFailure: @Sendable (Error) -> Error = { MacControlError.ioFailure("Process.run() failed: \($0)") }
    ) async throws -> ProcessRunResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.currentDirectoryURL = currentDirectory
        proc.environment = environment
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        let inputPipe = standardInput.map { _ in Pipe() }
        proc.standardInput = inputPipe ?? FileHandle.nullDevice

        let outBuf = _Buffer(byteLimit: outputByteLimit)
        let errBuf = _Buffer(byteLimit: outputByteLimit)
        let outDrain: ProcessPipeDrain
        do {
            outDrain = try ProcessPipeDrain(handle: outPipe.fileHandleForReading) { outBuf.append($0) }
        } catch {
            throw MacControlError.ioFailure(error.localizedDescription)
        }
        let errDrain: ProcessPipeDrain
        do {
            errDrain = try ProcessPipeDrain(handle: errPipe.fileHandleForReading) { errBuf.append($0) }
        } catch {
            outDrain.stop()
            throw MacControlError.ioFailure(error.localizedDescription)
        }

        let completion = _ProcessCompletion()
        proc.terminationHandler = { _ in completion.finish() }
        do {
            try proc.run()
        } catch {
            proc.terminationHandler = nil
            outDrain.stop()
            errDrain.stop()
            throw launchFailure(error)
        }
        let initialTree = _ProcessTermination.captureTree(rootPID: proc.processIdentifier)
        if let inputPipe, let standardInput {
            // A helper may accept a payload larger than the pipe buffer. Feed
            // it off-thread so the event-driven termination path remains able
            // to enforce its deadline if the child stops reading.
            let handle = inputPipe.fileHandleForWriting
            let writer = Thread {
                try? handle.write(contentsOf: standardInput)
                try? handle.close()
            }
            writer.qualityOfService = .utility
            writer.start()
        }
        ProcessTreeReaper.ensureChildLeadsOwnProcessGroup(proc.processIdentifier)
        let termination = _ProcessTermination(
            process: proc,
            initialTree: initialTree,
            onSettled: {
                outDrain.stop()
                errDrain.stop()
                completion.finish()
            }
        )
        let deadline = _ProcessDeadline()
        if let timeoutSeconds {
            deadline.start(seconds: timeoutSeconds) {
                termination.request(timedOut: true)
            }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion.wait(continuation)
            }
            await outDrain.wait()
            await errDrain.wait()
            await termination.waitIfRequested()
            deadline.cancel()
        } onCancel: {
            termination.request(timedOut: false)
        }
        proc.terminationHandler = nil
        let outData = outBuf.snapshot()
        let errData = errBuf.snapshot()
        if Task.isCancelled {
            throw CancellationError()
        }
        return ProcessRunResult(
            exitCode: proc.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            timedOut: termination.didTimeOut,
            stdoutTruncated: outBuf.truncated,
            stderrTruncated: errBuf.truncated
        )
    }

}

public final class SystemAppControlAdapter: Sendable {
    public init() {}

    public func focusApp(named name: String) async throws -> AppControlRunResult {
        let query = normalizedAppQuery(name)
        guard !query.isEmpty else { throw MacControlError.missingField("app") }
        #if canImport(AppKit)
        return try await Self.openAppOnMain(named: query, front: true)
        #else
        throw MacControlError.appControlFailed("AppKit unavailable on this platform")
        #endif
    }

    public func launchApp(named name: String) async throws -> AppControlRunResult {
        let query = normalizedAppQuery(name)
        guard !query.isEmpty else { throw MacControlError.missingField("app") }
        #if canImport(AppKit)
        return try await Self.openAppOnMain(named: query, front: false)
        #else
        throw MacControlError.appControlFailed("AppKit unavailable on this platform")
        #endif
    }

    public func quitApp(named name: String) async throws -> AppControlRunResult {
        let query = normalizedAppQuery(name)
        guard !query.isEmpty else { throw MacControlError.missingField("app") }
        #if canImport(AppKit)
        return try await Self.quitAppOnMain(named: query)
        #else
        throw MacControlError.appControlFailed("AppKit unavailable on this platform")
        #endif
    }

    public func isApplicationRunning(matching name: String) async -> Bool {
        let query = normalizedAppQuery(name)
        guard !query.isEmpty else { return false }
        #if canImport(AppKit)
        return await Self.isApplicationRunningOnMain(matching: query)
        #else
        return false
        #endif
    }

    private func normalizedAppQuery(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    #if canImport(AppKit)
    @MainActor
    private static func isApplicationRunningOnMain(matching query: String) -> Bool {
        (try? runningApplications(matching: query).isEmpty) == false
    }

    @MainActor
    private static func openAppOnMain(named query: String, front: Bool) async throws -> AppControlRunResult {
        try Task.checkCancellation()
        let running = try runningApp(matching: query)
        guard let url = try running?.bundleURL ?? applicationURL(matching: query) else {
            throw ToolFailureError("app_not_found: \(query)", argumentPath: "name",
                accepted: "An installed app's exact name, bundle identifier or .app path.", effects: .none)
        }
        // Only a request to come forward reopens a running app; one already
        // running in the background is left exactly as it is.
        if let running, !front {
            return runResult(requested: query, app: running, launched: false, activated: false, terminated: false)
        }
        // Opening a running bundle delivers its reopen event, just like the Dock.
        // Workspace also owns the cooperative activation hand-off.
        let app = try await openApplication(at: url, activates: front)
        if front { try await observeActivation(of: app.processIdentifier) }
        try Task.checkCancellation()
        let frontmost = NSWorkspace.shared.frontmostApplication
        let activated = front && frontmost?.processIdentifier == app.processIdentifier
        if front && !activated {
            throw ToolFailureError("Workspace opened \(url.path) with activation requested; after waiting up to 1.5 seconds for activation, the frontmost app is \(frontmost?.localizedName ?? "none") (pid: \(frontmost?.processIdentifier ?? 0)), not \(query) (pid: \(app.processIdentifier)).",
                effects: .occurred, owner: "macOS application activation", tap: "Dock > \(app.localizedName ?? query)")
        }
        return runResult(requested: query, app: app, fallbackURL: url,
            launched: running == nil, activated: activated, terminated: false)
    }

    @MainActor
    private static func observeActivation(of pid: Int32) async throws {
        let (events, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let center = NSWorkspace.shared.notificationCenter
        let observer = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: nil) { notification in
            if (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier == pid {
                signal.yield(())
            }
        }
        defer { center.removeObserver(observer); signal.finish() }
        // Register before reading so activation cannot fall between the read and the wait.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != pid else { return }
        _ = await raceAgainstTimeout(seconds: 1.5) {
            for await _ in events { break }
        }
        try Task.checkCancellation()
    }

    @MainActor
    private static func quitAppOnMain(named query: String) async throws -> AppControlRunResult {
        let running = try runningApplications(matching: query)
        guard !running.isEmpty else {
            if let url = try applicationURL(matching: query) {
                return AppControlRunResult(
                    requestedName: query,
                    matchedName: url.deletingPathExtension().lastPathComponent,
                    bundleIdentifier: Bundle(url: url)?.bundleIdentifier,
                    processIdentifier: nil,
                    launched: false,
                    activated: false,
                    terminated: false,
                    alreadyInDesiredState: true
                )
            }
            throw MacControlError.appControlFailed("app_not_running_or_not_found: \(query)")
        }
        let first = running[0]
        let identities = Set(running.map {
            $0.bundleURL?.standardizedFileURL.path ?? $0.bundleIdentifier ?? "pid:\($0.processIdentifier)"
        })
        guard identities.count == 1 else {
            throw MacControlError.appControlFailed("app_query_ambiguous: use an exact app name or bundle identifier")
        }
        var terminated = false
        for app in running {
            try Task.checkCancellation()
            guard MacDriverContext.binding?.allowsEmission == true else {
                throw MacControlError.appControlFailed(MacAttentionSessionStore.driverRefusal)
            }
            if app.terminate() { terminated = true }
        }
        return runResult(
            requested: query,
            app: first,
            launched: false,
            activated: false,
            terminated: terminated
        )
    }

    @MainActor
    private static func openApplication(at url: URL, activates: Bool) async throws -> NSRunningApplication {
        try Task.checkCancellation()
        guard MacDriverContext.binding?.allowsEmission == true else {
            throw ToolFailureError(MacAttentionSessionStore.driverRefusal, effects: .none,
                owner: "Mac attention", tap: "NativeAgent Mac chat > composer controls > Let [agent name] use the Mac",
                personDecides: true)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let config = NSWorkspace.OpenConfiguration()
            config.activates = activates
            config.allowsRunningApplicationSubstitution = false
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
                if let error {
                    let cause = error as NSError
                    continuation.resume(throwing: ToolFailureError("\(cause.domain) (\(cause.code)): \(cause.localizedDescription)",
                        effects: .unknown, owner: "macOS Launch Services", tap: "Finder > \(url.path) > Open"))
                } else if let app {
                    continuation.resume(returning: app)
                } else {
                    continuation.resume(throwing: ToolFailureError("Workspace returned no application for \(url.path)",
                        effects: .unknown, owner: "macOS Launch Services", tap: "Finder > \(url.path) > Open"))
                }
            }
        }
    }

    @MainActor
    private static func runningApp(matching query: String) throws -> NSRunningApplication? {
        let running = try runningApplications(matching: query)
        let identities = Set(running.map {
            $0.bundleURL?.standardizedFileURL.path ?? $0.bundleIdentifier ?? "pid:\($0.processIdentifier)"
        })
        guard identities.count <= 1 else {
            let candidates = running.map { "\($0.localizedName ?? "unnamed") [\($0.bundleIdentifier ?? "no bundle id")] \($0.bundleURL?.path ?? "pid:\($0.processIdentifier)")" }.sorted().joined(separator: "; ")
            throw ToolFailureError("app_query_ambiguous: \(query) matches \(candidates). Choose an exact app name, bundle identifier or .app path.",
                argumentPath: "name", accepted: candidates, effects: .none)
        }
        return running.first
    }

    @MainActor
    private static func runningApplications(matching query: String) throws -> [NSRunningApplication] {
        let running = NSWorkspace.shared.runningApplications
        let lower = query.lowercased()
        // A person means the app with a Dock icon, not a helper or service
        // that shares its name ("Google Chrome" alert service, 10-09).
        func preferRegular(_ apps: [NSRunningApplication]) -> [NSRunningApplication] {
            let regular = apps.filter { $0.activationPolicy == .regular }
            return regular.isEmpty ? apps : regular
        }
        if looksLikeBundleIdentifier(query) {
            let exactBundle = running.filter { ($0.bundleIdentifier ?? "").caseInsensitiveCompare(query) == .orderedSame }
            if !exactBundle.isEmpty { return preferRegular(exactBundle) }
        }
        let exactName = running.filter { ($0.localizedName ?? "").caseInsensitiveCompare(query) == .orderedSame }
        if !exactName.isEmpty { return preferRegular(exactName) }
        let exactBundle = running.filter { ($0.bundleIdentifier ?? "").caseInsensitiveCompare(query) == .orderedSame }
        if !exactBundle.isEmpty { return preferRegular(exactBundle) }
        // "Mail" with Mail stopped and MailMate running means Mail: a partial
        // name only when no app by that exact name is installed either.
        guard try applicationURL(matching: query) == nil else { return [] }
        let partial = running.filter { app in
            let name = (app.localizedName ?? "").lowercased()
            let bundle = (app.bundleIdentifier ?? "").lowercased()
            return name.contains(lower) || bundle.contains(lower)
        }
        return preferRegular(partial)
    }

    @MainActor
    private static func applicationURL(matching query: String) throws -> URL? {
        if let url = try installedApplicationURL(named: query) { return url }
        if looksLikeBundleIdentifier(query), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query) {
            nativeLog("SystemAppControlAdapter: Launch Services resolved %@ to %@", query, url.path)
            return url
        }
        // Anywhere else Launch Services knows an app by exactly this name.
        guard !query.contains("/") else { return nil }
        let name = query.hasSuffix(".app") ? String(query.dropLast(4)) : query
        guard let path = NSWorkspace.shared.fullPath(forApplication: name) else { return nil }
        let url = URL(fileURLWithPath: path)
        return url.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(name) == .orderedSame ? url : nil
    }

    /// Exact name, bundle id or bundle path from the Mac's own app index.
    public static func installedApplicationURL(named query: String) throws -> URL? {
        let expandedQuery = (query as NSString).expandingTildeInPath
        if expandedQuery.hasPrefix("/"), expandedQuery.hasSuffix(".app") {
            let url = URL(fileURLWithPath: expandedQuery)
            if isApplicationBundle(url) { return url }
        }
        let name = query.hasSuffix(".app") ? String(query.dropLast(4)) : query
        let apps: [MacAppIndex.App]
        do { apps = try MacAppIndex.shared.apps() }
        catch {
            throw ToolFailureError(error.localizedDescription, effects: .none,
                owner: "macOS Spotlight app index", tap: "System Settings > Spotlight")
        }
        return apps.first {
            $0.bundleID?.caseInsensitiveCompare(query) == .orderedSame
                || $0.name.caseInsensitiveCompare(name) == .orderedSame
                || $0.url.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
        }?.url
    }

    private static func looksLikeBundleIdentifier(_ query: String) -> Bool {
        query.contains(".") && !query.contains("/") && !query.contains(" ")
    }

    private static func isApplicationBundle(_ url: URL) -> Bool {
        url.pathExtension.caseInsensitiveCompare("app") == .orderedSame
            && FileManager.default.fileExists(atPath: url.path)
    }

    @MainActor
    private static func runResult(
        requested: String,
        app: NSRunningApplication,
        fallbackURL: URL? = nil,
        launched: Bool,
        activated: Bool,
        terminated: Bool
    ) -> AppControlRunResult {
        let name = app.localizedName ?? fallbackURL?.deletingPathExtension().lastPathComponent
        let bundleIdentifier = app.bundleIdentifier ?? fallbackURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
        return AppControlRunResult(
            requestedName: requested,
            matchedName: name,
            bundleIdentifier: bundleIdentifier,
            processIdentifier: app.processIdentifier,
            launched: launched,
            activated: activated,
            terminated: terminated
        )
    }
    #endif
}

public struct SystemOpenTargetAdapter: Sendable {
    public init() {}

    public func requestOpen(_ url: URL, background: Bool) async throws -> [String: JSONValue] {
        #if canImport(AppKit)
        return try await Self.requestOpenOnMain(url, background: background)
        #else
        throw MacControlError.appControlFailed("AppKit unavailable on this platform")
        #endif
    }

    #if canImport(AppKit)
    @MainActor
    private static func requestOpenOnMain(_ url: URL, background: Bool) async throws -> [String: JSONValue] {
        try Task.checkCancellation()
        guard MacDriverContext.binding?.allowsEmission == true else {
            throw MacControlError.appControlFailed(MacAttentionSessionStore.driverRefusal)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = !background
        let app = try await NSWorkspace.shared.open(url, configuration: configuration)
        return [
            "matched_name": app.localizedName.map(JSONValue.string) ?? .null,
            "bundle_identifier": app.bundleIdentifier.map(JSONValue.string) ?? .null,
            "process_identifier": .int(Int64(app.processIdentifier)),
        ]
    }
    #endif
}

public final class SystemFileManagerAdapter: Sendable {
    public init() {}
    // FileManager.default is NOT Sendable as of Swift 6 — fetch per-call
    // instead of storing on the actor/adapter. Per Apple's own audit it's
    // thread-safe for these operations even though the type lacks
    // the Sendable bill of health.
    public func readData(at url: URL, maxBytes: Int) throws -> Data {
        let handle = try regularFileHandle(at: url, writing: false)
        defer { try? handle.close() }
        return try handle.read(upToCount: max(0, maxBytes)) ?? Data()
    }
    private func regularFileHandle(at url: URL, writing: Bool) throws -> FileHandle {
        #if canImport(Darwin)
        // A FIFO blocks during open, before FileHandle can impose any read
        // limit. Inspect the opened descriptor, not a racy path preflight.
        let flags = writing ? O_WRONLY | O_APPEND : O_RDONLY
        let fd = Darwin.open(url.path, flags | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            Darwin.close(fd)
            throw POSIXError(code)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(fd)
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [
                NSLocalizedDescriptionKey: "I can only read or append to a regular file.",
            ])
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        #else
        return try writing ? FileHandle(forWritingTo: url) : FileHandle(forReadingFrom: url)
        #endif
    }
    public func writeData(_ data: Data, to url: URL, append: Bool) throws {
        let fm = FileManager.default
        if append, fm.fileExists(atPath: url.path) {
            let handle = try regularFileHandle(at: url, writing: true)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            let parent = url.deletingLastPathComponent()
            if !fm.fileExists(atPath: parent.path) {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            // A failed replacement (including a full disk) must leave the
            // previous file intact, rather than truncating it before writing.
            try data.write(to: url, options: .atomic)
        }
    }
    public func listDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
    }
    public func moveItem(from src: URL, to dst: URL) throws {
        try VerifiedPath.transfer(from: src, to: dst, copy: false, overwrite: false)
    }
    public func trashItem(at url: URL) throws {
        var resulting: NSURL? = nil
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
    }
    public func itemExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

extension SystemAppleScriptAdapter {
    /// Automation consent is per target application.
    public static let automationTargetApps = ["Mail", "Messages", "Notes", "Music"]

    /// Bundle IDs for the four target apps Agent drives via AppleScript.
    /// Used by `AEDeterminePermissionToAutomateTarget` — it identifies the
    /// target by bundle ID, not human-readable name.
    public static let automationTargetBundleIDs: [String: String] = [
        "Mail":     "com.apple.mail",
        "Messages": "com.apple.MobileSMS",
        "Notes":    "com.apple.Notes",
        "Music":    "com.apple.Music",
    ]

    public static func automationStatus(app: String, ask: Bool) async -> String {
        guard let bundleID = automationTargetBundleIDs[app] else { return "unknown" }
        let permission = await SystemAppleScriptAdapter.automationPermission(bundleID: bundleID, ask: ask)
        guard case .object(let fields) = permission else { return "unknown" }
        switch fields["code"] {
        case .int(0): return "granted"
        case .int(-1743): return "denied"
        case .int(-1744): return "not_determined"
        case .int(-600): return "app_not_running"
        default: return "unknown"
        }
    }

}
