import Darwin
import Foundation
import Senses

let io = PlugIO()
signal(SIGPIPE, SIG_IGN)
var runtime: JavaScriptProgramRuntime?

while true {
    var id: Int?
    do {
        guard let message = try io.receive() else { break }
        id = message["id"] as? Int
        switch message["type"] as? String {
        case "stop": exit(0)
        case "run":
            fallthrough
        case "changed":
            if runtime == nil {
                let installedSDK = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
                    .deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("Resources/Senses/sense.js")
                #if SWIFT_PACKAGE
                let sdk = FileManager.default.isReadableFile(atPath: installedSDK.path) ? installedSDK
                    : Bundle.module.bundleURL.appendingPathComponent("Senses/sense.js")
                #else
                let sdk = installedSDK
                #endif
                let shim = try String(contentsOf: sdk, encoding: .utf8)
                runtime = JavaScriptProgramRuntime(io: io, shim: shim)
            }
            try runtime?.run(message)
        default: throw SenseFailure(code: "bad_input", message: "Expected run, changed or stop on the sense plug.")
        }
    } catch {
        io.fail(id: id, (error as? SenseFailure) ?? SenseFailure(code: "crashed", message: error.localizedDescription))
        // Failed JSC contexts and interrupted plug exchanges cannot be reused.
        exit(1)
    }
}
