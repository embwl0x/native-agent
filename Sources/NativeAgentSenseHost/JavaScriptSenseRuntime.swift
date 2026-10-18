import Darwin
import Foundation
import JavaScriptCore
import Senses
import NativeAgentCore
import PersistenceCore

/// One isolated context per helper/program. Resident parts retain their context;
/// all kinds share the VM, exception latch, host exchange and JSC watchdog.
final class JavaScriptProgramRuntime {
    private typealias ShouldTerminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetTimeLimit = @convention(c) (JSContextGroupRef, Double, ShouldTerminate?, UnsafeMutableRawPointer?) -> Void
    private typealias ClearTimeLimit = @convention(c) (JSContextGroupRef) -> Void
    private static let setTimeLimit = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit")
        .map { unsafeBitCast($0, to: SetTimeLimit.self) }
    private static let clearTimeLimit = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupClearExecutionTimeLimit")
        .map { unsafeBitCast($0, to: ClearTimeLimit.self) }
    private static let expired: ShouldTerminate = { context, cell in
        guard let context, let cell, let setTimeLimit = JavaScriptProgramRuntime.setTimeLimit,
              let group = JSContextGetGroup(JSContextGetGlobalContext(context)) else { return true }
        let progress = Unmanaged<ProgressWindow>.fromOpaque(cell).takeUnretainedValue()
        // Flush a trailing accepted advance even when JS has stopped calling
        // the bridge, so coalescing cannot shorten the runner's stall window.
        do { try progress.flush() } catch { progress.forwardFailure = error; return true }
        if !progress.awaitingReply, ProcessInfo.processInfo.systemUptime >= progress.deadline { return true }
        setTimeLimit(group, 0.25, JavaScriptProgramRuntime.expired, cell)
        return false
    }

    private final class ProgressWindow {
        let io: PlugIO
        var id = 0
        var seconds = 30.0
        var kind = OwnedProgram.Kind.sense
        var last = 0.0
        var forwarded = -Double.infinity
        var pendingMark: Double?
        var forwardFailure: Error?
        private var replyStarted: Double?
        var awaitingReply: Bool { replyStarted != nil }
        var deadline: Double { last + seconds }
        init(io: PlugIO) { self.io = io }
        func begin(id: Int, seconds: Double, kind: OwnedProgram.Kind) {
            self.id = id; self.seconds = seconds; self.kind = kind
            last = ProcessInfo.processInfo.systemUptime
            forwarded = -Double.infinity; pendingMark = nil; forwardFailure = nil
            replyStarted = nil
        }
        func suspendForReply() { replyStarted = ProcessInfo.processInfo.systemUptime }
        func resumeAfterReply() {
            if let replyStarted { last += ProcessInfo.processInfo.systemUptime - replyStarted }
            replyStarted = nil
        }
        func record(mark: Double? = nil) throws {
            last = ProcessInfo.processInfo.systemUptime
            if let mark { pendingMark = mark }
            try flush()
        }
        func flush() throws {
            let now = ProcessInfo.processInfo.systemUptime
            guard let pendingMark, now - forwarded >= min(0.25, seconds / 4) else { return }
            try io.send(["id": id, "type": "progress", "n": pendingMark])
            forwarded = now; self.pendingMark = nil
        }
    }

    private let io: PlugIO
    private let shim: String
    private let progress: ProgressWindow
    private var progressCell: UnsafeMutableRawPointer { Unmanaged.passUnretained(progress).toOpaque() }
    private var context: JSContext?
    private var body: JSValue?
    private var updateInput: JSValue?
    private var record: SenseRecord?
    private var program: OwnedProgram?
    private var id = 0
    private var callID = 0
    private var entryProgress = SenseEntryProgress()
    private var entryType = ""
    private var address: String?
    private var initialMaterial: [String: Any]?
    private var published = false
    private var subscribed = false
    private var logBytes = 0
    private var thrown: JSValue?
    private var latched: SenseFailure?

    init(io: PlugIO, shim: String) {
        self.io = io; self.shim = shim; progress = ProgressWindow(io: io)
    }

    deinit {
        if let context, let group = JSContextGetGroup(context.jsGlobalContextRef) { Self.clearTimeLimit?(group) }
    }

