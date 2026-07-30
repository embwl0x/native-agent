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
    @MainActor
    static func relaunchApp() {
        let bundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        // Pass pid ($1) + bundlePath ($2) as POSITIONAL args, not interpolated into
        // the script body — no shell quoting/injection risk if the bundle path ever
        // contains metacharacters. Bound the wait to ~30s (150 × 0.2s) so the helper
        // can't spin forever if termination is somehow cancelled, then open anyway.
        let script = "i=0; while /bin/kill -0 \"$1\" >/dev/null 2>&1 && [ \"$i\" -lt 150 ]; do /bin/sleep 0.2; i=$((i+1)); done; /usr/bin/open \"$2\""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script, "relaunch", String(pid), bundlePath]
        do {
            try task.run()
        } catch {
            NSLog("[relaunch] failed to spawn relaunch helper for %@: %@", bundlePath, "\(error)")
            return
        }
        // The helper is now waiting on our PID; quitting triggers the relaunch.
        NSApplication.shared.terminate(nil)
    }
}

// PATCH-2026-05-29: restart-controls — wraps ContentView so the main Window
// gets an ever-present top toolbar (health dot + Restart App).
// The toolbar state (runtime health poll, restart-app confirmation) lives here because
// the controller is intentionally NOT ObservableObject — we poll isRunning on a
// timer instead. ContentView itself lives in another file and is left untouched.
struct MainWindowContent: View {
    // The Mac app process is the runtime now; the only restart control is
    // "Restart App".
    @State private var showRestartAppConfirm = false

    var body: some View {
        ContentView()
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showRestartAppConfirm = true
                    } label: {
                        Label("Restart App", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .help("Relaunch NativeAgent")
                }
            }
            .alert("Restart NativeAgent?", isPresented: $showRestartAppConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Restart", role: .destructive) {
                    AppRelauncher.relaunchApp()
                }
            } message: {
                Text("This relaunches the app.")
            }
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
