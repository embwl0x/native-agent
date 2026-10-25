/* NativeAgent ability
{"id":"mac-watch-catalog","kind":"tool","version":1,"reach":{"capabilities":[]},"face":{"page":"mac"},"record":{"description":"Return inactive Mail, Calendar and Reminders watch recipes. Reading this catalog never schedules a job.","actions":[],"inputSchema":{"type":"object","readOnly":true,"properties":{},"additionalProperties":false}}}
*/
function run(input) {
    const recipes = [
        {id:"local_mail_watch", title:"Local Mail.app watch", summary:"Poll local Mail.app read-only via the app-owned dispatcher.",
         scheduleLabel:"Every 30 minutes", sources:["mail.app"], requiredAccess:["local_mail","mac_control"],
         actionIds:["mac.mail_list_recent","scheduler.schedule_job"],
         jobPayload:{name:"Watch local Mail.app", kind:"connector_action", schedule:{type:"every",minutes:30},
             payload:{actionId:"mac.mail_list_recent",input:{limit:20,hours_back:24,unread_only:true}}},
         displayTitle:"Mac Mail", sentence:"I check Mail for unread messages {when} (read only)."},
        {id:"local_calendar_watch", title:"Local Calendar.app watch", summary:"Poll local Calendar.app read-only for the next day.",
         scheduleLabel:"Every 30 minutes", sources:["calendar.app"], requiredAccess:["local_calendar","mac_control"],
         actionIds:["mac.calendar_list_upcoming","scheduler.schedule_job"],
         jobPayload:{name:"Watch local Calendar.app",kind:"connector_action",schedule:{type:"every",minutes:30},
             payload:{actionId:"mac.calendar_list_upcoming",input:{hours_ahead:24}}},
         displayTitle:"Mac Calendar",sentence:"I check Calendar for the next day {when} (read only)."},
        {id:"local_reminders_watch",title:"Local Reminders.app watch",summary:"Poll due and overdue Reminders.app items read-only.",
         scheduleLabel:"Hourly",sources:["reminders.app"],requiredAccess:["local_reminders","mac_control"],
         actionIds:["mac.reminders_list_due_today","scheduler.schedule_job"],
         jobPayload:{name:"Watch due reminders",kind:"connector_action",schedule:{type:"hourly",minute:5},
             payload:{actionId:"mac.reminders_list_due_today",input:{include_completed:false}}},
         displayTitle:"Mac Reminders",sentence:"I check Reminders for due and overdue items {when} (read only)."}
    ];
    return recipes.map(recipe => {
        recipe.displaySummary = recipe.sentence.replace("{when}", recipe.scheduleLabel[0].toLowerCase() + recipe.scheduleLabel.slice(1));
        delete recipe.sentence;
        return recipe;
    });
}