    func run(_ message: [String: Any]) throws {
        if message["type"] as? String != "changed" {
            guard let raw = message["program"] as? [String: Any] else {
                throw failure("bad_input", "JavaScript run requires its exact owned program.")
            }
            let decoded = try JSONDecoder().decode(OwnedProgram.self, from: JSONSerialization.data(withJSONObject: raw))
            try decoded.validate()
            if let program, program != decoded {
                throw failure("bad_input", "A helper cannot switch its program identity or source.")
            }
            program = decoded
            if decoded.kind != .sense { try runProgram(decoded, message: message); return }
        }
        try runSense(message)
    }

    private func runSense(_ message: [String: Any]) throws {
        guard let program, program.kind == .sense, let runID = message["id"] as? Int else {
            throw failure("bad_input", "Sense run requires its owned program and an integer id.")
        }
        id = runID; callID = 0; published = false; logBytes = 0; thrown = nil; latched = nil
        let seconds = message["timeoutSeconds"] as? Double ?? 30
        guard seconds.isFinite, seconds > 0 else { throw failure("bad_input", "Sense stall window must be finite and positive.") }
        progress.begin(id: id, seconds: seconds, kind: .sense)
        entryProgress = SenseEntryProgress()
        if message["type"] as? String == "changed" {
            guard subscribed, context != nil, let material = message["material"] as? [String: Any] else {
                throw failure("bad_input", "Sense change requires an active source subscription and material.")
            }
            entryType = "changed"; address = nil; initialMaterial = try checkedMaterial(material)
        } else {
            guard let rawRecord = message["sense"] as? [String: Any],
                  let request = message["request"] as? [String: Any],
                  let kind = request["type"] as? String, ["read", "act", "watch", "event"].contains(kind) else {
                throw failure("bad_input", "Sense run requires sense and request.")
            }
            let decoded = try JSONDecoder().decode(SenseRecord.self, from: JSONSerialization.data(withJSONObject: rawRecord))
            guard decoded.language == .javascript else { throw failure("unsupported", "JSC requires a JavaScript sense.") }
            guard program.id == decoded.id, Int(program.version) == decoded.version, program.reach == decoded.reach else {
                throw failure("bad_input", "Sense program does not match its record.")
            }
            if let record {
                guard record.id == decoded.id, record.version == decoded.version,
                      record.corner == decoded.corner, record.mode == decoded.mode,
                      record.reach == decoded.reach else {
                    throw failure("bad_input", "A helper cannot switch its sense identity.")
                }
            } else { record = decoded }
            entryType = kind; address = request["address"] as? String
            if kind == "act" {
                guard request["verb"] is String, address != nil else { throw failure("bad_input", "Sense act requires verb and address.") }
            }
            if kind == "watch", decoded.mode != .live { throw failure("bad_input", "Only live senses can watch.") }
            initialMaterial = try (message["material"] as? [String: Any]).map(checkedMaterial)
        }
        if context == nil {
            let created = try createContext(sdk: shim, inputJSON: nil, kind: .sense)
            if thrown == nil { created.evaluateScript(program.source, withSourceURL: URL(string: "sense-entry.js")) }
            if thrown == nil, created.evaluateScript("typeof read === 'function'")?.toBool() != true {
                throw failure("bad_output", "Sense must define read(request).")
            }
        }
        guard let setTimeLimit = Self.setTimeLimit else { throw failure("unsupported", "JavaScript execution time limits are unavailable.") }
        guard let context, let group = JSContextGetGroup(context.jsGlobalContextRef) else { throw failure("unsupported", "JavaScript context is unavailable.") }
        setTimeLimit(group, 0.25, Self.expired, progressCell)
        defer { Self.clearTimeLimit?(group) }
        try checkException()
        guard let function = context.objectForKeyedSubscript(entryType), !function.isUndefined,
              isFunction(function, in: context) else {
            throw failure("unsupported", "Sense does not define \(entryType)(request).")
        }
        let input: [String: Any]
        if entryType == "changed" {
            // The SDK conversion is used for the change argument as well.
            // read() returns the supplied change without an app round trip.
            // File Uint8Array construction belongs to the SDK; source.read()
            // consumes the exact current material.
            let converted = context.evaluateScript("sense.source.read()")
            try checkException()
            guard let converted else { throw failure("bad_input", "Missing changed material.") }
            let result = function.call(withArguments: [converted])
            try finish(result)
            return
        } else {
            input = message["request"] as? [String: Any] ?? [:]
        }
        let result = function.call(withArguments: [input])
        try finish(result)
    }

