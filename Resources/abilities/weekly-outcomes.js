/* NativeAgent ability
{"id":"weekly-outcomes","kind":"tool","version":1,"reach":{"capabilities":[]},"face":{"page":"desk"},"record":{"description":"Compose the weekly Workshop outcome digest from complete native-normalized samples. CPU only; never schedules work or reads execution stores.","actions":[],"inputSchema":{"type":"object","required":["availability","samples"],"properties":{"availability":{"type":"string","enum":["available"]},"samples":{"type":"array"},"maxWeeks":{"type":"integer"},"onlyTriggerSource":{"type":["string","null"]}},"additionalProperties":false,"readOnly":true}}}
*/

function run(input) {
    // Native source failures never arrive as an empty sample list. The native
    // owner fails the pass; L0 refuses oversized input without truncation.
    const median = values => {
        if (!values.length) return 0;
        const sorted = values.slice().sort((a, b) => a - b);
        const middle = Math.floor(sorted.length / 2);
        return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
    };
    // createdDay is the Mac's local calendar day, decoded natively. UTC here
    // is only date arithmetic over that day, so DST cannot shift the bucket.
    const weekStart = day => {
        const date = new Date(day + "T00:00:00Z");
        date.setUTCDate(date.getUTCDate() - (date.getUTCDay() + 6) % 7);
        return date.toISOString().slice(0, 10);
    };
    const buckets = new Map();
    for (const sample of input.samples) {
        if (input.onlyTriggerSource != null && sample.triggerSource !== input.onlyTriggerSource) continue;
        const week = weekStart(sample.createdDay);
        if (!buckets.has(week)) buckets.set(week, []);
        buckets.get(week).push(sample);
    }
    const weeks = Array.from(buckets.keys()).sort().map(week => {
        const group = buckets.get(week);
        const terminal = group.filter(s => s.terminal);
        const completed = group.filter(s => s.completed).length;
        return {
            weekStart: week, total: group.length, terminal: terminal.length, completed,
            unverified: group.filter(s => s.status === "unverified").length,
            completionRate: terminal.length ? completed / terminal.length : 0,
            medianTotalSteps: median(group.map(s => s.totalSteps)),
            medianWallSeconds: median(terminal.map(s => s.wallSeconds)),
            medianRerunCount: median(group.map(s => s.rerunCount)),
            stubRate: group.filter(s => s.wasStub).length / group.length
        };
    });
    const window = Math.max(0, input.maxWeeks === undefined ? 8 : input.maxWeeks);
    if (!weeks.length || window === 0) return "";
    const recent = weeks.slice(-window);
    const lines = recent.map(w => {
        const rate = Math.round(w.completionRate * 100);
        const wall = w.medianWallSeconds >= 60
            ? Math.round(w.medianWallSeconds / 60) + "m" : Math.round(w.medianWallSeconds) + "s";
        return "- week of " + w.weekStart + ": "
            + w.total + " job(s), " + w.completed + "/" + w.terminal + " completed (" + rate + "%), "
            + w.unverified + " unverified, "
            + "median " + Math.round(w.medianTotalSteps) + " steps, ~" + wall + " wall, "
            + w.medianRerunCount.toFixed(1) + " reruns, "
            + Math.round(w.stubRate * 100) + "% planner-fallback";
    });
    let trend = "";
    if (recent.length >= 2) {
        const delta = (recent[recent.length - 1].completionRate - recent[recent.length - 2].completionRate) * 100;
        const direction = delta > 0.5 ? "UP" : delta < -0.5 ? "DOWN" : "flat";
        // String(format: "%+.0f") keeps a minus for negative values rounded to
        // zero and uses nearest-even ties. Preserve the old prompt's bytes.
        const magnitude = Math.abs(delta), floor = Math.floor(magnitude);
        const rounded = magnitude - floor === 0.5 ? floor + floor % 2 : Math.round(magnitude);
        trend = "\nTrend: completion rate " + direction + " "
            + (delta < 0 || Object.is(delta, -0) ? "-" : "+") + rounded + " pts week-over-week.";
    }
    return "## Workshop outcomes (week-over-week - is the assistant completing real multi-step jobs better?)\n"
        + lines.join("\n") + trend;
}
