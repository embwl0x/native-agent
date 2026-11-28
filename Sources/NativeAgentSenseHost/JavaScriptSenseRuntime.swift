import CoreFoundation
import Darwin
import Foundation
import JavaScriptCore
import zlib
import SenseCore
import NativeAgentCore
import PersistenceCore
// Blueprint: | `Sources/NativeAgentSenseHost/JavaScriptSenseRuntime.swift` | JSC contexts, sense SDK and prelude, exact-source leases and bounded execution |

/// Resident programs retain context; rehearsal needs a fresh realm. Both share the exception latch, exchange and watchdog.
@safe final class JavaScriptProgramRuntime {
    private typealias ShouldTerminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetTimeLimit = @convention(c) (JSContextGroupRef, Double, ShouldTerminate?, UnsafeMutableRawPointer?) -> Void
    private typealias ClearTimeLimit = @convention(c) (JSContextGroupRef) -> Void
    private static let setTimeLimit = unsafe dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit")
        .map { unsafe unsafeBitCast($0, to: SetTimeLimit.self) }
    private static let clearTimeLimit = unsafe dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupClearExecutionTimeLimit")
        .map { unsafe unsafeBitCast($0, to: ClearTimeLimit.self) }
    private static let expired: ShouldTerminate = { context, cell in
        guard let context = unsafe context, let cell = unsafe cell, let setTimeLimit = unsafe JavaScriptProgramRuntime.setTimeLimit,
              let group = unsafe JSContextGetGroup(JSContextGetGlobalContext(context)) else { return true }
        let progress = unsafe Unmanaged<ProgressWindow>.fromOpaque(cell).takeUnretainedValue()
        if let failure = JavaScriptProgramRuntime.memoryFailure() { progress.io.fatal(id: progress.id, failure) }
        if progress.expired { return true }
        unsafe setTimeLimit(group, 0.25, JavaScriptProgramRuntime.expired, cell)
        return false
    }

    /// A sense entry has no window: it is alive while it runs and Stop ends it (SENSES.md). Other program kinds keep ONE_DOOR's renewable window.
    private final class ProgressWindow {
        let io: PlugIO
        var id = 0
        var window: ProgramProgressWindow?
        var kind = OwnedProgram.Kind.sense
        private var replyStarted: ContinuousClock.Instant?
        var expired: Bool {
            guard let window, replyStarted == nil else { return false }
            return ContinuousClock.now >= window.deadline
        }
        init(io: PlugIO) { self.io = io }
        func begin(id: Int, seconds: Double?, kind: OwnedProgram.Kind) {
            self.id = id; self.kind = kind; window = seconds.map(ProgramProgressWindow.init(seconds:))
            replyStarted = nil
        }
        func suspendForReply() { replyStarted = .now }
        func resumeAfterReply() {
            if let replyStarted { window?.resume(after: replyStarted) }
            replyStarted = nil
        }
        /// Each accepted numeric mark is forwarded as it is made, without clock coalescing.
        func record(mark: Double? = nil) throws {
            window?.renew()
            if let mark { try io.send(["id": id, "type": "progress", "n": mark]) }
        }
    }

    static let memoryLimit: UInt64? = {
        guard let i = CommandLine.arguments.firstIndex(of: "--memory-bytes"),
              i + 1 < CommandLine.arguments.count else { return nil }
        return UInt64(CommandLine.arguments[i + 1])
    }()

    static func memoryFailure() -> SenseFailure? {
        var info = task_vm_info_data_t()
        info.phys_footprint = .max
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) {
            unsafe $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                unsafe task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS, info.phys_footprint != .max, let memoryLimit else {
            return SenseFailure(code: "resource_unavailable", message: "Helper footprint is unavailable.")
        }
        guard info.phys_footprint <= memoryLimit else {
            return SenseFailure(code: "resource_limit", message: "Helper exceeded its memory cap.")
        }
        return nil
    }

    private static let callback: JSObjectCallAsFunctionCallback = { ctx, _, owner, count, args, exception in
        guard let ctx = unsafe ctx, let owner = unsafe owner, let pointer = unsafe JSObjectGetPrivate(owner) else { return nil }
        let runtime = unsafe Unmanaged<JavaScriptProgramRuntime>.fromOpaque(pointer).takeUnretainedValue()
        guard let context = runtime.context,
              let args, count >= 1, let type = unsafe JSValue(jsValueRef: args[0], in: context)?.toString() else { return nil }
        do {
            guard runtime.acceptingCalls, count >= 2 else { throw runtime.failure("bad_input", "Missing bridge argument.") }
            return try unsafe runtime.invoke(type, count: count, args: args, in: context)
        } catch {
            let failed = SenseFailure(error, code: "bad_output")
            if !["utf8", "text", "inflate", "crc32"].contains(type) || ["resource_unavailable", "resource_limit"].contains(failed.code) {
                runtime.latched = failed
            }
            let fault = JSValue(newErrorFromMessage: failed.message, in: context)
            fault?.setValue(failed.code, forProperty: "code")
            fault?.setValue(failed.code, forProperty: "reason")
            unsafe exception?.pointee = fault?.jsValueRef
            return unsafe JSValueMakeUndefined(ctx)
        }
    }

    private var acceptingCalls = false
    private var admittedNames: [String: [String]] = [:]

    private final class Namespace {
        weak var runtime: JavaScriptProgramRuntime?
        let path: String
        init(_ runtime: JavaScriptProgramRuntime, _ path: String) { self.runtime = runtime; self.path = path }
    }

