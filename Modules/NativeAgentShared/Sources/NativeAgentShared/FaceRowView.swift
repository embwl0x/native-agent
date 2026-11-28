import SwiftUI
import Foundation
#if os(macOS)
import AppKit
import Combine
import CoreGraphics
#elseif os(iOS)
import UIKit
#endif
// Blueprint: | `FaceRowView.swift` | Quiet native rows, inline control groups, drawn-call submission and row-local pending, failure and undo |

struct FaceRowView: View {
    let row: PartFace.Row
    let item: FaceItemID
    let door: any FaceDoor
    let session: FacePageSession
    let focus: FocusState<FaceFocus?>.Binding
    let move: (FaceItemID, Int) -> Void
    let sectionStyle: PartFace.Style
    let waiting: Bool
    let connectsTimeline: Bool
    /// The section's inline-group columns (one child per word), so every row's group lines up under every other.
    var columns: [PartFace.Row] = []
    /// Set when this row is one control of its parent's inline group: the parent's title, drawn as the word and its control alone.
    var cellOf: String? = nil
    var leading: CGFloat = 0
    @Environment(\.faceContainerWidth) private var containerWidth
    #if os(macOS)
    @Environment(FaceConfirmations.self) private var confirmations
    @Environment(\.faceInlineTextSelection) private var inlineTextSelection
    private var selectsInlineText: Bool {
        inlineTextSelection && sectionStyle == .note && actions.isEmpty && row.open == nil && !discloses
            && row.control == nil && row.group.isEmpty && row.meter == nil
    }
    private var pendingConfirmation: FaceConfirmations.Request? {
        get { confirmations.pending }
        nonmutating set { confirmations.pending = newValue }
    }
    #else
    @State private var pendingConfirmation: FaceConfirmations.Request?
    #endif
    @Environment(\.faceStyle) private var style
    @Environment(\.faceListWidth) private var listWidth
    @Environment(\.faceListCompact) private var listCompact
    private var inList: Bool { listWidth != nil }
    @State private var confirmationSource = UUID()
    @State private var hovering = false
    @State private var trailingWidth: CGFloat = 0
    private var measuresControl: Bool { row.control != nil || row.group.contains { $0.control != nil } }
    private var width: CGFloat { max(0, (listWidth?.width ?? containerWidth) - leading) }

    private var actions: [PartFace.Action] { row.actions ?? [] }
    private var operation: FacePageSession.Operation? { session.operation(for: item.row) }
    private var pendingOperation: FacePageSession.Operation? { operation?.outcome == nil || operation?.checking == true ? operation : nil }
    private var sent: String? { operation?.outcome == nil ? operation?.submission.value : nil }
    private var compact: Bool {
        let insets = style.insets.leading + style.insets.trailing
        if inList, leading == 0, let listCompact, listCompact.insets == insets { return listCompact.value }
        let given = inList ? width + insets : width
        return given > 0 && given < 420
    }
    private var focused: Bool { focus.wrappedValue?.item == item }
    private var handlesRowKeys: Bool { focused && focus.wrappedValue != .control(item) }
    private var discloses: Bool { cellOf == nil && (row.holdsBeneath || row.expands == true) }
    private var disclosed: Bool { discloses && session[open: .row(item)] }
    private var rowInsets: EdgeInsets {
        if inList { return EdgeInsets() }
        if sectionStyle == .note || sectionStyle == .timeline || sectionStyle == .flow {
            return EdgeInsets(top: style.insets.top, leading: 0, bottom: style.insets.bottom, trailing: 0)
        }
        return style.insets
    }
    private var hasTrailingContent: Bool {
        row.control != nil || row.meter != nil || row.value?.isEmpty == false || row.at != nil || !row.group.isEmpty
    }
    private var clampsValueLabel: Bool { sectionStyle == .values && hasTrailingContent }
    private var primary: PartFace.Action? {
        let primaries = actions.filter { $0.role == .primary }
        return primaries.count == 1 ? primaries.first : actions.count == 1 ? actions.first : nil
    }
    /// A page's commands, a row that is only its one action, and what asks for the person stay drawn; the rest come on hover or focus. A row
    /// that already says its state (a value such as "Granted") is not only its action, so it stays one line.
    private var keepsActions: Bool {
        sectionStyle == .flow || row.tone == .attention || actions.contains { $0.role == .primary }
            || (row.open == nil && row.control == nil && actions.count == 1 && (row.value ?? "").isEmpty)
    }
    /// A row with an inline group or disclosure draws as a line, including in a flow.
    private var pill: Bool {
        sectionStyle == .flow && !inList && !discloses && row.control == nil && row.group.isEmpty && (row.open != nil || actions.count <= 1)
    }
    private var text: String {
        [row.title, row.detail, row.value, controlWords, groupWords, row.at].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
    }
    /// A control's name where it is read aloud: an inline group's child is "<parent>, <word>"; its visible word stays short.
    private var label: String { cellOf.map { $0 + ", " + row.title } ?? row.title }
    private var groupWords: String? {
        guard !row.group.isEmpty else { return nil }
        return row.group.map { child in
            let operation = session.operation(for: child.id)
            let sent = operation?.outcome == nil ? operation?.submission.value : nil
            guard let on = child.control?.on else { return child.title }
            return child.title + ((sent.map { $0 == "on" } ?? on) ? " on" : " off")
        }.joined(separator: ", ")
    }
    private func childItem(_ child: PartFace.Row) -> FaceItemID { FaceItemID(section: item.section, row: child.id) }
    private var controlWords: String? {
        guard let control = row.control else { return nil }
        if let text = control.text { return session.drafts.value(key, seed: text) }
        if let number = control.number { return numberValue(number).map(PartFace.amount) }
        if let date = control.date { return sent ?? date }
        if let on = control.on { return (sent.map { $0 == "on" } ?? on) ? "on" : "off" }
        let selected = sent ?? control.selected
        return control.options?.first { $0.id == selected }?.label
    }
    private func numberValue(_ number: PartFace.Control.Number) -> Double? {
        guard let operation, operation.outcome == nil, operation.submission.action == "set" else { return number.value }
        guard case .double(let value)? = operation.submission.expectedCall.args["value"] else { return nil }
        return value
    }
    private var key: String { session.draftKey(item) }

