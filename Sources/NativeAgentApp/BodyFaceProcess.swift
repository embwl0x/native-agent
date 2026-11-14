import AppKit
import Foundation
import NativeAgentShared
import NativeAgentCore
import MacControl
// Blueprint: | `BodyFaceProcess.swift` | Body-owned child process, inherited pipes and explicit window reopening; process exit owns retirement |

actor BodyFaceProcess {
    private let executable: URL
    private let source: FaceFeedSource
    private let handler: any FaceActHandler
    private let dataRoot: URL
    private let connected: @Sendable (UUID) async throws -> Void
    private let disconnected: @Sendable (UUID?, String) async -> Void
    private var child: Process?
    private var childID: UUID?
    private var endpoint: BodyFaceConnection?
    private var launch: Task<BodyFaceConnection, Error>?
    private var reader: Task<Void, Never>?
    private var retirement: Task<Void, Never>?
    private var closing = false
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []

    init(bodyBundle: URL, dataRoot: URL, source: FaceFeedSource, handler: any FaceActHandler,
         connected: @escaping @Sendable (UUID) async throws -> Void,
         disconnected: @escaping @Sendable (UUID?, String) async -> Void) {
        executable = bodyBundle.appendingPathComponent("Contents/Helpers/NativeAgentFace.app/Contents/MacOS/NativeAgentFace")
        self.source = source; self.handler = handler
        self.dataRoot = dataRoot
        self.connected = connected; self.disconnected = disconnected
    }

    /// Opens the window, spawning its process after the previous one exits; her body calls it on open requests and after a lost window.
    func showWindow(destination: FaceDestination? = nil) async throws -> FaceReply {
        let endpoint = try await connection()
        if let pid = child?.processIdentifier { await Self.handActivation(to: pid) }
        return try await endpoint.call(.showMainWindow(destination: destination))
    }

    /// macOS only lets the window's process come forward if it is handed the front. A person's launch gives it to this process; an app that kept it keeps it.
    @MainActor private static func handActivation(to pid: pid_t) {
        guard let window = NSRunningApplication(processIdentifier: pid) else { return }
        NSApp.activate()
        NSApp.yieldActivation(to: window)
    }

    /// Background presentation work cannot reopen a window the person closed.
    func call(_ call: FaceCall, connection: UUID? = nil) async throws -> FaceReply {
        guard let endpoint else { throw FaceWireError.disconnected }
        return try await endpoint.call(call, connection: connection)
    }

    func renderPage(page: String, tab: String?, width: Double, height: Double, reader: UUID) async throws -> FaceReply {
        guard let endpoint else { throw FaceWireError.disconnected }
        return try await endpoint.renderPage(page: page, tab: tab, width: width, height: height, reader: reader)
    }

    private func connection() async throws -> BodyFaceConnection {
        guard !closing else { throw FaceWireError.disconnected }
        if let launch { return try await launch.value }
        if let child, endpoint == nil || !child.isRunning { await withCheckedContinuation { exitWaiters.append($0) } }
        await retirement?.value
        try Task.checkCancellation()
        guard !closing else { throw FaceWireError.disconnected }
        if let launch { return try await launch.value }
        if let endpoint { return endpoint }
        guard child == nil else {
            throw WireFailure(code: "face_process_exiting", message: "The NativeAgent window is closing.",
                              cause: "Wait for its process to exit before opening another window.", effects: .none)
        }
        let task = Task { try await spawn() }
        launch = task
        do {
            let endpoint = try await task.value
            launch = nil
            return endpoint
        } catch { launch = nil; throw error }
    }

    private func spawn() async throws -> BodyFaceConnection {
        try Task.checkCancellation()
        guard !closing else { throw FaceWireError.disconnected }
        let log = try await FaceLinkLog.open(dataRoot: dataRoot, role: .body)
        try Task.checkCancellation()
        guard !closing else { throw FaceWireError.disconnected }
        let process = Process()
        let toFace = Pipe(), fromFace = Pipe()
        var handles = [toFace.fileHandleForReading, toFace.fileHandleForWriting,
                       fromFace.fileHandleForReading, fromFace.fileHandleForWriting]
        process.executableURL = executable
        var environment = ProcessInfo.processInfo.environment
        environment["NATIVEAGENT_FACE_DATA_ROOT"] = dataRoot.path
        process.environment = environment
        process.standardInput = toFace
        process.standardOutput = fromFace
        process.standardError = FileHandle.standardError
        let id = UUID()
        process.terminationHandler = { process in
            let status = process.terminationStatus
            Task { await self.exited(id, status: status) }
        }
        do {
            try process.run()
            child = process
            childID = id
            try PersonOnlyWindows.faceStarted(processID: process.processIdentifier)
            let childHandles = [toFace.fileHandleForReading, fromFace.fileHandleForWriting]
            handles.removeAll { handle in childHandles.contains { $0 === handle } }
            try Self.closeHandles(childHandles)
            let link = try await FaceLink.Connection.open(input: fromFace.fileHandleForReading, output: toFace.fileHandleForWriting)
            let parentHandles = handles
            handles.removeAll()
            do { try Self.closeHandles(parentHandles) }
            catch { await link.close(); throw error }
            guard !closing, childID == id else { await link.close(); throw FaceWireError.disconnected }
            let processID = process.processIdentifier
            let didConnect = connected
            let endpoint = BodyFaceConnection(link: link, source: source, handler: handler, log: log,
                connected: { connection in
                    try await MacInputRouting.faceConnected(connection, processID: processID)
                    try await didConnect(connection)
                }, ending: { connection in
                    // Every renderer ends through its link's close (exit, quit, a lost pipe); Doctor forgets it before anything awaits.
                    BodyFaceDoctor.disconnect(connection)
                }, disconnected: { connection, detail in
                    if let connection { await MacInputRouting.faceDisconnected(connection) }
                    await self.disconnected(connection, detail)
                    await self.connectionClosed(id)
                })
            self.endpoint = endpoint
            reader = Task { await endpoint.run() }
            return endpoint
        } catch {
            // Closing the parent's ends delivers EOF to the child; exit is its lifecycle event.
            do { try Self.closeHandles(handles) }
            catch let cleanup {
                throw WireFailure(code: "face_launch_cleanup_failed", message: "The NativeAgent window did not launch cleanly.",
                    cause: "\(error.localizedDescription)\nPipe cleanup: \(cleanup.localizedDescription)", effects: .unknown)
            }
            throw error
        }
    }

    private static func closeHandles(_ handles: [FileHandle]) throws {
        var failures: [String] = []
        for handle in handles {
            do { try handle.close() }
            catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty {
            throw WireFailure(code: "face_pipe_close_failed", message: "A NativeAgent window pipe did not close.",
                              cause: failures.joined(separator: "\n"), effects: .unknown)
        }
    }

    private func connectionClosed(_ id: UUID) {
        guard childID == id else { return }
        endpoint = nil
    }

    private func exited(_ id: UUID, status: Int32) async {
        guard childID == id else { return }
        if let child { PersonOnlyWindows.faceExited(processID: child.processIdentifier) }
        let endpoint = endpoint, reader = reader
        child = nil; childID = nil; self.endpoint = nil
        reader?.cancel(); self.reader = nil
        retirement = Task {
            await endpoint?.close(WireFailure(code: "face_process_exited", message: "The NativeAgent window process exited.",
                                             cause: "Exit status \(status)", effects: .unknown))
            await endpoint?.joinClose()
            await reader?.value
        }
        let waiters = exitWaiters
        exitWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await retirement?.value
    }

    func close() async {
        closing = true
        let launch = launch, reader = reader, endpoint = endpoint
        launch?.cancel()
        // Quit owns the child even when its drawing thread cannot consume pipe EOF.
        if let child, child.isRunning { child.terminate() }
        await endpoint?.close()
        await endpoint?.joinClose()
        _ = await launch?.result
        if child != nil { await withCheckedContinuation { exitWaiters.append($0) } }
        await retirement?.value
        await reader?.value
    }
}
