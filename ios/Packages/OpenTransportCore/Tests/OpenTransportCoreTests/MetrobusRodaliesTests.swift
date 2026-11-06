import XCTest
@testable import OpenTransportCore

final class MetrobusRodaliesTests: XCTestCase {
    private var assets: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("app/src/main/assets")
    }

    func testRodaliesBundledNetwork() {
        let data = RodaliesData.load(from: assets)
        XCTAssertGreaterThan(data.places.count, 40)
        let castello = data.places.first { $0.name == "Castelló de la Plana" }
        XCTAssertEqual(castello?.lines, ["C6"])
        XCTAssertEqual(castello?.network, .rodalies)
        XCTAssertTrue(castello?.id.hasPrefix("rd-") ?? false)
        XCTAssertFalse(data.routes["C6"]?.ida.shapes.first?.isEmpty ?? true)
    }

    func testRodaliesTimesWithinThreeHours() {
        let data = RodaliesData(places: [], routes: [:], timetable: [
            "Sagunt": ["05:40|C6|València", "06:10|C6|CIVIS", "09:30|C6|Late", "bad"],
        ])
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 23; components.hour = 6; components.minute = 0
        let now = Calendar.current.date(from: components)!
        let times = data.times(at: "Sagunt", now: now)
        // 05:40 is tomorrow (> 3 h away); 09:30 is 3 h 30 min away.
        XCTAssertEqual(times, [Arrival(line: "C6", destination: "CIVIS", minutes: "10 min")])
        XCTAssertTrue(data.times(at: "Nowhere").isEmpty)
    }

    func testRodaliesAlertsKeepValencianRoutes() {
        let json = """
        {"entity":[
          {"alert":{"informedEntity":[{"routeId":"40T0001C1"}],"headerText":{"translation":[{"text":"Obras C1","language":"es"}]},
                    "descriptionText":{"translation":[{"text":"Works","language":"en"},{"text":"Obras entre X e Y","language":"es"}]}}},
          {"alert":{"informedEntity":[{"routeId":"10T0001C1"}],"headerText":{"translation":[{"text":"Madrid"}]}}}]}
        """
        let alerts = RodaliesAlerts.parse(json)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].title, "Obras C1")
        XCTAssertEqual(alerts[0].detail, "Obras entre X e Y")
        XCTAssertEqual(alerts[0].network, .rodalies)
    }

    func testMetrobusStopsAndOccupancy() {
        let stops = MetrobusClient.parseStops(#"[{"stop_code":"1234","stop_name":"Alboraia","stop_lat":39.5,"stop_lon":-0.35,"concesion":"MB2"},{"stop_name":""}]"#)
        XCTAssertEqual(stops.map(\.id), ["mb-1234"])
        XCTAssertEqual(stops[0].detail, "MB2")

        let arrivals = MetrobusClient.parseOccupancy("""
        [{"line":"110","route":"València","estimations":[{"minutesToArrival":12,"ocupacion":"Baja"}]},
         {"line":"112","route":"Port Saplaya","estimations":[{"minutesToArrival":3}]},
         {"line":"113","estimations":[{"minutesToArrival":-1}]}]
        """)
        XCTAssertEqual(arrivals, [
            Arrival(line: "MB112", destination: "Port Saplaya", minutes: "3 min"),
            Arrival(line: "MB110", destination: "València", minutes: "12 min · Baja"),
        ])
    }

    func testMetrobusScheduleSorted() {
        let schedule = MetrobusClient.parseSchedule(#"{"8":[{"minute":"15","route_short_name":"110","direction":"A"}],"7":[{"minute":"50","route_short_name":"112","direction":"B"},{"minute":"05","route_short_name":"110","direction":"A"}]}"#)
        XCTAssertEqual(schedule.map { "\($0.hour):\($0.minute) \($0.line)" }, ["7:5 MB110", "7:50 MB112", "8:15 MB110"])
    }

    func testMetrobusIncidentsOnlyUploads() {
        let html = """
        <a href="https://metgovalencia.com/wp-content/uploads/2026/10/aviso.pdf"><strong>Desvío línea 110</strong></a>
        <a href="https://metgovalencia.com/contacto/">Contacto</a>
        <a href="https://metgovalencia.com/wp-content/uploads/x.pdf">Desvío línea 110</a>
        """
        let incidents = MetrobusClient.parseIncidents(html)
        XCTAssertEqual(incidents.map(\.title), ["Desvío línea 110"])
        XCTAssertTrue(incidents[0].url.hasSuffix("aviso.pdf"))
    }
}

final class MetrobusNetworkTests: XCTestCase {
    private func reply(_ stops: [(String, Double, Double)]) -> String {
        let items = stops.map { #"{"stop_code":"\#($0.0)","stop_name":"S\#($0.0)","stop_lat":\#($0.1),"stop_lon":\#($0.2)}"# }
        return #"{"isCircular":false,"stops":[\#(items.joined(separator: ","))]}"#
    }

    func testBuildsStopsAndBothDirections() {
        var builder = MetrobusNetwork.Builder(baseId: MetrobusNetwork.baseId)
        builder.add(line: "MB1", direction: 0, reply: reply([("10", 39.40, -0.40), ("11", 39.41, -0.41), ("12", 39.42, -0.42)]))
        builder.add(line: "MB1", direction: 1, reply: reply([("12", 39.42, -0.42), ("10", 39.40, -0.40)]))
        builder.add(line: "MB2", direction: 0, reply: reply([("11", 39.41, -0.41), ("20", 39.43, -0.43)]))
        builder.add(line: "MB3", direction: 0, reply: "not json")
        let network = builder.build()

        XCTAssertEqual(network.stops.count, 4) // shared stops are merged by code
        XCTAssertTrue(network.stops.allSatisfy { MetrobusNetwork.isMetrobus($0.id) })
        let transfer = network.stops.first { network.codes[$0.id] == "11" }
        XCTAssertEqual(transfer?.lines, ["MB1", "MB2"])
        XCTAssertEqual(network.routes["MB1"]?.ida.stops.count, 3)
        XCTAssertEqual(network.routes["MB1"]?.vuelta.stops.count, 2)
        XCTAssertEqual(network.routes["MB2"]?.vuelta.stops.count, 2) // one direction: reused
        XCTAssertNil(network.routes["MB3"])
        XCTAssertEqual(network.routes["MB1"]?.ida.shapes.first?.count, 3)
    }

    func testPlannerUsesMergedMetrobus() async {
        var builder = MetrobusNetwork.Builder(baseId: MetrobusNetwork.baseId)
        builder.add(line: "MB1", direction: 0, reply: reply([("10", 39.40, -0.40), ("11", 39.43, -0.40)]))
        let network = builder.build()
        let transit = network.merged(into: TransitData(stops: [], stopsById: [:], routes: [:]))
        let planner = JourneyPlanner(transit: transit,
                                     streetWalk: { a, b in let d = TransitMotion.distanceMeters(a, b); return (d, d) },
                                     nextBus: { _, _ in 3 })
        let options = await planner.plan(from: LonLat(lon: -0.40, lat: 39.40), to: LonLat(lon: -0.40, lat: 39.43))
        XCTAssertEqual(options.first?.legs.first { !$0.walk }?.line, "MB1")
    }
}

final class MetrobusVehicleTests: XCTestCase {
    func testParsesOnlyBusesWithGPS() {
        // Trimmed real reply of /estimacion/ocupacion/3940.
        let reply = #"[{"line":"170B","route":"Torrent (El Vedat)","estimations":[{"vehicleId":6324,"minutesToArrival":20,"ocupacion":"SIN DATOS"},{"vehicleId":6320,"minutesToArrival":51,"ocupacion":"ALTA","almex":{"bus":"6320","DestStopName":"Cid - Hospital General","passengers":70,"latitude":"39.469726","longitude":"-0.406643","position":28,"seats":81}}]},{"line":"192B","route":"Millares","estimations":[{"vehicleId":6015,"minutesToArrival":125,"ocupacion":"SIN DATOS","almex":{"latitude":"0","longitude":"0"}}]}]"#
        let vehicles = MetrobusClient.parseVehicles(reply)
        XCTAssertEqual(vehicles.count, 1)
        XCTAssertEqual(vehicles.first?.id, 6320)
        XCTAssertEqual(vehicles.first?.line, "MB170B")
        XCTAssertEqual(vehicles.first?.destination, "Cid - Hospital General")
        XCTAssertEqual(vehicles.first?.occupancy, "ALTA")
        XCTAssertEqual(vehicles.first?.lat ?? 0, 39.469726, accuracy: 1e-6)
        XCTAssertTrue(MetrobusClient.parseVehicles("<html>").isEmpty)
    }
}

final class MetrobusScheduleTests: XCTestCase {
    func testDropOffOnlyAndMinuteOfDay() {
        // Trimmed real reply of /stops/code/700/times.
        let reply = #"{"05":[{"minute":"15","route_short_name":"161","direction":"València","pickup_type":1,"isLastStop":false},{"minute":"26","route_short_name":"160B","direction":"València","pickup_type":0,"isLastStop":true}],"14":[{"minute":"07","route_short_name":"150","direction":"Aeroport","pickup_type":0,"isLastStop":false}]}"#
        let times = MetrobusClient.parseSchedule(reply)
        XCTAssertEqual(times.map(\.line), ["MB161", "MB160B", "MB150"])
        XCTAssertEqual(times.map(\.dropOffOnly), [true, true, false])
        XCTAssertEqual(times.last?.minuteOfDay, 14 * 60 + 7)
    }

    func testRodaliesFullDaySchedule() {
        let data = RodaliesData(places: [], routes: [:], timetable: [
            "X": ["06:10|C6|CIVIS", "05:40|C6|València-Estació del Nord", "24:05|C1|Gandia", "bad"],
        ])
        let times = data.schedule(at: "X")
        XCTAssertEqual(times.map(\.minuteOfDay), [5, 340, 370]) // 00:05, 05:40, 06:10
        XCTAssertEqual(times.last?.destination, "CIVIS")
        XCTAssertTrue(data.schedule(at: "Nowhere").isEmpty)
    }

    func testLineColors() {
        let reply = #"[{"route_short_name":"150","route_color":"25D5FF"},{"route_short_name":"160B","route_color":"fe8686"},{"route_short_name":"9","route_color":""},{"route_color":"FFFFFF"}]"#
        XCTAssertEqual(MetrobusClient.parseLineColors(reply), ["MB150": 0x25D5FF, "MB160B": 0xFE8686])
    }
}
