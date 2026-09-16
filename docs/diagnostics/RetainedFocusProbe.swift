import SwiftUI
import AppKit

@main
struct RetainedFocusProbeApp: App {
    var body: some Scene {
        WindowGroup { ProbeRoot().frame(minWidth: 1040, minHeight: 712) }
    }
}

@MainActor @Observable
final class ProbeState {
    // Lifecycle callbacks are counted separately from the persistent state token.
    var transcriptMounts = 0
    var transcriptDisappears = 0
    var buttonActions = 0
    var nativeHostsCreated = 0
    var nativeHostsDismantled = 0
    var toggleStates = Array(repeating: false, count: 80)
}

struct ProbeRoot: View {
    @State private var state = ProbeState()
    @State private var showTranscript = false
    // Select mode before launch to avoid destroying one arm during measurement.
    private let separateHost = ProcessInfo.processInfo.arguments.contains("--separate-host")
    private let tabs = ProcessInfo.processInfo.arguments.contains("--tabs")

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text(tabs ? "Native SwiftUI TabView" : (separateHost ? "Separate NSHostingView" : "Same SwiftUI ZStack"))
                    .font(.headline)
                Toggle("Show transcript", isOn: $showTranscript)
                    .toggleStyle(.switch)
                Spacer()
                Text("Mounts \(state.transcriptMounts) · disappears \(state.transcriptDisappears) · actions \(state.buttonActions)")
                    .font(.caption.monospacedDigit())
            }.padding(16)
            Divider()
            if tabs {
                TabView(selection: $showTranscript) {
                    TrustControls(state: state)
                        .tabItem { Text("Trust") }.tag(false)
                    SyntheticTranscript(state: state, visible: showTranscript)
                        .tabItem { Text("Transcript") }.tag(true)
                }
            } else {
            ZStack {
                TrustControls(state: state)
                    .opacity(showTranscript ? 0 : 1)
                    .allowsHitTesting(!showTranscript)
                    .disabled(showTranscript)
                    .accessibilityHidden(showTranscript)
                    .accessibilityElement(children: showTranscript ? .ignore : .contain)

                if separateHost {
                    RetainedTranscriptHost(state: state, visible: showTranscript)
                        .allowsHitTesting(showTranscript)
                        .accessibilityHidden(!showTranscript)
                } else {
                    SyntheticTranscript(state: state, visible: showTranscript)
                        .opacity(showTranscript ? 1 : 0)
                        .allowsHitTesting(showTranscript)
                        .disabled(!showTranscript)
                        .accessibilityHidden(!showTranscript)
                        .accessibilityElement(children: showTranscript ? .contain : .ignore)
                }
            }
            }
        }
    }
}

struct TrustControls: View {
    let state: ProbeState
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Trust controls").font(.largeTitle)
                Text("Synthetic settings only. Scroll this pane with the transcript hidden.")
                ForEach(0..<80, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Capability \(index + 1)", systemImage: "shield")
                                .font(.headline)
                            Spacer()
                            Toggle("Allowed", isOn: Binding(
                                get: { state.toggleStates[index] },
                                set: { state.toggleStates[index] = $0 }
                            )).toggleStyle(.switch)
                        }
                        Text("Choose whether this synthetic capability may run. The setting stays in memory only.")
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Review details") { state.buttonActions += 1 }
                            Button("Reset") { state.toggleStates[index] = false }
                        }
                    }
                    .padding(16)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
                }
            }.padding(24).frame(maxWidth: 820)
        }
        .accessibilityIdentifier("probe.trust-scroll")
    }
}

struct SyntheticTranscript: View {
    let state: ProbeState
    var visible: Bool
    @State private var identity = UUID()
    @State private var draft = ""
    @FocusState private var draftFocused: Bool

    var body: some View {
        VStack {
            Text("State identity: \(identity.uuidString.prefix(8))")
                .font(.caption.monospaced())
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(0..<60, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Synthetic message \(index + 1)").font(.headline)
                            Text("A selectable response discussing a harmless example. It has enough words to wrap over several lines, with no real conversation or personal data. This row remains resident while another page is visible.")
                                .textSelection(.enabled)
                            Button("Copy example \(index + 1)") { state.buttonActions += 1 }
                        }
                        .padding(12)
                        .accessibilityElement(children: .contain)
                    }
                }.padding(20)
            }
            TextField("Synthetic draft", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .focused($draftFocused)
                .padding(16)
        }
        .onAppear { state.transcriptMounts += 1 }
        .onDisappear { state.transcriptDisappears += 1 }
        .onChange(of: visible) { _, isVisible in
            if !isVisible { draftFocused = false }
        }
        .accessibilityIdentifier("probe.transcript")
    }
}

struct RetainedTranscriptHost: NSViewRepresentable {
    let state: ProbeState
    let visible: Bool

    final class Container: NSView {
        let hosting: NSHostingView<SyntheticTranscript>
        init(state: ProbeState, visible: Bool) {
            hosting = NSHostingView(rootView: SyntheticTranscript(state: state, visible: visible))
            super.init(frame: .zero)
            hosting.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
                hosting.topAnchor.constraint(equalTo: topAnchor),
                hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            hosting.isHidden = !visible
        }
        required init?(coder: NSCoder) { fatalError("Not supported") }
    }

    func makeNSView(context: Context) -> Container {
        state.nativeHostsCreated += 1
        return Container(state: state, visible: visible)
    }
    func updateNSView(_ view: Container, context: Context) {
        // Same NSHostingView and same root type; assigning new value updates the
        // visibility input while keeping the hosted SwiftUI @State identity.
        view.hosting.rootView = SyntheticTranscript(state: state, visible: visible)
        view.hosting.isHidden = !visible
    }
    static func dismantleNSView(_ view: Container, coordinator: ()) {
        view.hosting.rootView.state.nativeHostsDismantled += 1
    }
}
