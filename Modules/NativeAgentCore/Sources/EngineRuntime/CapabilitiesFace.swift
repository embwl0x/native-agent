import Foundation
import AppToolRuntime
import AuthoredCapabilities
import Cognition
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import PersonaEngine
import Senses
import ToolRegistry
import TrustCenter
// Blueprint: | `CapabilitiesFace.swift` | Owner-backed capability rows, action calls, approval levers and availability |

enum CapabilitiesFace {
    /// What the page reads beside the owners that push their own changes: ability and sense files (their writes post AbilityStore.didChange;
    /// run accounting in abilities/state.json does not), the senses' attachment, and the built-in guidance bodies.
    static let notifications = [AbilityStore.didChange, SensesHub.didBecomeReady]
    static func paths(_ root: URL) -> [URL] { [defaultPersonaRoot(dataRoot: root).appendingPathComponent("skills/bodies")] }

    @MainActor static func reader(_ engine: NativeAgentEngine) -> PartFaces.Read {
        let changed: @MainActor @Sendable () async -> Void = { [weak pages = engine.pages] in
            _ = await pages?.refresh(page: "capabilities")
        }
        engine.trust.capabilitiesDidChange = changed
        engine.desk.capabilitiesDidChange = changed
        engine.tools.capabilitiesDidChange = changed
        engine.doctor.capabilitiesDidChange = changed
        engine.connectors.capabilitiesDidChange = changed
        // The chat-tool catalog is its owner's costly read (every tool weighed by Trust): it runs at launch and when abilities, Trust policy or
        // Mac access change, never on each page read; the page draws what the owner last published.
        let tools = engine.tools, pages = engine.pages
        let inputs = ["trust/policy.json", "security/mac_integration_permissions.json"].map { engine.dataRoot.appendingPathComponent($0) }
        Task { @MainActor in
            await EventDeadlinePhysiology.refreshOnChanges(paths: inputs, notifications: [AbilityStore.didChange]) {
                _ = await tools.refreshCatalog()
                _ = await pages.refresh(page: "capabilities")
            }
        }
        return { [weak engine] in
            guard let engine else { throw PartCallError(code: "unavailable", message: "The Capabilities owner has closed.") }
            return await read(engine)
        }
    }

    @concurrent nonisolated static func read(_ engine: NativeAgentEngine) async -> (face: PartFace, epoch: UInt64) {
        let epoch = UInt64(Date().timeIntervalSince1970 * 1000)
        let state = await MainActor.run {
            let trust = engine.trust
            return (summary: trust.capabilitySummary, summaryError: trust.capabilitySummaryError, policy: trust.policy,
                    policyError: trust.policyReadError ?? trust.securityRefreshError)
        }
        var sections: [PartFace.Section] = []
        if let failure = state.summaryError {
            sections.append(issue("inventory-read", "What I can do", failure))
        } else if state.summary == nil {
            sections.append(.init(id: "inventory-wait", title: "Reading what I can do", style: .waiting, rows: []))
        }
        let grown = await grownRows(engine.tools)
        if case .failure(let error) = grown {
            sections.append(issue("abilities-read", "My abilities", "Their versions and switches could not be read: " + error.localizedDescription))
        }
        if let summary = state.summary {
            let abilities: [String: Ability] = if case .success(let read) = grown { read } else { [:] }
            sections += inventory(CapabilityRecord.displayRecords(summary.records), abilities: abilities, stale: state.summaryError != nil)
        }
        sections.append(await catalog(engine.trust))
        sections += await senses()
        sections += await chatTools(engine)
        sections += await guidance(engine.tools)
        if let kernel = state.policy.map(TrustFacade.autonomyKernel(for:)) {
            let summary: [PartFace.Row] = [
                .init(id: "autonomy", title: "Autonomy", detail: kernel.disabledReason, value: kernel.status, tone: tone(kernel.status)),
                .init(id: "autonomy-mode", title: "Mode", value: kernel.mode ?? "Mode unavailable"),
            ]
            sections.append(.init(id: "guardrails", title: "Guardrails", style: .values, rows: summary + kernel.guardrails.map {
                .init(id: $0.id, title: $0.title, value: $0.status, tone: tone($0.status))
            }))
        } else if let failure = state.policyError {
            sections.append(issue("guardrails", "Guardrails", failure))
        } else {
            sections.append(.init(id: "guardrails", title: "Guardrails", style: .waiting,
                rows: [.init(id: "guardrails-unread", title: "Trust policy has not been read")]))
        }
        sections += await actionSections(engine)
        return (.init(title: "Capabilities", line: line(state.summary, error: state.summaryError), sections: sections), epoch)
    }

    private static func line(_ summary: CapabilitySummaryResponse?, error: String?) -> String? {
        guard error == nil, let counts = summary?.summary else { return nil }
        let ready = counts.active == counts.total ? "all ready to use" : "\(counts.active) ready to use"
        var line = "I have \(counts.total) \(counts.total == 1 ? "capability" : "capabilities")"
        if counts.total > 0 { line += ", " + ready }
        return line + "."
    }

