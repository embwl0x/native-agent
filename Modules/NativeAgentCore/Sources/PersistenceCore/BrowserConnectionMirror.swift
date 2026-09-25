import Foundation

/// The Chrome link's connection as the app's runtime last published it, so a
/// reader (the agent's home screen) can say it without dispatching a tool.
/// Nil until the runtime has said anything.
public enum BrowserConnectionMirror {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var value: Bool?

    public static func set(connected: Bool) { lock.withLock { value = connected } }
    public static var connected: Bool? { lock.withLock { value } }
}
