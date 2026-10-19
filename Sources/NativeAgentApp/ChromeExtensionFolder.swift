import Foundation
import EngineRuntime
import AppKit
import ChromeControl
import PersistenceCore
import NativeAgentCore
import TrustCenter

typealias ChromeExtensionFolder = ChromeControl.ChromeExtensionFolder

extension ChromeExtensionFolder {
    @MainActor
    static func setUp() async throws -> URL {
        try await setUp(chrome: NativeAgentEngine.live.chrome,
            dataRoot: PersistenceCore.defaultDataRoot(),
            origin: ChromeControlInvocationContext.origin ?? SecurityOriginContext(surface: "native_actions"))
    }

    static func setupMessage(_ error: Error) -> String {
        String(error.localizedDescription.prefix { $0 != "\n" })
            + ((error as? ToolFailureError)?.tap.map { " Open \($0)." } ?? "")
    }
}