    private var bindingFactory: JSValue?
    private var bindings: [String: JSValue] = [:]
    private var builtinNames: Set<String> = []
    private lazy var namespaceClass: JSClassRef = {
        var definition = kJSClassDefinitionEmpty
        definition.finalize = { object in
            if let ptr = unsafe JSObjectGetPrivate(object) { unsafe Unmanaged<Namespace>.fromOpaque(ptr).release() }
        }
        definition.getProperty = { ctx, object, property, exception in
            guard let ctx = unsafe ctx, let object = unsafe object, let ptr = unsafe JSObjectGetPrivate(object), let property,
                  let name = unsafe JSStringCopyCFString(nil, property) else { return nil }
            let namespace = unsafe Unmanaged<Namespace>.fromOpaque(ptr).takeUnretainedValue()
            guard let runtime = namespace.runtime, runtime.acceptingCalls, let context = runtime.context else { return nil }
            do { return try unsafe runtime.member(in: namespace.path, named: name as String, context: context)?.jsValueRef }
            catch {
                let failed = SenseFailure(error)
                runtime.latched = failed
                unsafe exception?.pointee = JSValue(newErrorFromMessage: failed.message, in: context)?.jsValueRef
                return unsafe JSValueMakeUndefined(ctx)
            }
        }
        return unsafe JSClassCreate(&definition)
    }()

    private func namespace(_ path: String, _ context: JSContext) -> JSValue {
        let pointer = unsafe Unmanaged.passRetained(Namespace(self, path)).toOpaque()
        return unsafe JSValue(jsValueRef: JSObjectMake(context.jsGlobalContextRef, namespaceClass, pointer), in: context)
    }

    private func actionNames(_ id: String) throws(SenseFailure) -> [String] {
        let space = String(id.prefix { $0 != "." })
        let names: [String]
        if let known = admittedNames[""] ?? admittedNames[space] { names = known }
        else {
            callID += 1
            let reply = try exchange(["id": self.id, "callID": callID, "type": "binding_names", "space": space], replyType: "binding_reply")
            guard let selected = reply["names"] as? [String] else { throw failure("bad_frame", "Missing action names.") }
            admittedNames[space] = selected
            names = selected
        }
        return names
    }

    private func member(in path: String, named property: String, context: JSContext) throws -> JSValue? {
        func make(_ path: String, _ kind: String, _ id: String) throws -> JSValue {
            if let value = bindings[path] { return value }
            var arguments: [Any] = [kind, id]
            if kind != "primitive", kind != "door" { arguments.append(namespace(path, context)) }
            guard let factory = bindingFactory,
                  let value = factory.call(withArguments: arguments), !value.isUndefined else {
                throw failure("engine_start_failed", "Could not bind " + path + ".")
            }
            if kind != "primitive" { bindings[path] = value }
            return value
        }
        if path.isEmpty {
            switch property {
            case "app": return try make("app", "root", "")
            case "host" where program?.isPart == true: return try make("host", "host", "")
            default: return nil
            }
        }
        guard let operation = property.first, "*=?+".contains(operation) else { return nil }
        let key = String(property.dropFirst())
        let child = path + "." + key
        if path == "host" {
            let spaces = OwnedProgramRunner.hostPrimitiveNamespaces
            let doors = OwnedProgramRunner.hostDoorActions.map { String($0.prefix { $0 != "." }) }
            if operation == "*" { return JSValue(object: spaces.union(doors).sorted(), in: context) }
            return try make(child, spaces.contains(key) ? "primitives" : "doors", key)
        }
        if path.hasPrefix("host.") {
            let group = String(path.dropFirst(5)), id = group + "." + key
            if operation == "*" {
                let prefix = group + "."
                return JSValue(object: OwnedProgramRunner.hostDoorActions.filter { $0.hasPrefix(prefix) }.sorted().map { String($0.dropFirst(prefix.count)) }, in: context)
            }
            return try make(child, OwnedProgramRunner.hostPrimitiveNamespaces.contains(group) ? "primitive" : "door", id)
        }
        let id = String(child.dropFirst(4))
        if operation == "*" {
            let prefix = path == "app" ? "" : String(path.dropFirst(4)) + "."
            let names = try actionNames(String(prefix.dropLast()))
            var keys = path == "app" ? builtinNames : []
            for name in names where name.hasPrefix(prefix) {
                let suffix = String(name.dropFirst(prefix.count))
                keys.insert(suffix)
                if let dot = suffix.firstIndex(of: ".") { keys.insert(String(suffix[..<dot])) }
            }
            return JSValue(object: keys.sorted(), in: context)
        }
        if operation == "+" {
            if builtinNames.contains(key) { return try make("app." + key, "action", key) }
            return try make(child, path == "app" && !key.contains(".") ? "namespace" : "action", id)
        }
        let kind: String?
        if path == "app", builtinNames.contains(key) { kind = "action" }
        else {
            let names = try actionNames(id)
            kind = names.contains(id) ? "action" : names.contains(where: { $0.hasPrefix(id + ".") }) ? "namespace" : nil
        }
        if operation == "?" { return JSValue(bool: kind != nil, in: context) }
        guard let kind else { return JSValue(undefinedIn: context) }
        return try make(child, kind, id)
    }

    private func installBridge(in context: JSContext) throws(SenseFailure) -> JSValue {
        var definition = kJSClassDefinitionEmpty
        let type = unsafe JSClassCreate(&definition)
        defer { unsafe JSClassRelease(type) }
        let owner = unsafe JSObjectMake(context.jsGlobalContextRef, type, Unmanaged.passUnretained(self).toOpaque())
        let function = unsafe JSObjectMakeFunctionWithCallback(context.jsGlobalContextRef, nil, Self.callback)
        guard let receiver = unsafe JSValue(jsValueRef: owner, in: context),
              let bound = unsafe JSValue(jsValueRef: function, in: context)?.invokeMethod("bind", withArguments: [receiver]) else {
            throw failure("engine_start_failed", "Could not bind the helper plug.")
        }
        return bound
    }

