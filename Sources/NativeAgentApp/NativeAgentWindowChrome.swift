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
        NSApplication.shared.terminate(nil)
    }
}

enum MainWindowRestartToolbarPresentation: Equatable {
    case ready
    case confirming
    case relaunching
    case failedToStart

    var showsConfirmation: Bool {
        self == .confirming
    }

    var isActionEnabled: Bool {
        self != .relaunching
    }

    var failureMessage: String? {
        guard self == .failedToStart else { return nil }
        return "Restart couldn't start. NativeAgent is still running — try again."
    }

    mutating func requestConfirmation() {
        guard isActionEnabled else { return }
        self = .confirming
    }

    mutating func cancelConfirmation() {
        guard self == .confirming else { return }
        self = .ready
    }

    mutating func beginRelaunch() {
        guard self == .confirming else { return }
        self = .relaunching
    }

    mutating func markStartFailure() {
        guard self == .relaunching else { return }
        self = .failedToStart
    }
}

struct MainWindowRestartToolbarButton: View {
    let presentation: MainWindowRestartToolbarPresentation
    let requestConfirmation: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Button(action: requestConfirmation) {
                Label(
                    presentation == .relaunching ? "Restarting NativeAgent…" : "Restart App",
                    systemImage: "arrow.triangle.2.circlepath"
                )
            }
            .accessibilityIdentifier("mainWindow.restartToolbarButton")
            .help("Relaunch NativeAgent")
            .disabled(!presentation.isActionEnabled)

            if let failureMessage = presentation.failureMessage {
                Text(failureMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("mainWindow.restartToolbarButton.failure")
            }
        }
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
    @State private var restartPresentation: MainWindowRestartToolbarPresentation = .ready
    @AppStorage(NativeAgentShellPreference.classicShellKey) private var classicShell = false

    var body: some View {
        ContentView()
            .background {
                if !classicShell { ShellWindowChrome() }
            }
            // Agent, 2026-09-02, glyph diet: in the new shell the window title
            // bar showed a bare circular-arrows glyph and the » that AppKit
            // adds when the item behind it will not fit — two marks, no words,
            // for an action nobody is looking for in a title bar. Restart App
            // is not lost: it is a worded item in the menu bar's NativeAgent
            // menu (NativeAgentApp.swift), which is reachable even when this
            // window is closed. The classic shell keeps the button here.
            .toolbar {
                if classicShell {
                    ToolbarItemGroup(placement: .primaryAction) {
                        MainWindowRestartToolbarButton(presentation: restartPresentation) {
                            restartPresentation.requestConfirmation()
                        }
                    }
                }
            }
            .alert("Restart NativeAgent?", isPresented: restartConfirmationBinding) {
                Button("Cancel", role: .cancel) {
                    restartPresentation.cancelConfirmation()
                }
                Button("Restart", role: .destructive) {
                    restartPresentation.beginRelaunch()
                    AppRelauncher.relaunchApp(onSpawnFailure: {
                        restartPresentation.markStartFailure()
                    })
                }
            } message: {
                Text("This relaunches the app.")
            }
    }

    private var restartConfirmationBinding: Binding<Bool> {
        Binding(
            get: { restartPresentation.showsConfirmation },
            // The alert's explicit Cancel action owns dismissal. Keeping this
            // setter inert prevents SwiftUI's automatic `false` write from
            // racing the destructive action and clearing `.confirming`
            // before it can transition to `.relaunching`.
            set: { _ in }
        )
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
