import SwiftUI
import AppKit

@main
struct FrameworkProbe: App {
    var body: some Scene {
        WindowGroup("Framework probe") { ProbeView().frame(minWidth: 800, minHeight: 600) }
    }
}

struct ProbeView: View {
    @State private var showTranscript = true
    @State private var selectable = true
    var body: some View {
        VStack {
            HStack {
                Button("Toggle transcript") { showTranscript.toggle() }
                Toggle("Selectable text", isOn: $selectable)
            }.padding()
            if showTranscript {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(0..<100) { index in
                            Text("Message \(index). " + String(repeating: "A quiet afternoon in the observatory. The telescope tracks a distant star while the notebook holds the evening plan. ", count: 8))
                                .frame(maxWidth: 680, alignment: .leading)
                        }
                    }.padding()
                }
                .modifier(SelectionMode(enabled: selectable))
            } else {
                Text("Transcript removed").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct SelectionMode: ViewModifier {
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.textSelection(.enabled) }
        else { content.textSelection(.disabled) }
    }
}
