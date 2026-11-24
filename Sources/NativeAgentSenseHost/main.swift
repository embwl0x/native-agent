import CoreFoundation
import Darwin
import Foundation
import JavaScriptCore
import SenseCore
// Blueprint: | `Sources/NativeAgentSenseHost/main.swift` | Framed entry loop for the shared JavaScript executor |

let io = PlugIO()
signal(SIGPIPE, SIG_IGN)
var runtime: JavaScriptProgramRuntime?
final class ProgramAnalyzer {
    private var loaded: JSValue?

    func function() throws -> JSValue {
        if let loaded { return loaded }
        guard let context = JSContext(virtualMachine: JSVirtualMachine()) else {
            throw SenseFailure(code: "engine_start_failed", message: "Could not prepare the JavaScript parser.")
        }
        var value: JSValue?
        for name in SenseSandboxProfile.analyzerLibraries {
            value = context.evaluateScript(try JavaScriptProgramRuntime.resource(name))
            if let error = context.exception { throw SenseFailure(code: "engine_start_failed", message: error.toString()) }
        }
        guard let value, !value.isUndefined else { throw SenseFailure(code: "engine_start_failed", message: "The program analyzer did not load.") }
        loaded = value
        return value
    }
}
let parser = ProgramAnalyzer()

guard let bootstrap = JSGlobalContextCreate(nil) else { exit(1) }
JSGlobalContextRelease(bootstrap)
do { try io.send(["type": "ready"]) } catch { exit(1) }

while autoreleasepool(invoking: { () -> Bool in
    var id: Int?
    do {
        guard let message = try io.receive() else { return false }
        id = message["id"] as? Int
        switch message["type"] as? String {
        case "stop": exit(0)
        case "analyze":
            if let failure = JavaScriptProgramRuntime.memoryFailure() { throw failure }
            guard let id, let source = message["source"] as? String else {
                throw SenseFailure(code: "bad_input", message: "Program analysis requires an id and source.")
            }
            let analyzer = try parser.function()
            guard let context = analyzer.context, let script = JSStringCreateWithCFString(source as CFString) else {
                throw SenseFailure(code: "engine_start_failed", message: "Could not prepare the JavaScript parser.")
            }
            defer { JSStringRelease(script) }
            var exception: JSValueRef?
            if unsafe JSCheckScriptSyntax(context.jsGlobalContextRef, script, nil, 1, &exception) {
                let facts = analyzer.call(withArguments: [source])
                if let failure = JavaScriptProgramRuntime.memoryFailure() { throw failure }
                if let error = context.exception {
                    context.exception = nil
                    io.fail(id: id, SenseFailure(code: "analysis_failed", message: error.toString()))
                } else if let facts, facts.isString, let json = facts.toString() {
                    try io.send(["id": id, "type": "analysis", "facts": json])
                } else {
                    throw SenseFailure(code: "bad_output", message: "The program analyzer returned no facts.")
                }
            } else {
                var detail = "Invalid JavaScript syntax."
                if let exception, let reason = unsafe JSValueToStringCopy(context.jsGlobalContextRef, exception, nil) {
                    defer { JSStringRelease(reason) }
                    if let text = JSStringCopyCFString(nil, reason) { detail = text as String }
                }
                io.fail(id: id, SenseFailure(code: "invalid_syntax", message: detail))
            }
        case "run":
            fallthrough
        case "changed":
            if runtime == nil { runtime = JavaScriptProgramRuntime(io: io, parser: parser) }
            try runtime?.run(message)
        default: throw SenseFailure(code: "bad_input", message: "Unknown sense plug request.")
        }
    } catch {
        io.fatal(id: id, error)
    }
    return true
}) {}
