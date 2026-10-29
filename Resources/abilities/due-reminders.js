/* NativeAgent ability
{"id":"due-reminders","kind":"tool","version":1,
 "reach":{"capabilities":["reminders"]},
 "face":{"page":"reminders"},
 "record":{"description":"Read reminders in two named parts: today (local day, earliest first) and overdue (before today, oldest first). Each has its full count, capped reminders and has_more; summary names both counts. Includes at most 200 reminders per part from one native query snapshot, with the legacy reminders union beside them. Permission and unavailable results retain their native evidence.","actions":["reminders.query"],"inputSchema":{"type":"object","required":["request","now","timeZone"]}}}
*/
function run(input) {
    const request = input.request;
    const text = v => ["string","number","boolean"].includes(typeof v) ? String(v) : "";
    const flag = (v, d) => {
        if (typeof v === "boolean") return v;
        if (typeof v === "number") return d;
        const s = text(v).trim().toLowerCase();
        return ["1","true","yes","on"].includes(s) ? true : ["0","false","no","off"].includes(s) ? false : d;
    };
    const raw = request.limit === undefined ? request.max : request.limit;
    const number = typeof raw === "number" ? Math.trunc(raw) : typeof raw === "string" && /^[+-]?\d+$/.test(raw.trim()) ? Number(raw.trim()) : 50;
    const limit = Math.max(1, Math.min(200, Number.isInteger(number) && number >= -9223372036854775808 && number < 9223372036854775808 ? number : 50));
    const completed = flag(request.include_completed === undefined ? request.includeCompleted : request.include_completed, false);
    const start = new Date(input.now);
    start.setHours(0, 0, 0, 0);
    const dueStart = start.toISOString().replace(/\.\d{3}Z$/, "Z");
    const end = new Date(start);
    end.setDate(end.getDate() + 1);
    const dueEnd = end.toISOString().replace(/\.\d{3}Z$/, "Z");
    let page;
    try {
        page = host.reminders.list({due_end:dueEnd,split_due_at:dueStart,include_completed:completed,
            list_name:text(request.list_name === undefined ? request.listName : request.list_name).trim(),
            offset:0,limit});
    } catch (error) {
        if (error.name !== "AppError" || error.stopped || error.reason === "cancelled") throw error;
        return Object.assign({}, error.receipt, {actionId:"mac.reminders_list_due_today"});
    }
    const part = value => ({count:value.total,returned_count:value.count,
        has_more:value.next_offset !== null,reminders:value.reminders});
    const today = part(page.on_or_after), overdue = part(page.before);
    const rows = overdue.reminders.concat(today.reminders);
    return {status:"completed",actionId:"mac.reminders_list_due_today",source:"eventkit",access:page.access,
        includeCompleted:completed,scope:"due_today_and_overdue",due_start:dueStart,due_end:dueEnd,timeZone:input.timeZone,
        summary:today.count+" due today · "+overdue.count+" overdue",today,overdue,
        count:rows.length,total:today.count+overdue.count,has_more:today.has_more || overdue.has_more,reminders:rows};
}
