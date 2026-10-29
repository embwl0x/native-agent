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

// Blueprint: | `MacAppleEvents.swift` | `AppleScriptExecution`: bundle-specific AppleScript/JXA targets and Automation status; URL-bound launch:false calls, native per-event read-only enforcement and Music playback settled once against the original track/process/command |

public final class AppleScriptExecution: Sendable {
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
        guard let script = args["script"] else {
            if args["seconds"] != nil || args["track_id"] != nil { throw SenseFailure(code: "bad_input", message: "Music seconds and track_id require a playback script.") }
            return
        }
        guard case .string(let source) = script, !source.isEmpty,
              Set(args.keys).isSubset(of: ["bundle_id", "script", "launch", "read_only", "seconds", "track_id"]),
              args["launch"] == nil || args["launch"] == .bool(true) || args["launch"] == .bool(false),
              args["read_only"] == nil || args["read_only"] == .bool(true) || args["read_only"] == .bool(false) else {
            throw SenseFailure(code: "bad_input", message: "Pass {bundle_id,script,launch?,read_only?} with an AppleScript body for the declared app; launch:false never opens it; read_only:true refuses every modifying event.")
        }
        if let seconds = args["seconds"] {
            guard args["bundle_id"] == .string("com.apple.Music"), args["read_only"] == .bool(false),
                  case .int(let duration) = seconds, (1...30).contains(duration),
                  case .string(let trackID)? = args["track_id"],
                  trackID.range(of: "^[0-9A-Fa-f]{16}$", options: .regularExpression) != nil else {
                throw SenseFailure(code: "bad_input", message: "Only a Music playback script takes seconds (integer 1–30), with read_only:false and track_id (the selected song's 16-digit hex persistent ID).")
            }
        } else if args["track_id"] != nil {
            throw SenseFailure(code: "bad_input", message: "A Music track_id accompanies seconds only.")
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
    // One serial queue owns OSA dictionary reads, consent, scripts and reply waits; queued cancellation sends nothing, running cancellation is checked at every event.
    private static let appleScriptQueue = DispatchQueue(label: "NativeAgent.AppleScript", qos: .userInitiated)
    // Playback commands, not reads, transfer ownership. A later play of the
    // same song must not be stopped by an older bounded command's settlement.
    private static let musicPlaybackOwner = OSAllocatedUnfairLock<(pid: pid_t, token: UUID)?>(initialState: nil)
    private static let playbackCommands: Set<String> = ["Play", "Paus", "Stop", "PlPs", "Next", "Prev", "Back", "Resu", "Fast", "Rwnd"]

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

    /// App events stay in the app process; the isolated executor only supplies JSON.
    public func callApp(_ arguments: JSONValue, targets: [String: String]) async throws -> JSONValue {
        try await callApp(arguments, targets: targets, expectedMusicOwner: nil)
    }

    private func callApp(_ arguments: JSONValue, targets: [String: String], expectedMusicOwner: UUID?) async throws -> JSONValue {
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
        let pid: pid_t
        if args["launch"] == .bool(false) {
            try Task.checkCancellation()
            guard let running = await MainActor.run(body: { Self.runningApp(at: url)?.processIdentifier }) else {
                return .object(["bundle_id": .string(bundleID), "app_path": .string(url.path),
                                "state": .string("not_running"), "effects": .string("none")])
            }
            pid = running
        } else {
            pid = try await Self.appProcess(at: url)
        }
        let musicToken = bundleID == "com.apple.Music" ? UUID() : nil
        let response: JSONValue = try await Self.onAppleScriptQueue { cancelled in
            if let expectedMusicOwner, !Self.musicPlaybackOwner.withLock({ $0?.pid == pid && $0?.token == expectedMusicOwner }) {
                return .object(["code": .int(0), "value": .string("playback_changed"), "effects": .string("none")])
            }
            let permission = Self.permission(bundleID: bundleID, url: url, pid: pid)
            guard case .object(let consent) = permission, consent["state"] == .string("allowed") else { return permission }
            var effects: String?
            do {
                let value: NSAppleEventDescriptor?
                if case .string(let source)? = args["script"] {
                    let target = bundleID.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                    let program = "use AppleScript version \"2.4\"\ntell application id \"\(target)\"\n\(source)\nend tell"
                    value = try Self.scriptValue(program, pid: pid, authored: true, readOnly: read, cancelled: cancelled, musicToken: musicToken, effects: &effects)
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
                    if let musicToken, args["event_class"] == .string("hook"),
                       Self.playbackCommands.contains(args["event_id"]?.stringValue ?? "") {
                        Self.musicPlaybackOwner.withLock { $0 = (pid, musicToken) }
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
        guard case .int(let seconds)? = args["seconds"], case .object(let played) = response else { return response }
        let value = played["value"]?.stringValue ?? ""
        let started = played["code"] == .int(0) && value == "ok|||" + (args["track_id"]?.stringValue ?? "")
        guard started || ["occurred", "partial", "unknown"].contains(played["effects"]?.stringValue ?? "") else { return response }
        // This bounded native call owns the Music player until settlement;
        // neither the part nor her turn keeps a timer or a future stop job.
        // A different track belongs to whoever took over, so leave it alone.
        let trackID = args["track_id"]?.stringValue ?? ""
        var cancelled = false
        do { if started { try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000) } }
        catch { cancelled = true }
        let stop = await settle { () -> JSONValue in
            do {
                guard await MainActor.run(body: { Self.runningApp(at: url)?.processIdentifier }) == pid else {
                    return .object(["code": .int(0), "value": .string("player_exited"), "effects": .string("none")])
                }
                return try await self.callApp(.object([
                    "bundle_id": .string(bundleID), "launch": .bool(false), "read_only": .bool(false),
                    "script": .string("""
                    if player state is stopped then return "already_stopped"
                    if (persistent ID of current track) is not "\(trackID)" then return "playback_changed"
                    stop
                    return "stopped"
                    """)
                ]), targets: targets, expectedMusicOwner: musicToken)
            } catch {
                return .object(["state": .string("failed"), "effects": .string("unknown"), "message": .string(error.localizedDescription)])
            }
        }
        var done = played
        done["play_receipt"] = response
        done["seconds"] = .int(seconds)
        done["cancelled"] = .bool(cancelled)
        done["stop_receipt"] = stop
        if case .object(let stopped) = stop, stopped["code"] == .int(0) || stopped["state"] == .string("not_running") {
            done["bounded_outcome"] = stopped["value"] ?? .string("not_running")
        } else {
            done["state"] = .string("bounded_stop_failed")
            done["message"] = .string("Music started, but its bounded stop could not be confirmed. Read Music before doing anything again.")
            done["effects"] = .string("unknown")
        }
        return .object(done)
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
            do { value = try scriptValue(program, pid: pid, authored: false, cancelled: cancelled,
                                         musicToken: bundleID == "com.apple.Music" ? UUID() : nil, effects: &effects) }
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
    private static func scriptValue(_ source: String, pid: pid_t, authored: Bool, readOnly: Bool = false, cancelled: OSAllocatedUnfairLock<Bool>, musicToken: UUID? = nil,
                                    effects: inout String?) throws -> NSAppleEventDescriptor {
        guard let language = OSALanguage(forName: "AppleScript") else {
            throw SenseFailure(code: "unavailable", message: "AppleScript language is unavailable.")
        }
        let instance = OSALanguageInstance(language: language)
        typealias Target = (pid: pid_t, authored: Bool, readOnly: Bool, refused: Bool, refusedRead: Bool, wrote: Bool, attempted: Bool, cancelled: OSAllocatedUnfairLock<Bool>, musicToken: UUID?)
        var target: Target = (pid, authored, readOnly, false, false, false, false, cancelled, musicToken)
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
                let read = AuthoredToolEffects.appReadOnly(["event_class": .string(AppleScriptExecution.codeText(eventClass)),
                                                            "event_id": .string(AppleScriptExecution.codeText(eventID))])
                if target.pointee.readOnly && !read {
                    target.pointee.refusedRead = true
                    return OSErr(-1743)
                }
                if let token = target.pointee.musicToken, AppleScriptExecution.codeText(eventClass) == "hook",
                   AppleScriptExecution.playbackCommands.contains(AppleScriptExecution.codeText(eventID)) {
                    AppleScriptExecution.musicPlaybackOwner.withLock { $0 = (target.pointee.pid, token) }
                }
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
        let result = try await ProcessExecution().run(
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

extension AppleScriptExecution {
    /// Automation consent is per target application.
    public static let automationTargetApps = ["Mail", "Messages", "Notes", "Music"]

    /// Automation targets are identified by bundle ID, independently of their display names.
    public static let automationTargetBundleIDs: [String: String] = [
        "Mail":     "com.apple.mail",
        "Messages": "com.apple.MobileSMS",
        "Notes":    "com.apple.Notes",
        "Music":    "com.apple.Music",
    ]

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
