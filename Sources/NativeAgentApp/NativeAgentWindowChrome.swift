import Foundation
import SwiftUI

// PATCH-2026-05-29: restart-controls — app/runtime relaunch helper.
// Reliable macOS relaunch: spawn a DETACHED shell that polls until THIS process
// has fully exited, then `open`s the bundle for a fresh launch, then terminate.
// The relaunched instance's applicationDidFinishLaunching rebuilds the
// in-process Swift runtime. Net effect: "Restart App" = app process and
// runtime state restart together.
//
// NOTE: plain `open <App.app>` on a STILL-RUNNING app just activates it and
// returns — it does NOT wait-for-quit-then-relaunch — and `-n` would spawn a
// duplicate app instance. Hence the wait-for-PID helper. The sh child is
// reparented to launchd when we terminate,
// so it survives our exit to perform the relaunch.
//
// MainActor-isolated: touches NSApplication. Process.run() returns immediately
// (the sh detaches), so the brief launch on the main actor is fine right before
// we terminate.
enum AppRelauncher {
    /// Pure helper contract for the detached shell process. Keeping it outside
    /// `relaunchApp` lets the app and its behavioral evals exercise the same
    /// bounded, positional-argument script without scraping Swift source.
    static func relaunchHelperScript() -> String {
        let script = "i=0; while /bin/kill -0 \"$1\" >/dev/null 2>&1 && [ \"$i\" -lt 150 ]; do /bin/sleep 0.2; i=$((i+1)); done; /usr/bin/open \"$2\""
        return script
    }

    static func relaunchHelperArguments(pid: Int32, bundlePath: String) -> [String] {
        ["-c", relaunchHelperScript(), "relaunch", String(pid), bundlePath]
    }

    @MainActor
    static func relaunchApp(
        helperExecutableURL: URL = URL(fileURLWithPath: "/bin/sh"),
        onSpawnFailure: () -> Void = {}
    ) {
        let bundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        // Pass pid ($1) + bundlePath ($2) as POSITIONAL args, not interpolated into
        // the script body — no shell quoting/injection risk if the bundle path ever
        // contains metacharacters. Bound the wait to ~30s (150 × 0.2s) so the helper
        // can't spin forever if termination is somehow cancelled, then open anyway.
        let task = Process()
        task.executableURL = helperExecutableURL
        task.arguments = relaunchHelperArguments(pid: pid, bundlePath: bundlePath)
        do {
            try task.run()
        } catch {
            NSLog("[relaunch] failed to spawn relaunch helper for %@: %@", bundlePath, "\(error)")
            onSpawnFailure()
            return
        }
        // The helper is now waiting on our PID; quitting triggers the relaunch.
        // From the run loop, not this call's stack: callers include MainActor
        // tasks, and a quit held for in-flight turns must not sit inside a
        // main-queue block (the main queue could not drain until it ended).
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { NSApplication.shared.terminate(nil) } }
    }
}

// Wraps ContentView so the main window draws the shell's chrome behind it.
// Restart App is a worded item in the menu bar's NativeAgent menu
// (NativeAgentApp.swift), reachable even when this window is closed.
struct MainWindowContent: View {
    var body: some View {
        ContentView()
            .background { ShellWindowChrome() }
    }
}

// PATCH-2026-05-07: app-owned runtime helper button that opens the main
// window via @Environment(\.openWindow). Lives outside the MenuBarExtra
// closure because MenuBarExtra is a Scene, not a View — environment
// values for openWindow only resolve inside an actual view hierarchy.
struct MenuBarOpenButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open NativeAgent", systemImage: "macwindow") {
            NSApp.activate(ignoringOtherApps: true)
            // The main scene is a single-instance Window (not WindowGroup),
            // so openWindow(id:) reuses the existing one if visible or
            // recreates it if closed — never stacks copies.
            openWindow(id: "main")
        }
    }
}
