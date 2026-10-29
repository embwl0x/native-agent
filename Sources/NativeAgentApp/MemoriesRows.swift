import MemoryV2
import SwiftUI
import AppKit
import EngineRuntime
import Foundation
import Combine
import Cognition
import NativeAgentShared
import NativeAgentCore
import PersistenceCore

// Blueprint: | `MemoriesRows.swift` | Memory row, proposal, history and disclosure views with full-text sheet identity; actions remain page-owned closures |

// MARK: - Pieces

/// Full-text sheet identity; opening it does not pin, delete or mutate.
struct MemoriesFullText: Identifiable, Equatable {
    let id: String
    let text: String
    /// Set only for a kept memory row: the store id a correction is written
    /// against. A rejected proposal has no memory to correct.
    var memoryID: String? = nil
}

/// A fold on the page: one quiet line (a count and a chevron) that opens its
/// card beneath it. One gesture: one fade, one height change.
struct MemoriesFold<Content: View>: View {
    let title: String
    @Binding var isOpen: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        // Disclosure uses the native control.
        DisclosureGroup(isExpanded: $isOpen) {
            content()
                .padding(.top, AliveMetrics.eyebrowGap)
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isOpen ? NativeAgentShell.text : NativeAgentShell.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One kept memory. Up to two prose lines and a meta line; Read, Pin and
/// Delete appear on hover, the way the conversations list reveals its pin.
/// A row inside the group card: the card carries the chrome.
struct MemoriesRowCard: View {
    let line: String
    let meta: String
    let isPinned: Bool
    let onRead: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var confirmingDelete = false
    @FocusState private var focusedAction: Action?
    private enum Action: Hashable { case read, pin }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
                Text(line.isEmpty ? "An empty note" : line)
                    .font(ShellType.rowTitle)
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                Text(meta)
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(minHeight: TodayMetrics.rowContentHeight, alignment: .leading)
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                iconButton("doc.text.magnifyingglass", help: "Read the whole thing", action: onRead)
                    .focused($focusedAction, equals: .read)
                iconButton(
                    isPinned ? "pin.fill" : "pin",
                    help: isPinned ? "Unpin" : "Pin to the top",
                    tint: isPinned ? NativeAgentShell.text : nil,
                    action: onTogglePin
                )
                .focused($focusedAction, equals: .pin)
            }
            // Pinned rows keep the pin visible; everything else appears under
            // the cursor, so sixty rows read as sixty lines, not sixty toolbars.
            .opacity(hovering || isPinned || focusedAction != nil ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Row actions use the native context menu.
        .contextMenu {
            Button("Read the whole thing", systemImage: "doc.text.magnifyingglass", action: onRead)
            Button(isPinned ? "Unpin" : "Pin to the top", systemImage: isPinned ? "pin.slash" : "pin",
                   action: onTogglePin)
            Divider()
            Button("Forget this…", systemImage: "trash", role: .destructive) { confirmingDelete = true }
        }
        // Deletion requires confirmation and cannot be undone.
        .confirmationDialog(
            "Forget this memory?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Forget it", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\u{201C}\(line)\u{201D}\n\nThis cannot be undone.")
        }
        .accessibilityIdentifier("memories.row")
    }

    private func iconButton(
        _ symbol: String,
        help: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(ShellType.labelMedium)
                .foregroundStyle(tint ?? NativeAgentShell.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// One staged proposal in the teal card: what she'd like to keep, when it was
/// staged, and the two words she needs back.
struct MemoriesProposalRow: View {
    let line: String
    let meta: String
    let isSaving: Bool
    let onKeep: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AliveWaitingDot()
            VStack(alignment: .leading, spacing: 3) {
                // The memory is read whole before it is kept: it wraps.
                Text(line)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(NativeAgentShell.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(meta)
                    .font(.system(size: 13))
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Button("Don't keep", action: onNotNow)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("memories.waiting.not-now")
                Button("Keep", action: onKeep)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .hazeTinted(.button)
                    .accessibilityIdentifier("memories.waiting.keep")
            }
            .fixedSize()
            .disabled(isSaving)
            .opacity(isSaving ? 0 : 1)
            .overlay {
                if isSaving {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Saving…")
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Loaded history retains the store's order and proposal identity. Reading is
/// available independently of the terminal review decision.
struct MemoriesRejectedHistory: View {
    let proposals: [ProposalRecord]
    @Binding var shown: Int
    let onRead: (ProposalRecord) -> Void

    var body: some View {
        ForEach(Array(proposals.prefix(shown))) { proposal in
            Button { onRead(proposal) } label: {
                HStack {
                    DeskPageDetailRow(
                        title: MemoriesPageContent.line(proposal.content),
                        line: "", meta: "I didn't keep this")
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(NativeAgentShell.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Read the whole thing")
            .accessibilityIdentifier("memories.deleted.read.\(proposal.id)")
        }
        if proposals.count > shown {
            HStack {
                Button("Show \(min(proposals.count - shown, MemoriesPageMetrics.foldRowCap)) more") {
                    shown = min(proposals.count, shown + MemoriesPageMetrics.foldRowCap)
                }
                .accessibilityIdentifier("memories.deleted.show-more")
            }
        }
    }
}