    private func jsonBytes(_ value: JSValueRef?, context: JSContext) throws(SenseFailure) -> Data {
        var error: JSValueRef?
        guard let value, let string = unsafe JSValueCreateJSONString(context.jsGlobalContextRef, value, 0, &error) else {
            throw failure("bad_output", "The host argument has no JSON form.")
        }
        defer { unsafe JSStringRelease(string) }
        guard let text = unsafe JSStringCopyCFString(nil, string) else { throw failure("bad_output", "Unreadable JSON argument.") }
        return Data((text as String).utf8)
    }

    private func invoke(_ type: String, count: Int, args: UnsafePointer<JSValueRef?>, in context: JSContext) throws -> JSValueRef? {
        let ctx: JSContextRef = unsafe context.jsGlobalContextRef
        try checkExecution()
        if type == "source_line", progress.kind != .sense { return unsafe JSValueMakeNumber(ctx, Double(callerLine(in: context))) }
        if type == "app_call", progress.kind != .sense {
            guard count == 4, let kind = unsafe JSValue(jsValueRef: args[1], in: context)?.toString(),
                  let action = unsafe JSValue(jsValueRef: args[2], in: context)?.toString(),
                  let json = unsafe JSValue(jsValueRef: args[3], in: context), json.isString,
                  let arguments = json.toString() else { throw failure("bad_output", "Invalid app call.") }
            let site = callLines?[action.isEmpty ? kind : action]
            let line = if let site, site > 0 { site } else { callerLine(in: context) }
            callID += 1
            let reply = try exchange(["type": type, "id": id, "callID": callID, "kind": kind, "action": action, "line": line],
                                     replyType: "host_reply", payload: Data(arguments.utf8))
            if kind != "state" { try progress.record() }
            return try unsafe replyJSON(reply, in: context).jsValueRef
        }
        if type == "script_log", progress.kind != .sense {
            guard let text = unsafe JSValue(jsValueRef: args[1], in: context)?.toString() else { throw failure("bad_output", "Invalid program log.") }
            if logBytes < OwnedProgramRunner.logLimit {
                var kept = ""
                for scalar in text.unicodeScalars {
                    let size = scalar.utf8.count
                    guard logBytes + size <= OwnedProgramRunner.logLimit else { break }
                    kept.unicodeScalars.append(scalar)
                    logBytes += size
                }
                callID += 1
                try io.send(["id": id, "callID": callID, "type": type, "text": kept])
            }
            return unsafe JSValueMakeUndefined(ctx)
        }
        guard progress.kind == .sense else { throw failure("bad_output", "Call outside program host profile.") }
        switch type {
        case "redact":
            guard let text = unsafe JSValue(jsValueRef: args[1], in: context)?.toString() else { throw failure("bad_output", "Missing text.") }
            return unsafe JSValue(object: ContextSecretContentPolicy.redactedFragment(text), in: context).jsValueRef
        case "utf8", "text", "inflate", "crc32":
            return try unsafe bytes(type, count: count, args: args, in: context)
        default:
            guard let fields = unsafe JSValue(jsValueRef: args[1], in: context), fields.isObject else {
                throw failure("bad_output", "Sense call requires a JSON object.")
            }
            return try unsafe senseCall(type, fields: fields, in: context)
        }
    }

    private func typed(_ bytes: NSMutableData, _ ctx: JSContextRef) throws(SenseFailure) -> JSObjectRef {
        if bytes.length == 0, let empty = unsafe JSObjectMakeTypedArray(ctx, kJSTypedArrayTypeUint8Array, 0, nil) { return empty }
        let owner = unsafe Unmanaged.passRetained(bytes).toOpaque()
        guard let array = unsafe JSObjectMakeTypedArrayWithBytesNoCopy(ctx, kJSTypedArrayTypeUint8Array, bytes.mutableBytes, bytes.length, {
            _, owner in if let owner = unsafe owner { unsafe Unmanaged<NSMutableData>.fromOpaque(owner).release() }
        }, owner, nil) else { throw failure("resource_limit", "Could not expose sense bytes.") }
        return array
    }

