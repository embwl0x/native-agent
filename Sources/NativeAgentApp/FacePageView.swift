import AppKit
import AppToolRuntime
import AuthoredCapabilities
import DreamREMCycle
import EngineRuntime
import Foundation
import NativeAgentShared
import SwiftUI
import Transcripts
// Blueprint: | `FacePageView.swift` | `FacePageView`: any faced page drawn with FaceView over engine.pages, its links followed through Mac navigation and its row actions answered by the page's owner |


/// Every faced page draws the same description; navigation and owner answers are the Mac's only adapters.
struct FacePageView: View {
    let page: String
    /// A tab inside a rail page: the rail already shows the page's title and line, so the face's header and top space are not drawn twice.
    var asTab = false
    var isReading = false
    @Environment(AppModel.self) private var appModel
    @State private var feedback: String?
    @State private var topRequest = 0
    @State private var activityTarget: ActivityTarget?

    private struct ActivityTarget: Identifiable {
        let reference: WorkOverviewReference
        var id: String { reference.kind.rawValue + ":" + reference.id }
    }

    private var snapshot: PartFaceSnapshot? { appModel.engine.pages.snapshots[page] }
    private var title: String { QuietPages.page(named: page)?.title ?? page }

    var body: some View {
        content.task(id: page) { await appModel.engine.pages.refresh(page: page) }
    }

    private var content: some View {
        ScrollViewReader { reader in
        ScrollView {
            // Nothing empty takes a section's space: the first thing shown sits at the top, under the rail's tabs when it is a tab.
            VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
                if !asTab, snapshot?.face?.title?.isEmpty != false || snapshot?.status != .ready {
                    AlivePageHeader(title: title)
                }
                if isReading { PageReadStatus(isReading: true, text: "Reading " + title + "…") }
                if let snapshot {
                    if snapshot.status == .ready, let face = snapshot.face {
                        FaceView(face: asTab ? PartFace(sections: face.sections) : face, open: open, act: act)
                    } else {
                        Text(snapshot.error?.message ?? (snapshot.status == .ready
                            ? title + " returned no drawable face." : title + " " + snapshot.status.rawValue + "."))
                            .foregroundStyle(.secondary).textSelection(.enabled)
                    }
                } else if !isReading {
                    Text(title + " has not published a face.").foregroundStyle(.secondary)
                }
                if let feedback { Text(feedback).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            .padding(.top, asTab ? 0 : TodayMetrics.topPadding)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id("face-top")
        }
        // A link within this page (an item opened in place) shows what it opened at the top.
        .onChange(of: topRequest) { withAnimation(.snappy) { reader.scrollTo("face-top", anchor: .top) } }
        // A page that puts what was just opened first (a selected item) shows it.
        .onChange(of: snapshot?.face?.sections.first?.id) { withAnimation(.snappy) { reader.scrollTo("face-top", anchor: .top) } }
        }
        .pageScrollColumn()
        .padding(.horizontal, 20)
        .frame(maxWidth: TodayMetrics.contentWidth, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(item: $activityTarget) { target in
            MacWorkOverviewDetail(reference: target.reference) { activityTarget = nil }
        }
    }

    private func act(_ row: String, _ action: String, _ value: String?) {
        feedback = nil
        Task {
            do { feedback = try await appModel.engine.pages.act(page: page, row: row, action: action, value: value, by: .person(door: "mac")) }
            catch { feedback = error.localizedDescription }
        }
    }

    private func open(_ link: String) {
        feedback = nil
        Task {
            do { try await follow(link) }
            catch { feedback = error.localizedDescription }
        }
    }

    private func follow(_ link: String) async throws {
        guard PartFace.isLink(link), let colon = link.firstIndex(of: ":") else {
            throw PartCallError(code: "bad_link", message: "This row has no supported destination.")
        }
        let kind = String(link[..<colon]), target = String(link[link.index(after: colon)...])
        switch kind {
        case "chat":
            await appModel.refreshChatSessionIndex()
            guard let session = appModel.engine.transcripts.sessions.first(where: { $0.id == target }) else {
                throw PartCallError(code: "conversation_unavailable", message: "This conversation could not be read from the conversation index.")
            }
            await appModel.selectChatSession(session)
            guard appModel.activeChatSessionId == target else {
                throw PartCallError(code: "conversation_unavailable", message: appModel.statusText)
            }
            ApplicationLifetime.shared.request(.sidebar(.chat))
        case "dream":
            let entry = try await appModel.engine.cognitionView.dreamEntry(date: target)
            guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PartCallError(code: "dream_unavailable", message: "This dream has no readable entry.")
            }
            ApplicationLifetime.shared.request(.savedThing(.dream(target)))
        case "page":
            let parts = target.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if parts[0] == "today", parts.count == 2, let section = ActivitySection(rawValue: parts[1]) {
                ApplicationLifetime.shared.request(.activity(section))
            } else {
                let result = await QuietComposerCommands.setPage(parts[0], item: parts.count == 2 ? parts[1] : "", appModel: appModel)
                if let refusal = result.refusal { feedback = refusal.detail } else if parts[0] == page { topRequest += 1 }
            }
        case "approval", "card":
            activityTarget = ActivityTarget(reference: .init(kind: kind == "approval" ? .approval : .inbox, id: target))
        case "url":
            guard let url = URL(string: target), ["http", "https"].contains(url.scheme), url.host?.isEmpty == false, NSWorkspace.shared.open(url) else {
                throw PartCallError(code: "url_unavailable", message: "The browser could not open this web link.")
            }
        default:
            throw PartCallError(code: "bad_link", message: "This row has no supported destination.")
        }
    }
}

