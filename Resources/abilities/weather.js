/* NativeAgent ability
{"id":"weather","kind":"tool","version":1,
 "reach":{"capabilities":["network_public"],"hosts":["geocoding-api.open-meteo.com","api.open-meteo.com"]},
 "face":{"page":"web","action":"weather.forecast"},
 "record":{"description":"Read current weather and daily temperature high/low, rain chance, wind, sunrise and sunset from Open-Meteo. place is a city or postal code, qualified by state or country when needed; when omitted, uses the fix this Mac holds through mac.location, with its age, and asks the paired iPhone through phone.location only when the Mac holds none; it says which. Mac Location Services permissions apply. NativeAgent must be open on the phone; phone location permissions apply. day: today (default), tomorrow or yyyy-MM-dd within 16 days. days: 1–16 daily forecasts starting at day, in one read (a week is days:7). hours: optional 1–24 hourly forecasts, from now today or midnight on another day. Units follow the Mac's locale (°F/mph for US).","actions":["mac.location","phone.location"],"inputSchema":{"type":"object","readOnly":true,"properties":{"place":{"type":"string"},"day":{"type":"string"},"days":{"type":"integer"},"hours":{"type":"integer"}},"required":[],"additionalProperties":false}}}
*/
function run(input) {
    const text = v => ["string", "number", "boolean"].includes(typeof v) ? String(v) : "";
    const fail = (reason, detail) => ({status:"failed", reason, detail});
    const object = v => v !== null && typeof v === "object" && !Array.isArray(v);
    let place = text(input.place).trim(); const hours = input.hours === undefined ? 0 : input.hours;
    if (input.hours !== undefined && (!Number.isInteger(hours) || hours < 1 || hours > 24)) return fail("invalid_hours", "hours must be an integer from 1 to 24, or omitted for a daily forecast.");
    const day = text(input.day).trim().toLowerCase(), days = input.days === undefined ? 1 : input.days;
    if (!Number.isInteger(days) || days < 1 || days > 16) return fail("invalid_days", "days must be an integer from 1 to 16, ending within 16 days of today.");
    function fetch(address, query) {
        let reply, result;
        try { reply = host.fetch({url:address + "?" + Object.keys(query).sort().map(k => encodeURIComponent(k) + "=" + encodeURIComponent(query[k])).join("&")}); }
        catch (e) { if (e.name === "AppError" && e.receipt) return e.receipt; throw e; }
        try { result = JSON.parse(reply.body); } catch (_) {}
        return object(result) && result.error !== true ? result
            : fail("forecast_unavailable", "Open-Meteo returned no usable weather data. Check the service status before retrying.");
    }
    const located = values => text(values.latitude).trim() && text(values.longitude).trim() && Number.isFinite(+values.latitude) && Number.isFinite(+values.longitude) && +values.latitude >= -90 && +values.latitude <= 90 && +values.longitude >= -180 && +values.longitude <= 180;
    let location = {}, locationSource = "GeoNames";
    if (!place) {
        // Where the Mac is, is a fact it holds, said with its age; the phone is asked only when the Mac holds none.
        let mac, phone;
        try { mac = app.mac.location(); } catch (e) { if (e.reason === "cancelled") throw e; mac = e.receipt; }
        if (object(mac) && mac.status === "ok" && located(mac)) {
            const minutes = Math.round((+mac.age_seconds || 0) / 60);
            location = mac; locationSource = (text(mac.source) || "this Mac") + ", fix " + (minutes < 120 ? minutes + " minutes" : Math.round(minutes / 60) + " hours") + " old";
        } else {
            locationSource = "paired iPhone";
            try { phone = app.phone.location(); } catch (e) { if (e.reason === "cancelled") throw e; phone = e.receipt; }
            location = object(phone) && phone.status === "completed" && object(phone.values) ? phone.values : {};
        }
        if (!located(location)) {
            const macCard = object(mac) && text(mac.card_id);
            return Object.assign(fail("location_unavailable", "Neither this Mac nor the paired iPhone provided a location. No weather was read."), {effects:"none", mac_result:mac, phone_result:phone,
                remedy: macCard
                    ? {kind:"card", instruction:"A Location Services card (" + macCard + ") is waiting for the owner. When it is allowed, call again; or give args.place.", next_call:null}
                    : {kind:"phone_location", instruction:"Open NativeAgent on the paired iPhone, allow location access, then make next_call; or give args.place.", next_call:{tool:"app",input:{action:"phone.location"}}}});
        }
    } else {
        const geocoded = fetch("https://geocoding-api.open-meteo.com/v1/search", {name:place,count:"1"});
        if (geocoded.status === "refused" || geocoded.status === "failed") return geocoded;
        if (!Array.isArray(geocoded.results) || !object(geocoded.results[0]) || !located(geocoded.results[0])) return fail("place_not_found", "No forecast location matched args.place. Give a city with its state or country, or a postal code.");
        location = geocoded.results[0];
    }
    // One read: Open-Meteo dates the days in the place's own zone, today first.
    const us = host.measurementSystem === "us", query = {latitude:text(location.latitude),longitude:text(location.longitude),timezone:"auto",forecast_days:"16",
        temperature_unit:us ? "fahrenheit" : "celsius", wind_speed_unit:host.measurementSystem === "metric" ? "kmh" : "mph", precipitation_unit:us ? "inch" : "mm",
        current:"temperature_2m,apparent_temperature,weather_code,precipitation,wind_speed_10m", daily:"temperature_2m_max,temperature_2m_min,precipitation_probability_max,wind_speed_10m_max,sunrise,sunset"};
    if (hours > 0) query.hourly = "temperature_2m,precipitation_probability,weather_code,wind_speed_10m";
    const result = fetch("https://api.open-meteo.com/v1/forecast", query), current = result.current, daily = result.daily, hourly = result.hourly;
    if (result.status === "refused" || result.status === "failed") return result;
    if (!object(current) || !object(daily) || !Array.isArray(daily.time) || !daily.time.length || hours > 0 && !(object(hourly) && Array.isArray(hourly.time))) return fail("forecast_unavailable", "Open-Meteo returned an incomplete forecast. No complete current and daily weather is available; check the service status before retrying.");
    const first = !day || day === "today" ? 0 : day === "tomorrow" ? 1 : daily.time.indexOf(day);
    if (first < 0) return fail("invalid_day", "day must be today, tomorrow or yyyy-MM-dd within the next 16 days at the forecast location.");
    if (first + days > daily.time.length) return fail("invalid_days", "days must be an integer from 1 to 16, ending within 16 days of today.");
    const slice = (series, from, count) => { for (const key of Object.keys(series)) if (Array.isArray(series[key])) series[key] = series[key].slice(from, from + count); };
    if (hours > 0) {
        // Today's hours run from now; another day's from its midnight.
        const from = first ? hourly.time.indexOf(daily.time[first] + "T00:00") : hourly.time.findIndex(t => t >= text(current.time).slice(0, 13) + ":00");
        if (from < 0) return fail("forecast_unavailable", "Open-Meteo returned no hours for the requested day; check the service status before retrying.");
        slice(hourly, from, hours);
    }
    slice(daily, first, days);
    if (Number.isInteger(current.weather_code)) {
        const conditions = [["Clear sky",0],["Mainly clear",1],["Partly cloudy",2],["Overcast",3],["Fog",45,48],["Drizzle",51,53,55],["Freezing drizzle",56,57],["Rain",61,63,65],["Freezing rain",66,67],["Snow",71,73,75,77],["Rain showers",80,81,82],["Snow showers",85,86],["Thunderstorm",95,96,99]];
        const found = conditions.find(c => c.slice(1).includes(current.weather_code)); current.condition = found ? found[0] : "Unknown weather code";
    }
    return Object.assign(result, {status:"ok",source:"Open-Meteo · https://open-meteo.com/; location data: " + locationSource,location_source:locationSource,place:Object.assign({}, location, {timezone:result.timezone}),requested_day:daily.time[0],read_at:new Date().toISOString().replace(/\.\d{3}Z$/, "Z")});
}