    private func bytes(_ operation: String, count: Int, args: UnsafePointer<JSValueRef?>, in context: JSContext) throws(SenseFailure) -> JSValueRef? {
        let ctx: JSContextRef = unsafe context.jsGlobalContextRef
        let size = operation == "inflate" && count == 3 ? unsafe JSValueToNumber(ctx, args[2], nil) : 0
        guard let arg = unsafe args[1], unsafe JSValueGetTypedArrayType(ctx, arg, nil) == kJSTypedArrayTypeUint8Array,
              let view = unsafe JSValueToObject(ctx, arg, nil), let buffer = unsafe JSObjectGetTypedArrayBuffer(ctx, view, nil) else {
            throw failure("bad_input", "Expected a Uint8Array.")
        }
        let length = unsafe JSObjectGetTypedArrayByteLength(ctx, view, nil)
        let offset = unsafe JSObjectGetTypedArrayByteOffset(ctx, view, nil)
        guard length <= Int(UInt32.max) else { throw failure("input_limit", "Byte input is too large.") }
        let pointer = unsafe JSObjectGetArrayBufferBytesPtr(ctx, buffer, nil)?.advanced(by: offset)
        guard pointer != nil || length == 0 else { throw failure("bad_input", "Detached byte buffer.") }
        let input = unsafe UnsafeRawBufferPointer(start: pointer, count: length)
        switch operation {
        case "crc32":
            let crc = unsafe zlib.crc32(0, input.bindMemory(to: Bytef.self).baseAddress, uInt(length))
            return unsafe JSValueMakeNumber(ctx, Double(crc))
        case "inflate":
            if let failure = Self.memoryFailure() { throw failure }
            guard count == 3, let capacity = Int(exactly: size), (0...32 * 1024 * 1024).contains(capacity),
                  let output = NSMutableData(length: max(capacity, 1)) else { throw failure("bad_input", "Invalid inflate length.") }
            var stream = z_stream()
            guard unsafe inflateInit2_(&stream, -MAX_WBITS, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw failure("resource_limit", "Could not initialize inflate.")
            }
            defer { unsafe inflateEnd(&stream) }
            unsafe stream.next_in = pointer?.assumingMemoryBound(to: Bytef.self)
            stream.avail_in = uInt(length)
            unsafe stream.next_out = output.mutableBytes.assumingMemoryBound(to: Bytef.self)
            stream.avail_out = uInt(output.length)
            guard unsafe zlib.inflate(&stream, Z_FINISH) == Z_STREAM_END, stream.total_out == capacity, stream.avail_in == 0 else {
                throw failure("bad_input", "Invalid raw DEFLATE stream or length.")
            }
            output.length = capacity
            if let failure = Self.memoryFailure() { throw failure }
            return try unsafe typed(output, ctx)
        default:
            if operation == "text", input.count >= 2, (input[0] == 255 && input[1] == 254 || input[0] == 254 && input[1] == 255) {
                guard length % 2 == 0 else { throw failure("bad_input", "Truncated UTF-16.") }
                let little = input[0] == 255
                let units = stride(from: 2, to: length, by: 2).map { i in
                    UInt16(input[i + (little ? 0 : 1)]) | UInt16(input[i + (little ? 1 : 0)]) << 8
                }
                let js = units.withUnsafeBufferPointer { unsafe JSStringCreateWithCharacters($0.baseAddress, $0.count) }!
                defer { unsafe JSStringRelease(js) }
                return unsafe JSValueMakeString(ctx, js)
            }
            guard var text = String(bytes: input, encoding: .utf8) else { throw failure("bad_input", "Invalid UTF-8.") }
            if text.unicodeScalars.first?.value == 0xfeff { text.unicodeScalars.removeFirst() }
            return unsafe JSValue(object: text, in: context).jsValueRef
        }
    }

    private let io: PlugIO
    private let parser: ProgramAnalyzer
    private var callLines: [String: Int]?
    private let progress: ProgressWindow
    private var progressCell: UnsafeMutableRawPointer { unsafe Unmanaged.passUnretained(progress).toOpaque() }
    private var context: JSContext?
    private var body: JSValue?
    private var callProgram: JSValue?
    private var updateInput: JSValue?
    private var record: SenseRecord?
    private var program: OwnedProgram?
    private var id = 0
    private var callID = 0
    private var entryProgress = SenseEntryProgress()
    private var entryType = ""
    private var address: String?
    private struct Material {
        let json: Data
        let isFile: Bool
        var bytes: NSMutableData?
    }
    private var initialMaterial: Material?
    private var published = false
    private var subscribed = false
    private var logBytes = 0
    private var thrown: JSValue?
    private var latched: SenseFailure?

    init(io: PlugIO, parser: ProgramAnalyzer) {
        self.io = io; self.parser = parser; progress = ProgressWindow(io: io)
    }

    deinit {
        unsafe JSClassRelease(namespaceClass)
        if let context, let group = unsafe JSContextGetGroup(context.jsGlobalContextRef) { unsafe Self.clearTimeLimit?(group) }
    }

    func run(_ message: [String: Any]) throws {
        acceptingCalls = true
        defer { acceptingCalls = false }
        if let failure = Self.memoryFailure() { throw failure }
        if message["type"] as? String != "changed" {
            guard let raw = message["program"] as? [String: Any] else {
                throw failure("bad_input", "JavaScript run requires its exact owned program.")
            }
            let decoded = try JSONDecoder().decode(OwnedProgram.self, from: JSONValue(fromFoundation: raw).serializedData(pretty: false))
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
        progress.begin(id: id, seconds: nil, kind: .sense)
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
            let decoded = try JSONDecoder().decode(SenseRecord.self, from: JSONValue(fromFoundation: rawRecord).serializedData(pretty: false))
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
            let created = try createContext(program: program, inputJSON: nil)
            if thrown == nil { created.evaluateScript(program.source, withSourceURL: URL(string: "sense-entry.js")) }
            if thrown == nil, entry("read", in: created).map({ isFunction($0, in: created) }) != true {
                throw failure("bad_output", "Sense must define read(request).")
            }
        }
        guard let context else { throw failure("unsupported", "JavaScript context is unavailable.") }
        try checkException()
        var entryFailure: SenseFailure?
        do throws(SenseFailure) { try callSenseEntry(in: context, request: message["request"] as? [String: Any] ?? [:]) }
        catch let failure {
            if failure.code == "resource_limit" || failure.code == "resource_unavailable" { throw failure }
            entryFailure = failure
        }
        acceptingCalls = false
        _ = CFRunLoopRunInMode(.defaultMode, 0, false)
        initialMaterial = nil
        JSGarbageCollect(context.jsGlobalContextRef)
        if let failure = Self.memoryFailure() { throw failure }
        if let entryFailure { io.fail(id: id, entryFailure, entry: true) }
        else { try io.send(["id": id, "type": "done"]) }
    }

