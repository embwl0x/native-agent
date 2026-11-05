import SwiftUI
// Blueprint: | `FaceView.swift` | The one renderer of a page's face on the Mac and the iPhone: header, sections by style, rows with time, symbol, tone, value, actions and controls |

/// Draws a page. The door passes where links lead (`open`) and the page owner's port (`act`); nothing here knows any page.
public struct FaceView: View {
    public let face: PartFace
    public let open: (String) -> Void
    public let act: (_ row: String, _ action: String, _ value: String?) -> Void

    public init(face: PartFace, open: @escaping (String) -> Void, act: @escaping (_ row: String, _ action: String, _ value: String?) -> Void) {
        self.face = face; self.open = open; self.act = act
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.section) {
            if face.title?.isEmpty == false || face.line?.isEmpty == false {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
                    if let title = face.title, !title.isEmpty { Text(title).font(.largeTitle.weight(.semibold)) }
                    if let line = face.line, !line.isEmpty { Text(line).font(.title3).foregroundStyle(.secondary) }
                }
            }
            // A section with nothing to show is not drawn: no rows and no footer leave a bare heading.
            ForEach(face.sections.filter { !$0.rows.isEmpty || $0.footer?.isEmpty == false }) { section in
                FaceSectionView(section: section, open: open, act: act)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FaceSectionView: View {
    let section: PartFace.Section
    let open: (String) -> Void
    let act: (String, String, String?) -> Void
    /// A pill that is a destructive action asks once, as every destructive face action does.
    @State private var confirming: PartFace.Row?

    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.eyebrowGap) {
            if let title = section.title, !title.isEmpty {
                Text(title.uppercased()).font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
            }
            content
            if let footer = section.footer, !footer.isEmpty { Text(footer).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var content: some View {
        switch section.style ?? .list {
        case .flow:
            FaceFlow(spacing: NativeAgentSpacing.sm) {
                // A pill leads where its row opens, or is the button of its row's one action.
                ForEach(section.rows) { row in
                    Button {
                        if let link = row.open { open(link) } else if let action = row.actions?.first {
                            if action.role == .destructive { confirming = row } else { act(row.id, action.id, nil) }
                        }
                    } label: {
                        Text(row.title).font(.callout).lineLimit(1).padding(.horizontal, NativeAgentSpacing.md).padding(.vertical, NativeAgentSpacing.xs + 2)
                            .background(Capsule().fill(.quaternary))
                    }
                    .buttonStyle(.plain).disabled(row.open == nil && row.actions?.count != 1)
                }
            }
            .confirmationDialog(confirming.flatMap { $0.actions?.first?.label }.map { $0 + " — " + (confirming?.title ?? "") } ?? "",
                                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
                if let row = confirming, let action = row.actions?.first {
                    Button(action.label, role: .destructive) { act(row.id, action.id, nil); confirming = nil }
                }
                Button("Cancel", role: .cancel) { confirming = nil }
            }
        case .timeline:
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                    HStack(alignment: .top, spacing: NativeAgentSpacing.md) {
                        VStack(spacing: 0) {
                            Circle().fill(FaceTone.color(row.tone)).frame(width: 7, height: 7).padding(.top, 6)
                            if index < section.rows.count - 1 { Rectangle().fill(.quaternary).frame(width: 1).frame(maxHeight: .infinity) }
                        }
                        .frame(width: 7)
                        FaceRowView(row: row, open: open, act: act).padding(.bottom, NativeAgentSpacing.md)
                    }
                }
            }
        case .note:
            VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
                ForEach(section.rows) { row in
                    Text([row.title, row.detail ?? ""].filter { !$0.isEmpty }.joined(separator: " — ")).font(.callout).foregroundStyle(.secondary)
                }
            }
        case .waiting:
            HStack(alignment: .top, spacing: NativeAgentSpacing.md) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
                    ForEach(section.rows) { row in Text(row.title).font(.body) }
                }
            }
            .padding(NativeAgentSpacing.lg).frame(maxWidth: .infinity, alignment: .leading).faceCard()
        case .list, .values:
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    FaceRowView(row: row, open: open, act: act, valueRow: section.style == .values)
                        .padding(.horizontal, NativeAgentSpacing.lg).padding(.vertical, NativeAgentSpacing.rowInsetV)
                }
            }
            .faceCard()
        }
    }
}