    var body: some View {
        Group {
            if cellOf != nil { cell }
            else { line }
        }
        #if !os(macOS)
        .modifier(FaceConfirmationDialog(pending: $pendingConfirmation))
        #endif
        .onDisappear { dismissConfirmation(.row(confirmationSource)) }
        .layoutValue(key: FaceFlowLine.self, value: cellOf == nil && sectionStyle == .flow && !inList && !pill)
    }

    private var line: some View {
        Group {
            #if os(macOS)
            if selectsInlineText { lineContent }
            else { lineContent.contextMenu { menu } }
            #else
            lineContent.contextMenu { menu }
            #endif
        }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(text))
            .accessibilityActions { accessibleActions }
            #if os(macOS)
            .focusable().focused(focus, equals: .row(item))
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                guard handlesRowKeys else { return .ignored }
                move(item, press.key == .downArrow ? 1 : -1)
                return .handled
            }
            .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                guard handlesRowKeys, discloses else { return .ignored }
                let expand = press.key == .rightArrow
                guard disclosed != expand else { return .ignored }
                withAnimation(.snappy) {
                    session[open: .row(item)] = expand
                }
                return .handled
            }
            .onKeyPress(.return) {
                if case .action(let focusedItem, let id)? = focus.wrappedValue, focusedItem == item,
                   let action = actions.first(where: { $0.id == id }) {
                    perform(action); return .handled
                }
                guard focus.wrappedValue == .row(item) else { return .ignored }
                return activate() ? .handled : .ignored
            }
            .onKeyPress(.space) {
                guard focus.wrappedValue == .row(item), let control = row.control, let on = control.on else { return .ignored }
                set((sent.map { $0 == "on" } ?? on) ? "off" : "on", control)
                return .handled
            }
            .onKeyPress(characters: CharacterSet(charactersIn: "c")) { press in
                guard press.modifiers == .command, handlesRowKeys else { return .ignored }
                copy(); return .handled
            }
            #else
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                ForEach(actions) { action in
                    Button(action.label) { perform(action) }
                        .foregroundStyle(.primary)
                        .buttonStyle(.automatic)
                        .disabled(session.held(item) || action.unavailable != nil)
                }
            }
            #endif
    }

    private var lineContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            surface
            outcomeView
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var surface: some View {
        if pill {
            HStack(spacing: 8) {
                // A command that can't run now still reads as one of the page's commands, greyed.
                Button { _ = activate() } label: {
                    Text(row.title).font(.callout).lineLimit(1)
                        .foregroundStyle(row.tone == .failed ? FaceTone.color(.failed) : .primary)
                        .opacity(pendingOperation == nil ? 1 : 0)
                        .overlay { if pendingOperation != nil { ProgressView().controlSize(.mini) } }
                        .padding(.horizontal, 12).padding(.vertical, 6).background(Capsule().fill(.quaternary))
                }
                .buttonStyle(.plain)
                .disabled(row.open == nil && (primary == nil || primary?.unavailable != nil || session.held(item)))
                .accessibilityHint(Text(row.detail ?? ""))
                #if os(macOS)
                .help(row.detail ?? "")
                #endif
                if let pendingOperation { cancelButton(pendingOperation).font(style.detail) }
            }
        } else {
            rowBody
                .frame(maxWidth: .infinity, minHeight: max(0, style.minimumHeight - style.insets.top - style.insets.bottom), alignment: .leading)
                .padding(rowInsets)
                .background(hovering || focused ? style.elevation : .clear)
                .overlay(alignment: compact && measuresControl ? .topTrailing : .trailing) {
                    #if os(macOS)
                    if row.group.isEmpty {
                        let inset = !compact && measuresControl && pendingOperation == nil ? trailingWidth + 12 : 0
                        floatingActions
                            .padding(.leading, rowInsets.leading)
                            .padding(.trailing, rowInsets.trailing + inset)
                            .padding(.top, compact && measuresControl && pendingOperation == nil ? rowInsets.top : 0)
                    }
                    #endif
                }
        }
    }

    #if os(macOS)
    @ViewBuilder private var floatingActions: some View {
        if let pendingOperation {
            // A pending act moves nothing on the page, however quick it turns out to be.
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                cancelButton(pendingOperation)
            }
            .font(style.detail).padding(4).background(style.actionSurface, in: RoundedRectangle(cornerRadius: 6))
        } else if !keepsActions, !actions.isEmpty, hovering || focused,
                  !row.group.isEmpty || !measuresControl || trailingWidth > 0 {
            actionStrip.padding(4).background(style.actionSurface, in: RoundedRectangle(cornerRadius: 6))
        }
    }
    #endif

    private func cancelButton(_ operation: FacePageSession.Operation) -> some View {
        Button(door.cancellationLabel) { session.cancel(item) }.disabled(operation.cancelling).buttonStyle(.plain)
    }

    @ViewBuilder private var rowBody: some View {
        #if os(macOS)
        if selectsInlineText {
            SelectableFaceRowText(row: row, copyText: text, session: session)
        } else { rowFields }
        #else
        rowFields
        #endif
    }

    private var rowFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !row.group.isEmpty {
                // The group is placed by what fits, not by a width threshold: beside the title when both fit, beneath it otherwise.
                FaceBesideOrBeneath(spacing: 12, lineSpacing: 4) {
                    titleAndDetail
                        #if os(macOS)
                        .frame(minHeight: (!keepsActions && !actions.isEmpty) || pendingOperation != nil ? 32 : 0, alignment: .leading)
                        .overlay(alignment: .trailing) { floatingActions }
                        #endif
                    trailing
                }
            } else if compact {
                titleAndDetail
                trailing.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: stacksDetail ? .top : .center, spacing: 12) {
                    titleAndDetail
                        .frame(width: clampsValueLabel ? max(0, width * 0.45) : nil, alignment: .leading)
                        .frame(maxWidth: clampsValueLabel ? nil : .infinity, alignment: .leading)
                    trailing
                        .frame(maxWidth: row.control?.text != nil || clampsValueLabel ? .infinity : nil, alignment: .trailing)
                }
            }
            if keepsActions { actionStrip.padding(.leading, titleLeading) }
        }
        .background(alignment: .topLeading) {
            if connectsTimeline && !inList {
                GeometryReader { geometry in
                    Rectangle().fill(.quaternary)
                        .frame(width: 1, height: max(0, geometry.size.height + rowInsets.top + rowInsets.bottom - 7))
                        .offset(x: 3 - leading, y: 13)
                }
            }
        }
    }

    private var chevronSize: CGFloat {
        #if os(iOS)
        28
        #else
        24
        #endif
    }

    private var titleLeading: CGFloat {
        #if os(iOS)
        let spinner: CGFloat = 28
        #else
        let spinner: CGFloat = 24
        #endif
        return (discloses ? chevronSize + 8 : 0) + (waiting ? spinner : 0) + (sectionStyle == .timeline ? 15 : 0)
            + (row.symbol?.isEmpty == false ? 26 : 0)
    }

    private var titleAndDetail: some View {
        HStack(alignment: .top, spacing: 8) {
            if sectionStyle == .timeline {
                Circle().fill(FaceTone.color(row.tone)).frame(width: 7, height: 7).padding(.top, 6).offset(x: -leading)
                    .accessibilityHidden(true)
            }
            if discloses {
                Button {
                    withAnimation(.snappy) {
                        session[open: .row(item)].toggle()
                    }
                } label: {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(disclosed ? 90 : 0))
                        .frame(width: chevronSize, height: chevronSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text((disclosed ? "Collapse " : "Expand ") + row.title))
                .accessibilityValue(disclosed ? "Expanded" : "Collapsed")
            }
            if waiting { ProgressView().controlSize(.small) }
            if let symbol = row.symbol, !symbol.isEmpty {
                Image(systemName: symbol).foregroundStyle(FaceTone.color(row.tone)).frame(width: 18)
                    .accessibilityHidden(true)
            }
            Group {
                if stacksDetail {
                    VStack(alignment: .leading, spacing: 2) { titleWords; detailWords }
                } else {
                    besideTitle
                    #if os(macOS)
                    .help(row.detail ?? "")
                    #endif
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            focus.wrappedValue = .row(item)
            if let link = row.open { door.open(link) }
        }
    }

    /// What asks for the person reads whole, wherever it is drawn: its full title, every line of its detail (what a secret is for, what it
    /// grants, for how long, what Not now costs) and every answer it offers.
    private var whole: Bool { row.tone == .attention }

    private var titleWords: some View {
        FaceWordTitle(title: row.title, whole: whole).font(style.title)
            .foregroundStyle(row.tone == .failed ? AnyShapeStyle(FaceTone.color(.failed))
                : row.tone == .quiet || sectionStyle == .note ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
    }

    @ViewBuilder private var detailWords: some View {
        if let detail = row.detail, !detail.isEmpty {
            if whole {
                Text(detail).font(style.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                let singleLine = detail.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                if !singleLine.isEmpty {
                    Text(singleLine).font(style.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
        }
    }

    /// A row is one line. What asks for the person or went wrong keeps its second line, and so does a narrow door.
    private var stacksDetail: Bool {
        compact || waiting || sectionStyle == .waiting || row.tone == .attention || row.tone == .failed
    }

    /// The detail sits beside the title when real room is left for it; otherwise the title has the line and the detail is its tooltip.
    private var detailFitsBeside: Bool {
        let room = width - rowInsets.leading - rowInsets.trailing - trailingWidth - 24
        return room - CGFloat(row.title.count) * 7.5 > 120
    }

    @ViewBuilder private var besideTitle: some View {
        if measuresControl {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                titleWords.layoutPriority(1)
                if detailFitsBeside { detailWords }
            }
        } else if row.detail?.isEmpty == false {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    titleWords.layoutPriority(1)
                    detailWords
                }
                .frame(idealWidth: CGFloat(row.title.count) * 7.5 + 132)
                titleWords
            }
        } else { titleWords }
    }

    @ViewBuilder private var trailing: some View {
        if measuresControl {
            trailingContent.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trailingWidth = $0 }
        } else { trailingContent }
    }

    private var trailingContent: some View {
        VStack(alignment: compact ? .leading : .trailing, spacing: 2) {
            if !row.group.isEmpty { group }
            if let control = row.control { controlView(control) }
            if row.meter != nil || row.value?.isEmpty == false {
                HStack(spacing: 8) {
                    if let meter = row.meter { FaceMeterBar(meter: meter, color: row.tone.map(FaceTone.color) ?? .secondary) }
                    if let value = row.value, !value.isEmpty {
                        Text(value).font(style.value).foregroundStyle(row.tone.map(FaceTone.color) ?? .secondary).lineLimit(1)
                    }
                }
            }
            if let at = row.at {
                Text(FaceTime.short(at) ?? at).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            } else if row.open != nil && row.control == nil && row.value == nil {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    /// The row's inline group: each child's word then its control, in the section's columns, so a missing child leaves its column empty.
    /// Side by side when the cells fit the width they are given; stacked one under another, each with its word, when they do not.
    private var group: some View {
        FaceGroupCells(spacing: style.insets.trailing, lineSpacing: 4) {
            ForEach(columns.isEmpty ? row.group : columns) { column in
                let child = row.group.first(where: { $0.title == column.title })
                Group {
                    if let child {
                        groupCell(child).id(child.id)
                    } else {
                        // Unseen, it holds the column's width: the same word and control another row draws here, under an item and an
                        // identity of its own so it never shares that child's focus or state.
                        groupCell(column, item: FaceItemID(section: item.section, row: "unseen:" + row.id + "/" + column.id))
                            .disabled(true).hidden().accessibilityHidden(true).id("unseen:" + column.id)
                    }
                }
                .layoutValue(key: FaceUnseenCell.self, value: child == nil)
            }
        }
    }

    private func groupCell(_ child: PartFace.Row, item: FaceItemID? = nil) -> FaceRowView {
        FaceRowView(row: child, item: item ?? childItem(child), door: door, session: session, focus: focus, move: move, sectionStyle: sectionStyle,
                    waiting: false, connectsTimeline: false, cellOf: row.title)
    }

    private var cell: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(row.title).font(style.detail).foregroundStyle(.secondary).lineLimit(1).fixedSize().accessibilityHidden(true)
            if let control = row.control {
                // A pending set moves nothing on the line: the control gives way to a spinner in its own place.
                controlView(control).controlSize(.small)
                    .opacity(pendingOperation == nil ? 1 : 0)
                    .overlay { if pendingOperation != nil { ProgressView().controlSize(.mini) } }
            }
        }
        #if os(macOS)
        .help(row.detail ?? "")
        #endif
    }

    private func controlView(_ control: PartFace.Control) -> some View {
        controlBody(control).onDisappear { dismissConfirmation(.control(confirmationSource)) }
    }

    @ViewBuilder private func controlBody(_ control: PartFace.Control) -> some View {
        if let text = control.text {
            FaceFieldInput.line(label, placeholder: control.placeholder ?? "", text: Binding(
                get: { session.drafts.value(key, seed: text) }, set: { session.drafts.set($0, for: key, baseline: text) }))
                .frame(maxWidth: .infinity).focused(focus, equals: .control(item))
                .onSubmit {
                    let value = session.drafts.value(key, seed: text)
                    submit("set", value, control.settingCall(value))
                }
        } else if let number = control.number {
            if let value = numberValue(number) {
                FaceFieldInput.number(label, words: PartFace.amount(value),
                                      increment: { changeNumber(number, direction: 1, control: control) },
                                      decrement: { changeNumber(number, direction: -1, control: control) })
                .focused(focus, equals: .control(item))
                .disabled(session.held(item))
            }
        } else if let iso = control.date {
            switch parsedDate(sent ?? iso) {
            case .success(let date):
                FaceFieldInput.date(label, value: Binding(get: { date }, set: { set($0.ISO8601Format(), control) }))
                    .focused(focus, equals: .control(item)).disabled(session.held(item))
            case .failure(let failure): Text("The date is unreadable: " + failure.localizedDescription).foregroundStyle(.red)
            }
        } else if let on = control.on {
            FaceFieldInput.toggle(label, value: Binding(get: { sent.map { $0 == "on" } ?? on }, set: { set($0 ? "on" : "off", control) }))
                .focused(focus, equals: .control(item))
                .disabled(session.held(item))
        } else if let options = control.options {
            FaceFieldInput.choice(label, options: options,
                                  value: Binding(get: { sent ?? control.selected ?? "" }, set: { set($0, control) }), allowsEmpty: false)
            .focused(focus, equals: .control(item))
            .disabled(session.held(item))
        }
    }

    private func parsedDate(_ iso: String) -> Result<Date, any Error> {
        Result { try Date.ISO8601FormatStyle().parse(iso) }
    }

    private func changeNumber(_ number: PartFace.Control.Number, direction: Double, control: PartFace.Control) {
        guard let current = numberValue(number) else { return }
        let value = current + direction * (number.step ?? 1)
        guard value.isFinite, number.min.map({ value >= $0 }) != false, number.max.map({ value <= $0 }) != false else { return }
        set(String(value), control)
    }

    /// What the strip draws as buttons: the answer first, then the other answers as they came. Housekeeping (`aside`) stands behind the
    /// "…" menu, unless the row has nothing else to answer with.
    private var answers: [PartFace.Action] {
        let drawn = actions.contains { $0.aside != true } ? actions.filter { $0.aside != true } : actions
        guard let lead = primary, drawn.contains(where: { $0.id == lead.id }) else { return drawn }
        return [lead] + drawn.filter { $0.id != lead.id }
    }

    /// A row's actions are buttons with a shape. The one answer leads, filled; it wears the door's accent only when the row waits on the
    /// person, because the accent means only that. The rest are quiet. No action is coloured by its role: a destructive one asks before it
    /// runs, and its confirmation names it.
    /// A row that asks keeps every answer as a button, wrapping onto further lines; only housekeeping goes behind "…".
    @ViewBuilder private var actionStrip: some View {
        if whole {
            FaceFlow(spacing: 8) {
                ForEach(answers) { action in
                    stripButton(action).focused(focus, equals: .action(item, action.id))
                }
                let rest = actions.filter { action in !answers.contains { $0.id == action.id } }
                if !rest.isEmpty { moreMenu(rest) }
            }
            .controlSize(.small)
        } else {
            ViewThatFits(in: .horizontal) {
                stripButtons(compact ? Array(answers.prefix(2)) : answers).fixedSize()
                stripButtons(Array(answers.prefix(1))).fixedSize()
                moreMenu(actions)
            }
            .controlSize(.small)
        }
    }

    private func stripButtons(_ shown: [PartFace.Action]) -> some View {
        HStack(spacing: 8) {
            ForEach(shown) { action in
                stripButton(action).focused(focus, equals: .action(item, action.id))
            }
            let rest = actions.filter { action in !shown.contains { $0.id == action.id } }
            if !rest.isEmpty { moreMenu(rest) }
        }
        .lineLimit(1)
    }

    /// Quiet buttons are in the primary ink, so no door's own tint colours them.
    private func stripButton(_ action: PartFace.Action) -> some View {
        let leads = action.id == primary?.id && action.aside != true && row.tone == .attention
        return actionButton(action).buttonStyle(FaceActionButtonStyle(fill: leads ? style.answer ?? .accentColor : nil))
    }

    /// The row's other actions behind one quiet "…" button, read aloud as "More actions".
    private func moreMenu(_ rest: [PartFace.Action]) -> some View {
        Menu { ForEach(rest) { action in actionButton(action) } } label: { Image(systemName: "ellipsis") }
            .menuStyle(.button).buttonStyle(FaceActionButtonStyle(fill: nil)).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(Text("More actions"))
            .focused(focus, equals: .actionMenu(item))
            #if os(macOS)
            .help(rest.map(\.label).joined(separator: ", "))
            #endif
    }

    private func actionButton(_ action: PartFace.Action) -> some View {
        Button(action.label + (action.unavailable.map { " (unavailable: " + $0 + ")" } ?? "")) { perform(action) }
            .disabled(session.held(item) || action.unavailable != nil)
    }

    @ViewBuilder private var menu: some View {
        if let link = row.open { Button(row.title) { door.open(link) } }
        ForEach(actions) { action in actionButton(action) }
        if pendingOperation != nil { Button(door.cancellationLabel) { session.cancel(item) } }
        groupCancels
        Divider()
        Button("Copy") { copy() }
    }

    @ViewBuilder private var accessibleActions: some View {
        if let link = row.open { Button(row.title) { door.open(link) } }
        ForEach(actions) { action in actionButton(action) }
        if pendingOperation != nil { Button(door.cancellationLabel) { session.cancel(item) } }
        groupCancels
        Button("Copy") { copy() }
    }

    /// A pending inline child is cancelled from its parent's menu, named by its word.
    @ViewBuilder private var groupCancels: some View {
        ForEach(row.group.filter { session.held(childItem($0)) }) { child in
            Button(door.cancellationLabel + " — " + child.title) { session.cancel(childItem(child)) }
        }
    }

    @discardableResult private func activate() -> Bool {
        if let link = row.open { door.open(link); return true }
        if let primary { perform(primary); return true }
        return false
    }

    private func perform(_ action: PartFace.Action) {
        guard !session.held(item), action.unavailable == nil else { return }
        if action.role == .destructive {
            pendingConfirmation = .init(source: .row(confirmationSource), title: action.label + " — " + row.title,
                                        label: action.label, role: .destructive) { run(action) }
        } else { run(action) }
    }

    private func run(_ action: PartFace.Action) {
        if let link = action.open { door.open(link) }
        else { submit(action.id, nil, action.call) }
    }

    private func set(_ value: String, _ control: PartFace.Control) {
        guard !session.held(item) else { return }
        let call = control.settingCall(value)
        if let question = control.confirm, !question.isEmpty {
            pendingConfirmation = .init(source: .control(confirmationSource), title: question, label: "Change", role: nil) {
                submit("set", value, call)
            }
        } else { submit("set", value, call) }
    }

    private func dismissConfirmation(_ source: FaceConfirmations.Source) {
        if pendingConfirmation?.source == source { pendingConfirmation = nil }
    }

    private func submit(_ action: String, _ value: String?, _ call: PartFace.Call?) {
        session.submit(item, row: row.id, action: action, value: value, call: call, door: door,
                       expectedPageRevision: row.pageRevision)
    }

    @ViewBuilder private var outcomeView: some View {
        if pill, let reason = primary?.unavailable { Text(reason).font(style.detail).foregroundStyle(.secondary) }
        outcome(row, item, word: nil)
        // An inline child's refusal, failure and undo are its own, drawn beneath the line it sits on and named by its word.
        ForEach(row.group) { child in outcome(child, childItem(child), word: child.title) }
    }

    @ViewBuilder private func outcome(_ row: PartFace.Row, _ item: FaceItemID, word: String?) -> some View {
        let named = word.map { $0 + ": " } ?? ""
        let name = word.map { self.row.title + " · " + $0 } ?? row.title
        if let refusal = session[row: item.row]?.refusal { Text(named + refusal.localizedDescription).foregroundStyle(.red).textSelection(.enabled) }
        if let operation = session.operation(for: item.row) {
            if let outcome = operation.outcome, !operation.checking {
                if let failure = outcome.failure {
                    Text(named + failure.localizedDescription).foregroundStyle(.red).textSelection(.enabled)
                    if let words = outcome.words { Text(words).foregroundStyle(.secondary).textSelection(.enabled) }
                    ForEach((failure.fields ?? [:]).keys.sorted(), id: \.self) { field in
                        if let words = failure.fields?[field] { Text(field + ": " + words).foregroundStyle(.red) }
                    }
                }
                if outcome.unresolved {
                    Text(named + (outcome.effects == .unknown ? "Not sure that went through. Check before trying again."
                        : "Not finished yet. Check before trying again."))
                        .foregroundStyle(.secondary)
                    if let words = outcome.words { Text(words).foregroundStyle(.secondary).textSelection(.enabled) }
                    Button("Check") { session.check(item, door: door) }.buttonStyle(FaceActionButtonStyle(fill: nil))
                }
                if let undo = outcome.undo, !session.held(item) {
                    Button(word.map { "Undo " + $0 } ?? "Undo") {
                        session.submit(item, row: row.id, action: "undo", value: nil, call: undo, door: door,
                                       undoOf: operation.submission.id, expectedPageRevision: row.pageRevision)
                    }.buttonStyle(FaceActionButtonStyle(fill: nil))
                }
            } else {
                #if !os(macOS)
                HStack {
                    ProgressView().controlSize(.small)
                    Text(operation.cancelling ? "Waiting on cancellation — " + name
                        : "Waiting on " + (operation.checking ? "current state — " : "") + name)
                    Button(door.cancellationLabel) { session.cancel(item) }.disabled(operation.cancelling).buttonStyle(.plain)
                }
                #endif
            }
        }
    }

    private func copy() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }
}

#if os(macOS)
private struct SelectableFaceRowText: View {
    let row: PartFace.Row
    let copyText: String
    let session: FacePageSession
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var textScale = BoardGeometry.macTextScale

    var body: some View {
        InlineFaceText(title: row.title, value: row.value, tone: row.tone, copyText: copyText, session: session, textScale: textScale)
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.AccessibilityDisplayOptionsDidChangeMessage.name)) { _ in
                textScale = BoardGeometry.macTextScale
            }
            .onChange(of: dynamicTypeSize, initial: true) { _, _ in textScale = BoardGeometry.macTextScale }
    }
}

