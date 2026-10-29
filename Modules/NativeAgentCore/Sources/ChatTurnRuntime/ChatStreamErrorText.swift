import Foundation
// Blueprint: | `ChatStreamErrorText.swift` | `ChatStreamErrorText` enum; `normalize` |

public enum ChatStreamErrorText {
    /// Mac and iPhone share failure wording; retryAction names the visible control on each surface.
    public static func normalize(_ raw: String, retryAction: String = "Try again") -> String {
        let d = raw.lowercased()

        // Retry hints point at the visible Try again action on the failed or
        // partial last assistant message. The prior pointer-only Regenerate
        // instruction was inaccessible to keyboard and touch users.
        // (1) ProviderStreamGuard's stable timeout strings (idle/wall).
        if d.contains("idle timeout") || d.contains("wall timeout") {
            // A timeout proves the service stopped answering; the saved request remains available for retry.
            return "The model service stopped answering partway through. Your message is saved - use \(retryAction) to retry."
        }
        // (2) URLError categories / adapter transport strings.
        if d.contains("network connection was lost") || d.contains("code=-1005") {
            return "Couldn't reach the model - the network connection dropped. Your message is saved - use \(retryAction) to retry."
        }
        if d.contains("not connected to internet") || d.contains("code=-1009") {
            // The ONLY arm that may name the network: URLError says so.
            return "No internet connection. Your message is saved - reconnect, then use \(retryAction) to retry."
        }
        if d.contains("timed out") || d.contains("code=-1001") {
            // A transport timeout does not say whose side was slow, so it no
            // longer sends anyone to check a network that may be fine.
            return "The request timed out before the model service answered. Your message is saved - use \(retryAction) to retry."
        }
        if d.contains("cannot connect to") || d.contains("code=-2003") {
            return "Couldn't reach the server. Use Try again to retry."
        }
        if d.contains("cannot resolve") || d.contains("cannot find host")
            || d.contains("code=-1003") || d.contains("code=-1004") {
            return "Couldn't resolve the server address. Check your network, then use \(retryAction) to retry."
        }
        // (3) Default — unchanged behavior so nothing regresses.
        return "Chat error: \(raw)"
    }
}
