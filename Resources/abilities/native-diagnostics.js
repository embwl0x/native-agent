/* NativeAgent ability
{
  "id":"native-diagnostics", "kind":"ability", "version":1,
  "reach":{"capabilities":[],"readPaths":[],"hosts":[],"apps":[]},
  "face":{"projection":true},
  "record":{
    "description":"My Diagnostics page from Doctor's measured verdicts, and my words for Desk and Activity checks, Doctor asks, storage and speech cards.",
    "actions":[], "inputSchema":{"type":"object","readOnly":true,"properties":{},"additionalProperties":true}
  }
}
*/
function labels(group) {
    return group.aliases.slice(0, 5).map(alias => "#" + alias).join(", ") +
        (group.count > 5 ? " and " + (group.count - 5) + " more" : "");
}
function run(input) {
    if (input.kind === "desk") {
        const waiting = input.waiting, blocked = input.blocked, contradictions = input.contradictions;
        if (input.pendingApprovals === 0 && waiting.count === 0 && blocked.count === 0 && contradictions.count === 0) {
            return {detail: "No blocked Desk work, owner decision, or terminal-parent contradiction.", humanAction: null};
        }
        const parts = [], actions = [];
        if (waiting.count > 0) {
            parts.push(waiting.count + " item(s) wait on your decision: " + labels(waiting));
            actions.push("open Desk and decide items " + labels(waiting) + " marked waiting on you");
        }
        if (input.pendingApprovals > 0) {
            parts.push(input.pendingApprovals + " pending approval(s) wait for your decision");
            actions.push("open Approvals and decide the " + input.pendingApprovals + " pending request(s)");
        }
        if (blocked.count > 0) {
            const reasons = blocked.items.slice(0, 5).map(item => "#" + item.alias + ": " + item.reason).join("; ") +
                (blocked.count > 5 ? "; and " + (blocked.count - 5) + " more" : "");
            parts.push(blocked.count + " blocked item(s): " + reasons);
            actions.push("open Desk and resolve " + labels(blocked) +
                " using each recorded blocked reason or waiting party, clarifying the block there if neither is recorded");
        }
        if (contradictions.count > 0) {
            parts.push(contradictions.count + " terminal parent(s) contain open descendants: " + labels(contradictions));
            actions.push("press Repair in Diagnostics → Health checks to reconcile terminal parents " + labels(contradictions));
        }
        return {detail: parts.join("; ") + ".", humanAction: "For the named work, " + actions.join("; ") + "."};
    }
    if (input.kind === "activity") {
        const partial = input.malformedCount > 0
            ? "Activity log " + (input.recordCount === 0 ? "unreadable" : "partially readable") + ": " + input.malformedCount +
                " malformed row(s) in its bounded tail; " : "";
        const titles = input.recent.slice().sort((a, b) => a.createdAt === b.createdAt ? 0 : a.createdAt > b.createdAt ? -1 : 1)
            .slice(0, 3).map(row => row.title).join("; ");
        return {detail: partial + input.reconciliationCount + " outcome(s) need reconciliation; " + input.failureCount +
            " historical failure receipt(s) in the last 15 minutes of the retained activity tail" +
            (titles.length === 0 ? "" : "; latest: " + titles) + ".", humanAction: null};
    }
    if (input.kind === "doctor") {
        const asks = [...new Set(input.asks.map(row => "• " + row.title + ": " + row.action))].sort();
        return {title: asks.length === 1 ? "Doctor needs one thing from you" : "Doctor needs " + asks.length + " things from you",
            summary: "Sign-ins and permissions Doctor cannot do itself.", detail: asks.join("\n")};
    }
    if (input.kind === "storage") {
        const lines = [
            "Measured dynamic storage: " + input.dynamicSize + " / " + input.budgetSize + " budget (includes backups and derived data).",
            "Required embedding model: " + input.modelSize + ", outside that budget."
        ];
        input.usage.slice().sort((a, b) => b.bytes - a.bytes).filter(row => row.bytes > 0).forEach(row => {
            lines.push("• " + row.owner + ": " + row.size + "; reclaimable " + row.reclaimSize + ". " +
                (row.policy === null ? "Kept: app state without a recoverable cleanup policy." : row.policy));
        });
        input.plans.forEach(plan => lines.push(...plan.notes));
        input.planReads.filter(row => row.status === "unavailable").forEach(row => lines.push(row.owner + " kept: " + row.error));
        if (input.accounting.status === "partial") {
            lines.push("Storage accounting is incomplete; usage may be undercounted or required assets unclassified. " +
                "Cleanup amounts come from complete owner plans.");
        }
        lines.push(input.reclaimable > 0
            ? "Clean Up will move " + input.reclaimSize + " out of app storage to Trash, recoverably. Disk space remains occupied until you empty the Trash."
            : "Nothing is safely reclaimable. All storage above is kept for the reasons shown; no Clean Up is offered.");
        return {title: "Disk usage is piling up", summary: "Dynamic storage " + input.dynamicSize + "; reclaimable " + input.reclaimSize,
            detail: lines.join("\n")};
    }
    if (input.kind === "speech") {
        return {title: "Speech Recognition is not approved", summary: input.warningSummary,
            detail: "A Telegram voice note could not be transcribed because macOS Speech Recognition is not approved for NativeAgent " +
                "(current state: " + input.permission + ").\n\n" +
                input.warningSummary + "\n\nTwo ways to fix it:\n" +
                "• In NativeAgent: Trust → macOS grants → Speech Recognition → Ask macOS.\n" +
                "• In macOS: open System Settings → Privacy & Security → Speech Recognition and switch NativeAgent on." +
                (input.settingsLink === null ? "" : "\n\nDirect link: " + input.settingsLink) +
                "\n\nUntil then, inbound voice notes will keep replying with the permission notice instead of a transcript."};
    }
    throw new Error("Unknown diagnostics input kind: " + input.kind);
}