    private func entry(_ name: String, in context: JSContext) -> JSValue? {
        if context.globalObject.hasProperty(name) { return context.objectForKeyedSubscript(name) }
        return context.evaluateScript("typeof \(name) === 'undefined' ? undefined : \(name)")
    }

    private func callSenseEntry(in context: JSContext, request: [String: Any]) throws(SenseFailure) {
        guard let function = entry(entryType, in: context), !function.isUndefined,
              isFunction(function, in: context) else {
            throw failure("unsupported", "Sense does not define \(entryType)(request).")
        }
        if entryType == "changed" {
            // Use the SDK's change/Uint8Array conversion so read() consumes the supplied material without an app round trip.
            let converted = context.evaluateScript("sense.source.read()")
            try checkException()
            guard let converted else { throw failure("bad_input", "Missing changed material.") }
            let result = function.call(withArguments: [converted])
            try finish(result)
            return
        }
        let result = function.call(withArguments: [request])
        try finish(result)
    }

    static func resource(_ name: String) throws -> String {
        let installed = SenseSandboxProfile.resources(for: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL)
        #if SWIFT_PACKAGE
        let root = FileManager.default.fileExists(atPath: installed.path) ? installed : Bundle.module.bundleURL.appendingPathComponent("Senses")
        #else
        let root = installed
        #endif
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    private func createContext(
        program: OwnedProgram,
        inputJSON: String?,
        home: String? = nil,
        workspace: String? = nil,
        dataRoot: String? = nil,
        measurementSystem: String? = nil
    ) throws -> JSContext {
        guard let created = JSContext(virtualMachine: JSVirtualMachine()),
              let group = unsafe JSContextGetGroup(created.jsGlobalContextRef) else {
            throw failure("unsupported", "JavaScriptCore did not start.")
        }
        context = created
        created.exceptionHandler = { [weak self] _, exception in self?.thrown = exception }
        let kind = program.kind
        if kind != .sense {
            guard let setTimeLimit = unsafe Self.setTimeLimit, Self.clearTimeLimit != nil else {
                throw failure("unsupported", "JavaScript execution time limits are unavailable.")
            }
            unsafe setTimeLimit(group, 0.25, Self.expired, progressCell)
        }
        let call = try installBridge(in: created)
        if kind == .sense {
            created.setObject(call, forKeyedSubscript: "__senseCall" as NSString)
            created.evaluateScript(try Self.resource("sense.js"), withSourceURL: URL(string: "sense-sdk.js"))
            created.globalObject.deleteProperty("__senseCall")
        } else {
            var settings: [String: Any] = ["part": program.isPart, "strict": program.isStrict, "turn": kind == .turn,
                "optionKeys": OwnedProgram.Calls.optionKeys, "requestKeys": OwnedProgram.Calls.requestKeys,
                "files": OwnedProgramRunner.hostFilePrimitives.sorted()]
            if program.isPart {
                guard let home, let workspace, let dataRoot, let measurementSystem else {
                    throw failure("bad_input", "An ability requires its home, workspace, data paths and measurement system from the app.")
                }
                settings["home"] = home; settings["workspace"] = workspace
                settings["dataRoot"] = dataRoot; settings["measurementSystem"] = measurementSystem
            }
            if let inputJSON { settings["input"] = inputJSON }
            if callLines == nil {
                if let sealed = program.analysis?.callLines { callLines = sealed }
                else {
                    let source = program.entry == .functionBody ? "(function () {" + program.source + "\n})" : program.source
                    let analyzer = try parser.function()
                    let locations = analyzer.invokeMethod("locations", withArguments: [source])
                    guard analyzer.context.exception == nil, let lines = locations?.toDictionary() as? [String: Int] else {
                        throw failure("analysis_failed", "Could not read program call locations.")
                    }
                    callLines = lines
                }
            }
            let installer = created.evaluateScript(try Self.resource(SenseSandboxProfile.partLibrary), withSourceURL: URL(string: "part-kit.js"))
            if thrown == nil {
                let installed = installer?.call(withArguments: [namespace("", created), call, settings])
                guard let names = installed?.objectForKeyedSubscript("names")?.toArray() as? [String],
                      let factory = installed?.objectForKeyedSubscript("member"), isFunction(factory, in: created) else {
                    throw failure("engine_start_failed", "Could not install program bindings: \(thrown?.toString() ?? "missing member factory").")
                }
                builtinNames = Set(names)
                bindingFactory = factory
                if inputJSON != nil { updateInput = installed?.objectForKeyedSubscript("update") }
                if program.isPart, let host = try member(in: "", named: "host", context: created) {
                    created.globalObject.defineProperty("host", descriptor: ["value": host])
                }
            }
        }
        if thrown == nil, kind == .sense {
            let libraries = try SenseSandboxProfile.senseLibraries.map { try Self.resource($0) }.joined(separator: "\n")
            created.evaluateScript("""
                (() => {
                \(libraries)
                for (const [name, library] of Object.entries({NativeKit, SenseZip, SenseXML, SenseXml: SenseXML, SenseDocuments, SenseIWork, SenseRTF})) {
                    globalThis[name] = Object.freeze(library);
                }
                })()
                """)
        }
        if kind != .sense, thrown == nil {
            // Attach thenable handlers in the entry API call so JSC's return-time microtask drain settles the value before Swift reads it.
            callProgram = created.evaluateScript("""
                (function (resolve) {
                  return function (entry, args) {
                    var state = {status: 0};
                    try {
                      var out = entry.apply(undefined, args);
                      if (out === null || (typeof out !== "object" && typeof out !== "function") || typeof out.then !== "function") {
                        state.value = out; state.status = 1;
                      } else {
                        resolve(out).then(function (value) {
                          state.value = value; state.status = 1;
                        }, function (error) {
                          state.error = error; state.status = 2;
                        });
                      }
                    } catch (error) { state.error = error; state.status = 2; }
                    return state;
                  };
                })(Promise.resolve.bind(Promise))
                """)
        }
        return created
    }

    private func runProgram(_ program: OwnedProgram, message: [String: Any]) throws {
        guard let fresh = message["freshContext"] as? Bool, !fresh || context == nil else {
            throw failure("bad_input", "A pooled run requires an empty realm.")
        }
        weak var retired: JSContext?
        weak var retiredVM: JSVirtualMachine?
        let done = try autoreleasepool {
            let result = try evaluate(program, message: message)
            acceptingCalls = false
            _ = CFRunLoopRunInMode(.defaultMode, 0, false)
            if fresh {
                retired = context
                retiredVM = context?.virtualMachine
                body = nil; callProgram = nil; updateInput = nil; thrown = nil; latched = nil
                bindings.removeAll(); bindingFactory = nil
                admittedNames.removeAll()
            }
            if let context { unsafe JSGarbageCollect(context.jsGlobalContextRef) }
            if fresh {
                context = nil
                id = 0; callID = 0; logBytes = 0
                progress.begin(id: 0, seconds: nil, kind: program.kind)
            }
            return result
        }
        guard retired == nil, retiredVM == nil else { throw failure("realm_retained", "A pooled JavaScript realm survived its run.") }
        if let failure = Self.memoryFailure() { throw failure }
        try io.send(done)
    }

    private func evaluate(_ program: OwnedProgram, message: [String: Any]) throws -> [String: Any] {
        guard (context == nil || program.isResident), let runID = message["id"] as? Int else {
            throw failure("bad_input", "Program requires an available helper and an integer id.")
        }
        id = runID; callID = 0; logBytes = 0; thrown = nil; latched = nil
        progress.begin(id: id, seconds: program.seconds, kind: program.kind)
        let inputJSON = try message["input"].map {
            try JSONValue(fromFoundation: $0).serialize(pretty: false)
        } ?? ([.run, .verbs, .face].contains(program.entry) ? "{}" : nil)
        let fresh = context == nil
        if fresh {
            _ = try createContext(
                program: program,
                inputJSON: inputJSON,
                home: message["home"] as? String,
                workspace: message["workspace"] as? String,
                dataRoot: message["dataRoot"] as? String,
                measurementSystem: message["measurementSystem"] as? String
            )
        }
        guard let context, let group = unsafe JSContextGetGroup(context.jsGlobalContextRef), let setTimeLimit = unsafe Self.setTimeLimit else {
            throw failure("unsupported", "JavaScript context is unavailable.")
        }
        unsafe setTimeLimit(group, 0.25, Self.expired, progressCell)
        defer { unsafe Self.clearTimeLimit?(group) }
        if !fresh, let inputJSON { updateInput?.call(withArguments: [inputJSON]) }
        try checkExecution()
        if let thrown {
            throw failure("engine_start_failed", "The script engine did not start: \(thrown)")
        }
        let programReused = body != nil
        let compiled = program.entry == .functionBody ? "(function () {" + program.source + "\n})" : program.source
        let unparsed = body == nil && !parses(compiled)
        if body == nil, program.entry == .functionBody {
            body = context.evaluateScript(compiled, withSourceURL: URL(string: "app-script.js"))
        } else if body == nil {
            context.evaluateScript(program.source, withSourceURL: URL(string: "app-script.js"))
            let entry = program.entry == .face ? "face" : "run"
            if program.entry == .verbs {
                body = context.evaluateScript("""
                    input => {
                        if (!Object.hasOwn(verbs, input.verb) || typeof verbs[input.verb] !== "function")
                            throw new TypeError("No handler for " + input.verb);
                        return verbs[input.verb](input);
                    }
                    """)
            } else if thrown == nil {
                body = self.entry(entry, in: context)
            }
            if thrown == nil, body.map({ isFunction($0, in: context) }) != true {
                throw failure("bad_output", "Owned program must define \(entry)(input).")
            }
        }
        let settled: JSValue?
        if thrown == nil, let body, let callProgram {
            let arguments: [Any] = [.run, .verbs, .face].contains(program.entry) ? [context.objectForKeyedSubscript("input")!] : []
            settled = callProgram.call(withArguments: [body, arguments])
        } else { settled = nil }
        try checkExecution()
        var done: [String: Any] = ["id": id, "type": "program_done"]
        if program.kind == .turn { done["programReused"] = programReused }
        if thrown == nil, settled?.objectForKeyedSubscript("status")?.toInt32() == 2 {
            thrown = settled?.objectForKeyedSubscript("error")
        }
        if let thrown {
            var report = exception(thrown)
            if unparsed { report["syntax"] = true }
            done["exception"] = report
            return done
        }
        guard let settled else { throw failure("bad_output", "The program entry returned no settlement state.") }
        guard settled.objectForKeyedSubscript("status")?.toInt32() == 1 else {
            done["unreadableReturn"] = "Its Promise never settled: only app and host calls, which answer at once, can be awaited here."
            return done
        }
        let value = settled.objectForKeyedSubscript("value")
        if let value, !value.isUndefined {
            let json = context.objectForKeyedSubscript("JSON")?.invokeMethod("stringify", withArguments: [value])
            try checkExecution()
            if thrown != nil || json?.isString != true {
                let detail = thrown != nil ? "The returned value could not be read: \((thrown?.toString() ?? "").prefix(300))"
                    : "The returned value has no JSON form (a function or a symbol)."
                done["unreadableReturn"] = detail
                return done
            }
            if let json, json.isString, let text = json.toString() {
                // This is transport, not a model view. The app's result owner retains the whole value before bounding it.
                done["returned"] = try JSONValue.parse(Data(text.utf8)).foundationObject
            }
        }
        return done
    }

    private func parses(_ source: String) -> Bool {
        guard let context, let script = unsafe JSStringCreateWithCFString(source as CFString) else { return true }
        defer { unsafe JSStringRelease(script) }
        return unsafe JSCheckScriptSyntax(context.jsGlobalContextRef, script, nil, 1, nil)
    }

    private func exception(_ value: JSValue) -> [String: Any] {
        var report: [String: Any] = ["message": String((value.toString() ?? "error").prefix(400))]
        for key in ["name", "reason"] {
            if let item = value.objectForKeyedSubscript(key), item.isString { report[key] = item.toString() }
        }
        let line = value.objectForKeyedSubscript("scriptLine").flatMap { $0.isNumber && $0.toInt32() > 0 ? Int($0.toInt32()) : nil }
            ?? scriptLine(in: value)
            ?? value.objectForKeyedSubscript("line").flatMap { $0.isNumber ? Int($0.toInt32()) : nil }
        if let line, line > 0 { report["line"] = line }
        if let n = value.objectForKeyedSubscript("callNumber"), n.isNumber { report["n"] = Int(n.toInt32()) }
        return report
    }

    private func scriptLine(in error: JSValue) -> Int? {
        guard let stack = error.objectForKeyedSubscript("stack"), stack.isString, let text = stack.toString(),
              let marker = text.range(of: "app-script.js:") else { return nil }
        return Int(text[marker.upperBound...].prefix(while: { $0.isASCII && $0.isNumber }))
    }

    private func callerLine(in context: JSContext) -> Int {
        let location = JSValue(newErrorFromMessage: "", in: context)
        return location.flatMap { scriptLine(in: $0) } ?? 0
    }

    private func finish(_ result: JSValue?) throws(SenseFailure) {
        try checkException()
        if let result, result.isObject, let then = result.objectForKeyedSubscript("then"),
           let context, isFunction(then, in: context) {
            throw failure("bad_output", "Sense entry points must finish synchronously.")
        }
        if entryType == "read", !published { throw failure("bad_output", "Sense read returned without publishing a page.") }
    }

    private func checkExecution() throws(SenseFailure) {
        if let latched { throw latched }
        if progress.expired { throw failure("timeout", "Owned program stalled without progress.") }
    }

    private func checkException() throws(SenseFailure) {
        try checkExecution()
        if let thrown {
            let message = String((thrown.toString() ?? "Sense threw an error.").prefix(1000))
            throw failure(message.contains("execution terminated") ? "timeout" : "javascript", message)
        }
    }

    private func replyJSON(_ reply: [String: Any], in context: JSContext) throws(SenseFailure) -> JSValue {
        guard let data = reply["payload"] as? NSData else { throw failure("bad_frame", "Missing JSON reply payload.") }
        return try jsonValue(data as Data, in: context)
    }

    private func jsonValue(_ data: Data, in context: JSContext) throws(SenseFailure) -> JSValue {
        guard let text = String(data: data, encoding: .utf8),
              let string = unsafe JSStringCreateWithCFString(text as CFString) else { throw failure("bad_frame", "Invalid JSON reply payload.") }
        defer { unsafe JSStringRelease(string) }
        guard let value = unsafe JSValueMakeFromJSONString(context.jsGlobalContextRef, string) else { throw failure("bad_frame", "Invalid reply JSON.") }
        return unsafe JSValue(jsValueRef: value, in: context)
    }

    private func senseCall(_ type: String, fields: JSValue, in context: JSContext) throws -> JSValueRef? {
        func payload() throws -> Data {
            let data = try unsafe jsonBytes(fields.jsValueRef, context: context)
            guard data.count <= 2 * 1024 * 1024 else { throw failure("output_limit", "Sense API call exceeds the 2 MiB JSON limit.") }
            return data
        }
        func header() -> [String: Any] {
            callID += 1
            return ["id": id, "callID": callID, "type": type]
        }
        guard let record else { throw failure("bad_output", "Sense call has no bound record.") }
        switch type {
        case "app_read", "act", "state_get", "state_set", "state_delete", "state_list", "state_cas":
            let data = try payload()
            guard type != "act" || entryType == "act" else {
                throw failure("bad_output", "Sense actions are allowed only while answering an act request.")
            }
            let response = type == "app_read" ? "app_reply" : type == "act" ? "act_reply" : "state_reply"
            return try unsafe replyJSON(exchange(header(), replyType: response, payload: data), in: context).jsValueRef
        case "publish", "notify", "present":
            let data = try payload()
            _ = try exchange(header(), replyType: type + "_reply", payload: data)
            if type == "publish" { published = true }
            if type != "present" { try progress.record() }
        case "source_watch":
            guard record.mode == .live else { throw failure("bad_output", "Only live senses can subscribe.") }
            var body = header()
            body["corner"] = record.corner.key
            guard try exchange(body, replyType: "source_reply")["subscribed"] as? Bool == true else {
                throw failure("source_unavailable", "Sense source subscription was not acknowledged.")
            }
            subscribed = true
        case "source_read":
            let target = fields.objectForKeyedSubscript("address")
            let requested: String?
            if target?.isNull == true { requested = address }
            else if target?.isString == true, let text = target?.toString() {
                _ = try payload()
                requested = text
            } else {
                let value = try JSONValue.parse(payload()).objectValue?["address"]
                guard value == .null || value?.stringValue != nil else { throw failure("bad_output", "Sense source address must be a string or null.") }
                requested = value?.stringValue ?? address
            }
            var body = header()
            let value: JSValue
            if let supplied = initialMaterial, requested == address {
                if supplied.isFile, supplied.bytes == nil {
                    body["type"] = "source_copy"
                    value = try sourceReply(body, in: context)
                } else {
                    value = try materialValue(supplied, in: context)
                    initialMaterial?.bytes = nil
                }
                if entryProgress.read(address: requested) {
                    try io.send(["id": id, "type": "progress", "readAddress": requested.map { $0 as Any } ?? NSNull()])
                    try progress.record()
                }
            } else {
                body["corner"] = record.corner.key
                body["address"] = requested.map { $0 as Any } ?? NSNull()
                value = try sourceReply(body, in: context)
                if entryProgress.read(address: requested) { try progress.record() }
            }
            return unsafe value.jsValueRef
        case "progress":
            let field = fields.objectForKeyedSubscript("n")
            let n: Double? = field?.isNull == true ? nil : (field?.isNumber == true ? field?.toDouble() : .nan)
            callID += 1
            if let mark = try entryProgress.advance(to: n) { try progress.record(mark: mark) }
        case "log":
            guard let field = fields.objectForKeyedSubscript("text"), field.isString, let text = field.toString() else {
                throw failure("bad_output", "Sense log requires text.")
            }
            guard logBytes + text.utf8.count <= 2048 else {
                _ = try payload()
                throw failure("bad_output", "Sense logs exceed 2 KiB.")
            }
            var body = header()
            body["text"] = text
            logBytes += text.utf8.count
            try io.send(body)
        default: throw failure("bad_output", "Unknown sense API call.")
        }
        return unsafe JSValueMakeNull(context.jsGlobalContextRef)
    }

    private func sourceReply(_ body: [String: Any], in context: JSContext) throws -> JSValue {
        let reply = try exchange(body, replyType: "source_reply")
        if let material = reply["material"] as? [String: Any], material["kind"] as? String == "file" {
            return try materialValue(checkedMaterial(material), in: context)
        }
        let result = try replyJSON(reply, in: context)
        switch result.objectForKeyedSubscript("kind")?.toString() {
        case "text" where result.objectForKeyedSubscript("text")?.isString == true,
             "accessibility" where result.hasProperty("tree"), "page" where result.hasProperty("snapshot"):
            return result
        default: throw failure("bad_input", "Invalid sense material.")
        }
    }

    private func materialValue(_ material: Material, in context: JSContext) throws -> JSValue {
        let result = try jsonValue(material.json, in: context)
        if let bytes = material.bytes {
            let array = try unsafe typed(bytes, context.jsGlobalContextRef)
            result.setValue(unsafe JSValue(jsValueRef: array, in: context), forProperty: "data")
        }
        return result
    }

    private func exchange(_ body: [String: Any], replyType: String, payload: Data? = nil) throws(SenseFailure) -> [String: Any] {
        // Exclude blocked app work from stall time without counting state traffic or repeated reads as progress.
        progress.suspendForReply()
        defer { progress.resumeAfterReply() }
        let reply: [String: Any]
        let rejected: SenseFailure?
        do {
            try io.send(body, payload: payload)
            guard let response = try io.receive() else { throw failure("source_unavailable", "Sense plug closed before replying.") }
            if response["type"] as? String == "stop" { exit(0) }
            guard response["type"] as? String == replyType, response["id"] as? Int == id, response["callID"] as? Int == callID else {
                throw failure("bad_input", "Sense plug reply has the wrong type, id or callID.")
            }
            reply = response
            rejected = try response["failure"].map {
                let data = try JSONValue(fromFoundation: $0).serializedData(pretty: false)
                return try JSONDecoder().decode(SenseFailure.self, from: data)
            }
        } catch { io.fatal(id: id, error) }
        if let rejected { throw rejected }
        return reply
    }

    private func checkedMaterial(_ material: [String: Any]) throws -> Material {
        switch material["kind"] as? String {
        case "file":
            guard material["path"] is String, let count = material["bytes"] as? Int, count >= 0, count <= 16 * 1024 * 1024,
                  let bytes = material["data"] as? NSMutableData, bytes.length == count else {
                throw failure("bad_input", "File material requires its binary attachment (at most 16 MiB).")
            }
        case "text": guard material["text"] is String else { throw failure("bad_input", "Text material requires text.") }
        case "accessibility": guard material["tree"] != nil else { throw failure("bad_input", "Accessibility material requires tree.") }
        case "page": guard material["snapshot"] != nil else { throw failure("bad_input", "Page material requires snapshot.") }
        default: throw failure("bad_input", "Unknown sense material kind.")
        }
        var fields = material
        let bytes = fields["data"] as? NSMutableData
        if bytes != nil { fields["data"] = NSNull() }
        return Material(json: try PlugFrame.json(JSONValue(fromFoundation: fields)), isFile: bytes != nil, bytes: bytes)
    }

    private func isFunction(_ value: JSValue, in context: JSContext) -> Bool {
        guard value.isObject, let object = unsafe JSValueToObject(context.jsGlobalContextRef, value.jsValueRef, nil) else { return false }
        return unsafe JSObjectIsFunction(context.jsGlobalContextRef, object)
    }
    private func failure(_ code: String, _ message: String) -> SenseFailure { SenseFailure(code: code, message: message) }
}
