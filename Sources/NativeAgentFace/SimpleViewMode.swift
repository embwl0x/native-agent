import SwiftUI
import NativeAgentShared

// Blueprint: | `SimpleViewMode.swift` | `ViewModeSwitch`: Simple/Advanced/Agent selection and shared top chrome placement |


struct ViewModeSwitch: View {
    @FacePreference(SimpleViewMode.key) private var raw = ""

    var body: some View {
        FacePreferences(keys: [SimpleViewMode.key]) { preferenceContent }
    }

    private var preferenceContent: some View {
        Picker("View", selection: Binding(
            get: { SimpleViewMode.faceSelection(raw) },
            set: { raw = $0 }
        )) {
            ForEach(SimpleViewMode.choices, id: \.self) { mode in
                Text(mode.capitalized).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }
}

extension View {
    func viewModeSwitch() -> some View {
        overlay {
            VStack {
                HStack { Spacer(); ViewModeSwitch() }
                Spacer()
            }
            .padding(.top, 3)
            .padding(.trailing, 10)
            .ignoresSafeArea(edges: .top)
        }
    }
}

extension SimpleViewMode {
    static func faceSelection(_ raw: String) -> String { choices.contains(raw) ? raw : "unavailable" }
}

private let simpleTopFade: CGFloat = 24

extension View {
    /// Use static inset geometry because safeAreaBar can block the main thread.
    /// Alpha-mask scrolled words because a plain inset has no system scroll-edge effect.
    /// Keep the header outside the mask for hit-testing; extend through the bottom inset for the composer.
    func roomTopChrome<Chrome: View>(@ViewBuilder _ chrome: () -> Chrome) -> some View {
        mask(alignment: .top) {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: simpleTopFade)
                Color.black
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .safeAreaInset(edge: .top, spacing: 0, content: chrome)
    }
}

extension EnvironmentValues {
    /// Share the layout profile so Simple chat omits Advanced-only columns and the Work pane.
    @Entry var layoutProfile = SimpleViewMode.advanced
}
