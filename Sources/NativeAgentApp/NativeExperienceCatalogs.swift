import Foundation
import NativeAgentCore
import PersistenceCore

enum NativeExperienceCatalogs {
    static let blueprints: [ExperienceAutomationBlueprint] = [
        .init(
            id: .morningBriefing,
            title: "Morning briefing",
            summary: "Prepare a concise, evidence-backed view of today's calendar, open work, and important messages.",
            kind: "workshop",
            schedule: ["type": .string("daily"), "at": .string("08:00")],
            payload: workshopPayload(
                title: "Morning briefing",
                objective: "Prepare today's concise briefing from canonical calendar, inbox, project, and Desk state. Cite the evidence used, identify unknowns, and surface the completed report in NativeAgent without sending externally unless separately approved.",
                evidence: "Desk execution receipt plus cited source timestamps"
            ),
            modelLabel: "Desk execution route",
            estimatedCost: "One bounded Desk run",
            requiredTools: ["mac_calendar_list_upcoming", "mail_list_recent", "workshop_status"],
            delivery: ["inbox"],
            trustImplications: "Read-only sources; external delivery remains separately approval-gated.",
            expectedEvidence: "Desk execution receipt and source timestamps"
        ),
        .init(
            id: .projectStatus,
            title: "Project status check",
            summary: "Review a saved project's branch, dirty state, recent work, and open Desk outcomes.",
            kind: "workshop",
            schedule: ["type": .string("daily"), "at": .string("17:00")],
            payload: workshopPayload(
                title: "Project status check",
                objective: "Review the selected saved project using read-only Git, file, and Desk evidence. Summarize branch, dirty state, recent completed work, blockers, and the next verified action. Do not commit, push, initialize Git, or modify files.",
                evidence: "Git status/log reads and canonical Desk records"
            ),
            modelLabel: "Desk execution route",
            estimatedCost: "One bounded Desk run",
            requiredTools: ["git_status", "git_log", "workshop_status"],
            delivery: ["inbox"],
            trustImplications: "Read-only project inspection; no implicit Git mutation.",
            expectedEvidence: "Git and Desk read receipts"
        ),
        .init(
            id: .repositoryMaintenance,
            title: "Repository maintenance",
            summary: "Inspect a saved repository for safe cleanup or reliability work and stage one verified proposal.",
            kind: "workshop",
            schedule: ["type": .string("weekly"), "weekday": .int(6), "at": .string("10:00")],
            payload: workshopPayload(
                title: "Repository maintenance",
                objective: "Inspect the selected repository for one high-value maintenance improvement. Work only through existing Desk and TrustCenter boundaries, use a worktree for mutations, run proportionate tests, and stop before commit, push, install, restart, or release unless those effects are separately authorized.",
                evidence: "Worktree diff, test receipt, and Desk terminal verification"
            ),
            modelLabel: "Desk execution route",
            estimatedCost: "One planning run plus task execution",
            requiredTools: ["git_status", "git_diff", "apply_patch", "run_tests"],
            delivery: ["inbox"],
            trustImplications: "Workspace mutations obey Desk and TrustCenter; publishing remains excluded.",
            expectedEvidence: "Bounded diff and passing test receipts"
        ),
        .init(
            id: .calendarPreparation,
            title: "Calendar preparation",
            summary: "Prepare context for upcoming events without modifying the calendar.",
            kind: "workshop",
            schedule: ["type": .string("every"), "interval_seconds": .int(10_800)],
            payload: workshopPayload(
                title: "Calendar preparation",
                objective: "Read upcoming calendar events and prepare short context cards for events needing attention. Do not add, edit, delete, or message anyone. Surface only evidence-backed preparation in NativeAgent.",
                evidence: "Calendar read receipt and event identifiers"
            ),
            modelLabel: "Desk execution route",
            estimatedCost: "At most one bounded run per 3 hours",
            requiredTools: ["mac_calendar_list_upcoming"],
            delivery: ["inbox"],
            trustImplications: "Calendar read permission is required; writes remain unavailable.",
            expectedEvidence: "Calendar event identifiers and read timestamp"
        ),
        .init(
            id: .serviceWatch,
            title: "Watch a webpage or service",
            summary: "Run the existing evidence-producing proactive scan and surface only changed conditions.",
            kind: "proactive_scan",
            schedule: ["type": .string("every"), "interval_seconds": .int(3_600)],
            payload: [
                "reason": .string("experience_service_watch"),
                "limit": .int(10),
                "surfaceLimit": .int(4),
                "sources": .array([.string("saved_workspaces"), .string("connectors")]),
            ],
            modelLabel: "Existing proactive scan",
            estimatedCost: "Uses the canonical scan policy",
            requiredTools: ["browser.status"],
            delivery: ["inbox"],
            trustImplications: "Only configured, verified routes are eligible.",
            expectedEvidence: "Proactive-scan item IDs or an explicit no-change receipt"
        ),
        .init(
            id: .weeklyMemoryReview,
            title: "Weekly memory review",
            summary: "Review pending memory and skill changes through their existing proposal owners.",
            kind: "workshop",
            schedule: ["type": .string("weekly"), "weekday": .int(0), "at": .string("16:00")],
            payload: workshopPayload(
                title: "Weekly memory review",
                objective: "Review pending MemoryV2 proposals, recent retained facts, skill evolution evidence, and Dream/REM proposals. Recommend approve, reject, consolidate, archive, or keep watching, but do not mutate canonical memory or skills without the user's explicit selection.",
                evidence: "Memory proposal IDs, skill version IDs, and Dream/REM receipt IDs"
            ),
            modelLabel: "Desk execution route",
            estimatedCost: "One bounded weekly review",
            requiredTools: ["recall_search", "list_skills", "read_skill"],
            delivery: ["inbox"],
            trustImplications: "Review-only; canonical changes stay proposal/user controlled.",
            expectedEvidence: "Canonical proposal and version identifiers"
        ),
        .init(
            id: .deliveredReport,
            title: "Deliver a report",
            summary: "Prepare a verified report and route any external delivery through the ordinary send approval boundary.",
            kind: "workshop",
            schedule: ["type": .string("weekly"), "weekday": .int(5), "at": .string("15:00")],
            payload: workshopPayload(
                title: "Weekly report",
                objective: "Prepare an evidence-backed weekly report from canonical project, Desk, and activity state. Save the report in NativeAgent and, only if an existing approved delivery destination is configured and effect-time policy authorizes it, deliver through that canonical connector. Otherwise leave a ready-to-review report and explain what authorization is missing.",
                evidence: "Saved report checksum, Desk receipt, and connector settlement if sent",
                delivery: ["inbox", "telegram"]
            ),
            modelLabel: "Desk execution route",
            estimatedCost: "One bounded weekly synthesis",
            requiredTools: ["workshop_status", "list_dir", "write_file"],
            delivery: ["inbox", "telegram"],
            trustImplications: "External delivery requires the existing explicit-send approval and settlement receipt.",
            expectedEvidence: "Report checksum and domain delivery settlement"
        ),
    ]

