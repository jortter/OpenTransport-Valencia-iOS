import Foundation

/// One departure in a stop's timetable (Metrobús, Rodalies).
public struct ScheduledDeparture: Hashable, Sendable {
    public let hour: Int
    public let minute: Int
    public let line: String
    public let destination: String
    /// No boarding here: the bus only lets people off (or ends at this stop).
    public var dropOffOnly = false

    /// Minutes since midnight, for comparing with the time now.
    public var minuteOfDay: Int { hour * 60 + minute }
}

/// A Metrobús line's shapes and brand colour, for drawing it on the map.
public struct MetrobusRoute: Sendable {
    public let line: String
    public let color: Int
    public let shapes: [[LonLat]]
}

/// Metrobús part of EmtRepository.kt (Softour API used by MetGo València).
public final class MetrobusClient: Sendable {
    public init() {}

    /// Stops within `radius` metres of a point (the API has no bulk list).
    public func stops(lat: Double, lon: Double, radius: Int = 7000) async -> [Place] {
        let body = #"{"radius":\#(radius),"lat":\#(lat),"lon":\#(lon)}"#
        var headers = Self.headers
        headers["Content-Type"] = "application/json"
        guard let text = try? await HTTP.post(URL(string: "\(Self.api)/stops/near")!, body: Data(body.utf8), headers: headers) else {
            return []
        }
        return Self.parseStops(text)
    }

    /// Live next arrival (and occupancy) per line at a stop code.
    public func arrivals(code: String) async -> [Arrival] {
        guard let text = try? await get("/estimacion/ocupacion/\(code)") else { return [] }
        return Self.parseOccupancy(text)
    }

    /// Minutes to the next bus of `line` ("MB106A") at a stop code, for the planner.
    public func nextBus(code: String, line: String) async -> Int? {
        await arrivals(code: code)
            .filter { $0.line == line }
            .map { EmtClient.etaMinutes($0) }
            .filter { $0 != Int.max }
            .min()
    }

    /// Every line's official colour ("MB150" → 0x25D5FF), from one request.
    public func lineColors() async -> [String: Int] {
        guard let text = try? await get("/old/routes") else { return [:] }
        return Self.parseLineColors(text)
    }