    /// The inventory in sections. First, ungrouped, whatever waits on the person or is not ready: waiting for review or approval, failing.
    /// What is only switched off asks for nothing and sits under its own fold, last. Then my abilities, one parent row per purpose with the abilities nested and their count as its value; then what is built in.
    /// An ability whose own record was not read (`abilities` lacks it) is drawn from its inventory record, after the groups.
    nonisolated private static func inventory(_ records: [CapabilityRecord], abilities: [String: Ability], stale: Bool) -> [PartFace.Section] {
        let staleNote = "These are the last read capabilities; the read above failed."
        guard !records.isEmpty else {
            return [.init(id: "inventory", title: "My abilities", footer: stale ? staleNote : nil,
                rows: [.init(id: "inventory-empty", title: "No capabilities in the read inventory", tone: .quiet)])]
        }
        var waiting: [PartFace.Row] = [], ungrouped: [PartFace.Row] = [], builtIn: [PartFace.Row] = [], switchedOff: [PartFace.Row] = []
        var groups: [String: (title: String, rows: [PartFace.Row])] = [:]
        for record in records {
            if let ability = abilities[record.id] {
                if ability.off { switchedOff.append(ability.row) }
                else if ability.waits { waiting.append(ability.row) }
                else { groups[ability.purpose, default: (ability.title, [])].rows.append(ability.row) }
                continue
            }
            let row = capabilityRow(record)
            let off = ["disabled", "off"].contains(record.status?.lowercased() ?? "")
            if off { switchedOff.append(row) }
            else if row.tone == .attention || row.tone == .failed { waiting.append(row) }
            // `tool:<id>` is an ability's inventory id (capabilityRecordsFull); every other record is built in.
            else if record.id.hasPrefix("tool:") { ungrouped.append(row) }
            else { builtIn.append(row) }
        }
        let parents = groups.sorted { $0.value.title.localizedCaseInsensitiveCompare($1.value.title) == .orderedAscending }.map {
            PartFace.Row(id: "abilities:" + $0.key, title: $0.value.title, value: String($0.value.rows.count), rows: $0.value.rows)
        }
        var sections: [PartFace.Section] = []
        if !waiting.isEmpty {
            sections.append(.init(id: "review", title: "Waiting on you or not ready", footer: stale ? "Review state is from the last successful read."
                : "Open an ability to read its exact version, code and evidence before approving it.", rows: waiting))
        }
        if !(parents + ungrouped).isEmpty {
            sections.append(.init(id: "inventory", title: "My abilities", footer: stale ? staleNote : nil, rows: parents + ungrouped))
        }
        if !builtIn.isEmpty {
            sections.append(.init(id: "built-in", title: "Built in", footer: stale ? staleNote : nil, rows: builtIn))
        }
        if !switchedOff.isEmpty {
            sections.append(.init(id: "off", title: "Switched off", footer: "Off until turned on again. Open one to read its exact version first.",
                                  rows: switchedOff, folded: true))
        }
        return sections
    }

    nonisolated private static func capabilityRow(_ record: CapabilityRecord) -> PartFace.Row {
        .init(id: record.id, title: CapabilityRecord.title(for: record), detail: CapabilityRecord.description(for: record),
            value: "\(record.kind ?? "Kind unavailable") · \(record.riskClass ?? "Risk unavailable") · \(record.status ?? "Status unavailable")",
            tone: tone(record.status))
    }

    private static func catalog(_ owner: TrustFacade) async -> PartFace.Section {
        let trust = await MainActor.run {
            (catalogRefresh: owner.catalogRefresh, capabilityCatalogSources: owner.capabilityCatalogSources, capabilityNetwork: owner.capabilityNetwork,
             latestCapabilityTrustEvaluation: owner.latestCapabilityTrustEvaluation, capabilitySummary: owner.capabilitySummary,
             capabilitySummaryError: owner.capabilitySummaryError)
        }
        let sourceFailure = trust.catalogRefresh?.failedEndpoints.contains("catalog sources") == true
        let networkFailure = trust.catalogRefresh?.failedEndpoints.contains("capability trust") == true
        let sources = trust.catalogRefresh == nil || sourceFailure ? "Unavailable" : String(trust.capabilityCatalogSources.count)
        let trusted = networkFailure ? nil : trust.capabilityNetwork?.summary.map { String($0.trusted) }
        let evaluation = trust.latestCapabilityTrustEvaluation
        var rows: [PartFace.Row] = [
            .init(id: "catalog-sources", title: "Sources", value: sources, tone: sourceFailure ? .failed : .plain),
            .init(id: "catalog-trusted", title: "Trusted", value: trusted ?? "Not read", tone: networkFailure ? .failed : .plain),
        ]
        if let subject = trust.capabilitySummary?.records.first, trust.capabilitySummaryError == nil {
            rows.append(.init(id: subject.id, title: "Latest check", detail: evaluation.map {
                "\($0.name ?? $0.id): " + $0.reasons.joined(separator: " ")
            }, value: evaluation?.trustTier ?? "No check in this session", at: evaluation?.createdAt,
                actions: [.init(id: "capability.check_trust", label: "Check trust", call: .init("capability.check_trust", ["id": .string(subject.id)]))]))
        } else {
            rows.append(.init(id: "catalog-check-unread", title: "Latest check", value: "Read the capabilities before checking trust"))
        }
        if let receipt = trust.catalogRefresh, receipt.isStale {
            rows.append(.init(id: "catalog-read", title: "Catalog read incomplete",
                detail: receipt.failedEndpoints.joined(separator: ", "), tone: .failed))
        }
        return .init(id: "catalog", title: "Catalog", style: .values, rows: rows)
    }

    nonisolated static func issue(_ id: String, _ title: String, _ detail: String) -> PartFace.Section {
        .init(id: id, title: title, rows: [.init(id: id, title: "Could not read this", detail: detail, tone: .failed)])
    }

    nonisolated static func tone(_ status: String?) -> PartFace.Tone {
        guard let status else { return .quiet }
        switch status.lowercased() {
        case "active", "installed", "ready", "configured", "ok", "passed", "succeeded", "completed", "trusted": return .done
        case "running": return .live
        case "failed", "error", "blocked": return .failed
        case "review", "proposal", "draft", "drafted", "needs_setup", "pending_approval", "untrusted", "unavailable": return .attention
        default: return .quiet
        }
    }
}

// MARK: - Senses, grown abilities, chat tools and guidance

extension CapabilitiesFace {
    /// A sense's row carries the version the person saw, so a switch acts on that version or is refused as changed.
    nonisolated static func senseRowID(_ record: SenseRecord) -> String { "sense." + record.id + "@" + String(record.version) }
    /// An ability's row carries the exact version its fold shows, so Approve keeps only what the person read.
    nonisolated static func abilityRowID(_ tool: ToolRecord) -> String { "ability." + tool.id + "@" + (tool.reviewedKeepDigest ?? "") }