private struct InlineFaceText: NSViewRepresentable {
    let title: String
    let value: String?
    let tone: PartFace.Tone?
    let copyText: String
    let session: FacePageSession
    let textScale: CGFloat

    func makeNSView(context: Context) -> ReadingView {
        let view = ReadingView(usingTextLayoutManager: false)
        view.session = session
        view.delegate = view
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        return view
    }

    func updateNSView(_ view: ReadingView, context: Context) {
        let words = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: (NSFont.systemFontSize * textScale).rounded(), weight: .medium),
            .foregroundColor: tone == .failed ? NSColor.systemRed : NSColor.secondaryLabelColor
        ])
        if let value, !value.isEmpty {
            words.append(NSAttributedString(string: "  " + value, attributes: [
                .font: NSFont.systemFont(ofSize: (NSFont.smallSystemFontSize * textScale).rounded()),
                .foregroundColor: NSColor(FaceTone.color(tone))
            ]))
        }
        view.pending = (words, copyText)
        view.refresh()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ReadingView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let rect = nsView.attributedString().boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                         options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: width, height: ceil(rect.height))
    }

    static func dismantleNSView(_ view: ReadingView, coordinator: ()) {
        view.clearFocus()
        view.session?.textSelections.remove(view.id)
        view.session?.copyMenus.remove(view.id)
        view.session = nil
    }

    final class ReadingView: NSTextView, NSTextViewDelegate, NSMenuDelegate {
        let id = UUID()
        weak var session: FacePageSession?
        var pending: (words: NSAttributedString, copyText: String)?
        private var copyText = ""

        func refresh() {
            guard selectedRange().length == 0, session?.copyMenus.contains(id) != true, let pending else { return }
            self.pending = nil
            copyText = pending.copyText
            if attributedString() != pending.words { textStorage?.setAttributedString(pending.words) }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if selectedRange().length > 0 { session?.textSelections.insert(id) }
            else {
                session?.textSelections.remove(id)
                refresh()
            }
        }

        override func becomeFirstResponder() -> Bool {
            guard super.becomeFirstResponder() else { return false }
            session?.focusedTextView = id
            return true
        }

        override func resignFirstResponder() -> Bool {
            guard super.resignFirstResponder() else { return false }
            clearFocus()
            setSelectedRange(NSRange(location: 0, length: 0))
            session?.textSelections.remove(id)
            refresh()
            return true
        }

        func clearFocus() {
            if session?.focusedTextView == id { session?.focusedTextView = nil }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = NSMenu()
            menu.delegate = self
            menu.autoenablesItems = false
            let item = menu.addItem(withTitle: "Copy", action: #selector(copyFromMenu(_:)), keyEquivalent: "")
            item.target = self
            let range = selectedRange()
            item.representedObject = range.length > 0 ? attributedString().attributedSubstring(from: range).string : copyText
            return menu
        }

        func menuWillOpen(_ menu: NSMenu) { session?.copyMenus.insert(id) }
        func menuDidClose(_ menu: NSMenu) {
            session?.copyMenus.remove(id)
            refresh()
        }

        @objc private func copyFromMenu(_ item: NSMenuItem) {
            guard let words = item.representedObject as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(words, forType: .string)
        }
    }
}
#endif

