import Foundation
import Testing
@testable import NativeAgentApp

@Test
func notificationTitleDefaultsToOnboardedAgentName() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NativeAgentNotificationDefaults-\(UUID().uuidString)", isDirectory: true)
    let memory = root.appendingPathComponent("memory", isDirectory: true)
    try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
    try Data(#"{"name":"Zara"}"#.utf8)
        .write(to: memory.appendingPathComponent("profile.json"), options: .atomic)

    #expect(NativeAgentNotificationDefaults.title(nil, dataRoot: root) == "Zara")
    #expect(NativeAgentNotificationDefaults.title("", dataRoot: root) == "Zara")
    #expect(NativeAgentNotificationDefaults.title("NativeAgent", dataRoot: root) == "Zara")
    #expect(NativeAgentNotificationDefaults.title("Build complete", dataRoot: root) == "Build complete")

    try? FileManager.default.removeItem(at: root)
}
