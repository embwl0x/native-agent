import Foundation
import NativeAgentCore
import PersistenceCore

extension AppToolExecutor {
    func runWeatherForecast(input: [String: JSONValue]) async throws -> JSONValue {
        let place = Self.doorText(input["place"])
        guard !place.isEmpty else {
            return Self.failure("place_needed", "Give a city or postal code in args.place. This Mac has no current location reader.")
        }
        let hours: Int
        if let supplied = input["hours"] {
            guard case .int(let count) = supplied, (1...24).contains(count) else {
                return Self.failure("invalid_hours", "hours must be an integer from 1 to 24, or omitted for a daily forecast.")
            }
            hours = Int(count)
        } else { hours = 0 }
        func fetch(_ address: String, _ query: [String: String]) async throws -> [String: JSONValue] {
            guard var url = URLComponents(string: address) else { throw URLError(.badURL) }
            url.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let endpoint = url.url else { throw URLError(.badURL) }
            let (data, response) = try await URLSession.shared.data(from: endpoint)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw NSError(domain: "weather_forecast", code: (response as? HTTPURLResponse)?.statusCode ?? 0,
                    userInfo: [NSLocalizedDescriptionKey: "Open-Meteo returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0). No weather was read; check the service status before retrying."])
            }
            guard case .object(let result) = try JSONValue.parse(data), result["error"] != .bool(true) else {
                throw NSError(domain: "weather_forecast", code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "Open-Meteo returned no usable weather data. Check the service status before retrying."])
            }
            return result
        }
        let geocoded = try await fetch("https://geocoding-api.open-meteo.com/v1/search", ["name": place, "count": "1"])
        guard case .array(let places)? = geocoded["results"], case .object(let location)? = places.first,
              let latitude = Self.inputString(location["latitude"]), let longitude = Self.inputString(location["longitude"]),
              case .string(let zone)? = location["timezone"], let timezone = TimeZone(identifier: zone) else {
            return Self.failure("place_not_found", "No forecast location matched args.place. Give a city with its state or country, or a postal code.")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        let today = calendar.startOfDay(for: Date())
        let day = Self.doorText(input["day"])
        let date: Date?
        switch day.lowercased() {
        case "", "today": date = today
        case "tomorrow": date = calendar.date(byAdding: .day, value: 1, to: today)
        default: date = formatter.date(from: day).flatMap { formatter.string(from: $0) == day ? $0 : nil }
        }
        guard let date, let offset = calendar.dateComponents([.day], from: today, to: date).day, (0...15).contains(offset) else {
            return Self.failure("invalid_day", "day must be today, tomorrow or yyyy-MM-dd within the next 16 days at the forecast location.")
        }
        let isoDay = formatter.string(from: date)
        // days: a run of daily forecasts in one read ("this week"), within the 16-day horizon.
        var endDay = isoDay
        if let supplied = input["days"] {
            guard case .int(let count) = supplied, (1...16).contains(count),
                  let last = calendar.date(byAdding: .day, value: Int(count) - 1, to: date),
                  (calendar.dateComponents([.day], from: today, to: last).day ?? 99) <= 15 else {
                return Self.failure("invalid_days", "days must be an integer from 1 to 16, ending within 16 days of today.")
            }
            endDay = formatter.string(from: last)
        }
        let us = Locale.autoupdatingCurrent.measurementSystem == .us
        var query = ["latitude": latitude, "longitude": longitude, "timezone": zone,
            "temperature_unit": us ? "fahrenheit" : "celsius",
            "wind_speed_unit": Locale.autoupdatingCurrent.measurementSystem == .metric ? "kmh" : "mph",
            "precipitation_unit": us ? "inch" : "mm", "start_date": isoDay, "end_date": endDay,
            "current": "temperature_2m,apparent_temperature,weather_code,precipitation,wind_speed_10m",
            "daily": "temperature_2m_max,temperature_2m_min,precipitation_probability_max,wind_speed_10m_max,sunrise,sunset"]
        if hours > 0 {
            query["hourly"] = "temperature_2m,precipitation_probability,weather_code,wind_speed_10m"
            if offset == 0 { query["forecast_hours"] = String(hours) }
            else {
                query["start_hour"] = isoDay + "T00:00"
                query["end_hour"] = isoDay + String(format: "T%02d:00", hours - 1)
            }
        }
        var result = try await fetch("https://api.open-meteo.com/v1/forecast", query)
        guard case .object(var current)? = result["current"], case .object(let daily)? = result["daily"],
              case .array(let days)? = daily["time"], !days.isEmpty else {
            return Self.failure("forecast_unavailable", "Open-Meteo returned an incomplete forecast. No complete current and daily weather is available; check the service status before retrying.")
        }
        if case .int(let code)? = current["weather_code"] {
            let condition: String
            switch code {
            case 0: condition = "Clear sky"
            case 1: condition = "Mainly clear"
            case 2: condition = "Partly cloudy"
            case 3: condition = "Overcast"
            case 45, 48: condition = "Fog"
            case 51, 53, 55: condition = "Drizzle"
            case 56, 57: condition = "Freezing drizzle"
            case 61, 63, 65: condition = "Rain"
            case 66, 67: condition = "Freezing rain"
            case 71, 73, 75, 77: condition = "Snow"
            case 80, 81, 82: condition = "Rain showers"
            case 85, 86: condition = "Snow showers"
            case 95, 96, 99: condition = "Thunderstorm"
            default: condition = "Unknown weather code"
            }
            current["condition"] = .string(condition)
        }
        result["current"] = .object(current)
        result["status"] = .string("ok")
        result["source"] = .string("Open-Meteo · https://open-meteo.com/; location data: GeoNames")
        result["place"] = .object(location)
        result["requested_day"] = .string(isoDay)
        result["read_at"] = .string(ISO8601DateFormatter().string(from: Date()))
        return .object(result)
    }
}