    private func createContext(sdk: String, inputJSON: String?, kind: OwnedProgram.Kind, workspace: String? = nil, dataRoot: String? = nil, measurementSystem: String? = nil) throws -> JSContext {
        guard let setTimeLimit = Self.setTimeLimit, Self.clearTimeLimit != nil else {
            throw failure("unsupported", "JavaScript execution time limits are unavailable.")
        }
        guard let created = JSContext(virtualMachine: JSVirtualMachine()),
              let group = JSContextGetGroup(created.jsGlobalContextRef) else {
            throw failure("unsupported", "JavaScriptCore did not start.")
        }
        context = created
        created.exceptionHandler = { [weak self] _, exception in self?.thrown = exception }
        let call: @convention(block) (String, String) -> String = { [unowned self] type, fields in
            self.bridge(type: type, fields: fields)
        }
        created.setObject(call, forKeyedSubscript: (kind == .sense ? "__senseCall" : "__call") as NSString)
        if kind == .sense {
            let redact: @convention(block) (String) -> String = { ContextSecretContentPolicy.redactedFragment($0) }
            created.setObject(redact, forKeyedSubscript: "__senseRedactText" as NSString)
        } else {
            let say: @convention(block) (String) -> Void = { [unowned self] text in
                guard self.logBytes < OwnedProgramRunner.logLimit else { return }
                let kept = String(text.prefix(OwnedProgramRunner.logLimit - self.logBytes))
                self.logBytes += kept.utf8.count
                _ = self.bridge(type: "script_log", fields: (try? self.jsonString(["text": kept])) ?? "{}")
            }
            created.setObject(say, forKeyedSubscript: "__log" as NSString)
            if kind == .tool {
                guard let workspace, let dataRoot, let measurementSystem else { throw failure("bad_input", "Authored tools require their workspace, data paths and measurement system from the app.") }
                created.setObject(FileManager.default.homeDirectoryForCurrentUser.path, forKeyedSubscript: "__home" as NSString)
                created.setObject(workspace, forKeyedSubscript: "__workspace" as NSString)
                created.setObject(dataRoot, forKeyedSubscript: "__dataRoot" as NSString)
                created.setObject(measurementSystem, forKeyedSubscript: "__measurementSystem" as NSString)
            }
            if let inputJSON { created.setObject(inputJSON, forKeyedSubscript: "__input" as NSString) }
        }
        setTimeLimit(group, 0.25, Self.expired, progressCell)
        let result = created.evaluateScript(sdk, withSourceURL: URL(string: kind == .sense ? "sense-sdk.js" : "app-prelude.js"))
        if inputJSON != nil { updateInput = result }
        for name in ["__senseCall", "__senseRedactText", "__call", "__log", "__input", "__home", "__workspace", "__dataRoot", "__measurementSystem"] { created.globalObject.deleteProperty(name) }
        return created
    }

