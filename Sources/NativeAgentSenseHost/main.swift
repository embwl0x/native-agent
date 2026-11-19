import Darwin
import Foundation
import Senses
// Blueprint: | `Sources/NativeAgentSenseHost/main.swift` | JSON-line entry loop for the shared JavaScript executor |

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
            if runtime == nil { runtime = JavaScriptProgramRuntime(io: io) }
            try runtime?.run(message)
        default: throw SenseFailure(code: "bad_input", message: "Expected run, changed or stop on the sense plug.")
        }
    } catch {
        io.fail(id: id, (error as? SenseFailure) ?? SenseFailure(code: "crashed", message: error.localizedDescription))
        // Failed JSC contexts and interrupted plug exchanges cannot be reused.
        exit(1)
    }
}
