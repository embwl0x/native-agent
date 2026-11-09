import SwiftUI
import Foundation
import NativeAgentShared
// Blueprint: | `ResearchView.swift` | Shared research form and result rows over the existing search owner |

struct ResearchView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openURL) private var openURL
    @State private var submittedQuery = ""
    @State private var response: ResearchReplyFace?
    private var session: FacePageSession { appModel.pageSessions.page("research") }

    var body: some View {
        FaceView(face: page, door: door, session: session)
            .padding().navigationTitle("Research").macFaceStyle()
    }

    private var page: PartFace {
        var sections: [PartFace.Section] = [
            .init(id: "search", rows: [], block: .init(kind: "form", key: "research-query", fields: [
                .init(id: "query", label: "Research query", kind: "line", value: .string(submittedQuery), required: true),
            ], submit: [.init(id: "search", label: "Search", role: .primary, call: .init("research.search"))])),
        ]
        if let response {
            let gaps = response.gaps + response.unresponsiveEngines
            if !gaps.isEmpty {
                sections.append(.init(id: "gaps", title: "Search gaps — repair the reported SearXNG reads",
                    rows: gaps.enumerated().map { offset, gap in .init(id: "gap/\(offset)", title: gap, tone: .attention) }))
            }
            sections.append(.init(id: "results", title: "Research results",
                footer: response.results.isEmpty ? (gaps.isEmpty ? "No matches found for \"" + submittedQuery + "\"."
                    : "No usable results were returned. Search incomplete: " + gaps.joined(separator: "; ")) : nil,
                rows: response.results.enumerated().map { offset, result in
                .init(id: "result/\(offset)", title: result.title, detail: result.snippet, value: result.url,
                      open: link(result.url))
            }))
        } else {
            sections.append(.init(id: "not-run", style: .note, rows: [
                .init(id: "not-run", title: "No search has run in this view.",
                      detail: "The search service it uses is set on Settings.", tone: .quiet),
            ]))
        }
        return PartFace(sections: sections)
    }

    private func link(_ value: String) -> String? {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme), url.host != nil else { return nil }
        return "url:" + value
    }

    private var door: ClosureFaceDoor {
        ClosureFaceDoor(open: { value in
            guard value.hasPrefix("url:"), let url = URL(string: String(value.dropFirst(4))) else { return }
            openURL(url)
        }, waitingOn: "research results", perform: { submission in
            guard !submission.checking else {
                return .interrupted(WireFailure(code: "research_reply_unconfirmed",
                    message: "The search reply has not been confirmed. The current result rows belong to their last completed query.",
                    cause: nil, effects: .unknown))
            }
            guard submission.action == "search", submission.expectedCall == PartFace.Call("research.search"),
                  let values = submission.values, case .string(let query)? = values["query"] else {
                return .interrupted(WireFailure(code: "research_form_invalid",
                    message: "The research query is missing. Open Research again.", cause: nil, effects: .none))
            }
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .interrupted(WireFailure(code: "research_query_required", message: "Enter a research query.", cause: nil,
                                                effects: .none, fields: ["query": "Enter a research query."]))
            }
            switch await appModel.search(query) {
            case .success(let result):
                response = result
                submittedQuery = query
                return .init(words: "Research returned \(result.results.count) results.", effects: .none, accepted: true,
                             committed: [.init(id: "query", value: .string(query))])
            case .failure(let failure):
                return .interrupted(WireFailure(code: "research_failed", message: failure.message, cause: nil, effects: .none))
            }
        })
    }
}
