import Foundation

/// Rodalies (Renfe Cercanías València) part of EmtRepository.kt: bundled
/// stations, route shapes and timetable, plus the GTFS-RT service alerts.
public struct RodaliesData: Sendable {
    public let places: [Place]
    /// "C1"… with the station ids (`rd-` stripped) as stop sequences.
    public let routes: [String: BusRoute]
    private let timetable: [String: [String]]
    /// A typical week from Renfe's GTFS (ios/tools/make_rodalies_schedule.py):
    /// "HH:MM|line|destination|weekday mask|last" per station.
    private let week: [String: [String]]

    public init(places: [Place], routes: [String: BusRoute], timetable: [String: [String]], week: [String: [String]] = [:]) {
        self.places = places
        self.routes = routes
        self.timetable = timetable
        self.week = week
    }

    static let idBase = 3_000_000

    /// Official line colours of Cercanías València (route_color in Renfe's
    /// GTFS, fomento_transit.zip); the bundled geojson has every line in red.
    public static let lineColors: [String: Int] = [
        "C1": 0x7AB3DE, "C2": 0xF79529, "C3": 0x7A2780, "C5": 0x018A27, "C6": 0x0D3386,
    ]
    /// Renfe red, for any line not in the table.
    public static let networkColor = 0xE30613

