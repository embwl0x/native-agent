import Darwin

/// Last-gasp crash stack: on a fatal signal, write the backtrace to a file
/// opened at launch, then re-raise so macOS still files its own report. The
/// backtrace calls are not guaranteed async-signal-safe; this is best effort
/// (10-07: two crashes left no .ips at all).
enum CrashBreadcrumbs {
    nonisolated(unsafe) private static var fd: Int32 = -1

    static func install(path: String) {
        guard fd < 0 else { return }
        let opened = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard opened >= 0 else { return }
        fd = opened
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { signum in
            signal(signum, SIG_DFL)
            let prefix: StaticString = "\nNativeAgent fatal signal "
            _ = write(CrashBreadcrumbs.fd, prefix.utf8Start, prefix.utf8CodeUnitCount)
            var digits: (UInt8, UInt8, UInt8) = (UInt8(48 + signum / 10), UInt8(48 + signum % 10), 10)
            _ = withUnsafeBytes(of: &digits) { write(CrashBreadcrumbs.fd, $0.baseAddress, 3) }
            withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: 64) { frames in
                let count = backtrace(frames.baseAddress, 64)
                backtrace_symbols_fd(frames.baseAddress, count, CrashBreadcrumbs.fd)
            }
            raise(signum)
        }
        action.sa_flags = SA_RESETHAND | SA_NODEFER
        sigemptyset(&action.sa_mask)
        // TERM/HUP name an outside kill; a clean exit leaves its own line, so silence means SIGKILL.
        for signum in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP, SIGTERM, SIGHUP] { sigaction(signum, &action, nil) }
        atexit {
            let line: StaticString = "\nNativeAgent exited\n"
            _ = write(CrashBreadcrumbs.fd, line.utf8Start, line.utf8CodeUnitCount)
        }
    }
}
