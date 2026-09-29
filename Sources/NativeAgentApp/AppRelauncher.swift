import Foundation
import Darwin

extension AppRelauncher {
    /// Production relauncher spawn: posix_spawn with POSIX_SPAWN_SETSID so
    /// the helper becomes its own session leader — it must survive launchd
    /// tearing down the app's process group when the login item exits —
    /// with stdio redirected to /dev/null (nohup-equivalent, no SIGHUP /
    /// no pipe to a dead parent).
    static func spawnDetached(argv: [String]) throws {
        precondition(!argv.isEmpty)

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        for fd: Int32 in 0...2 {
            posix_spawn_file_actions_addopen(&fileActions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // POSIX_SPAWN_SETSID (Darwin) — child starts in a NEW session,
        // detached from our session/process group and any controlling tty.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { for p in cArgs where p != nil { free(p) } }

        var childPID: pid_t = 0
        let rc = posix_spawn(&childPID, argv[0], &fileActions, &attr, cArgs, environ)
        guard rc == 0 else {
            throw NSError(
                domain: "AppRestartCoordinator",
                code: Int(rc),
                userInfo: [NSLocalizedDescriptionKey: "posix_spawn(\(argv[0])) failed: \(String(cString: strerror(rc)))"]
            )
        }
    }
}
