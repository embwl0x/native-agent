import Foundation
import Testing
import PersistenceCore

@Suite struct InstallPathsTests {
    @Test func shippedCompatibilityAndInstallIsolation() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let privatePaths = InstallPaths(bundleIdentifier: InstallPaths.privateBundleIdentifier, home: home)
        let publicPaths = InstallPaths(bundleIdentifier: "io.github.embwl0x.nativeagent.mac", home: home)
        let second = InstallPaths(bundleIdentifier: "test.nativeagent.mac", home: home)
        #expect(privatePaths.bridgeConfigRoot == home.appendingPathComponent(".config", isDirectory: true))
        #expect(privatePaths.chromeSocket == home.appendingPathComponent("Library/Application Support/NativeAgent/chrome-control.sock"))
        #expect(privatePaths.agentHostEntryName == "nativeagent")
        #expect(privatePaths.name("NativeAgent") == "NativeAgent")
        #expect(publicPaths.bridgeConfigRoot == privatePaths.bridgeConfigRoot)
        #expect(publicPaths.chromeSocket == privatePaths.chromeSocket)
        #expect(publicPaths.agentHostEntryName == "nativeagent")
        for legacy in ["NativeAgent", "nativeagent-backup", "builder-worktrees", "conversation/repository"] {
            #expect(privatePaths.name(legacy) == legacy)
            #expect(publicPaths.name(legacy) == legacy)
            #expect(second.name(legacy) == legacy + "-test.nativeagent.mac")
        }
        #expect(second.bridgeConfigRoot == home.appendingPathComponent(".config/test.nativeagent.mac", isDirectory: true))
        #expect(second.chromeSocket == second.bridgeConfigRoot.appendingPathComponent("chrome.sock"))
        #expect(second.agentHostEntryName == "nativeagent-test_dnativeagent_dmac")
        for paths in [privatePaths, publicPaths, second] {
            let root = home.appendingPathComponent("data")
            #expect(paths.bridgeConfigRoot(dataRoot: root, defaultRoot: root) == paths.bridgeConfigRoot)
            #expect(paths.bridgeConfigRoot(dataRoot: root, defaultRoot: home) == root.appendingPathComponent("bridge-config", isDirectory: true))
            #expect(paths.bridgeConfigRoot(dataRoot: root, defaultRoot: root, secondary: true) == root.appendingPathComponent("bridge-config", isDirectory: true))
            #expect(paths.bridgeDiscoveryDirectory(dataRoot: root, defaultRoot: root, secondary: false) == paths.bridgeConfigRoot.appendingPathComponent("claude-bridge", isDirectory: true))
            let relocated = paths.usesLegacyPaths ? root : root.appendingPathComponent("bridge-config", isDirectory: true)
            #expect(paths.bridgeDiscoveryDirectory(dataRoot: root, defaultRoot: home, secondary: false) == relocated.appendingPathComponent("claude-bridge", isDirectory: true))
            #expect(paths.bridgeDiscoveryDirectory(dataRoot: root, defaultRoot: root, secondary: true) == relocated.appendingPathComponent("claude-bridge", isDirectory: true))
            #expect(paths.bridgeEnvironment(configRoot: paths.bridgeConfigRoot)["NATIVE_AGENT_RETURN_BRIDGE_DIR"] == paths.bridgeConfigRoot.appendingPathComponent("claude-bridge").path)
        }
    }
}