    private func runProgram(_ program: OwnedProgram, message: [String: Any]) throws {
        guard (context == nil || program.isResident), let runID = message["id"] as? Int, let ids = message["actionIDs"] as? [String] else {
            throw failure("bad_input", "Program requires an available helper, an integer id and admitted action names.")
        }
        id = runID; callID = 0; logBytes = 0; thrown = nil; latched = nil
        progress.begin(id: id, seconds: program.seconds, kind: program.kind)
        let inputJSON = try message["input"].map {
            try JSONValue(fromFoundation: $0).serialize(pretty: false)
        } ?? (program.entry == .run ? "{}" : nil)
        let names = String(decoding: try JSONSerialization.data(withJSONObject: ids), as: UTF8.self)
        let sdk = OwnedProgramRunner.prelude(ids: names, strict: program.kind == .skill,
                                            input: inputJSON != nil, primitives: program.kind == .tool, turn: program.kind == .turn)
        let fresh = context == nil
        if fresh { _ = try createContext(sdk: sdk, inputJSON: inputJSON, kind: program.kind, workspace: message["workspace"] as? String, dataRoot: message["dataRoot"] as? String, measurementSystem: message["measurementSystem"] as? String) }
        guard let context, let group = JSContextGetGroup(context.jsGlobalContextRef), let setTimeLimit = Self.setTimeLimit else { throw failure("unsupported", "JavaScript context is unavailable.") }
        setTimeLimit(group, 0.25, Self.expired, progressCell)
        defer { Self.clearTimeLimit?(group) }
        if !fresh, let inputJSON { updateInput?.call(withArguments: [inputJSON]) }
        try checkExecution()
        if let thrown {
            try io.send(["id": id, "type": "program_done", "exception": ["message": "The script engine did not start: \(thrown)"]])
            return
        }
        if body == nil, program.entry == .functionBody {
            body = context.evaluateScript("(function () {" + program.source + "\n})", withSourceURL: URL(string: "app-script.js"))
        } else if body == nil {
            context.evaluateScript(program.source, withSourceURL: URL(string: "app-script.js"))
            body = context.objectForKeyedSubscript("run")
            if thrown == nil, body.map({ isFunction($0, in: context) }) != true {
                throw failure("bad_output", "Owned program must define run(input).")
            }
        }
        let value = thrown == nil ? body?.call(withArguments: program.entry == .run
            ? [context.objectForKeyedSubscript("input")!] : []) : nil
        try checkExecution()
        var done: [String: Any] = ["id": id, "type": "program_done"]
        if let thrown {
            done["exception"] = exception(thrown)
            try io.send(done); return
        }
        if program.kind == .tool, value == nil || value?.isUndefined == true {
            throw failure("bad_output", "The returned value has no JSON form (undefined).")
        }
        if let value, !value.isUndefined {
            let promise = value.isObject && value.objectForKeyedSubscript("then").map { isFunction($0, in: context) } == true
            let json = promise ? nil : context.objectForKeyedSubscript("JSON")?.invokeMethod("stringify", withArguments: [value])
            try checkExecution()
            if thrown != nil || promise || json?.isString != true {
                let detail = promise ? "Sync-only: define function run(input), use synchronous host/app calls and return plain JSON. Async functions and Promises are unsupported."
                    : thrown != nil ? "The returned value could not be read: \((thrown?.toString() ?? "").prefix(300))"
                    : "The returned value has no JSON form (a function or a symbol)."
                if program.kind == .tool { throw failure("bad_output", detail) }
                done["unreadableReturn"] = detail
                try io.send(done); return
            }
            if let json, json.isString, let text = json.toString() {
                if text.utf8.count > program.returnLimit {
                    if program.kind == .tool {
                        throw failure("output_limit", "The returned value exceeds the \(program.returnLimit)-byte output limit.")
                    }
                    done["returned"] = String(text.prefix(program.returnLimit))
                    done["returnedNote"] = "The returned value was \(text.utf8.count) bytes; this is its first \(program.returnLimit), as text."
                } else {
                    guard let returned = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else {
                        throw failure("bad_output", "The returned value has invalid JSON form.")
                    }
                    done["returned"] = returned
                }
            }
        }
        try io.send(done)
    }

    private func exception(_ value: JSValue) -> [String: Any] {
        var report: [String: Any] = ["message": String((value.toString() ?? "error").prefix(400))]
        for key in ["name", "reason"] {
            if let item = value.objectForKeyedSubscript(key), item.isString { report[key] = item.toString() }
        }
        let line = value.objectForKeyedSubscript("scriptLine").flatMap { $0.isNumber ? Int($0.toInt32()) : nil }
            ?? value.objectForKeyedSubscript("line").flatMap { $0.isNumber ? Int($0.toInt32()) : nil }
        if let line, line > 0 { report["line"] = line }
        if let n = value.objectForKeyedSubscript("callNumber"), n.isNumber { report["n"] = Int(n.toInt32()) }
        return report
    }

    private func finish(_ result: JSValue?) throws {
        try checkException()
        if let result, result.isObject, let then = result.objectForKeyedSubscript("then"),
           let context, isFunction(then, in: context) {
            throw failure("bad_output", "Sense entry points must finish synchronously.")
        }
        if entryType == "read", !published { throw failure("bad_output", "Sense read returned without publishing a page.") }
        let done: [String: Any] = ["id": id, "type": "done"]
        try io.send(done)
    }

    private func checkExecution() throws {
        if let latched { throw latched }
        if let error = progress.forwardFailure { throw failure("source_unavailable", error.localizedDescription) }
        if ProcessInfo.processInfo.systemUptime >= progress.deadline { throw failure("timeout", "Sense execution stalled without progress.") }
    }

    private func checkException() throws {
        try checkExecution()
        if let thrown {
            let message = String((thrown.toString() ?? "Sense threw an error.").prefix(1000))
            throw failure(message.contains("execution terminated") ? "timeout" : "javascript", message)
        }
    }