    /// The senses as their registry holds them now, those not on first. A sense is on unless switched off, so its row says its state in words
    /// and carries no switch; turning it off or on stays an action on the row (`sense.switch`). The registry records who switched a sense
    /// off, so the person's off stays off across launches.
    @concurrent nonisolated static func senses() async -> [PartFace.Section] {
        let footer = "Live watches and recent sense changes are on Home, under My senses."
        guard SensesHub.shared.registry != nil else {
            return [.init(id: "senses", title: "Senses", footer: footer, rows: [.init(id: "senses-unattached", title: "Senses are not connected yet",
                detail: "The sense registry is not attached to this app. Doctor's Senses installation reading (launch.senses) names why.",
                tone: .attention)])]
        }
        let records: [SenseRecord]
        do { records = try await SensesHub.shared.presentationRecords().0 }
        catch { return [issue("senses", "Senses", "Senses registry unavailable: " + error.localizedDescription)] }
        let rows = (records.filter { $0.status != .on } + records.filter { $0.status == .on }).map { record -> PartFace.Row in
            let state = switch record.status {
            case .unavailable: "Unavailable"
            case .draft: "Not ready yet"
            case .on: "On"
            case .off: record.disabledBy == "owner" ? "Off, switched off by you" : "Off"
            }
            let origin = switch record.origin {
            case .builtIn: "Built in"
            case .grown: "Grown"
            case .shared: "Shared"
            }
            let cost: String
            if record.origin == .builtIn && record.version == 1 {
                cost = "Growth cost: $0"
            } else if let usd = record.growthCostUSD, usd.isFinite, usd >= 0 {
                cost = "Growth cost: " + usd.formatted(.currency(code: "USD"))
            } else {
                cost = "Growth cost: not recorded"
            }
            var lines = ["\(origin) · \(record.uses) uses · \(record.corrections) corrections"]
            if let reason = record.unavailableReason { lines.append(reason) }
            lines.append(record.lastUsedAt == nil ? "Never used · \(cost)" : cost)
            // Turning it off or on and Share name the exact version the row shows; the switch's call carries the new state as its value.
            let version: [String: PartFace.Value] = ["sense_id": .string(record.id), "version": .int(Int64(record.version))]
            var actions: [PartFace.Action] = []
            if record.status != .draft {
                let on = record.status == .on
                actions.append(.init(id: "sense.switch", label: on ? "Turn off" : "Turn on",
                    call: .init("sense.switch", version.merging(["value": .bool(!on)]) { _, new in new })))
            }
            if record.language != .native {
                actions.append(.init(id: "sense.share", label: "Share sense", doors: ["mac"], call: .init("sense.share", version)))
            }
            return .init(id: senseRowID(record), title: "\(record.corner.surfaceName) · v\(record.version)",
                detail: lines.joined(separator: "\n"), value: state,
                at: record.lastUsedAt.map { ISO8601DateFormatter().string(from: $0) }, tone: record.status == .unavailable ? .attention : nil,
                actions: actions.isEmpty ? nil : actions)
        }
        return [.init(id: "senses", title: "Senses", footer: footer,
            rows: rows.isEmpty ? [.init(id: "senses-empty", title: "No senses yet", tone: .quiet)] : rows)]
    }

    /// One of my abilities as the inventory draws it: its row, what it is for (`purpose`, the parent row it is drawn under, and that parent's
    /// `title`), and whether it waits on the person or is not ready (drawn first, ungrouped).
    struct Ability: Sendable {
        let row: PartFace.Row
        let purpose: String
        let title: String
        let waits: Bool
        /// Switched off and nothing else: no new version, nothing failing. It asks for nothing, so it is not drawn as waiting.
        var off = false
    }

    /// My abilities from the tool registry's checked records, keyed by the inventory record each one is (`tool:<id>`): one row carries it, its
    /// status, an open to its exact version, code and evidence (to read before approving), and the person's Approve and Turn off.
    /// Catalog failures return failure so the page can name the unavailable source.
    @concurrent nonisolated static func grownRows(_ tools: ToolsFacade) async -> Result<[String: Ability], Error> {
        let records: [ToolRecord]
        do { records = try await tools.listAuthored() }
        catch { return .failure(error) }
        return await Task.detached(priority: .userInitiated) {
            Result<[String: Ability], Error>.success(Dictionary(records.map { tool -> (String, Ability) in
                let status = tool.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let word = switch status {
                case "active": "On"
                case "draft": "Draft"
                case "proposed": "Proposed"
                case "disabled": "Off"
                default: "Status unavailable"
                }
                var actions: [PartFace.Action] = []
                var refusal: String?
                let onlyOff = status == "disabled" && tool.candidateDigest == nil && tool.validationErrors?.isEmpty != false
                if tool.status != "active" || tool.candidateDigest != nil {
                    refusal = (tool.candidateDigest ?? tool.codeFingerprint) != nil && tool.keepReview == nil
                        ? "Version unavailable. Read Capabilities again before approving." : tools.keepRefusal(tool, turn: nil)
                    // Approve names the exact version the row's fold shows.
                    var keep: [String: PartFace.Value] = ["id": .string(tool.id)]
                    if let digest = tool.reviewedKeepDigest { keep["version"] = .string(digest) }
                    if refusal == nil {
                        actions.append(.init(id: "ability.keep", label: onlyOff ? "Turn on" : "Approve", role: .primary, doors: ["mac"],
                                             call: .init("ability.keep", keep)))
                    }
                }
                if tool.status != "disabled" {
                    actions.append(.init(id: "ability.off", label: "Turn off", role: .destructive, doors: ["mac"],
                                         call: .init("ability.off", ["id": .string(tool.id)])))
                }
                let lines = [firstLine(tool.description)] + (refusal.map { ["Approve unavailable: " + $0] } ?? [])
                let tone: PartFace.Tone
                if tool.validationErrors?.isEmpty == false { tone = .failed }
                else { tone = status == "active" ? .done : status == "disabled" ? .quiet : .attention }
                let row = PartFace.Row(id: abilityRowID(tool), title: tool.name, detail: lines.joined(separator: "\n"), value: word,
                    tone: tone, open: "page:capabilities/" + abilityRowID(tool), actions: actions.isEmpty ? nil : actions)
                let subject = purpose(tool)
                // Anything but on and settled waits: a draft, a proposal, off, failing validation, or a new version waiting for approval.
                return ("tool:" + tool.id, Ability(row: row, purpose: subject.key, title: subject.title,
                    waits: tone != .done || tool.candidateDigest != nil, off: onlyOff))
            }, uniquingKeysWith: { first, _ in first }))
        }.value
    }

