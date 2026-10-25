/* NativeAgent ability
{"id":"studio-canon","kind":"tool","version":1,
 "reach":{"capabilities":[]},
 "record":{"description":"Propose canon tending from neutral recurrence, production-pull and membership facts, with reasons and the next silence deadline. Never decides membership.","actions":[],"inputSchema":{"type":"object","required":["now","evidence","members"]}}}
*/
function run(input) {
    const recurrenceThreshold = 3, recallThreshold = 1, silenceWindow = 90 * 24 * 60 * 60;
    const proposals = [];
    const members = new Set(input.members.map(row => row.key));
    // Native facts arrive in canonical work-key order; selection is ours.
    for (const work of input.evidence) {
        if (members.has(work.key)) continue;
        if (work.recurrence_count >= recurrenceThreshold) proposals.push({key:work.key,action:"promote",evidenceKind:"recurrence",
            reasonLine:work.recurrence_count + " later entries deepen or echo this work. That is recurrence, not a rating — you kept coming back to it."});
        else if (work.recall_hits >= recallThreshold) proposals.push({key:work.key,action:"promote",evidenceKind:"pulled_in_production",
            reasonLine:"This work's pointer was pulled " + work.recall_hits + " time(s) in live judgments. It is being used, not just filed."});
    }
    let nextAt = null;
    for (const member of input.members) {
        if (member.last_signal_seconds !== null && input.now - member.last_signal_seconds >= silenceWindow) {
            proposals.push({key:member.key,action:"demote",evidenceKind:"silence",
                reasonLine:"Nothing has been written about this work and nothing has pulled it since "
                    + (member.last_signal || "it entered the canon") + ". Demote it, or say it still holds and it stays."});
        }
        if (member.deadline_signal_seconds !== null) {
            const last = member.deadline_signal_seconds;
            const windows = Math.floor(Math.max(0,input.now - last) / silenceWindow) + 1;
            const deadline = last + windows * silenceWindow;
            if (nextAt === null || deadline < nextAt) nextAt = deadline;
        }
    }
    return {proposals,nextAt};
}
