/* NativeAgent ability
{"id":"due-reminders","kind":"ability","version":1,
 "reach":{"capabilities":["reminders"]},
 "face":{"page":"reminders"},
 "record":{"description":"Read reminders in two named parts: today (local day, earliest first) and overdue (before today, oldest first). Each has its full count, capped reminders and has_more; summary names both counts. Includes at most 200 reminders per part from one native query snapshot. Permission and unavailable results retain their native evidence.","actions":["reminders.query"],"inputSchema":{"type":"object","required":["request","now","timeZone"]}}}
*/
function run(input) {
    const request = input.request;
    const raw = request.limit === undefined ? 50 : request.limit;
    if (!Number.isSafeInteger(raw)) throw new Error("request.limit must be an integer.");
    const limit = Math.max(1, Math.min(200, raw));
    const completed = request.include_completed === undefined ? false : request.include_completed;
    if (typeof completed !== "boolean") throw new Error("request.include_completed must be a Boolean.");
    const listName = request.list_name === undefined ? "" : request.list_name;
    if (typeof listName !== "string") throw new Error("request.list_name must be a string.");
    const start = new Date(input.now);
    start.setHours(0, 0, 0, 0);
    const dueStart = start.toISOString().replace(/\.\d{3}Z$/, "Z");
    const end = new Date(start);
    end.setDate(end.getDate() + 1);
    const dueEnd = end.toISOString().replace(/\.\d{3}Z$/, "Z");
    let page;
    try {
        page = host.reminders.query({due_end:dueEnd,split_due_at:dueStart,include_completed:completed,
            list_name:listName.trim(),
            offset:0,limit});
    } catch (error) {
        if (error.name !== "AppError" || error.stopped || error.reason === "cancelled") throw error;
        return Object.assign({}, error.receipt, {actionId:"mac.reminders_list_due_today"});
    }
    const part = value => ({count:value.total,returned_count:value.count,
        has_more:value.next_offset !== null,reminders:value.reminders});
    const today = part(page.on_or_after), overdue = part(page.before);
    return {status:"completed",actionId:"mac.reminders_list_due_today",source:"eventkit",access:page.access,
        includeCompleted:completed,scope:"due_today_and_overdue",due_start:dueStart,due_end:dueEnd,timeZone:input.timeZone,
        summary:today.count+" due today · "+overdue.count+" overdue",today,overdue,
        count:today.returned_count+overdue.returned_count,total:today.count+overdue.count,has_more:today.has_more || overdue.has_more};
}
