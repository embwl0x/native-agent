import Foundation

enum NativeAgentLaunchPreflight {
    private static let distExecutableSuffix = "/dist/NativeAgent.app/Contents/MacOS/NativeAgentApp"

    static func shouldSuppressGUIStart(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executablePath: String = CommandLine.arguments.first ?? ""
    ) -> Bool {
        guard environment["CODEX_SHELL"] == "1" else { return false }
        let standardized = NSString(string: executablePath).standardizingPath
        return standardized.hasSuffix(distExecutableSuffix)
    }

    static func writeSuppressedLaunchReceipt() {
        let message = "NativeAgent: refusing to launch the dist GUI bundle from a Codex shell; use script/install_app.sh and probe the installed app through the authenticated bridge.\n"
        FileHandle.standardError.write(Data(message.utf8))
    }
}