    /// What an ability is for, from what its record declares, first found: the page it is placed on (`face.page`); a face drawn with no page
    /// (`face.projection`), which is a page I draw; the subject of a verb it answers, its face's action or an app action it calls
    /// (`mail.search` → mail); the app it reaches (`app_read:`/`app_write:` → the bundle id's last word); else its id's first word. The title is
    /// the app page of that name where one exists.
    nonisolated static func purpose(_ tool: ToolRecord) -> (key: String, title: String) {
        let face = tool.fields["face"]?.objectValue ?? [:]
        if face["page"] == nil, face["projection"] == .bool(true) { return ("pages", "Pages I draw") }
        let verbs = (tool.fields["answers"]?.objectValue?.keys.sorted() ?? []) + [face["action"]?.stringValue].compactMap { $0 } + (tool.actions ?? [])
        let apps = (tool.permissions ?? []).compactMap { reach -> String? in
            let parts = reach.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, ["app_read", "app_write"].contains(String(parts[0])) else { return nil }
            return parts[1].split(separator: ".").last.map(String.init)
        }
        let declared = [face["page"]?.stringValue].compactMap { $0 } + verbs.map { String($0.prefix { $0 != "." }) } + apps
        let key = (declared.first { !$0.isEmpty } ?? String(tool.id.prefix { $0 != "-" })).lowercased()
        return (key, QuietToolPage.page(named: key)?.title ?? key.prefix(1).uppercased() + String(key.dropFirst()))
    }

    /// The page's first line of a longer text.
    nonisolated private static func firstLine(_ text: String) -> String {
        String(text.split(whereSeparator: \.isNewline).first ?? "")
    }

    /// The documents behind the page's rows, read on demand by every door: an ability's version, code and evidence, a chat tool's schema and
    /// route, a guidance text. A row id that names nothing current is refused as stale.
    @MainActor static func body(_ engine: NativeAgentEngine) -> PartFaces.Body {
        { [weak engine] item in
            guard let engine else { throw PartCallError(code: "unavailable", message: "The Capabilities owner has closed.") }
            let tools = engine.tools
            if item.hasPrefix("ability.") {
                guard let tool = tools.authored.first(where: { abilityRowID($0) == item }) else { throw staleBody() }
                return abilityDocument(tool)
            }
            if item.hasPrefix("tools."), let bucket = ChatToolCatalogBucket(rawValue: String(item.dropFirst("tools.".count))) {
                return try toolGroupDocument(engine, bucket: bucket)
            }
            if item.hasPrefix("tool."), let catalog = tools.catalog {
                guard let tool = catalog.tools.first(where: { "tool." + $0.name == item }) else { throw staleBody() }
                return toolDocument(tool, status: catalog.status(for: tool).title)
            }
            if item.hasPrefix("skill.") {
                guard let skill = try await tools.refreshSkills(includingSource: true).first(where: { "skill." + $0.id == item }) else {
                    throw staleBody()
                }
                guard let body = skill.body else {
                    throw PartCallError(code: "no_text", message: skill.status == "unavailable" ? skill.description : "This guidance has no text to show.")
                }
                return body
            }
            throw staleBody()
        }
    }

    /// One tool as the person and the agent read it: name and status, the whole description, what it takes and where it runs.
    private static func toolDocument(_ tool: ChatCatalogTool, status: String) -> String {
        var lines = [tool.name + " — " + status, tool.description.isEmpty ? "An additional tool I can use for your tasks." : tool.description]
        if let parameters = tool.parametersPreview { lines.append("Takes " + parameters) }
        if let via = tool.dispatchableVia { lines.append("Runs through " + via) }
        return lines.joined(separator: "\n")
    }

    private static func staleBody() -> PartCallError {
        .init(code: "stale_row", message: "That row is no longer on Capabilities. Read Capabilities again.")
    }

    /// Everything the person reads before approving one ability: its whole description, reach, the exact waiting version and its code.
    private static func abilityDocument(_ tool: ToolRecord) -> String {
        var notes: [String] = [tool.name]
        func note(_ key: String, _ title: String, _ text: String?) {
            guard let text, !text.isEmpty else { return }
            notes.append(title + ":\n" + text)
        }
        func json(_ key: String, _ title: String, _ value: JSONValue) {
            do { note(key, title, try value.serialize(pretty: true)) }
            catch { note(key, title, "Could not be shown: " + error.localizedDescription) }
        }
        note("about", "About", tool.description)
        var facts: [String] = tool.autoCreated == true ? ["Written by me"] : []
        if let validation = tool.validationStatus { facts.append("Validation: \(validation)") } else { facts.append("Untested") }
        if let uses = tool.useCount { facts.append("Used \(uses) times") } else { facts.append("Use count not recorded") }
        note("facts", "Status", facts.joined(separator: " · "))
        note("triggers", "Triggers", tool.triggers.joined(separator: ", "))
        note("permissions", "Permissions", tool.permissions?.joined(separator: ", "))
        note("errors", "Validation errors", tool.validationErrors?.joined(separator: " "))
        note("path", "Saved at", (tool.activePath ?? tool.proposalPath).map(UserDisplayFormatters.tildifyPath))
        if let review = tool.keepReview, case .string(let version)? = review["version"], case .string(let code)? = review["code"],
           let reach = review["reach"] {
            note("version", tool.candidateDigest == nil ? "Version to turn on" : "Waiting version", version)
            if case .string(let description)? = review["description"] { note("change", "This version", description) }
            json("reach", "Reach", reach)
            note("code", "Code", code)
            let declarations = review.filter { !["code", "description", "reach", "version"].contains($0.key) }
            if !declarations.isEmpty { json("declarations", "Declarations and fixtures", .object(declarations)) }
        }
        let evidence = tool.fields.filter { ["validation_evidence", "candidate_validation_evidence", "learned"].contains($0.key) }
        if !evidence.isEmpty { json("evidence", "Evidence and learned use", .object(evidence)) }
        return notes.joined(separator: "\n\n")
    }

