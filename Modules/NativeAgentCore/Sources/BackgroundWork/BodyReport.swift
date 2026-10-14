import Darwin
import Foundation

/// The crash breadcrumbs: a launch row opens each run, the exit row closes
/// a clean one, a fatal-signal row names a crash; nothing after the launch
/// row is a SIGKILL.
public enum BodyReport {
    public static func crashBreadcrumbs(_ dataRoot: URL) -> URL { dataRoot.appendingPathComponent("logs/crash-breadcrumbs.log") }
    public static let launchMark = "NativeAgent launched "
}

/// Last-gasp crash stack: on a fatal signal, write the backtrace to a file
/// opened at launch, then re-raise so macOS still files its own report. The
/// backtrace calls are not guaranteed async-signal-safe; this is best effort
/// (10-07: two crashes left no .ips at all).
extension BodyReport {
    nonisolated(unsafe) private static var crashFD: Int32 = -1

    public static func installCrashBreadcrumbs(path: String) {
        guard crashFD < 0 else { return }
        let opened = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard opened >= 0 else { return }
        crashFD = opened
        let launched = "\n" + BodyReport.launchMark + Date().ISO8601Format() + "\n"
        _ = launched.withCString { write(opened, $0, strlen($0)) }
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { signum in
            signal(signum, SIG_DFL)
            let prefix: StaticString = "\nNativeAgent fatal signal "
            _ = write(BodyReport.crashFD, prefix.utf8Start, prefix.utf8CodeUnitCount)
            var digits: (UInt8, UInt8, UInt8) = (UInt8(48 + signum / 10), UInt8(48 + signum % 10), 10)
            _ = withUnsafeBytes(of: &digits) { write(BodyReport.crashFD, $0.baseAddress, 3) }
            withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: 64) { frames in
                let count = backtrace(frames.baseAddress, 64)
                backtrace_symbols_fd(frames.baseAddress, count, BodyReport.crashFD)
            }
            raise(signum)
        }
        action.sa_flags = SA_RESETHAND | SA_NODEFER
        sigemptyset(&action.sa_mask)
        // TERM/HUP name an outside kill; a clean exit leaves its own line, so silence after the launch row means SIGKILL.
        for signum in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP, SIGTERM, SIGHUP] { sigaction(signum, &action, nil) }
        atexit {
            let line: StaticString = "\nNativeAgent exited\n"
            _ = write(BodyReport.crashFD, line.utf8Start, line.utf8CodeUnitCount)
        }
    }
}