    public static func load(from directory: URL) -> RodaliesData {
        let network = (try? Data(contentsOf: directory.appendingPathComponent("rodalies.geojson"))).map(parseNetwork) ?? ([], [:])
        let times = (try? Data(contentsOf: directory.appendingPathComponent("rodalies_times.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [String]] } ?? [:]
        let week = (try? Data(contentsOf: directory.appendingPathComponent("rodalies_schedule.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["stations"] as? [String: [String]] } ?? [:]
        return RodaliesData(places: network.0, routes: network.1, timetable: times, week: week)
    }

    static func parseNetwork(_ data: Data) -> ([Place], [String: BusRoute]) {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let features = root["features"] as? [[String: Any]]
        else { return ([], [:]) }
        func lineKey(_ value: Any?) -> String {
            let raw = (value as? String) ?? jsonInt(value).map(String.init) ?? ""
            return "C" + (raw.hasPrefix("C") ? String(raw.dropFirst()) : raw)
        }

        var stations: [String: Place] = [:]
        var order: [String] = []
        var lineStrings: [[String: Any]] = []
        for feature in features {
            guard let geometry = feature["geometry"] as? [String: Any] else { continue }
            let properties = feature["properties"] as? [String: Any] ?? [:]
            switch geometry["type"] as? String {
            case "Point":
                let coords = (geometry["coordinates"] as? [Any])?.compactMap(jsonDouble) ?? []
                guard coords.count >= 2, let name = properties["stop_name"] as? String, !name.isEmpty else { continue }
                let id = idBase + stations.count
                if stations[name] == nil { order.append(name) }
                stations[name] = Place(id: "rd-\(id)", network: .rodalies, name: name, lat: coords[1], lon: coords[0],
                                       lines: ((properties["lines"] as? [Any]) ?? []).map { lineKey($0) }, detail: "Rodalies")
            case "LineString":
                lineStrings.append(feature)
            default:
                continue
            }
        }

        var groups: [String: [[String: Any]]] = [:]
        var groupOrder: [String] = []
        for feature in lineStrings {
            let line = lineKey((feature["properties"] as? [String: Any])?["line"])
            if groups[line] == nil { groupOrder.append(line) }
            groups[line, default: []].append(feature)
        }
        var routes: [String: BusRoute] = [:]
        for line in groupOrder {
            let directions: [RouteDirection] = (groups[line] ?? []).prefix(2).map { feature in
                let coords = (feature["geometry"] as? [String: Any])?["coordinates"] as? [[Any]] ?? []
                let shape = coords.compactMap { raw -> LonLat? in
                    let p = raw.compactMap(jsonDouble)
                    return p.count >= 2 ? LonLat(lon: p[0], lat: p[1]) : nil
                }
                let names = jsonStrings((feature["properties"] as? [String: Any])?["stops"])
                return RouteDirection(shapes: [shape], stops: names.compactMap { stations[$0].map { String($0.id.dropFirst(3)) } })
            }
            if let first = directions.first {
                routes[line] = BusRoute(ida: first, vuelta: directions.count > 1 ? directions[1] : first)
            }
        }
        return (order.compactMap { stations[$0] }, routes)
    }

    /// Whether the week timetable is bundled (otherwise the old table, capped
    /// at 80 trains a station and with no calendar).
    public var hasWeekTimetable: Bool { !week.isEmpty }

    /// Whether a station has any timetable (to offer the timetable screen).
    public func hasTimetable(at stationName: String) -> Bool {
        week[stationName] != nil || timetable[stationName] != nil
    }

    /// A day's departures at a station, trains ending there included (marked
    /// drop-off only).
    public func schedule(at stationName: String, on date: Date, calendar: Calendar = .current) -> [ScheduledDeparture] {
        guard let entries = week[stationName] else { return schedule(at: stationName) }
        // Calendar weekday: 1 = Sunday … 7 = Saturday; mask bit 0 = Monday.
        let bit = 1 << ((calendar.component(.weekday, from: date) + 5) % 7)
        return entries.compactMap { entry -> ScheduledDeparture? in
            let parts = entry.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let time = parts.first?.split(separator: ":") ?? []
            guard parts.count >= 5, time.count >= 2, let hour = Int(time[0]), let minute = Int(time[1]),
                  let mask = Int(parts[3]), mask & bit != 0 else { return nil }
            // GTFS hours can run past midnight ("24:10").
            return ScheduledDeparture(hour: hour % 24, minute: minute, line: parts[1], destination: parts[2],
                                      dropOffOnly: parts[4] == "1")
        }
        .sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
    }

    /// The whole day's departures at a station from the old table (the usual
    /// weekday service, no calendar).
    public func schedule(at stationName: String) -> [ScheduledDeparture] {
        (timetable[stationName] ?? []).compactMap { entry -> ScheduledDeparture? in
            let parts = entry.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let time = parts.first?.split(separator: ":") ?? []
            guard parts.count >= 2, time.count >= 2, let hour = Int(time[0]), let minute = Int(time[1]) else { return nil }
            // GTFS hours can run past midnight ("24:10").
            return ScheduledDeparture(hour: hour % 24, minute: minute, line: parts[1], destination: parts.count > 2 ? parts[2] : "")
        }
        .sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
    }

    /// Departures in the next 3 hours at a station (bundled GTFS table).
    public func times(at stationName: String, now: Date = Date(), calendar: Calendar = .current) -> [Arrival] {
        if week[stationName] != nil {
            let c = calendar.dateComponents([.hour, .minute], from: now)
            let nowMinute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            // Today's still to come, then tomorrow's early ones for late at night.
            let upcoming = schedule(at: stationName, on: now).map { ($0.minuteOfDay - nowMinute, $0) }
                + schedule(at: stationName, on: tomorrow).map { ($0.minuteOfDay + 1440 - nowMinute, $0) }
            return upcoming
                .filter { $0.0 >= 0 && $0.0 <= 180 && !$0.1.dropOffOnly }
                .sorted { $0.0 < $1.0 }
                .prefix(8)
                .map { Arrival(line: $0.1.line, destination: $0.1.destination, minutes: "\($0.0) min") }
        }
        guard let list = timetable[stationName] else { return [] }
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        let nowMinute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        var out: [(Int, Arrival)] = []
        for entry in list {
            let parts = entry.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { continue }
            let time = parts[0].split(separator: ":")
            guard let hour = time.first.flatMap({ Int($0) }) else { continue }
            let minutes = hour * 60 + (time.count > 1 ? Int(time[1]) ?? 0 : 0)
            let diff = minutes >= nowMinute ? minutes - nowMinute : minutes + 1440 - nowMinute
            if diff <= 180 {
                out.append((diff, Arrival(line: parts[1], destination: parts.count > 2 ? parts[2] : "", minutes: "\(diff) min")))
            }
        }
        return out.sorted { $0.0 < $1.0 }.prefix(8).map(\.1)
    }
}

public enum RodaliesAlerts {
    /// Renfe GTFS-RT alerts for Valencian Community routes (ids "40T…").
    public static func fetch() async -> [Incident] {
        guard let text = try? await HTTP.get(URL(string: "https://gtfsrt.renfe.com/alerts.json")!,
                                             headers: ["Accept": "application/json", "User-Agent": "okhttp/4.10.0"]) else {
            return []
        }
        return parse(text)
    }

    static func parse(_ text: String) -> [Incident] {
        guard
            let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            let entities = root["entity"] as? [[String: Any]]
        else { return [] }
        return entities.compactMap { entity in
            guard let alert = entity["alert"] as? [String: Any] else { return nil }
            let informed = alert["informedEntity"] as? [[String: Any]] ?? []
            guard informed.contains(where: { ($0["routeId"] as? String ?? "").hasPrefix("40T") }) else { return nil }
            var text = ""
            for translation in (alert["descriptionText"] as? [String: Any])?["translation"] as? [[String: Any]] ?? [] {
                let value = translation["text"] as? String ?? ""
                if (translation["language"] as? String ?? "").hasPrefix("es") || text.isEmpty { text = value }
            }
            let header = (((alert["headerText"] as? [String: Any])?["translation"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            let title = header.isEmpty ? String(text.prefix(120)) : header
            guard !title.isEmpty else { return nil }
            return Incident(title: title, date: "", lines: [], network: .rodalies, detail: String(text.prefix(240)))
        }
    }
}