// A status reads by the stem's bucket for it: running work is live, queued work and readings are quiet.
function tone(status, bucket) {
    const word = status.toLowerCase();
    if (word === "running" || word === "active") return "live";
    if (word === "queued" || word === "pending" || word === "info") return "quiet";
    if (bucket === "healthy") return "done";
    if (bucket === "failing") return "failed";
    if (bucket === "off" || bucket === "not needed") return "quiet";
    return "attention";
}

// Counts of the stem's per-check buckets, and the one word they add up to.
function summarize(checks) {
    const s = {healthy: 0, warning: 0, failing: 0, unclear: 0, reading: 0, off: 0, notNeeded: 0};
    for (const check of checks) {
        if (check.bucket === "healthy") s.healthy++;
        else if (check.bucket === "warning") s.warning++;
        else if (check.bucket === "failing") s.failing++;
        else if (check.bucket === "off") s.off++;
        else if (check.bucket === "not needed") s.notNeeded++;
        else if (check.bucket === "reading") s.reading++;
        else s.unclear++;
    }
    s.total = s.healthy + s.warning + s.failing + s.unclear + s.reading + s.off + s.notNeeded;
    s.status = s.failing > 0 ? "failed" : s.warning > 0 ? "warn" : s.total === 0 || s.unclear > 0 ? "unknown"
        : s.reading > 0 ? "info" : "ok";
    s.tone = {failed: "failed", warn: "attention", unknown: "attention", info: "quiet", ok: "done"}[s.status];
    return s;
}

function headline(s) {
    if (s.total === 0) return "No checks have run yet.";
    if (s.failing > 0) return "Some parts of the app are not working.";
    if (s.warning > 0) return "The app is running, but some parts need attention.";
    if (s.unclear > 0) return "The app is running. Some checks came back unclear.";
    if (s.reading > 0) return "The app is running. Some checks are readings.";
    // Inactive parts cannot establish the health of everything.
    const inactive = [[s.off, "off"], [s.notNeeded, "not needed"]].filter(p => p[0] > 0).map(p => p[0] + " " + p[1]);
    return inactive.length === 0 ? "Everything looks healthy." : "Healthy; " + inactive.join(", ") + ".";
}

function summaryDetail(s) {
    if (s.total === 0) return "Press Repair to check everything and fix what is broken.";
    const parts = [s.healthy + " working"];
    if (s.warning > 0) parts.push(s.warning + " need attention");
    if (s.failing > 0) parts.push(s.failing + " not working");
    if (s.unclear > 0) parts.push(s.unclear + " unclear");
    if (s.reading > 0) parts.push(s.reading + " readings");
    if (s.off > 0) parts.push(s.off + " off");
    if (s.notNeeded > 0) parts.push(s.notNeeded + " not needed");
    return (s.total === 1 ? "1 area checked" : s.total + " areas checked") + ": " + parts.join(", ") + ".";
}

function counts(s) {
    return [[s.healthy, "ok"], [s.warning, "warn"], [s.failing, "failed"], [s.off, "off"], [s.notNeeded, "not needed"],
        [s.reading, "readings"], [s.unclear, "unclear"]].filter(p => p[0] > 0).map(p => p[0] + " " + p[1]).join(", ");
}