    /// The chat tools as the catalog owner last published them, each dispatch group folded. A tool's value is Trust's decision for it now:
    /// the standing and Mac access on Trust decide it, and no per-tool setting exists. The owner has no filter, so the groups are the browse.
    static func chatTools(_ engine: NativeAgentEngine) async -> [PartFace.Section] {
        let (tools, policy, policyError) = await MainActor.run {
            ((catalog: engine.tools.catalog, catalogLoadError: engine.tools.catalogLoadError, authored: engine.tools.authored),
             engine.trust.policy, engine.trust.policyReadError)
        }
        let readAgain = PartFace.Action(id: "tools.read", label: "Read again", call: .init("tools.refresh"))
        guard let catalog = tools.catalog else {
            if let failure = tools.catalogLoadError {
                return [.init(id: "tools", title: "Chat tools", rows: [.init(id: "tools.count", title: "The tool list could not be read",
                    detail: failure, tone: .failed, actions: [readAgain])])]
            }
            return [.init(id: "tools", title: "Chat tools", style: .waiting, rows: [.init(id: "tools-wait", title: "Reading the tools")])]
        }
        // The abilities above are not listed again; a blank or repeated name is withheld rather than drawn as an arbitrary record.
        let grown = Set(tools.authored.map(\.id))
        let runtime = catalog.tools.filter { !grown.contains($0.name) }
        let names = runtime.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        let counts = Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +)
        let shown = zip(runtime, names).filter { !$0.1.isEmpty && counts[$0.1] == 1 }.map { $0.0 }
        var groups: [ChatToolCatalogBucket: [ChatCatalogTool]] = [:]
        for tool in shown {
            let bucket: ChatToolCatalogBucket
            if let raw = tool.catalogBucket, let known = ChatToolCatalogBucket(rawValue: raw) {
                bucket = known == .core && catalog.alwaysOnTools.contains(tool.name) ? .alwaysOn : known
            } else {
                bucket = .unclassified
            }
            groups[bucket, default: []].append(tool)
        }
        var header: [PartFace.Row] = [.init(id: "tools.count", title: "Chat tools", value: shown.count == catalog.tools.count
            ? "\(catalog.tools.count) chat tools" : "\(shown.count) of \(catalog.tools.count) chat tools shown", actions: [readAgain])]
        if let failure = tools.catalogLoadError {
            header.append(.init(id: "tools.stale", title: "Showing the tools that loaded last time",
                detail: "The latest read failed: " + failure, tone: .failed))
        }
        if runtime.count > shown.count {
            let withheld = runtime.count - shown.count
            header.append(.init(id: "tools.withheld", title: "\(withheld) broken or duplicate \(withheld == 1 ? "row was" : "rows were") left out",
                detail: "Read the tools again once the list is fixed.", tone: .failed))
        }
        if let unclassified = groups[.unclassified]?.count {
            header.append(.init(id: "tools.unclassified", title: "\(unclassified) not sorted into a group yet",
                detail: "Whether each is available is shown, but its group has not been checked.", tone: .quiet))
        }
        if let banner = fullMacBanner(catalog, policy: policy, policyError: policyError) {
            header.append(.init(id: "tools.full-mac", title: banner.title, detail: banner.detail, tone: .attention, open: "page:trust"))
        }
        if shown.isEmpty {
            header.append(.init(id: "tools.none", title: "No tools to show", detail: catalog.tools.isEmpty
                ? "The last list that loaded had no tools in it. Read it again to get a current one."
                : "The list came back with \(catalog.tools.count) row\(catalog.tools.count == 1 ? "" : "s"), but none had a usable name.",
                tone: .attention))
        }
        // One row per group, saying how many are available; the group's list and each tool's schema are read on demand, never carried.
        let groupRows = ChatToolCatalogBucket.allCases.compactMap { bucket -> PartFace.Row? in
            guard let members = groups[bucket], !members.isEmpty else { return nil }
            // Runnable now: always on, available, or available with the person's approval.
            let available = members.filter { [.active, .available, .approval].contains(catalog.status(for: $0)) }.count
            return .init(id: "tools." + bucket.rawValue, title: bucket.title, detail: "\(available) of \(members.count) available now",
                value: "\(members.count)", open: "page:capabilities/tools." + bucket.rawValue)
        }
        return [.init(id: "tools", title: "Chat tools", rows: header + groupRows)]
    }

    /// A group's tools as one document, sorted by name: each tool's name, its status now, its whole description, what it takes and where it
    /// runs.
    @MainActor private static func toolGroupDocument(_ engine: NativeAgentEngine, bucket: ChatToolCatalogBucket) throws -> String {
        guard let catalog = engine.tools.catalog else { throw staleBody() }
        let grown = Set(engine.tools.authored.map(\.id))
        let members = catalog.tools.filter { tool in
            guard !grown.contains(tool.name) else { return false }
            if let raw = tool.catalogBucket, let known = ChatToolCatalogBucket(rawValue: raw) {
                return (known == .core && catalog.alwaysOnTools.contains(tool.name) ? .alwaysOn : known) == bucket
            }
            return bucket == .unclassified
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !members.isEmpty else { throw staleBody() }
        return ([bucket.title + " · \(members.count)"] + members.map { tool in
            toolDocument(tool, status: catalog.status(for: tool).title)
        }).joined(separator: "\n\n")
    }

    /// Why Full Mac tools read as locked, from the loaded catalog and Trust's own policy reading; nil when the two agree that all is well.
    private static func fullMacBanner(_ catalog: ChatToolCatalogSnapshot, policy: TrustPolicy?, policyError: String?) -> (title: String, detail: String)? {
        let trustFullMac = policy.map { TrustAccessModeCapabilityCatalog.fullMacGrantIsActive($0) }
        if catalog.fullMacActive {
            guard trustFullMac == false else { return nil }
            return ("Full Mac status needs a fresh read",
                "Full Mac tools are still loaded, but Trust now says Full Mac is off. Read the tools again before relying on this list.")
        }
        if policyError != nil {
            return ("Full Mac tools are locked", "The Trust policy could not be read, so why Full Mac is locked is unknown. Open Trust to see the cause.")
        }
        guard let trustFullMac else {
            return ("Full Mac tools are locked", "Trust has not been read yet. Full Mac tools stay locked until it is.")
        }
        if !trustFullMac {
            return ("Full Mac is off", "File, system, shell and Mac-control tools are locked. Turn Full Mac on in Trust to unlock them.")
        }
        return ("Full Mac tools are locked",
            "Trust says Full Mac is on, but these tools are still locked. Read the tools again; if that does not help, choose Full Mac again on Trust.")
    }

    /// The built-in guidance with each body, read from its owner. A body is long text, so it folds beneath the list as a note read whole.
    @concurrent nonisolated static func guidance(_ tools: ToolsFacade) async -> [PartFace.Section] {
        let build = PartFace.Row(id: "guidance.build", title: "Build a skill in chat",
            detail: "Opens chat with the request started in the message box; nothing is sent until you send it.",
            actions: [.init(id: "skill.build", label: "Build in chat", doors: ["mac"], call: .init("skill.build"))])
        let skills: [SkillRecord]
        do { skills = try await tools.refreshSkills(includingSource: false) }
        catch {
            return [.init(id: "guidance", title: "Guidance", rows: [
                .init(id: "guidance-read", title: "Could not read the guidance", detail: error.localizedDescription, tone: .failed), build])]
        }
        guard !skills.isEmpty else {
            return [.init(id: "guidance", title: "Guidance", rows: [.init(id: "guidance-empty", title: "No skills yet",
                detail: "Ask me to build an ability in chat. You can review it here, under My abilities.", tone: .quiet), build])]
        }
        let rows = skills.map { skill -> PartFace.Row in
            let unavailable = skill.status == "unavailable"
            return .init(id: "skill." + skill.id, title: skill.name, detail: firstLine(skill.description),
                value: unavailable ? "Unavailable" : "Built in", tone: unavailable ? .failed : nil, open: "page:capabilities/skill." + skill.id)
        }
        return [.init(id: "guidance", title: "Guidance", footer: "\(skills.count) skills. I pull up the right one when a conversation calls for it; "
            + "the full text loads only when it is needed.", rows: rows + [build])]
    }
}

