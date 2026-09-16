import SwiftUI
import AppKit

@main struct WorkaroundProbe: App {
    var body: some Scene { WindowGroup("Workaround probe") { Probe().frame(width: 850, height: 650) } }
}

struct Probe: View {
    @State private var visible = false
    @State private var nativeText = true
    @State private var retainViews = false
    var body: some View {
        VStack {
            HStack {
                Button("Toggle transcript") { visible.toggle() }
                Toggle("Native text view", isOn: $nativeText)
                Toggle("Retain views", isOn: $retainViews)
            }.padding()
            if retainViews {
                transcript.opacity(visible ? 1 : 0)
                    .allowsHitTesting(visible).disabled(!visible)
                    .accessibilityHidden(!visible)
                    .accessibilityElement(children: visible ? .contain : .ignore)
            } else if visible { transcript }
            else { Text("Transcript removed").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
    }
    var transcript: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(0..<100) { i in
                    let text = "Message \(i). Select this text. A quiet afternoon in the observatory."
                    if nativeText { NativeText(text: text).frame(height: 40) }
                    else { Text(text).textSelection(.enabled) }
                }
            }.padding()
        }
    }
}

struct NativeText: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.font = .systemFont(ofSize: 14)
        view.textColor = .labelColor
        return view
    }
    func updateNSView(_ view: NSTextView, context: Context) {
        if view.string != text { view.string = text }
    }
}