/// One line, cut by the system at its tail. A plain Text is measured once and cached, so a title as long as a whole prompt costs the
/// same as a short one however deeply its row is nested; only the part a line could ever show is handed over. A `whole` title (a row that
/// asks for the person) wraps instead, every word of it.
private struct FaceWordTitle: View {
    let title: String
    var whole = false

    var body: some View {
        if whole {
            Text(title).fixedSize(horizontal: false, vertical: true)
        } else {
            Text(title.prefix(400)).lineLimit(1).truncationMode(.tail)
                .accessibilityLabel(Text(title))
        }
    }
}

/// A row's length as a bar: its share of the whole, set where it begins. The value's words say the amount; the bar is not read aloud.
struct FaceMeterBar: View {
    let meter: PartFace.Row.Meter
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let whole = meter.max > 0 ? meter.max : 1
            let start = min(max((meter.start ?? 0) / whole, 0), 1)
            let length = min(max(meter.value / whole, 0), 1 - start)
            let barWidth = min(geometry.size.width, max(2, geometry.size.width * length))
            let offset = min(max(0, geometry.size.width - barWidth), geometry.size.width * start)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: barWidth).offset(x: offset)
            }
        }
        .frame(width: 72, height: 6)
        .accessibilityHidden(true)
    }
}