    static func parseLineColors(_ text: String) -> [String: Int] {
        guard let routes = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else { return [:] }
        var out: [String: Int] = [:]
        for route in routes {
            guard let short = route["route_short_name"].map({ "\($0)" }), !short.isEmpty,
                  let hex = route["route_color"] as? String,
                  let color = Int(hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")), radix: 16) else { continue }
            out["MB\(short)"] = color
        }
        return out
    }

    /// Live positions of the buses on `lines`. There is no fleet endpoint, but
    /// every stop's estimates carry the GPS fix of the buses heading to it,
    /// so sampling every `step`-th stop along both directions finds every
    /// bus on the line with a GPS unit (about 1 s per line). Buses that
    /// report no position are left out.
    public func vehicles(lines: [String], network: MetrobusNetwork, step: Int = 4, maxStops: Int = 60) async -> [MetrobusVehicle] {
        var codes: [String] = []
        var seen = Set<String>()
        for line in lines {
            guard let route = network.routes[line] else { continue }
            for direction in [route.ida, route.vuelta] {
                let ids = direction.stops
                for (index, id) in ids.enumerated() where index % step == 0 || index == ids.count - 1 {
                    if let stopId = Int(id), let code = network.codes[stopId], seen.insert(code).inserted { codes.append(code) }
                }
            }
        }
        codes = Array(codes.prefix(maxStops))
        let wanted = Set(lines)
        var byId: [Int: MetrobusVehicle] = [:]
        for chunk in stride(from: 0, to: codes.count, by: 8) {
            let slice = codes[chunk..<min(chunk + 8, codes.count)]
            await withTaskGroup(of: [MetrobusVehicle].self) { group in
                for code in slice {
                    group.addTask { (try? await self.get("/estimacion/ocupacion/\(code)")).map(Self.parseVehicles) ?? [] }
                }
                for await found in group {
                    for vehicle in found where wanted.contains(vehicle.line) { byId[vehicle.id] = vehicle }
                }
            }
        }
        return byId.values.sorted { ($0.line, $0.id) < ($1.line, $1.id) }
    }

    /// Buses with a GPS fix in one stop's estimates reply.
    static func parseVehicles(_ text: String) -> [MetrobusVehicle] {
        guard let items = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else { return [] }
        var out: [MetrobusVehicle] = []
        for item in items {
            let line = "MB" + (item["line"].map { "\($0)" } ?? "")
            for estimation in item["estimations"] as? [[String: Any]] ?? [] {
                guard let id = jsonInt(estimation["vehicleId"]),
                      let almex = estimation["almex"] as? [String: Any],
                      let lat = jsonDouble(almex["latitude"]), let lon = jsonDouble(almex["longitude"]),
                      lat != 0, lon != 0 else { continue }
                let destination = (almex["DestStopName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? item["route"] as? String ?? ""
                let occupancy = (estimation["ocupacion"] as? String ?? "").uppercased()
                out.append(MetrobusVehicle(id: id, line: line, destination: destination, lat: lat, lon: lon,
                                           occupancy: occupancy == "SIN DATOS" ? "" : occupancy))
            }
        }
        return out
    }

    /// The whole day's timetable for a stop code.
    public func schedule(code: String, date: Date = Date()) async -> [ScheduledDeparture] {
        guard let text = try? await get("/stops/code/\(code)/times?date=\(Self.dayFormat.string(from: date))") else { return [] }
        return Self.parseSchedule(text)
    }

    /// Shapes of just the given lines ("MB1"…), used when a stop is selected.
    public func routes(for lines: [String]) async -> [MetrobusRoute] {
        guard !lines.isEmpty, let text = try? await get("/old/routes"),
              let routes = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else { return [] }
        var out: [MetrobusRoute] = []
        for route in routes {
            let line = "MB" + (route["route_short_name"] as? String ?? jsonInt(route["route_short_name"]).map(String.init) ?? "")
            guard lines.contains(line), let id = route["route_id"].map({ "\($0)" }) else { continue }
            let concesion = route["concesion"].map { "\($0)" } ?? ""
            let color = Int((route["route_color"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16)
                ?? 0x0EA5E9
            var shapes: [[LonLat]] = []
            for direction in 0...1 {
                guard let geo = try? await get("/routes/\(id)/shapes?direction=\(direction)&concesion=\(concesion)") else { continue }
                shapes += Self.parseShapes(geo)
            }
            out.append(MetrobusRoute(line: line, color: color, shapes: shapes))
        }
        return out
    }

    /// Service notices scraped from metgovalencia.com (title + PDF link).
    public func incidents() async -> [Incident] {
        guard let html = try? await HTTP.get(URL(string: "https://metgovalencia.com/avisos-de-lineas/")!,
                                             headers: ["User-Agent": "Mozilla/5.0"]) else { return [] }
        return Self.parseIncidents(html)
    }

    /// Metrobús stops and the stop sequence of every line in both directions,
    /// for the trip planner (Android's `metrobusNetwork`). Stops get ids from
    /// `baseId` up so they never clash with EMT or Metro; `codes` maps them
    /// back to the stop codes the live arrivals use. Shapes are the straight
    /// path through the stops (enough to draw a planned ride).
    public func network(baseId: Int = MetrobusNetwork.baseId) async -> MetrobusNetwork {
        guard let text = try? await get("/old/routes"),
              let routes = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else { return .empty }
        struct Request: Sendable { let line: String; let route: String; let concesion: String; let direction: Int }
        var requests: [Request] = []
        for route in routes {
            guard let short = route["route_short_name"].map({ "\($0)" }), !short.isEmpty,
                  let id = route["route_id"].map({ "\($0)" }) else { continue }
            let concesion = route["concesion"].map { "\($0)" } ?? ""
            for direction in [0, 1] { requests.append(Request(line: "MB\(short)", route: id, concesion: concesion, direction: direction)) }
        }
        // ~200 small requests: a few at a time so the service is not flooded.
        var replies: [Int: String] = [:]
        for chunk in stride(from: 0, to: requests.count, by: 8) {
            let slice = Array(requests.enumerated())[chunk..<min(chunk + 8, requests.count)]
            await withTaskGroup(of: (Int, String?).self) { group in
                for (index, request) in slice {
                    group.addTask {
                        let path = "/routes/\(request.route)/stops?direction=\(request.direction)&concesion=\(request.concesion)"
                        return (index, try? await self.get(path))
                    }
                }
                for await (index, reply) in group { if let reply { replies[index] = reply } }
            }
        }
        var builder = MetrobusNetwork.Builder(baseId: baseId)
        for (index, request) in requests.enumerated() {
            builder.add(line: request.line, direction: request.direction, reply: replies[index] ?? "")
        }
        return builder.build()
    }

    private func get(_ path: String) async throws -> String {
        try await HTTP.get(URL(string: Self.api + path)!, headers: Self.headers)
    }

    // MARK: - Parsing

    static func parseStops(_ text: String) -> [Place] {
        guard let items = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let name = item["stop_name"] as? String, !name.isEmpty,
                  let lat = jsonDouble(item["stop_lat"]), let lon = jsonDouble(item["stop_lon"]) else { return nil }
            let code = item["stop_code"].map { "\($0)" } ?? ""
            return Place(id: "mb-\(code)", network: .metrobus, name: name, lat: lat, lon: lon,
                         detail: item["concesion"].map { "\($0)" } ?? "")
        }
    }

    static func parseOccupancy(_ text: String) -> [Arrival] {
        guard let items = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else { return [] }
        var out: [(Int, Arrival)] = []
        for item in items {
            guard let estimation = (item["estimations"] as? [[String: Any]])?.first,
                  let minutes = jsonInt(estimation["minutesToArrival"]), minutes >= 0 else { continue }
            let occupancy = estimation["ocupacion"] as? String ?? ""
            let line = "MB" + (item["line"].map { "\($0)" } ?? "")
            out.append((minutes, Arrival(line: line, destination: item["route"] as? String ?? "",
                                         minutes: occupancy.isEmpty ? "\(minutes) min" : "\(minutes) min · \(occupancy)")))
        }
        return out.sorted { $0.0 < $1.0 }.map(\.1)
    }

    static func parseSchedule(_ text: String) -> [ScheduledDeparture] {
        guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [] }
        var out: [ScheduledDeparture] = []
        for (key, value) in root {
            guard let hour = Int(key), let items = value as? [[String: Any]] else { continue }
            for item in items {
                guard let minute = jsonInt(item["minute"]) else { continue }
                let line = "MB" + (item["route_short_name"].map { "\($0)" } ?? "")
                // GTFS pickup_type 1 = no pickup; the last stop of a trip has none either.
                let dropOffOnly = jsonInt(item["pickup_type"]) == 1 || (item["isLastStop"] as? Bool ?? false)
                out.append(ScheduledDeparture(hour: hour, minute: minute, line: line, destination: item["direction"] as? String ?? "",
                                        dropOffOnly: dropOffOnly))
            }
        }
        return out.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
    }

    static func parseShapes(_ text: String) -> [[LonLat]] {
        guard
            let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            let features = root["features"] as? [[String: Any]]
        else { return [] }
        return features.compactMap { feature in
            let coords = (feature["geometry"] as? [String: Any])?["coordinates"] as? [[Any]] ?? []
            let shape = coords.compactMap { raw -> LonLat? in
                let p = raw.compactMap(jsonDouble)
                return p.count >= 2 ? LonLat(lon: p[0], lat: p[1]) : nil
            }
            return shape.count >= 2 ? shape : nil
        }
    }

    static func parseIncidents(_ html: String) -> [Incident] {
        var seen = Set<String>()
        var out: [Incident] = []
        for match in html.matches(of: #"<a [^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            let href = match[1]
            let text = match[2].htmlText
            guard href.contains("/wp-content/uploads/"), text.count > 4, seen.insert(text).inserted else { continue }
            out.append(Incident(title: text, date: "", lines: [], network: .metrobus, url: href))
        }
        return out
    }

    // Same values as EmtRepository.kt.
    static let api = "https://api.softoursistemas.com/metrobus"
    static let headers = [
        "Accept": "application/json",
        "User-Agent": "Mozilla/5.0 (Linux; Android 17; Pixel 8a)",
        "x-requested-with": "com.softoursistemas.metgovalencia",
        "Origin": "https://localhost",
        "Referer": "https://localhost/",
    ]

    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()
}

/// A Metrobús bus with a live GPS fix.
public struct MetrobusVehicle: Identifiable, Hashable, Sendable {
    public let id: Int
    /// "MB170B"
    public let line: String
    public let destination: String
    public let lat: Double
    public let lon: Double
    /// "BAJA", "MEDIA", "ALTA"… or empty when unknown.
    public let occupancy: String
}

/// The Metrobús network folded into the planner.
public struct MetrobusNetwork: Sendable {
    public static let baseId = 2_000_000
    public static let empty = MetrobusNetwork(stops: [], routes: [:], codes: [:])

    public let stops: [Stop]
    public let routes: [String: BusRoute]
    /// Planner stop id → Metrobús stop code.
    public let codes: [Int: String]

    /// Network-wide id of a planner stop, if it is a Metrobús one.
    public static func isMetrobus(_ stopId: Int) -> Bool { stopId >= baseId }

    /// Merges this network into the EMT/Metro data.
    public func merged(into transit: TransitData) -> TransitData {
        guard !stops.isEmpty else { return transit }
        var byId = transit.stopsById
        for stop in stops { byId[String(stop.id)] = stop }
        return TransitData(stops: transit.stops + stops, stopsById: byId, routes: transit.routes.merging(routes) { old, _ in old })
    }

    struct Builder {
        var nextId: Int
        var idByCode: [String: Int] = [:]
        var info: [Int: (name: String, lat: Double, lon: Double)] = [:]
        var linesAt: [Int: Set<String>] = [:]
        var directions: [String: [Int: RouteDirection]] = [:]

        init(baseId: Int) { nextId = baseId }

        /// One `/routes/{id}/stops` reply for a line and direction.
        mutating func add(line: String, direction: Int, reply: String) {
            guard let root = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any],
                  let items = root["stops"] as? [[String: Any]] else { return }
            var ids: [String] = []
            var shape: [LonLat] = []
            for item in items {
                guard let code = item["stop_code"].map({ "\($0)" }), !code.isEmpty,
                      let lat = jsonDouble(item["stop_lat"]), let lon = jsonDouble(item["stop_lon"]) else { continue }
                let id: Int
                if let known = idByCode[code] {
                    id = known
                } else {
                    id = nextId
                    nextId += 1
                    idByCode[code] = id
                    info[id] = (item["stop_name"] as? String ?? code, lat, lon)
                }
                linesAt[id, default: []].insert(line)
                ids.append(String(id))
                shape.append(LonLat(lon: lon, lat: lat))
            }
            guard !ids.isEmpty else { return }
            directions[line, default: [:]][direction] = RouteDirection(shapes: shape.count >= 2 ? [shape] : [], stops: ids)
        }

        func build() -> MetrobusNetwork {
            var routes: [String: BusRoute] = [:]
            for (line, byDirection) in directions {
                guard let first = byDirection[0] ?? byDirection[1] else { continue }
                routes[line] = BusRoute(ida: first, vuelta: byDirection[1] ?? first)
            }
            let stops = info.keys.sorted().compactMap { id -> Stop? in
                guard let item = info[id] else { return nil }
                return Stop(id: id, name: item.name, lines: (linesAt[id] ?? []).sorted(), lat: item.lat, lon: item.lon)
            }
            return MetrobusNetwork(stops: stops, routes: routes,
                                   codes: Dictionary(idByCode.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a }))
        }
    }
}