// MARK: - Mac actions, connector actions and checks

/// The Mac's own controls behind Capabilities rows: a save panel and the chat message box. A person answers these, never an agent's payload.
@MainActor public protocol CapabilitiesFaceHost {
    func chooseSenseDestination(name: String) async throws -> URL?
    func buildSkillInChat() async throws -> String
}

@MainActor
extension CapabilitiesFace {
    @concurrent nonisolated static func actionSections(_ engine: NativeAgentEngine) async -> [PartFace.Section] {
        let (tools, connectors, policy) = await MainActor.run {
            ((nativeActionReceipts: engine.tools.nativeActionReceipts, nativePowerRefresh: engine.tools.nativePowerRefresh),
             (actionsReadError: engine.connectors.actionsReadError, actions: engine.connectors.actions), engine.trust.policy)
        }
        let fullMac = policy.map { TrustAccessModeCapabilityCatalog.fullMacGrantIsActive($0) } == true
        let nativeRows = NativeActionRoutes.swiftNativeActionRecords().map { action in
            let receipt = tools.nativeActionReceipts.last { $0.actionId == action.id }
            var details = [action.kind, nativeGate(action, fullMac: fullMac), receipt?.detail].compactMap { $0 }
            if action.dryRunAvailable == false { details.append("Dry run is unavailable for this action.") }
            let id: [String: PartFace.Value] = ["id": .string(action.id)]
            return PartFace.Row(id: action.id, title: action.name, detail: details.joined(separator: " "),
                value: [action.risk, receipt?.status].compactMap { $0 }.joined(separator: " · "), at: receipt?.createdAt,
                tone: receipt.map { tone($0.status) }, actions: [
                    .init(id: "native.dry_run", label: "Dry run", call: .init("native.dry_run", id)),
                    .init(id: runActionID(action), label: "Run", call: .init("native.run", id)),
                ])
        }
        var connectorRows: [PartFace.Row] = []
        if let failure = connectors.actionsReadError {
            connectorRows.append(.init(id: "connector-read", title: "Connector actions could not be read", detail: failure, tone: .failed))
        }
        if let registry = connectors.actions {
            connectorRows += registry.actions.map { action in
                .init(id: action.id, title: action.name,
                    detail: [action.connectorId, action.authState, action.dryRunAvailable == false ? "Dry run is unavailable." : nil]
                        .compactMap { $0 }.joined(separator: " · "),
                    value: action.connectorStatus ?? "Status unavailable", tone: tone(action.connectorStatus),
                    actions: [.init(id: "connector.dry_run", label: "Dry run", call: .init("connector.dry_run", ["id": .string(action.id)]))])
            }
            if registry.actions.isEmpty { connectorRows.append(.init(id: "connector-empty", title: "No registered connector actions")) }
            if let receipt = registry.latestReceipt {
                connectorRows.append(.init(id: "connector-receipt", title: "Latest connector action", detail: receipt.actionId,
                    value: receipt.status, at: receipt.createdAt, tone: tone(receipt.status)))
            }
        }
        let nativeReadFailure = tools.nativePowerRefresh.flatMap { receipt in
            receipt.isStale ? "Some action receipts or browser status could not be read: " + receipt.failedEndpoints.joined(separator: ", ") : nil
        }
        return [
            .init(id: "mac-actions", title: "Mac actions", footer: nativeReadFailure, rows: nativeRows),
            .init(id: "connector-actions", title: "Connector actions",
                style: connectors.actions == nil && connectors.actionsReadError == nil ? .waiting : .list, rows: connectorRows),
            await checks(engine),
        ]
    }

