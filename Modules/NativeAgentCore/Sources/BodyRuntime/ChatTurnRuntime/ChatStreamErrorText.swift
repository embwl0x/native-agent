import Foundation
// Blueprint: | `ChatStreamErrorText.swift` | `ChatStreamErrorText` enum; `normalize` |

public enum ChatStreamErrorText {
    /// Mac and iPhone share failure wording; retryAction names the visible control on each surface.
    public static func normalize(_ raw: String, retryAction: String = "Try again") -> String {
        let d = raw.lowercased()

        // Point retry hints at the visible action so keyboard and touch users can reach them.
        if d.contains("idle timeout") || d.contains("wall timeout") {
            // A timeout proves the service stopped answering; the saved request remains available for retry.
            return "The model service stopped answering partway through. Your message is saved - use \(retryAction) to retry."
        }
        if d.contains("network connection was lost") || d.contains("code=-1005") {
            return "Couldn't reach the model - the network connection dropped. Your message is saved - use \(retryAction) to retry."
        }
        if d.contains("not connected to internet") || d.contains("code=-1009") {
            // The ONLY arm that may name the network: URLError says so.
            return "No internet connection. Your message is saved - reconnect, then use \(retryAction) to retry."
        }
        if d.contains("timed out") || d.contains("code=-1001") {
            // Transport timeout cannot identify which side was slow, so it supplies no network verdict.
            return "The request timed out before the model service answered. Your message is saved - use \(retryAction) to retry."
        }
        if d.contains("cannot connect to") || d.contains("code=-2003") {
            return "Couldn't reach the server. Use Try again to retry."
        }
        if d.contains("cannot resolve") || d.contains("cannot find host")
            || d.contains("code=-1003") || d.contains("code=-1004") {
            return "Couldn't resolve the server address. Check your network, then use \(retryAction) to retry."
        }
        return "Chat error: \(raw)"
    }
}