// Where a check belongs on the page, in the order the groups read.
const groups = [
    ["Provider", "AI provider", ["codex_login", "llm", "codex_login_helper", "live.providers"]],
    ["Runtime", "The app itself", ["live.background_loops", "live.bridges", "prompt_prefix_health", "model.shims"]],
    ["Cognition", "Inner state", ["subconscious_vitals"]],
    ["Connectors", "Connected services", ["searxng", "telegram", "connectors", "live.telegram", "live.search"]],
    ["Data", "Your data", ["storage", "chat_sessions", "session_identity", "persona_engine", "backups", "write_test", "live.memory"]],
    ["Tools", "Tools", ["tools", "live.tools"]],
    ["Autonomy", "Actions I take on my own", ["autonomy", "live.autonomy"]],
    ["Release", "Stored data health", null]
];
function group(checkID) {
    const found = groups.find(g => g[2] !== null && g[2].includes(checkID));
    return found ? found[0] : "Release";
}

// A time the stem could not read is named beside the detail rather than dropped.
function dated(detail, at, readable) {
    if (readable) return detail === null ? undefined : detail;
    const evidence = at === "" ? "Time was not recorded." : "Unreadable time: " + at;
    return detail === null ? evidence : detail + "\n" + evidence;
}

// A run's recorded status in words; an unknown word stays visibly distinct.
function runBadge(raw) {
    const trimmed = raw.trim();
    const key = trimmed.toLowerCase().split("-").join("_").split(" ").join("_");
    const table = {
        succeeded: ["Succeeded", "done"], completed: ["Succeeded", "done"], done: ["Succeeded", "done"],
        queued: ["Queued", "quiet"], pending: ["Queued", "quiet"],
        running: ["Running", "live"], active: ["Running", "live"],
        failed: ["Failed", "failed"], failed_pre_dispatch: ["Failed", "failed"],
        partial: ["Partially completed", "attention"],
        timeout: ["Timed out", "failed"], timed_out: ["Timed out", "failed"],
        stopped: ["Stopped", "attention"], canceled: ["Stopped", "attention"], cancelled: ["Stopped", "attention"],
        interrupted: ["Interrupted", "attention"],
        blocked: ["Blocked", "attention"],
        waiting_approval: ["Waiting for approval", "attention"],
        rolled_back: ["Rolled back", "attention"],
        skipped: ["Skipped", "attention"],
        disabled: ["Disabled", "attention"],
        unknown: ["Outcome unknown", "attention"],
        "": ["Status unavailable", "attention"]
    };
    if (Object.prototype.hasOwnProperty.call(table, key)) return {label: table[key][0], tone: table[key][1]};
    const words = trimmed === "" ? "(missing)" : trimmed.split(/\s+/).join(" ");
    const points = Array.from(words);
    return {label: "Unrecognized status: " + (points.length > 80 ? points.slice(0, 80).join("") + "…" : words), tone: "attention"};
}

function runKind(kind) {
    const word = kind.toLowerCase();
    if (word === "codex") return {name: "Codex", symbol: "terminal"};
    if (word === "claude") return {name: "Claude Code", symbol: "sparkles"};
    return {name: "Other run", symbol: undefined};
}

function duration(seconds) {
    if (!Number.isFinite(seconds) || seconds < 0) return "";
    if (seconds < 10) {
        // An exact tie rounds to even, as the stem's formatter does.
        const quarters = seconds * 4;
        if (Number.isInteger(quarters) && quarters % 2 === 1) {
            const tenths = Math.floor(seconds * 10);
            return ((tenths % 2 === 0 ? tenths : tenths + 1) / 10).toFixed(1) + "s";
        }
        return seconds.toFixed(1) + "s";
    }
    const total = Math.round(seconds);
    if (total >= 9223372036854775807) return "";
    if (total < 60) return total + "s";
    if (total < 3600) {
        const s = total % 60;
        return s === 0 ? Math.floor(total / 60) + "m" : Math.floor(total / 60) + "m " + s + "s";
    }
    const m = Math.floor((total % 3600) / 60);
    return m === 0 ? Math.floor(total / 3600) + "h" : Math.floor(total / 3600) + "h " + m + "m";
}