struct FaceRowView: View {
    let row: PartFace.Row
    let open: (String) -> Void
    let act: (String, String, String?) -> Void
    var valueRow = false
    /// A destructive action asks once before its owner is asked; so does a control that names its question.
    @State private var confirming: PartFace.Action?
    @State private var pendingSet: String?
    @State private var draft: String?

    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: NativeAgentSpacing.sm) {
                if let symbol = row.symbol, !symbol.isEmpty {
                    Image(systemName: symbol).foregroundStyle(FaceTone.color(row.tone)).frame(width: 18)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: NativeAgentSpacing.sm) {
                        if let at = row.at, let time = FaceTime.short(at) {
                            Text(time).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        }
                        Text(row.title).font(valueRow ? .body : .body.weight(.medium))
                            .foregroundStyle(row.tone == .quiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    }
                    if let detail = row.detail, !detail.isEmpty {
                        // A row that asks for an answer (attention, with its answers) shows all of what is being decided; other rows stay short.
                        Text(detail).font(.callout).foregroundStyle(.secondary)
                            .lineLimit(row.tone == .attention && row.actions?.isEmpty == false ? nil : 4)
                    }
                }
                Spacer(minLength: NativeAgentSpacing.sm)
                trailing
            }
            .modifier(FaceRowOpens(link: row.open, ownsTaps: row.actions?.isEmpty == false || row.control != nil, open: open))
            if let actions = row.actions, !actions.isEmpty {
                HStack(spacing: NativeAgentSpacing.sm) {
                    ForEach(actions) { action in
                        Button(action.label) {
                            if action.role == .destructive { confirming = action } else { act(row.id, action.id, nil) }
                        }
                        .buttonStyle(.bordered)
                        .tint(action.role == .destructive ? .red : action.role == .primary ? .accentColor : nil)
                    }
                }
                .confirmationDialog(confirming.map { $0.label + " — " + row.title } ?? "", isPresented: Binding(
                    get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
                    if let action = confirming {
                        Button(action.label, role: .destructive) { act(row.id, action.id, nil); confirming = nil }
                    }
                    Button("Cancel", role: .cancel) { confirming = nil }
                }
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        if let control = row.control {
            if let text = control.text {
                TextField(control.placeholder ?? "", text: Binding(get: { draft ?? text }, set: { draft = $0 }))
                    .textFieldStyle(.roundedBorder).frame(minWidth: 160, maxWidth: 280)
                    .onSubmit { act(row.id, "set", draft ?? text); draft = nil }
            } else if let on = control.on {
                Toggle("", isOn: Binding(get: { on }, set: { set($0 ? "on" : "off", control) })).labelsHidden().toggleStyle(.switch).tint(.accentColor)
                    .modifier(FaceSetConfirmation(question: control.confirm, pending: $pendingSet) { act(row.id, "set", $0) })
            } else if let options = control.options {
                Picker("", selection: Binding(get: { control.selected ?? "" }, set: { set($0, control) })) {
                    ForEach(options) { Text($0.label).tag($0.id) }
                }
                .labelsHidden().fixedSize()
                .modifier(FaceSetConfirmation(question: control.confirm, pending: $pendingSet) { act(row.id, "set", $0) })
            }
        } else if let value = row.value, !value.isEmpty {
            Text(value).font(.callout.monospacedDigit()).foregroundStyle(row.tone.map(FaceTone.color) ?? .secondary)
        } else if row.open != nil {
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
    }
}

/// A row with a link opens it when tapped anywhere; a row without one takes no tap, so its switch or choice keeps every touch. A linked
/// row that holds its own buttons or control opens on a tap beside them, never as one button that would swallow theirs.
struct FaceRowOpens: ViewModifier {
    let link: String?
    let ownsTaps: Bool
    let open: (String) -> Void

    func body(content: Content) -> some View {
        if let link, ownsTaps {
            content.contentShape(Rectangle()).onTapGesture { open(link) }
        } else if let link {
            // One button for the whole row: a tap anywhere opens it, and VoiceOver reads it as one.
            Button { open(link) } label: { content.contentShape(Rectangle()) }.buttonStyle(.plain)
        } else {
            content
        }
    }
}

extension FaceRowView {
    func set(_ value: String, _ control: PartFace.Control) {
        if control.confirm?.isEmpty == false { pendingSet = value } else { act(row.id, "set", value) }
    }
}

/// A control's change waits for the person's yes when the control names a question.
struct FaceSetConfirmation: ViewModifier {
    let question: String?
    @Binding var pending: String?
    let send: (String) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(question ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                                   titleVisibility: .visible) {
            Button("Change") { if let value = pending { send(value) }; pending = nil }
            Button("Cancel", role: .cancel) { pending = nil }
        }
    }
}

enum FaceTone {
    static func color(_ tone: PartFace.Tone?) -> Color {
        switch tone ?? .plain {
        case .plain, .quiet: .secondary
        case .attention: .orange
        case .failed: .red
        case .done: .green
        case .live: .accentColor
        }
    }
}

enum FaceTime {
    /// A time today reads as its clock time; an older one as its day.
    static func short(_ iso: String) -> String? {
        guard let date = UserDisplayFormatters.parseISOTimestamp(iso) else { return nil }
        return Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day())
    }
}

extension View {
    func faceCard() -> some View {
        background(RoundedRectangle(cornerRadius: NativeAgentRadius.card, style: .continuous).fill(.background.secondary))
            .overlay(RoundedRectangle(cornerRadius: NativeAgentRadius.card, style: .continuous).strokeBorder(.quaternary))
    }
}

/// Pills that wrap to the next line when the row is full.
struct FaceFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = Self.size(of: view, within: width)
            if x > 0, x + size.width > width { y += line + spacing; x = 0; line = 0 }
            x += size.width + spacing; line = max(line, size.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = Self.size(of: view, within: bounds.width)
            if x > bounds.minX, x + size.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; line = max(line, size.height)
        }
    }

    /// A row never runs past the line: one wider than the line is given the line's width, where its words end in an ellipsis.
    private static func size(of view: LayoutSubview, within width: CGFloat) -> CGSize {
        let ideal = view.sizeThatFits(.unspecified)
        return ideal.width <= width ? ideal : view.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }
}