    nonisolated private static func checks(_ engine: NativeAgentEngine) async -> PartFace.Section {
        let (doctor, tools) = await MainActor.run {
            let doctor = engine.doctor, tools = engine.tools
            return ((latestImprovementGauntletRun: doctor.latestImprovementGauntletRun, hardeningRefresh: doctor.hardeningRefresh,
                     improvementRunError: doctor.improvementRunError, improvementRunStartedAt: doctor.improvementRunStartedAt,
                     productionExports: doctor.productionExports, productionExportWork: doctor.productionExportWork,
                     productionExportFailure: doctor.productionExportFailure, productionHardening: doctor.productionHardening),
                    (browserDryRunPreview: tools.browserDryRunPreview, browserDryRunError: tools.browserDryRunError,
                     browserDryRunStartedAt: tools.browserDryRunStartedAt, browserStatus: tools.browserStatus))
        }
        let gauntlet = doctor.latestImprovementGauntletRun
        let checks = gauntlet?.checks
        let checkDetail = checks.map { checks in
            if checks.isEmpty { return "No checks recorded" }
            let failures = checks.filter { !$0.passed }.map(\.title)
            return failures.isEmpty ? "All recorded checks passed" : failures.joined(separator: ", ")
        }
        let unread = doctor.hardeningRefresh == nil
        let missingGauntlet = unread || doctor.hardeningRefresh?.failedEndpoints.contains("improvement gauntlet") == true
        let missingExports = unread || doctor.hardeningRefresh?.failedEndpoints.contains("production exports") == true
        let browser = tools.browserDryRunPreview
        var rows: [PartFace.Row] = [
            .init(id: "improvement", title: "Improvement checks",
                detail: doctor.improvementRunError ?? checkDetail,
                value: doctor.improvementRunStartedAt != nil ? "Running" : doctor.improvementRunError != nil ? "Failed"
                    : gauntlet?.status ?? (missingGauntlet ? "Not read" : "No recorded run"),
                at: stamp(doctor.improvementRunStartedAt) ?? (doctor.improvementRunError == nil ? gauntlet?.createdAt : nil),
                tone: doctor.improvementRunStartedAt != nil ? .live : doctor.improvementRunError == nil ? tone(gauntlet?.status) : .failed,
                actions: [.init(id: "improvement.run", label: "Run", call: .init("improvement.run"))]),
            .init(id: "browser-preview", title: "Browser dry run", detail: tools.browserDryRunError ?? browser?.url,
                value: tools.browserDryRunStartedAt != nil ? "Running" : tools.browserDryRunError != nil ? "Failed"
                    : browser?.status ?? "No preview in this session",
                at: stamp(tools.browserDryRunStartedAt) ?? (tools.browserDryRunError == nil ? browser?.createdAt : nil),
                tone: tools.browserDryRunStartedAt != nil ? .live : tools.browserDryRunError == nil ? tone(browser?.status) : .failed,
                actions: [.init(id: "browser.open", label: "Run", call: .init("browser.preview"))]),
        ]
        for run in tools.browserStatus?.activeRuns ?? [] {
            rows.append(.init(id: run.id, title: "Browser run", detail: run.url, value: run.status, at: run.createdAt,
                tone: .live, actions: [.init(id: "browser.cancel", label: "Cancel", call: .init("browser.cancel", ["id": .string(run.id)]))]))
        }
        if let receipt = tools.browserStatus?.latestReceipt {
            rows.append(.init(id: "browser-receipt", title: "Latest browser run", detail: receipt.url,
                value: receipt.status, at: receipt.createdAt, tone: tone(receipt.status)))
        }
        for (id, title) in [("export", "Export"), ("support", "Support bundle")] {
            let latest = doctor.productionExports.first { $0.kind == id }
            let work = doctor.productionExportWork.flatMap { $0.support == (id == "support") ? $0.startedAt : nil }
            let failure = doctor.productionExportFailure.flatMap { $0.support == (id == "support") ? $0.detail : nil }
            rows.append(.init(id: id, title: title, detail: failure ?? latest?.path,
                value: work != nil ? "Creating" : failure != nil ? "Failed"
                    : latest.map { $0.sizeBytes.map { "\($0) bytes" } ?? "Size unavailable" }
                        ?? (missingExports ? "Not read" : "No recorded export"),
                at: stamp(work) ?? (failure == nil ? latest?.createdAt : nil),
                tone: work != nil ? .live : failure == nil ? .quiet : .failed,
                actions: [.init(id: "export.bundle", label: title, call: .init("export.bundle", ["support": .bool(id == "support")]))]))
        }
        if let hardening = doctor.productionHardening {
            rows.append(.init(id: "hardening", title: "Release checks", detail: hardening.detail,
                value: hardening.status, at: hardening.createdAt, tone: tone(hardening.status)))
            rows += (hardening.release?.items ?? []).map {
                .init(id: "release:" + $0.id, title: $0.title, detail: $0.detail, value: $0.status, tone: tone($0.status))
            }
        }
        if let receipt = doctor.hardeningRefresh, receipt.isStale {
            rows.append(.init(id: "checks-read", title: "Checks read incomplete",
                detail: receipt.failedEndpoints.joined(separator: ", "), tone: .failed))
        } else if doctor.hardeningRefresh == nil {
            rows.append(.init(id: "checks-unread", title: "Recorded checks and exports have not been read", tone: .quiet))
        }
        return .init(id: "checks", title: "Checks", rows: rows)
    }

    nonisolated private static func stamp(_ date: Date?) -> String? { date.map { ISO8601DateFormatter().string(from: $0) } }

    /// A Mac action's Run keeps the id of the agent's own verb for that action, where it has one; its call is native.run.
    nonisolated static func runActionID(_ action: NativeActionRecord) -> String { ToolNameAliases.appAction(action.id) ?? "native.run" }

    nonisolated static func nativeGate(_ action: NativeActionRecord, fullMac: Bool) -> String? {
        action.requiresApproval != false && !fullMac ? "Approval is required before this action can run. Use Trust to review its access." : nil
    }
}

// MARK: - The verbs the rows call

/// What the Capabilities rows' `connections` verbs run (`NativeAgentEngine.connectionsVerb`): each is the code its row ran, on the record
/// its arguments name as it reads now; a record that moved is refused as stale.
@MainActor
extension CapabilitiesFace {
    /// `capability.check_trust`
    static func checkTrust(_ engine: NativeAgentEngine, id: String) async throws -> String? {
        guard engine.trust.capabilitySummaryError == nil,
              engine.trust.capabilitySummary?.records.contains(where: { $0.id == id }) == true else { throw stale() }
        let result = try await engine.trust.checkCapabilityTrust(id: id)
        return "\(result.name ?? result.id): \(result.trustTier). " + result.reasons.joined(separator: " ")
    }

    /// `connector.dry_run`
    static func connectorDryRun(_ engine: NativeAgentEngine, id: String) async throws -> String? {
        guard let record = engine.connectors.actions?.actions.first(where: { $0.id == id }) else { throw stale() }
        guard record.dryRunAvailable != false else {
            throw PartCallError(code: "dry_run_unavailable", message: "Dry run is unavailable for this connector action.")
        }
        let receipt = try await engine.runConnectorAction(id: id, dryRun: true,
            origin: "mac_ui:connector_action:" + id, platform: engine.ports.connectorActions(engine))
        _ = try await engine.connectors.refreshActions()
        return "\(record.name): \(receipt.status)."
    }

    /// `native.dry_run` and `native.run`: the run is the person's own act on the Mac, behind the action's approval gate.
    static func nativeAction(_ engine: NativeAgentEngine, id: String, dryRun: Bool) async throws -> String? {
        guard let record = engine.tools.nativeActions.first(where: { $0.id == id }) else { throw stale() }
        let receipt = try await engine.tools.runNativeAction(record, dryRun: dryRun, trust: engine.trust, browser: engine.ports.browserRoutes)
        return "\(record.name): \(receipt.status)" + (receipt.detail.map { ": " + $0 } ?? ".")
    }