function face(input) {
    const doctor = input.doctor, keys = input.keys || {};
    const issue = doctor.reportIssue === null ? undefined : doctor.reportIssue;
    const checks = doctor.checks || [];
    const summary = summarize(checks);
    const line = doctor.running ? "Running health checks." : doctor.runFailure !== null ? doctor.runFailure : headline(summary);
    const sections = [{id: "doctor", style: "list", footer: issue !== undefined ? issue : summaryDetail(summary), rows: [{
        id: "doctor", title: "Health checks", value: issue === undefined ? summary.status : "unavailable",
        at: doctor.completedAt === null ? undefined : doctor.completedAt,
        tone: doctor.running ? "live" : doctor.runFailure === null ? summary.tone : "attention",
        actions: doctor.running ? [] : [
            {id: "doctor.run", label: "Run checks"},
            {id: "doctor.repair", label: "Repair safe issues"},
            {id: "doctor.support_report", label: "Support report"}
        ]
    }]}];
    if (doctor.running) {
        sections.push({id: "running", title: "Running health checks", style: "waiting", rows: [{
            id: "doctor.running", title: "Running health checks", detail: doctor.runStartedAt === null
                ? "The run's start time is unavailable. Retained checks are not current until it finishes."
                : "Retained checks are not current until this run finishes.",
            at: doctor.runStartedAt === null ? undefined : doctor.runStartedAt, tone: "live"
        }]});
    }

    // Readings are counted in Checks; only what is wrong or about to be stands in Needs attention.
    let attention = checks.filter(c => ["warning", "failing", "unclear"].includes(c.bucket)).map(c => {
        const key = keys[c.id];
        const repair = key !== undefined && (key.actions || []).some(a => a.id === "doctor.repair");
        return {id: c.id, title: c.title,
            detail: [c.detail, c.adverse ? c.harm : null, c.recovery, c.receipt].filter(t => t !== null && t !== "").join("\n"),
            value: c.status, tone: tone(c.status, c.bucket), open: key !== undefined ? key.open : undefined,
            actions: repair ? [{id: "doctor.repair", label: "Repair"}] : undefined};
    });
    if (attention.length === 0) {
        attention = [{id: "attention.empty", title: summary.total === 0 ? "No measured checks yet" : "No measured checks need attention",
            detail: issue !== undefined ? issue : summary.total === 0 ? "Run checks to read this Mac's health." : undefined,
            tone: issue === undefined && summary.total > 0 ? "quiet" : "attention"}];
    }
    sections.push({id: "attention", title: "Needs attention", style: "list", footer: issue, rows: attention});

    let background = input.loops.filter(l => l.fault).map(l => ({id: "loop." + l.loopId, title: l.name, detail: l.detail,
        value: l.status, tone: tone(l.status, l.bucket)}));
    for (const c of checks) {
        if (!["background_loops", "live.background_loops"].includes(c.checkID)) continue;
        if (["healthy", "off", "not needed"].includes(c.bucket)) continue;
        background.push({id: "background.check." + c.id, title: c.title, detail: c.detail, value: c.status, tone: tone(c.status, c.bucket)});
    }
    const watchdog = input.watchdog;
    if (watchdog !== null && watchdog.status !== "ok") {
        background.push({id: "background.runtime", title: "Background scheduling", detail: watchdog.detail, value: watchdog.status,
            tone: tone(watchdog.badge, watchdog.badgeBucket)});
    }
    // What is healthy folds under one row at the end of Checks, so what needs attention reads first.
    const healthy = [];
    if (background.length === 0) {
        if (input.loops.length === 0) {
            background = [{id: "background.unmeasured", title: "Background work has not been measured", tone: "attention"}];
        } else if (input.loops.some(l => l.ok)) {
            healthy.push({id: "background.healthy", title: issue === undefined
                ? "All background work is healthy" : "Last measured background work was healthy",
                detail: "Off and unneeded work is excluded from this health verdict.", tone: "done"});
        } else {
            background = [{id: "background.inactive", title: "Background work is off or not needed", tone: "quiet"}];
        }
    }
    if (background.length > 0) sections.push({id: "background", title: "Background work", style: "list", footer: issue, rows: background});

    const grouped = groups.map(g => [g, checks.filter(c => group(c.checkID) === g[0])]).filter(p => p[1].length > 0).map(p => {
        const s = summarize(p[1]);
        return {id: "checks." + p[0][0], title: p[0][1], value: counts(s), tone: s.tone};
    });
    healthy.unshift(...grouped.filter(row => row.tone === "done"));
    const checkRows = grouped.length === 0 ? [{id: "checks.empty", title: "No measured checks yet", tone: "attention"}]
        : grouped.filter(row => row.tone !== "done");
    if (healthy.length > 0) {
        checkRows.push({id: "checks.healthy", title: "Nothing else needs attention", value: String(healthy.length), tone: "done", rows: healthy});
    }
    sections.push({id: "checks", title: "Checks", style: "values", footer: issue, rows: checkRows});

    const mac = [];
    if (input.mac !== null) {
        mac.push({id: "mac.version", title: "Version", value: input.mac.version},
            {id: "mac.started", title: "Running since", at: input.mac.startedAt},
            {id: "mac.data", title: "Data folder", value: input.mac.dataDir});
    } else {
        mac.push({id: "mac.unmeasured", title: "This Mac has not published its status", tone: "attention"});
    }
    mac.push({id: "mac.runs", title: "Runs", value: input.runs.read === true ? String(input.runs.count) : "Unavailable"});
    mac.push({id: "mac.sessions", title: "Sessions", detail: input.sessions.error === null ? undefined : input.sessions.error,
        value: input.sessions.error === null ? input.sessions.count + " loaded" : "Unavailable"});
    sections.push({id: "mac", title: "This Mac", style: "values", rows: mac});

    const living = input.living, snapshot = living.snapshot;
    const livingRows = snapshot !== null ? [
        {id: "living.posture", title: "Posture", value: snapshot.posture, tone: tone(snapshot.postureStatus, snapshot.postureBucket)},
        {id: "living.body", title: "Body", value: snapshot.bodyState},
        {id: "living.behavior", title: "Behavior", value: snapshot.behaviorLine},
        {id: "living.desk", title: "Desk", value: snapshot.deskSummary},
        {id: "living.approvals", title: "Approvals", value: snapshot.approvalsSummary},
        {id: "living.dream", title: "Dream", value: snapshot.lastDreamSummary}
    ] : [{id: "living.unmeasured", title: "Living status is unavailable", tone: "attention"}];
    const notices = [];
    if (living.failedEndpoints !== null && living.failedEndpoints.length > 0) {
        notices.push("Current state could not be read: " + living.failedEndpoints.join(", ")
            + (snapshot !== null ? ". Showing the last known state." : "."));
    }
    if (living.watchUnavailable !== null) notices.push("Live status updates are unavailable: " + living.watchUnavailable);
    sections.push({id: "living", title: "Living status", style: "values",
        footer: notices.length === 0 ? undefined : notices.join("\n"), rows: livingRows});

    const activity = input.activity;
    let events = activity.tail.slice().reverse().map(e => ({id: "activity." + e.id, title: e.title,
        detail: dated(e.detail, e.createdAt, e.timeReadable), value: e.status, at: e.createdAt, tone: tone(e.status, e.bucket)}));
    if (events.length === 0) {
        events = [{id: "activity.empty", title: activity.failed ? "Recent activity is unavailable"
            : activity.refreshed ? "No activity recorded yet" : "Recent activity has not been read", tone: "quiet"}];
    }
    sections.push({id: "activity", title: "Recent activity", style: "timeline",
        footer: activity.failed ? "The activity log could not refresh. Any displayed events are the last loaded reading." : undefined, rows: events});

    const runs = input.runs;
    let runRows = runs.recent.map(r => {
        const badge = runBadge(r.status), kind = runKind(r.kind);
        // A run with no model simply used none; its row says how long it took and, when it did not finish, why.
        const took = r.durationSeconds !== null ? duration(r.durationSeconds) : "Duration unavailable";
        const words = [r.model !== null && r.model !== "" ? r.model : null, took,
            r.cause !== undefined && r.cause !== null && r.cause !== "" ? r.cause : null].filter(w => w !== null).join(" · ");
        return {id: r.id, title: typeof r.name === "string" && r.name !== "" ? r.name : kind.name,
            detail: dated(words, r.createdAt, r.timeReadable), value: badge.label,
            at: r.createdAt, symbol: kind.symbol, tone: badge.tone, open: keys[r.id] !== undefined ? keys[r.id].open : undefined};
    });
    if (runRows.length === 0) {
        runRows = [{id: "runs.empty", title: runs.read === false ? "Run history is unavailable"
            : runs.read === null ? "Run history has not been read" : "No runs recorded yet", tone: "quiet"}];
    }
    sections.push({id: "runs", title: "Runs", style: "timeline",
        footer: runs.read === false ? "The run history could not refresh. Any displayed runs are the last loaded reading." : undefined, rows: runRows});

    return {title: "Diagnostics", line, sections};
}
