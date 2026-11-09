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

// Blueprint: | `MacAppleEvents.swift` | Native OSA: per-event target/Write checks, bounded replies, held calls and their settle, volume recipe |

public final class AppleScriptExecution: Sendable {
    public init() {}

    public static let appleScriptOutcomeUnknownCode = -1002

    public static func automationTarget(_ permission: String) -> String? {
        switch permission {
        case "notes", "mail", "music": return MacIntegrationID.appBundleIDs(for: permission).first
        default: break
        }
        guard let prefix = ["applescript:", "jxa:"].first(where: permission.hasPrefix),
              permission.count > prefix.count else { return nil }
        return String(permission.dropFirst(prefix.count))
    }

    public static func checkAppScript(_ args: [String: JSONValue]) throws {
        guard let script = args["script"] else {
            if args["hold"] != nil { throw SenseFailure(code: "bad_input", message: "hold requires a script.") }
            return
        }
        guard case .string(let source) = script, !source.isEmpty,
              Set(args.keys).isSubset(of: ["bundle_id", "script", "launch", "read_only", "hold"]),
              args["launch"] == nil || args["launch"] == .bool(true) || args["launch"] == .bool(false),
              args["read_only"] == nil || args["read_only"] == .bool(true) || args["read_only"] == .bool(false) else {
            throw SenseFailure(code: "bad_input", message: """
                Pass {bundle_id,script,launch?,read_only?,hold?} with an AppleScript body for the declared app; launch:false never opens it; read_only:true \
                refuses every modifying event.
                """)
        }
        if let hold = args["hold"] {
            guard args["read_only"] == .bool(false), case .object(let held) = hold, Set(held.keys) == ["seconds", "settle"],
                  case .int(let seconds)? = held["seconds"], (1...30).contains(seconds), case .string(let settle)? = held["settle"] else {
                throw SenseFailure(code: "bad_input", message: """
                    hold is {seconds, settle}: a whole number of seconds from 1 through 30 and the AppleScript body that settles the app afterwards; a held \
                    call is read_only:false.
                    """)
            }
            try checkAppScript(["bundle_id": args["bundle_id"] ?? .null, "script": .string(settle), "launch": .bool(false), "read_only": .bool(false)])
        }
        // Validate syntax that can change the execution environment, not app commands. Strings/comments are data; quoted identifiers remain code.
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
            throw SenseFailure(code: "undeclared_target", message: """
                The runner owns the script environment and app target. Resource imports (use / using terms from), script objects (including load script / run \
                script), explicit app tells, self references and raw code terms are refused.
                """)
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
                throw SenseFailure(code: "undeclared_target",
                    message: "The script body must not close the runner's app tell. Use explicit end statements for its own blocks.")
            }
        }
    }

    public static func automationPermission(bundleID: String, ask: Bool = false) async -> JSONValue {
        #if canImport(AppKit)
        // Resolve even if the caller cancels: an unfinished lookup must not be reported as an app that is not installed.
        guard let url = await Task.detached(priority: .userInitiated, operation: {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        }).value else {
            return .object(["bundle_id": .string(bundleID), "state": .string("unavailable"),
                            "detail": .string("No installed app resolves this bundle id.")])
        }
        do {
            // A stopped target cannot present consent. Only the owner's ask opens it, without activating it, through the execution owner.
            let pid = ask ? try await appProcess(at: url) : nil
            // Passive reads resolve the running process and consent together, off-main, and never launch or prompt.
            return try await onAppleScriptQueue { _ in
                permission(bundleID: bundleID, url: url, pid: ask ? pid : runningApp(at: url)?.processIdentifier, ask: ask)
            }
        } catch {
            return .object(["bundle_id": .string(bundleID), "app_path": .string(url.path),
                            "state": .string("unavailable"), "detail": .string(error.localizedDescription)])
        }
        #else
        return .object(["state": .string("unavailable")])
        #endif
    }

    #if canImport(AppKit)
    // One serial queue owns OSA/consent/reply work; queued cancellation sends nothing and running cancellation is checked per event.
    private static let appleScriptQueue = DispatchQueue(label: "NativeAgent.AppleScript", qos: .userInitiated)
    // The latest held call on an app process owns its settle; any later write to that process supersedes it, so an earlier hold settles nothing.
    private static let holders = OSAllocatedUnfairLock<[pid_t: UUID]>(initialState: [:])

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

    // NSRunningApplication's properties are thread-safe; keep these reads on the Apple Event owner's queue.
    private static func runningApp(at url: URL) -> NSRunningApplication? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath()
        return NSWorkspace.shared.runningApplications.first {
            !$0.isTerminated && $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == path
        }
    }

    private static func appProcess(at url: URL) async throws -> pid_t {
        try Task.checkCancellation()
        if let pid = try await onAppleScriptQueue({ _ in runningApp(at: url)?.processIdentifier }) { return pid }
        return try await launchAppProcess(at: url)
    }

    @MainActor private static func launchAppProcess(at url: URL) async throws -> pid_t {
        try Task.checkCancellation()
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
        var fields: [String: JSONValue] = ["bundle_id": .string(bundleID), "app_path": .string(url.path), "code": .int(Int64(code)),
                        "state": .string(state), "detail": .string(code == -1743
                            ? "Automation was denied by the owner; only the owner can change it in System Settings › Privacy & Security › Automation."
                            : code == -1744 ? "macOS Automation consent is still not asked for this app. Allow the permission card to ask macOS."
                            : code == -600 ? "Open \(url.path), then request Automation consent again." : state)]
        if [-1743, -1744].contains(Int(code)) {
            fields["remedy"] = MacFourVerbsReply.permissionRemedy("applescript:" + bundleID, name: "Automation for " + bundleID)
        }
        return .object(fields)
    }
    #endif

    /// Keep app events in-process; the isolated executor supplies only JSON.
    public func callApp(_ arguments: JSONValue, targets: [String: String], context: MacOperationContext) async throws -> JSONValue {
        try await callApp(arguments, targets: targets, holder: nil, context: context)
    }

    private func callApp(_ arguments: JSONValue, targets: [String: String], holder: UUID?, context: MacOperationContext) async throws -> JSONValue {
        guard case .object(let args) = arguments, case .string(let bundleID)? = args["bundle_id"],
              let access = targets[bundleID], ["read", "write"].contains(access) else {
            throw SenseFailure(code: "undeclared_target", message: "Declare read or write reach for this app's bundle id.")
        }
        let read = AuthoredToolEffects.appReadOnly(args)
        if !read, let refusal = MacAppActGate.refusal(bundleID: bundleID, throughAppleEvents: true, context: context) { throw refusal }
        guard access == "write" || read else {
            throw SenseFailure(code: "read_only", message: "A read-declared app refuses modifying or unclassified events.")
        }
        try Self.checkAppScript(args)
        #if canImport(AppKit)
        guard let url = await Task.detached(priority: .userInitiated, operation: {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        }).value else {
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
        let pid: pid_t
        if args["launch"] == .bool(false) {
            try Task.checkCancellation()
            guard let running = try await Self.onAppleScriptQueue({ _ in Self.runningApp(at: url)?.processIdentifier }) else {
                return .object(["bundle_id": .string(bundleID), "app_path": .string(url.path),
                                "state": .string("not_running"), "effects": .string("none")])
            }
            pid = running
        } else {
            pid = try await Self.appProcess(at: url)
        }
        let consentRoot = context.dataRoot
        if !read, holder == nil { Self.holders.withLock { if $0[pid] != nil { $0[pid] = UUID() } } }
        let response: JSONValue = try await Self.onAppleScriptQueue { cancelled in
            if let holder, Self.holders.withLock({ $0[pid] }) != holder {
                return .object(["code": .int(0), "value": .string("superseded"), "effects": .string("none")])
            }
            let permission = Self.permission(bundleID: bundleID, url: url, pid: pid)
            guard case .object(let consent) = permission, consent["state"] == .string("allowed") else { return permission }
            var effects: String?
            do {
                let value: NSAppleEventDescriptor?
                if case .string(let source)? = args["script"] {
                    let target = bundleID.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                    let program = "use AppleScript version \"2.4\"\ntell application id \"\(target)\"\n\(source)\nend tell"
                    value = try Self.scriptValue(program, pid: pid, readOnly: read, cancelled: cancelled,
                        consentRoot: consentRoot, effects: &effects, context: context)
                } else {
                    let event = NSAppleEventDescriptor.appleEvent(withEventClass: try Self.fourCode(args["event_class"]),
                        eventID: try Self.fourCode(args["event_id"]), targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
                        returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
                    if let value = args["parameters"] {
                        guard case .object(let parameters) = value else { throw Self.badEvent() }
                        for (key, value) in parameters { event.setParam(try Self.descriptor(value), forKeyword: try Self.fourCode(.string(key))) }
                    }
                    // Bound replies with the Apple Event Manager timeout so an unresponsive app cannot wait forever.
                    let options: NSAppleEventDescriptor.SendOptions = [.waitForReply, .neverInteract,
                        .init(rawValue: UInt(kAEDoNotPromptForUserConsent))]
                    // A cancel that arrived during the preflight stops the event before it is sent.
                    guard !cancelled.withLock({ $0 }) else {
                        throw NSError(domain: "NativeAgentAppleEvent", code: -128,
                                      userInfo: [NSLocalizedDescriptionKey: "The call was cancelled before its event was sent."])
                    }
                    if !read, let refusal = MacAppActGate.refusal(pid: pid, throughAppleEvents: true, dataRoot: consentRoot, context: context) { throw refusal }
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
            } catch let refusal as MacAppActRefusal {
                var fields = refusal.fields
                fields["effects"] = effects.map(JSONValue.string) ?? .string("none")
                return .object(fields)
            } catch {
                let error = Self.appError(error, pid: pid, app: url.deletingPathExtension().lastPathComponent, context: context) as NSError
                let code = error.userInfo["apple_event_code"] as? Int ?? error.code
                var failed: [String: JSONValue] = ["bundle_id": .string(bundleID), "app_path": .string(url.path), "read_only": .bool(read),
                    "code": .int(Int64(code)), "state": .string(error.userInfo["state"] as? String
                        ?? (code == -1744 ? "needs_consent" : code == -1743 ? "denied" : "failed")),
                    "message": .string(error.localizedDescription),
                    "detail": .string(error.userInfo["state"] != nil ? error.localizedDescription
                        : code == -1743 ? """
                            Automation was denied by the owner; only the owner can change it in System Settings › Privacy & Security › Automation.
                            """
                        : error.localizedDescription)]
                failed["effects"] = effects.map(JSONValue.string)
                if error.userInfo["state"] == nil, [-1743, -1744].contains(code) {
                    failed["remedy"] = MacFourVerbsReply.permissionRemedy("applescript:" + bundleID,
                        name: "Automation for " + bundleID, mode: read ? .read : .write)
                }
                return .object(failed)
            }
        }
        guard case .object(let hold)? = args["hold"], case .int(let seconds)? = hold["seconds"], case .string(let settleScript)? = hold["settle"],
              case .object(let played) = response else { return response }
        // A hold holds only what the call changed: a script that sent no write event leaves nothing to wait on or settle.
        guard ["occurred", "partial", "unknown"].contains(played["effects"]?.stringValue ?? "") else { return response }
        let ran = played["code"] == .int(0) && played["state"] == nil
        // The stem owns the hold: neither the part nor the agent's turn keeps a timer or a later job. Stop ends the wait; the settle still runs.
        let token = UUID()
        Self.holders.withLock { $0[pid] = token }
        var cancelled = false
        do { if ran { try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000) } }
        catch { cancelled = true }
        let settled = await settle { () -> JSONValue in
            let context = context.settling()
            do {
                guard try await Self.onAppleScriptQueue({ _ in Self.runningApp(at: url)?.processIdentifier }) == pid else {
                    return .object(["code": .int(0), "value": .string("player_exited"), "effects": .string("none")])
                }
                return try await self.callApp(.object(["bundle_id": .string(bundleID), "launch": .bool(false), "read_only": .bool(false),
                                                       "script": .string(settleScript)]), targets: targets, holder: token, context: context)
            } catch {
                return .object(["state": .string("failed"), "effects": .string("unknown"), "message": .string(error.localizedDescription)])
            }
        }
        Self.holders.withLock { if $0[pid] == token { $0[pid] = nil } }
        var done = played
        var receipt: [String: JSONValue] = ["seconds": .int(seconds), "cancelled": .bool(cancelled), "settle": settled]
        if case .object(let settledFields) = settled, settledFields["code"] == .int(0) || settledFields["state"] == .string("not_running") {
            receipt["outcome"] = settledFields["value"] ?? .string("not_running")
        } else {
            receipt["state"] = .string("settle_failed")
            receipt["message"] = .string("The held call ran, but its settle could not be confirmed. Read the app before doing anything again.")
            done["effects"] = .string("unknown")
        }
        done["hold"] = .object(receipt)
        return .object(done)
        #else
        throw SenseFailure(code: "unavailable", message: "App events require macOS.")
        #endif
    }

    #if canImport(AppKit)
    private static func appError(_ error: Error, pid: pid_t, app: String, context: MacOperationContext) -> Error {
        let ns = error as NSError
        guard (ns.userInfo["apple_event_code"] as? Int ?? ns.code) == -1712 else { return error }
        var state = "app_timeout"
        let observation = context.holding(\.readDeadline, Date().addingTimeInterval(MacAXLimits.readSeconds)) {
            context in let source = SystemMacAXElementSource()
            guard source.isTrusted() else { return "Accessibility permission is unavailable, so a dialog could not be checked." }
            for window in source.windowRoots(pid: pid, context: context) {
                let snapshot = MacAccessibilityReader.walk(source: source, root: window.ref, context: context)
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

    /// `effects` is what the script's events did: none when it sent only reads, occurred when the app accepted another event, unknown when the app answered one
    /// with an error.
    private static func scriptValue(_ source: String, pid: pid_t, readOnly: Bool, cancelled: OSAllocatedUnfairLock<Bool>,
                                    consentRoot: URL, effects: inout String?, context: MacOperationContext) throws -> NSAppleEventDescriptor {
        guard let language = OSALanguage(forName: "AppleScript") else {
            throw SenseFailure(code: "unavailable", message: "AppleScript language is unavailable.")
        }
        let instance = OSALanguageInstance(language: language)
        typealias Target = (pid: pid_t, readOnly: Bool, refused: Bool, refusedRead: Bool, wrote: Bool, attempted: Bool,
            cancelled: OSAllocatedUnfairLock<Bool>, consentRoot: URL, appRefusal: MacAppActRefusal?, deadline: Date, context: MacOperationContext)
        var target: Target = (pid, readOnly, false, false, false, false, cancelled, consentRoot, nil, Date().addingTimeInterval(30), context)
        return try withUnsafeMutablePointer(to: &target) { pointer in
            // A private component confines even computed targets and nested tells; every send keeps the raw primitive's consent, interaction and reply policy,
            // and the reply wait the script itself declared (`with timeout`, else the default).
            let sendCode = OSASetSendProc(instance.componentInstance, { event, reply, _, _, timeout, _, _, refCon in
                guard let event, let reply, let refCon else { return OSErr(-50) }
                let target = refCon.assumingMemoryBound(to: Target.self)
                var pid: pid_t = 0
                var size = 0
                let addressCode = AEGetAttributePtr(event, keyAddressAttr, typeKernelProcessID, nil, &pid,
                                                  MemoryLayout<pid_t>.size, &size)
                guard addressCode == 0, size == MemoryLayout<pid_t>.size,
                      pid == target.pointee.pid else {
                    target.pointee.refused = true
                    return OSErr(-1743)
                }
                if target.pointee.cancelled.withLock({ $0 }) || Date() >= target.pointee.deadline { return OSErr(-128) }
                // Each event is judged by the raw app call's own read rule.
                var eventClass: OSType = 0, eventID: OSType = 0
                AEGetAttributePtr(event, keyEventClassAttr, typeType, nil, &eventClass, MemoryLayout<OSType>.size, &size)
                AEGetAttributePtr(event, keyEventIDAttr, typeType, nil, &eventID, MemoryLayout<OSType>.size, &size)
                let read = AuthoredToolEffects.appReadOnly(["event_class": .string(AppleScriptExecution.codeText(eventClass)),
                                                            "event_id": .string(AppleScriptExecution.codeText(eventID))])
                if target.pointee.readOnly && !read {
                    target.pointee.refusedRead = true
                    return OSErr(-1743)
                }
                if !read {
                    let refusal = MacAppActGate.refusal(pid: pid, throughAppleEvents: true, dataRoot: target.pointee.consentRoot,
                        context: target.pointee.context)
                    if let refusal {
                        target.pointee.appRefusal = refusal
                        return OSErr(-1743)
                    }
                }
                let remainingTicks = max(1, Int(target.pointee.deadline.timeIntervalSinceNow * 60))
                let sent = OSErr(AESendMessage(event, reply, AESendMode(kAEWaitReply | kAENeverInteract | kAEDoNotPromptForUserConsent),
                                               min(timeout > 0 ? Int(timeout) : remainingTicks, remainingTicks)))
                // Another event wrote only when the app accepted it; an error reply or failed send leaves it unconfirmed. One macOS refused for want of consent
                // never reached the app.
                if !read, ![-1743, -1744].contains(sent) {
                    var number: Int32 = 0
                    let errorReply = AEGetParamPtr(reply, keyErrorNumber, typeSInt32, nil, &number, MemoryLayout<Int32>.size, &size) == noErr && number != 0
                    if sent == noErr, !errorReply { target.pointee.wrote = true } else { target.pointee.attempted = true }
                }
                return sent
            }, pointer)
            let activeCode = OSASetActiveProc(instance.componentInstance, { refCon in
                guard let refCon else { return OSErr(-50) }
                let target = refCon.assumingMemoryBound(to: Target.self).pointee
                return target.cancelled.withLock { $0 } || Date() >= target.deadline ? OSErr(-128) : 0
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
            // AppleScript Language Guide, use (scripting additions): any use disables OSAX unless use/using terms from explicitly enables it.
            // https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/reference/ASLR_control_statements.html
            let script = OSAScript(source: source, from: nil, languageInstance: instance, using: [])
            var error: NSDictionary?
            let value = script.compileAndReturnError(&error) ? script.executeAndReturnError(&error) : nil
            if let refusal = pointer.pointee.appRefusal { throw refusal }
            if pointer.pointee.refusedRead {
                throw NSError(domain: "NativeAgentAppleEvent", code: -1743, userInfo: ["state": "read_only",
                    NSLocalizedDescriptionKey: "This script declared read-only access; a modifying or unclassified event was refused before dispatch."])
            }
            if pointer.pointee.refused {
                throw NSError(domain: "NativeAgentAppleEvent", code: -1743, userInfo: ["state": "undeclared_target",
                    NSLocalizedDescriptionKey: "The script must target only the declared app process \(pid)."])
            }
            let number = cancelled.withLock({ $0 }) ? -128 : error?[OSAScriptErrorNumber] as? Int ?? 0
            guard number == 0, let value else {
                let unknown = (pointer.pointee.wrote || pointer.pointee.attempted) && [ -128, -1712 ].contains(number)
                var message = error?[OSAScriptErrorMessage] as? String ?? "AppleScript failed."
                if let range = (error?[OSAScriptErrorRange] as? NSValue)?.rangeValue,
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
        SenseFailure(code: "bad_input", message: """
            Use four-character event codes and JSON descriptors: string, bool, int, double, list, or {type}, {enum}, {ordinal}, {record}, \
            {object:{want,form,seld,from}}. ordinal must be \"all \", \"firs\", \"last\", \"midd\" or \"any \" (including spaces).
            """)
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
            if let value = fields["ordinal"] {
                var ordinal = try fourCode(value)
                guard [OSType(kAEAll), OSType(kAEFirst), OSType(kAELast), OSType(kAEMiddle), OSType(kAEAny)].contains(ordinal),
                      let descriptor = NSAppleEventDescriptor(descriptorType: DescType(typeAbsoluteOrdinal),
                          bytes: &ordinal, length: MemoryLayout<OSType>.size) else { throw badEvent() }
                return descriptor
            }
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
        case typeAbsoluteOrdinal:
            guard value.data.count == MemoryLayout<OSType>.size else { break }
            let ordinal = value.data.withUnsafeBytes { $0.loadUnaligned(as: OSType.self) }
            return .object(["ordinal": .string(codeText(ordinal))])
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
    /// Only the fixed system-volume recipe calls this subprocess exit. App scripts use callApp and its native, per-event target enforcement.
    package func runSystemVolume(script: String) async throws -> String {
        #if canImport(AppKit)
        let result = try await ProcessExecution().run(
            executable: "/usr/bin/osascript", arguments: ["-"], currentDirectory: nil,
            environment: nil, standardInput: Data(script.utf8), timeoutSeconds: 30)
        guard !result.timedOut else { throw MacControlError.applescriptFailed("System volume script timed out after 30 seconds") }
        guard !result.stdoutTruncated, !result.stderrTruncated else {
            throw MacControlError.applescriptFailed("System volume output exceeded the capture limit")
        }
        guard result.exitCode == 0 else { throw MacControlError.applescriptFailed(result.stderr.trimmingCharacters(in: .newlines)) }
        var output = result.stdout
        if output.hasSuffix("\n") { output.removeLast() }
        return output
        #else
        throw MacControlError.applescriptFailed("AppKit unavailable on this platform")
        #endif
    }

}

extension AppleScriptExecution {
    public static let automationTargetApps = ["Mail", "Messages", "Notes", "Music"]

    /// Use bundle IDs for Automation targets so display-name changes cannot redirect consent.
    public static let automationTargetBundleIDs: [String: String] = Dictionary(uniqueKeysWithValues:
        [MacIntegrationID.mail, MacIntegrationID.messages, MacIntegrationID.notes, MacIntegrationID.music].compactMap { id in
            MacIntegrationID.appBundleIDs(for: id).first.map { (MacIntegrationID.displayName(for: id), $0) }
        })

    public static func automationStatusKey(app: String) -> String { "apple_events_\(app.lowercased())" }

    public static func automationStatus(app: String, ask: Bool) async -> String {
        guard let bundleID = automationTargetBundleIDs[app] else { return "unknown" }
        let permission = await AppleScriptExecution.automationPermission(bundleID: bundleID, ask: ask)
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