    /// `improvement.run`
    static func runImprovement(_ engine: NativeAgentEngine) async throws -> String? {
        let run = try await engine.doctor.runImprovementChecks()
        return "Improvement checks: \(run.status)."
    }

    /// `browser.preview`
    static func previewBrowser(_ engine: NativeAgentEngine) async throws -> String? {
        let run = try await engine.tools.previewBrowser(using: engine.ports.browserRoutes)
        return "Browser dry run: \(run.status) · \(run.url ?? "URL unavailable")."
    }

    /// `browser.cancel`
    static func cancelBrowser(_ engine: NativeAgentEngine, id: String) async throws -> String? {
        guard engine.tools.browserStatus?.activeRuns?.contains(where: { $0.id == id }) == true else { throw stale() }
        let run = try await engine.ports.browserRoutes.cancelBrowserRun(id: id, dataRoot: engine.dataRoot)
        _ = await engine.tools.refreshNativePower()
        return "Browser run: \(run.status)."
    }

    /// `tools.refresh`
    static func refreshTools(_ engine: NativeAgentEngine) async throws -> String? {
        _ = try await engine.tools.loadCatalog()
        return "The tools were read again."
    }

    /// `skill.build`: chat opens on the Mac with the request started in the message box.
    static func buildSkill(_ engine: NativeAgentEngine) async throws -> String? {
        try await host(engine).buildSkillInChat()
    }

    /// `sense.switch` on the version the row showed. Turning a sense on is always the person's decision (the door admits nothing else).
    /// Turning one off is the person's when they did it, and the registry then records an owner's off that the agent cannot turn back
    /// on; the agent's own off is recorded as its own.
    static func switchSense(id: String, version: Int?, on: Bool?, byPerson: Bool) async throws -> String? {
        guard let on else { throw PartCallError(code: "bad_value", message: "A sense switch takes on or off; nothing changed.") }
        let (registry, record) = try await sense(id, version: version)
        guard record.status != .draft else {
            throw PartCallError(code: "not_ready", message: "This sense is not ready yet; nothing changed.")
        }
        let saved = try await registry.setStatus(id: record.id, version: record.version, status: on ? .on : .off,
            ownerAuthorized: on || byPerson, turn: nil)
        return saved.corner.surfaceName + " is " + (saved.status == .on ? "on" : saved.status == .off ? "off" : saved.status.rawValue) + "."
    }

    /// `sense.share`: the sense version goes to a file the person chooses in the Mac's save panel.
    static func shareSense(_ engine: NativeAgentEngine, id: String, version: Int?) async throws -> String? {
        let (registry, record) = try await sense(id, version: version)
        guard record.language != .native else {
            throw PartCallError(code: "not_shareable", message: "Built-in native code cannot be shared as a portable sense.")
        }
        guard let destination = try await host(engine).chooseSenseDestination(name: record.id + ".sense.json") else {
            return "No place was chosen; nothing was shared."
        }
        _ = try await registry.exportBundle(id: record.id, to: destination, userApproved: true)
        return "Shared " + record.corner.surfaceName + " to " + destination.path + "."
    }

    /// The registry and the exact sense version the call names, read now; a version that moved is refused as stale.
    private static func sense(_ id: String, version: Int?) async throws -> (FileSenseRegistry, SenseRecord) {
        guard let version else { throw stale() }
        guard let registry = SensesHub.shared.registry else {
            throw PartCallError(code: "senses_unavailable", message: "Senses are not connected yet; nothing changed.")
        }
        guard let record = try await SensesHub.shared.presentationRecords().0.first(where: { $0.id == id && $0.version == version }) else {
            throw stale()
        }
        return (registry, record)
    }

    /// `ability.keep`: approve the exact version the row's fold showed; it reads back through the registry before answering.
    static func keepAbility(_ engine: NativeAgentEngine, id: String, version seen: String?) async throws -> String? {
        let tools = engine.tools
        guard let tool = tools.authored.first(where: { $0.id == id }), tool.reviewedKeepDigest == seen else { throw stale() }
        if let refusal = tools.keepRefusal(tool, turn: nil) { throw PartCallError(code: "keep_refused", message: refusal) }
        let version = tool.reviewedKeepDigest
        guard version != nil || (tool.candidateDigest ?? tool.codeFingerprint) == nil
            && tool.activePath.map({ URL(fileURLWithPath: $0).pathExtension == "md" }) == true else {
            throw PartCallError(code: "version_unread", message: "Read Capabilities again before approving this ability.")
        }
        let updated = try await tools.keep(id: tool.id, version: version)
        guard try await tools.refreshAuthored(confirming: updated.id, status: "active") else {
            throw PartCallError(code: "unconfirmed", message: "Approving \(tool.name) could not be confirmed after reading it again.")
        }
        return tool.name + " is approved and on."
    }

    /// `ability.off`: the person's off, which stays off until the person turns it on; it reads back through the registry before answering.
    static func switchOffAbility(_ engine: NativeAgentEngine, id: String) async throws -> String? {
        let tools = engine.tools
        guard let tool = tools.authored.first(where: { $0.id == id }) else { throw stale() }
        let updated = try await tools.switchOff(id: tool.id, reason: "Owner switched off from NativeAgent UI.")
        guard try await tools.refreshAuthored(confirming: updated.id, status: "disabled") else {
            throw PartCallError(code: "unconfirmed", message: "Turning \(tool.name) off could not be confirmed after reading it again.")
        }
        return tool.name + " is off."
    }

    private static func host(_ engine: NativeAgentEngine) throws -> any CapabilitiesFaceHost {
        guard let host = engine.ports.appTools(SwiftNativeSecurityCenter(dataRoot: engine.dataRoot), false).quietHost() as? any CapabilitiesFaceHost else {
            throw PartCallError(code: "unavailable", message: "The Mac's Capabilities controls are unavailable; nothing was done.")
        }
        return host
    }

    private static func stale() -> PartCallError {
        .init(code: "stale_action", message: "This capability action is no longer available. Read Capabilities again before acting.")
    }
}
