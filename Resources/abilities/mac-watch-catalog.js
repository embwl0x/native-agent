/* NativeAgent ability
{"id":"mac-watch-catalog","kind":"ability","version":2,"reach":{"capabilities":[]},"face":{"page":"mac"},"record":{"description":"Return inactive Mail, Calendar and Reminders watch recipes and the words for each Mac access row. Reading this catalog never schedules a job.","actions":[],"inputSchema":{"type":"object","readOnly":true,"properties":{},"additionalProperties":false}}}
*/
function run(input) {
    // Once scheduled, each read is a watch: the rows new since its last read come to her as news.
    const recipes = [
        {id:"local_mail_watch", title:"Local Mail.app watch", summary:"Poll local Mail.app read-only via the app-owned dispatcher.",
         scheduleLabel:"Every 30 minutes", sources:["mail.app"],
         actionIds:["mail.recent","schedule.create"],
         jobPayload:{kind:"connector_action", schedule:{type:"every",minutes:30},
             payload:{actionId:"mail.recent",input:{limit:20,unread:true}}},
         displayTitle:"Mac Mail", sentence:"I check Mail for unread messages {when} (read only)."},
        {id:"local_calendar_watch", title:"Local Calendar.app watch", summary:"Poll local Calendar.app read-only for the next day.",
         scheduleLabel:"Every 30 minutes", sources:["calendar.app"],
         actionIds:["calendar.upcoming","schedule.create"],
         jobPayload:{kind:"connector_action",schedule:{type:"every",minutes:30},
             payload:{actionId:"calendar.upcoming",input:{hours_ahead:24}}},
         displayTitle:"Mac Calendar",sentence:"I check Calendar for the next day {when} (read only)."},
        {id:"local_reminders_watch",title:"Local Reminders.app watch",summary:"Poll due and overdue Reminders.app items read-only.",
         scheduleLabel:"Hourly",sources:["reminders.app"],
         actionIds:["reminders.due_today","schedule.create"],
         jobPayload:{kind:"connector_action",schedule:{type:"hourly",minute:5},
             payload:{actionId:"reminders.due_today",input:{}}},
         displayTitle:"Mac Reminders",sentence:"I check Reminders for due and overdue items {when} (read only)."}
    ];
    const grant = " Reads check the current grant; missing access returns a permission card for you to allow.";
    // Each access row's words; the row's status, route and ids are the stem's verdict.
    const access = {
        mac_control:{title:"Mac control", detail:"Lets me run shortcuts, post notifications, read files and script apps on this Mac."},
        mac_notifications:{title:"Mac notifications", detail:"I post notifications on this Mac. Readiness uses policy, macOS authorization and a "
            + "delivered notification retained by Notification Center."},
        iphone_push:{title:"iPhone notifications", detail:"I send what a watch found to your iPhone through APNS, with activity opens on iOS."},
        local_mail:{title:"Mac Mail", detail:"I read Mail account metadata through Apple Events, mailbox pages through Mail's local Envelope Index, and "
            + "message bodies from local message files. These reads need Automation and Full Disk Access.",
            nextStep:"Use Check Mail to check account coverage. If access is missing, follow the returned permission remedy."},
        local_calendar:{title:"Mac Calendar", detail:"I read Calendar (read only), through EventKit." + grant,
            nextStep:"Ask me to read Calendar, then allow access on the permission card if requested."},
        local_reminders:{title:"Mac Reminders", detail:"I read Reminders (read only), through EventKit." + grant,
            nextStep:"Ask me to read Reminders, then allow access on the permission card if requested."}
    };
    return {
        recipes:recipes.map(recipe => {
            recipe.displaySummary = recipe.sentence.replace("{when}", recipe.scheduleLabel[0].toLowerCase() + recipe.scheduleLabel.slice(1));
            delete recipe.sentence;
            return recipe;
        }),
        access,
        summary:"Watch recipes are inactive here. Reading this status creates no jobs; use an explicit schedule action to create a watch."
    };
}