    static let kits: [ExperienceCapabilityKit] = [
        .init(
            id: "research",
            title: "Research",
            summary: "Search, browse, read sources, and preserve citations.",
            systemImage: "magnifyingglass",
            toolNames: ["browser.status", "browser.open_url", "browser.read_text", "browser.read_links", "read_file", "write_file"],
            destinations: [.skills, .connectors]
        ),
        .init(
            id: "building",
            title: "Building",
            summary: "Files, Git, patches, builds, tests, Desk execution, and verification.",
            systemImage: "hammer",
            toolNames: ["read_file", "write_file", "list_dir", "apply_patch", "git_status", "git_diff", "git_log", "run_tests", "swift_build", "swift_test", "workshop_status"],
            destinations: [.desk, .skills]
        ),
        .init(
            id: "personal-admin",
            title: "Personal administration",
            summary: "Calendar, reminders, contacts, mail, and notifications under Mac permissions.",
            systemImage: "macbook.and.iphone",
            toolNames: ["mac_calendar_list_upcoming", "mac_reminders_list_due_today", "contacts_search", "mail_list_recent", "mac_notify", "mobile_notify"],
            destinations: [.macIntegration, .trust]
        ),
        .init(
            id: "travel",
            title: "Travel planning",
            summary: "Research, calendar context, files, and approved communication.",
            systemImage: "airplane",
            toolNames: ["browser.status", "browser.open_url", "browser.read_text", "mac_calendar_list_upcoming", "read_file", "write_file"],
            destinations: [.skills, .macIntegration]
        ),
        .init(
            id: "content",
            title: "Content creation",
            summary: "Research, drafting, images, files, and review.",
            systemImage: "paintbrush",
            toolNames: ["browser.status", "browser.open_url", "browser.read_text", "image_generate", "read_file", "write_file", "list_dir"],
            destinations: [.skills, .desk]
        ),
        .init(
            id: "home-operations",
            title: "Home operations",
            summary: "Reminders, schedules, notifications, and bounded recurring work.",
            systemImage: "house",
            toolNames: ["mac_reminders_list_due_today", "scheduler_list_jobs", "scheduler_create_job", "mac_notify", "mobile_notify"],
            destinations: [.macIntegration, .desk]
        ),
    ]

    static func schedulerBody(
        for blueprint: ExperienceAutomationBlueprint,
        projectSpaceId: String? = nil
    ) -> [String: JSONValue] {
        var payload = blueprint.payload
        payload["blueprintId"] = .string(blueprint.id.rawValue)
        payload["blueprintVersion"] = .int(1)
        if let projectSpaceId, !projectSpaceId.isEmpty {
            payload["projectSpaceId"] = .string(projectSpaceId)
        }
        return [
            "id": .string("native-experience-\(blueprint.id.rawValue)"),
            "name": .string(blueprint.title),
            "kind": .string(blueprint.kind),
            "schedule": .object(blueprint.schedule),
            "payload": .object(payload),
            "createdBy": .string("user_blueprint"),
        ]
    }

    private static func workshopPayload(
        title: String,
        objective: String,
        evidence: String,
        delivery: [String] = ["inbox"]
    ) -> [String: JSONValue] {
        [
            "title": .string(title),
            "objective": .string(objective),
            "expectedEvidence": .string(evidence),
            "delivery": .array(delivery.map(JSONValue.string)),
        ]
    }
}