/// A row action's shape, drawn by SwiftUI itself: the filled answer, or a quiet button on the row's ground. The press stays a SwiftUI
/// press, as the plain buttons' was; the AppKit-backed `.bordered` and `.borderedProminent` buttons inside a row never ran their action.
struct FaceActionButtonStyle: ButtonStyle {
    let fill: Color?

    func makeBody(configuration: Configuration) -> some View {
        FaceActionButtonBody(configuration: configuration, fill: fill)
    }
}

private struct FaceActionButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let fill: Color?
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        configuration.label
            .font(.callout)
            .lineLimit(1)
            .foregroundStyle(fill == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.white))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background { if let fill { shape.fill(fill) } else { shape.fill(.quaternary) } }
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    }
}

/// Marks a cell drawn unseen only to hold its column's width; a stacked group leaves it out.
private struct FaceUnseenCell: LayoutValueKey {
    static let defaultValue = false
}

/// A row's title and its inline group, placed by what fits: the group beside the title at the trailing edge when both fit the width
/// offered, beneath the title otherwise. One set of views is measured and placed (where `ViewThatFits` would keep a live copy of every
/// switch per arrangement, each with its own confirmation and the same focus value), so every control keeps one identity and one state.
private struct FaceBesideOrBeneath: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    private func beside(_ width: CGFloat?, _ subviews: Subviews) -> Bool {
        guard subviews.count == 2, let width else { return true }
        return subviews[0].sizeThatFits(.unspecified).width + spacing + subviews[1].sizeThatFits(.unspecified).width <= width + 0.5
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return subviews.first?.sizeThatFits(proposal) ?? .zero }
        let lead = subviews[0], trail = subviews[1]
        if beside(proposal.width, subviews) {
            let trailSize = trail.sizeThatFits(.unspecified)
            let leadSize = lead.sizeThatFits(ProposedViewSize(width: proposal.width.map { max(0, $0 - spacing - trailSize.width) }, height: nil))
            return CGSize(width: proposal.width ?? leadSize.width + spacing + trailSize.width, height: max(leadSize.height, trailSize.height))
        }
        let column = ProposedViewSize(width: proposal.width, height: nil)
        let leadSize = lead.sizeThatFits(column), trailSize = trail.sizeThatFits(column)
        return CGSize(width: proposal.width ?? max(leadSize.width, trailSize.width), height: leadSize.height + lineSpacing + trailSize.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
            return
        }
        let lead = subviews[0], trail = subviews[1]
        if beside(bounds.width, subviews) {
            let trailSize = trail.sizeThatFits(.unspecified)
            lead.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                       proposal: ProposedViewSize(width: max(0, bounds.width - spacing - trailSize.width), height: bounds.height))
            trail.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(trailSize))
        } else {
            let column = ProposedViewSize(width: bounds.width, height: nil)
            let leadSize = lead.sizeThatFits(column)
            lead.place(at: bounds.origin, proposal: column)
            trail.place(at: CGPoint(x: bounds.minX, y: bounds.minY + leadSize.height + lineSpacing), proposal: column)
        }
    }
}

/// An inline group's cells: side by side when they fit the width offered, otherwise stacked one under another, each cell still its
/// word then its control. A cell drawn unseen to hold a column takes no line when the cells stack.
private struct FaceGroupCells: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    private func across(_ sizes: [CGSize]) -> CGFloat {
        sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, sizes.count - 1))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let wide = across(sizes)
        if proposal.width.map({ wide <= $0 + 0.5 }) ?? true { return CGSize(width: wide, height: sizes.map(\.height).max() ?? 0) }
        let seen = zip(subviews, sizes).filter { !$0.0[FaceUnseenCell.self] }.map(\.1)
        return CGSize(width: seen.map(\.width).max() ?? 0,
                      height: seen.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, seen.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        if across(sizes) <= bounds.width + 0.5 {
            var x = bounds.minX
            for (subview, size) in zip(subviews, sizes) {
                subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        } else {
            var y = bounds.minY
            for (subview, size) in zip(subviews, sizes) {
                if subview[FaceUnseenCell.self] {
                    subview.place(at: bounds.origin, proposal: .zero)
                    continue
                }
                subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(size))
                y += size.height + lineSpacing
            }
        }
    }
}
