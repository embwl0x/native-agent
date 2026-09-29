import Darwin
import Foundation
import NativeAgentCore
import ChatOrchestration

/// ACP owns and reaps its children directly: Foundation's termination observer
/// must not reap the group leader before descendants have been signaled.
struct MacAgentACPProcess: AgentACPProcessHosting {
    func spawn(executable: String, arguments: [String], directory: URL,
                      environment: [String: String], input: Pipe, output: Pipe,
                      approvedExecutable: AgentACPExecutable? = nil) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw AgentACPClient.Failure.unavailable }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw AgentACPClient.Failure.unavailable }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, directory.path) == 0,
              posix_spawn_file_actions_adddup2(&actions, input.fileHandleForReading.fileDescriptor, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0 else {
            throw AgentACPClient.Failure.unavailable
        }
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        if let approvedExecutable {
            do { try approvedExecutable.verify() }
            catch { throw AgentACPClient.Failure.executableChanged }
        }
        let result = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&pid, executable, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        guard result == 0 else { throw AgentACPClient.Failure.unavailable }
        return pid
    }

    func finish(_ pid: pid_t, snapshot: ProcessTreeSnapshot? = nil,
                       grace: Duration = .milliseconds(200)) async {
        guard pid > 0 else { return }
        try? await Task.sleep(for: grace)
        kill(-pid, SIGTERM)
        if let snapshot { ProcessTreeReaper.signal(snapshot, signal: SIGTERM) }
        try? await Task.sleep(for: .milliseconds(500))
        kill(-pid, SIGSTOP)
        if let snapshot {
            ProcessTreeReaper.quiesceAndKill(ProcessTreeReaper.snapshot(rootPID: pid, retaining: snapshot))
        }
        kill(-pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    }
}