    private func bridge(type: String, fields: String) -> String {
        do {
            if let latched { throw latched }
            try progress.flush()
            guard ProcessInfo.processInfo.systemUptime < progress.deadline else { throw failure("timeout", "Sense execution stalled without progress.") }
            callID += 1
            let callLimit = progress.kind == .sense ? 2 * 1024 * 1024 : PlugIO.maximumLineBytes
            guard let data = fields.data(using: .utf8), data.count <= callLimit else {
                throw failure("output_limit", progress.kind == .sense
                    ? "Sense API call exceeds the 2 MiB JSON limit." : "Program host call exceeds the helper wire limit.")
            }
            guard var body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw failure("bad_output", "Sense call has invalid arguments.")
            }
            body["id"] = id; body["callID"] = callID; body["type"] = type
            if progress.kind != .sense {
                switch type {
                case "app_call":
                    guard body["kind"] is String, body["action"] is String, body["args"] is String, body["line"] is Int else {
                        throw failure("bad_output", "App call requires kind, action, arguments and source line.")
                    }
                    let reply = try exchange(body, replyType: "host_reply")
                    if body["kind"] as? String != "state" { try progress.record() }
                    guard let value = reply["value"] as? String else { throw failure("bad_output", "App call requires a journal reply.") }
                    return try jsonString(["value": value])
                case "script_log": try io.send(body); return try jsonString(["value": NSNull()])
                default: throw failure("bad_output", "Program called an API outside its host profile.")
                }
            }
            guard let record else { throw failure("bad_output", "Sense call has no bound record.") }
            let value: Any
            switch type {
            case "app_read":
                value = try exchange(body, replyType: "app_reply")["result"] ?? NSNull()
            case "source_read":
                guard body["address"] is NSNull || body["address"] is String else {
                    throw failure("bad_output", "Sense source address must be a string or null.")
                }
                let requestedAddress = body["address"] as? String ?? address
                if let supplied = initialMaterial, requestedAddress == address {
                    value = supplied
                    if entryProgress.read(address: requestedAddress) {
                        // The app validates this address against the snapshot it supplied.
                        try io.send(["id": id, "type": "progress",
                                     "readAddress": requestedAddress.map { $0 as Any } ?? NSNull()])
                        try progress.record()
                    }
                } else {
                    body["corner"] = record.corner.key
                    body["address"] = requestedAddress.map { $0 as Any } ?? NSNull()
                    value = try checkedMaterial(exchange(body, replyType: "source_reply")["material"] as? [String: Any] ?? [:])
                    if entryProgress.read(address: requestedAddress) { try progress.record() }
                }
            case "source_watch":
                guard record.mode == .live else { throw failure("bad_output", "Only live senses can subscribe.") }
                body["corner"] = record.corner.key
                guard try exchange(body, replyType: "source_reply")["subscribed"] as? Bool == true else {
                    throw failure("source_unavailable", "Sense source subscription was not acknowledged.")
                }
                subscribed = true; value = NSNull()
            case "publish":
                guard var page = body["page"] as? [String: Any] else { throw failure("bad_output", "Sense publish requires a page.") }
                page["corner"] = try jsonObject(record.corner)
                if page["things"] == nil || page["things"] is NSNull { page["things"] = [] }
                if page["folded"] == nil || page["folded"] is NSNull { page["folded"] = [] }
                if var things = page["things"] as? [[String: Any]] {
                    for i in things.indices {
                        if things[i]["verbs"] == nil || things[i]["verbs"] is NSNull { things[i]["verbs"] = [] }
                    }
                    page["things"] = things
                }
                let decoded = try JSONDecoder().decode(NativePage.self, from: JSONSerialization.data(withJSONObject: page))
                guard !decoded.address.isEmpty, decoded.text.utf8.count <= NativePage.maximumTextBytes else {
                    throw failure("bad_output", "Sense page requires an address and at most 40,000 text bytes.")
                }
                body["page"] = try jsonObject(decoded)
                try io.send(body); published = true; try progress.record(); value = NSNull()
            case "notify":
                guard let news = body["news"] as? [String: Any], let newsAddress = news["address"] as? String,
                      let summary = news["summary"] as? String, summary.utf8.count <= 4000 else {
                    throw failure("bad_output", "Sense news requires address and summary (at most 4,000 bytes).")
                }
                body["news"] = try jsonObject(SenseNews(senseID: record.id, version: record.version,
                    address: ContextSecretContentPolicy.redactedFragment(newsAddress),
                    summary: ContextSecretContentPolicy.redactedFragment(summary), at: Date()))
                try io.send(body); try progress.record(); value = NSNull()
            case "progress":
                // No argument means one completed unit; explicit values must
                // advance the entry's high-water mark. Repeats are inert.
                let n: Double? = body["n"] is NSNull ? nil : (body["n"] as? Double ?? .nan)
                if let mark = try entryProgress.advance(to: n) { try progress.record(mark: mark) }
                value = NSNull()
            case "present":
                if !(body["view"] is NSNull) {
                    guard let view = body["view"] as? [String: Any], view["title"] is String,
                          let html = view["html"] as? String, html.utf8.count <= 256 * 1024 else {
                        throw failure("bad_output", "Sense view requires title and at most 256 KiB of HTML.")
                    }
                }
                try io.send(body); value = NSNull()
            case "act":
                guard entryType == "act", body["verb"] is String, body["address"] is String else {
                    throw failure("bad_output", "Sense actions are allowed only while answering an act request.")
                }
                let reply = try exchange(body, replyType: "act_reply")
                guard let result = reply["result"] else { throw failure("bad_input", "Sense action reply requires result (null is allowed).") }
                value = result
            case "state_get", "state_set":
                guard let key = body["key"] as? String, !key.isEmpty, key.utf8.count <= 256 else {
                    throw failure("bad_output", "Sense state requires a key of 1–256 bytes.")
                }
                if type == "state_set" {
                    guard let value = body["value"], try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]).count <= 16 * 1024 else {
                        throw failure("bad_output", "Sense state values must be JSON of at most 16 KiB.")
                    }
                }
                let reply = try exchange(body, replyType: "state_reply")
                guard let stateValue = reply["value"] else { throw failure("bad_input", "Sense state reply requires value (null is allowed).") }
                value = stateValue
            case "log":
                guard let text = body["text"] as? String else { throw failure("bad_output", "Sense log requires text.") }
                guard logBytes + text.utf8.count <= 2048 else { throw failure("bad_output", "Sense logs exceed 2 KiB.") }
                logBytes += text.utf8.count; try io.send(body); value = NSNull()
            default: throw failure("bad_output", "Unknown sense API call.")
            }
            return try jsonString(["value": value])
        } catch {
            let failed = (error as? SenseFailure) ?? failure("bad_output", error.localizedDescription)
            latched = failed
            return (try? jsonString(["failure": ["code": failed.code, "message": failed.message]])) ?? "{\"failure\":{\"code\":\"bad_output\",\"message\":\"Sense bridge failed.\"}}"
        }
    }

    private func exchange(_ body: [String: Any], replyType: String) throws -> [String: Any] {
        // App-owned work may keep progressing while JS is blocked. Exclude
        // that wait without granting progress to state traffic or repeated reads.
        progress.suspendForReply()
        defer { progress.resumeAfterReply() }
        try io.send(body)
        guard let reply = try io.receive() else { throw failure("source_unavailable", "Sense plug closed before replying.") }
        if reply["type"] as? String == "stop" { exit(0) }
        guard reply["type"] as? String == replyType, reply["id"] as? Int == id, reply["callID"] as? Int == callID else {
            throw failure("bad_input", "Sense plug reply has the wrong type, id or callID.")
        }
        if let rawFailure = reply["failure"] as? [String: Any] {
            throw try JSONDecoder().decode(SenseFailure.self, from: JSONSerialization.data(withJSONObject: rawFailure))
        }
        return reply
    }

    private func checkedMaterial(_ material: [String: Any]) throws -> [String: Any] {
        switch material["kind"] as? String {
        case "file":
            guard material["path"] is String, let count = material["bytes"] as? Int, count >= 0, count <= 16 * 1024 * 1024,
                  let base64 = material["data"] as? String, let data = Data(base64Encoded: base64), data.count == count else {
                throw failure("bad_input", "File material requires its bytes as base64 data (at most 16 MiB).")
            }
        case "text": guard material["text"] is String else { throw failure("bad_input", "Text material requires text.") }
        case "accessibility": guard material["tree"] != nil else { throw failure("bad_input", "Accessibility material requires tree.") }
        case "page": guard material["snapshot"] != nil else { throw failure("bad_input", "Page material requires snapshot.") }
        default: throw failure("bad_input", "Unknown sense material kind.")
        }
        return material
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
    }
    private func isFunction(_ value: JSValue, in context: JSContext) -> Bool {
        guard value.isObject, let object = JSValueToObject(context.jsGlobalContextRef, value.jsValueRef, nil) else { return false }
        return JSObjectIsFunction(context.jsGlobalContextRef, object)
    }
    private func jsonString(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
    private func failure(_ code: String, _ message: String) -> SenseFailure { SenseFailure(code: code, message: message) }
}
