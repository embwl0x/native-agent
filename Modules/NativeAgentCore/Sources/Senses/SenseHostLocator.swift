import Foundation

public enum SenseHostLocator {
    /// Installed location only; a missing helper is an installation failure.
    public static var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/NativeAgentSenseHost")
    }
}
