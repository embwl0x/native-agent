/* NativeAgent ability
{
  "id": "desk-notify",
  "kind": "tool",
  "version": 1,
  "reach": {"capabilities": [], "readPaths": [], "hosts": [], "apps": []},
  "face": {"page": "desk"},
  "record": {
    "description": "My Desk interruption policy: changed work, earned nudges, quiet-window drift and exact deadlines. Returns proposals; the Desk owns consent, publication and its ledger.",
    "actions": [],
    "inputSchema": {"type": "object"}
  }
}
*/
// CPU only, no wake and no store access. The stem supplies one complete read;
// it commits this decision against that read before delivering anything.
function run(input) {
    if (input.availability !== "ready") throw new Error("Desk notification sources are unavailable.");
    const items = input.items, facts = input.facts, config = input.config, now = input.now;
    const byHandle = Object.fromEntries(items.map(i => [i.handle, i]));
    const result = {notifications: [], nags: [], digest: [], consume: [], openWindow: false, deadline: null, digestTitle: "Desk · back on", digestBody: ""};
    const terminal = i => i.status === "done" || i.status === "canceled";
    // Foundation's whitespacesAndNewlines (not JS trim's BOM/next-line set).
    const clean = s => typeof s === "string" ? s.replace(/^[\u0009-\u000d\u0020\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+|[\u0009-\u000d\u0020\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+$/g, "") : "";
    const filters = i => [...new Set((i.notify.on || []).map(s => clean(s).toLowerCase()).filter(Boolean))];
    const explicit = i => { const f = filters(i); return f.length === 1 && f[0] === "explicit"; };
    const cooldown = (i, inherited) => (inherited ? inherited.cooldown : facts[i.handle].cooldown) ?? 1800;
    function inherited(i, includeDeferred) {
        if (i.notify.level !== "quiet" || !i.parent || (i.notify.on || []).length || clean(i.notify.cooldown)) return null;
        let parent = i.parent, donor = null, chosen = false, parked = false;
        const seen = new Set([i.handle]);
        while (parent && seen.size <= input.graphDepth && !seen.has(parent)) {
            seen.add(parent);
            const ancestor = byHandle[parent];
            if (!ancestor) break;
            if (facts[parent].deferred) parked = true;
            if (!chosen && ["direct", "urgent"].includes(ancestor.notify.level)) {
                chosen = true;
                if (!explicit(ancestor)) donor = {level: ancestor.notify.level, filters: filters(ancestor),
                    cooldown: facts[parent].cooldown, title: ancestor.title};
            }
            parent = ancestor.parent;
        }
        return (!parked || includeDeferred) && !parent ? donor : null;
    }
    function decision(i, at, donor) {
        const f = facts[i.handle], level = donor ? donor.level : i.notify.level;
        if (!["direct", "urgent"].includes(level)) return null;
        const base = {handle: i.handle, title: "Desk · " + i.project, level,
            observedUpdatedAt: i.updatedAt, oneTimeAnnouncement: false};
        const on = donor ? donor.filters : filters(i);
        if (terminal(i)) {
            if (explicit(i) || (on.length && !on.includes("done") && !on.includes("state_change")) ||
                f.closed === null || at - f.closed > 172800 || (f.last !== null && f.closed <= f.last)) return null;
            return {...base, body: (i.status === "done" ? "✓ " : "✕ ") + i.title + " — " + i.status +
                (donor ? " (step of " + donor.title + ")" : "")};
        }
        if (f.deferred) return null;
        if (donor) {
            if (i.status !== "blocked" || (on.length && !on.includes("blocked") && !on.includes("state_change")) ||
                f.updated === null || at - f.updated > 172800) return null;
        } else if (on.length && !explicit(i) && !on.includes("state_change") && !(on.includes("blocked") && i.status === "blocked")) return null;
        if (f.last !== null && ((!donor && explicit(i)) || f.updated === null || f.updated <= f.last || at - f.last < cooldown(i, donor))) return null;
        let body = donor ? "⛔ " + i.title + " — blocked (step of " + donor.title + ")" :
            (f.last === null && clean(i.notify.notifyReason) ? clean(i.notify.notifyReason) : i.project + " · " + i.title + " — now " + i.status);
        if (i.status === "blocked" && clean(i.waitingOn)) body += " — waiting on: " + clean(i.waitingOn);
        return {...base, body, oneTimeAnnouncement: !donor && explicit(i)};
    }
    const deadlines = [];
    for (const i of items) {
        const f = facts[i.handle], donor = inherited(i, false);
        if (!f.parked) {
            const d = decision(i, now, donor);
            if (d) result.notifications.push(d);
        }
        const futureDonor = inherited(i, true), level = futureDonor ? futureDonor.level : i.notify.level;
        if (!["direct", "urgent"].includes(level)) continue;
        if (terminal(i)) {
            if (f.parked && f.until !== null && decision(i, f.until, futureDonor)) deadlines.push(f.until);
            continue;
        }
        if (f.lastSet && explicit(i)) continue;
        if (f.parked) {
            if (f.until === null) continue;
            if (f.last === null) deadlines.push(f.until);
            else if (f.updated !== null && f.updated > f.last) deadlines.push(Math.max(f.until, f.last + cooldown(i, futureDonor)));
        } else if (f.last !== null && f.updated !== null && f.updated > f.last) {
            const due = f.last + cooldown(i, futureDonor);
            if (due > now) deadlines.push(due);
        }
    }
    const observation = i => ({updatedAt: i.updatedAt, effectiveBlockerCount: facts[i.handle].blockers, deferElapsed: !facts[i.handle].parked});
    const reasons = (previous, current, stale) => {
        const r = [];
        if (previous.effectiveBlockerCount > 0 && current.effectiveBlockerCount === 0) r.push("blockers cleared");
        if (!previous.deferElapsed && current.deferElapsed) r.push("defer elapsed");
        if (stale && current.updatedAt > previous.updatedAt) r.push("moved while stale");
        return r;
    };
    const ageText = age => { const s = Math.max(0, Math.trunc(age)); return s >= 86400 ? Math.trunc(s / 86400) + "d" : s >= 3600 ? Math.trunc(s / 3600) + "h" : Math.trunc(s / 60) + "m"; };
    const capped = (lines, what) => lines.length > 8 ? lines.slice(0, 8).concat("+" + (lines.length - 8) + " more " + what + " — run desk to see them") : lines;
    const unmute = input.mode === "unmute" || (config.enabled && input.muteSet && !(input.muteEnd !== null && input.muteEnd > now));
    result.openWindow = unmute;
    if (unmute) {
        const lines = [];
        for (const i of items) {
            if (terminal(i) || !facts[i.handle].scoped) continue;
            result.consume.push(i.handle);
            if (!config.enabled) continue;
            const current = observation(i), previous = (config.observed || {})[i.handle];
            if (!previous) { lines.push(i.alias + " " + i.title + " — new since the mute"); continue; }
            if (previous.updatedAt === current.updatedAt && previous.effectiveBlockerCount === current.effectiveBlockerCount && previous.deferElapsed === current.deferElapsed) continue;
            const moved = reasons(previous, current, true);
            if (!previous.deferElapsed && !current.deferElapsed) moved.push("still parked");
            if (!moved.length) moved.push("changed");
            lines.push(i.alias + " " + i.title + " — " + moved.join(", "));
        }
        result.digest = capped(lines, "moved");
    } else if (config.enabled) {
        if (input.muteEnd !== null && input.muteEnd > now) deadlines.push(input.muteEnd);
        else {
            const digest = [];
            for (const i of items) {
                const f = facts[i.handle];
                if (terminal(i) || i.project === input.myQueue || !f.scoped) continue;
                const current = observation(i), previous = (config.observed || {})[i.handle];
                result.consume.push(i.handle);
                if (!previous || !current.deferElapsed) continue;
                const age = f.updated === null ? null : now - f.updated;
                const stale = age !== null && age > (f.staleAfter ?? 259200), moved = reasons(previous, current, stale);
                if (stale && moved.length) {
                    if ((config.ledger || {})[i.handle] !== config.windowId) result.nags.push({handle: i.handle,
                        title: "Desk · " + i.project, body: i.alias + " " + i.project + " · " + i.title + " — " + moved.join(", ") + "; untouched " + ageText(age)});
                } else if (stale) digest.push(i.alias + " " + i.title + " — stale " + ageText(age));
            }
            result.digest = capped(digest, "stale");
        }
    }
    if (result.openWindow && result.digest.length) result.digestBody =
        ["Your mute elapsed. What moved while you were quiet:", ...result.digest].join("\n");
    if (result.nags.length && result.digest.length) result.nags[0].body +=
        "\n\nAlso sitting still:\n" + result.digest.join("\n");
    // Deadline proposals are independent of whether this pass opens a window.
    if (config.enabled && !(input.muteEnd !== null && input.muteEnd > now)) {
        for (const i of items) {
            const f = facts[i.handle];
            if (!terminal(i) && f.scoped && f.until !== null) deadlines.push(f.until);
        }
    }
    result.deadline = deadlines.length ? Math.min(...deadlines) : null;
    return result;
}
