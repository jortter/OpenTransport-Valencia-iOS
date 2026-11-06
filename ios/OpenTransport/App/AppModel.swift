import Foundation
import Observation
import OpenTransportCore

/// App-wide state: static network data, the API client and saved stops.
/// (On Android this all lives inside the `EmtApp()` composable.)
@MainActor
@Observable
final class AppModel {
    private(set) var transit: TransitData?
    private(set) var client: EmtClient?
    private(set) var loadError: String?
    /// Saved stops and places, keyed like Android: "emt-<stop>" or a place id ("mt-20", "vb-1"…).
    private(set) var favorites: [String]
    var tab: AppTab
    /// Stop+line pairs to alert about ("<stop>:<line>" or "mb-<code>:<line>").
    private(set) var pins: Set<String>
    private let alerts = ArrivalAlerts()
    /// Service alerts of every network, shown in Alerts and in stop/place sheets.
    private(set) var incidents: [Incident]?
    /// Points of the other networks (Metro stations so far).
    private(set) var places: [Place] = []
    /// Trip planner over EMT, Metro and (once fetched) Metrobús itineraries.
    @ObservationIgnored private(set) var planner: JourneyPlanner?
    /// The planner's network: `transit` plus the Metrobús stops and lines.
    private(set) var planTransit: TransitData?
    /// Every Metrobús line's stops (loaded with the planner); live buses use it.
    @ObservationIgnored private var metrobusNetwork: MetrobusNetwork = .empty
    /// Live Metrobús buses on the lines of the selected Metrobús stop.
    private(set) var metrobusVehicles: [MetrobusVehicle] = []
    @ObservationIgnored private var metrobusLiveTask: Task<Void, Never>?
    /// Bumped on every places reload, so the map knows to redraw them.
    private(set) var placesVersion = 0
    private(set) var metroAssets = MetroAssets(stationNames: [:], lineColors: [:])
    let map = MapModel()
    let location = LocationModel()
    let metro = MetroClient()
    let valenbisi = ValenbisiClient()
    let metrobus = MetrobusClient()
    private(set) var rodalies: RodaliesData?
    /// Route shapes beyond EMT/Metro: Rodalies, and Metrobús lines once loaded.
    private(set) var extraRoutes: [String: BusRoute] = [:]
    private(set) var extraColors: [String: Int] = [:]
    @ObservationIgnored private var metrobusTask: Task<Void, Never>?
    @ObservationIgnored private var bikesTask: Task<Void, Never>?

    private static let favoritesKey = "favorite_keys"
    private static let legacyFavoritesKey = "favorites" // [Int] EMT stop ids from the first builds

    init() {
        let defaults = UserDefaults.standard
        if let keys = defaults.stringArray(forKey: Self.favoritesKey) {
            favorites = keys
        } else {
            let migrated = ((defaults.array(forKey: Self.legacyFavoritesKey) as? [Int]) ?? []).map(Self.stopKey)
            favorites = migrated
            defaults.set(migrated, forKey: Self.favoritesKey)
        }
        pins = Set(defaults.stringArray(forKey: ArrivalAlerts.pinsKey) ?? [])
        // `-initialTab settings` as a launch argument opens that tab (used by CI screenshots).
        tab = AppTab(rawValue: UserDefaults.standard.string(forKey: "initialTab") ?? "") ?? .map
    }

    /// Switches to the map and opens a stop there (from Saved, search…).
    func openStop(_ id: Int) {
        tab = .map
        map.selectStop(id)
    }

    /// Spanish/Valencian devices start in their language; everything else in English.
    static var defaultLanguage: Language {
        let code = Locale.preferredLanguages.first?.lowercased() ?? ""
        if code.hasPrefix("ca") || code.hasPrefix("va") { return .va }
        if code.hasPrefix("es") { return .es }
        return .en
    }

    func load() async {
        guard transit == nil else { return }
        guard let directory = Bundle.main.url(forResource: "assets", withExtension: nil) else {
            loadError = "Missing bundled assets"
            return
        }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try TransitDataLoader.load(from: directory)
            }.value
            let emt = EmtClient(data: data)
            transit = data
            client = emt
            metroAssets = await Task.detached { MetroAssets.load(from: directory) }.value
            let rodaliesData = await Task.detached { RodaliesData.load(from: directory) }.value
            rodalies = rodaliesData
            extraRoutes.merge(rodaliesData.routes) { _, new in new }
            for line in rodaliesData.routes.keys { extraColors[line] = 0xE30613 }
            replacePlaces(of: .rodalies, with: rodaliesData.places)
            map.configure(transit: data, client: emt)
            planner = makePlanner(data, emt: emt, metrobusCodes: [:])
            planTransit = data
            startMetrobusPlanner(data, emt: emt)
            location.start()
            alerts.start(model: self)
            startMetrobus()
            openDemoSelection()
            async let metroStations = metro.stations()
            await refreshIncidents()
            replacePlaces(of: .metro, with: await metroStations)
            // Valenbisi availability changes all the time: refresh every minute, like Android.
            bikesTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let stations = await self.valenbisi.stations()
                    self.replacePlaces(of: .valenbisi, with: stations)
                    self.openDemoPlace()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
            openDemoPlace()
        } catch {
            loadError = String(describing: error)
        }
    }

    /// `-demoStop 7` / `-demoLine 19` launch arguments (used by CI screenshots).
    private func openDemoSelection() {
        let defaults = UserDefaults.standard
        if let line = defaults.string(forKey: "demoLine") {
            map.selectLine(line)
        } else if defaults.integer(forKey: "demoStop") > 0 {
            map.selectStop(defaults.integer(forKey: "demoStop"))
        }
    }

    /// `-demoPlace mt-20` (used by CI screenshots): opened once, as soon as
    /// that network's points have loaded.
    private func openDemoPlace() {
        guard !demoPlaceOpened, let id = UserDefaults.standard.string(forKey: "demoPlace"),
              let place = places.first(where: { $0.id == id }) else { return }
        demoPlaceOpened = true
        select(place)
    }
    @ObservationIgnored private var demoPlaceOpened = false

    /// A CI demo selection was asked for at launch (no "nearby" popup then).
    static var hasDemoSelection: Bool {
        let defaults = UserDefaults.standard
        return defaults.string(forKey: "demoPlace") != nil || defaults.string(forKey: "demoLine") != nil
            || defaults.integer(forKey: "demoStop") > 0
    }

    private func replacePlaces(of network: Network, with fresh: [Place]) {
        guard !fresh.isEmpty else { return }
        places = places.filter { $0.network != network } + fresh
        placesVersion += 1
        openDemoPlace()
        // Keep an open place sheet on the fresh numbers (bikes, docks…).
        if let selected = map.selectedPlace, let updated = fresh.first(where: { $0.id == selected.id }) {
            map.refreshSelectedPlace(updated)
        }
    }

    func place(_ id: String) -> Place? { places.first { $0.id == id } }


    /// Every route the map can draw.
    var mapRoutes: [String: BusRoute] {
        (transit?.routes ?? [:]).merging(extraRoutes) { _, extra in extra }
    }

    /// Brand colours for Metro, Rodalies and loaded Metrobús lines.
    var lineColors: [String: Int] {
        metroAssets.lineColors.merging(extraColors) { _, extra in extra }
    }

    /// Opens a place; a Metrobús stop then fetches its lines and their shapes
    /// (Android does the same when one is selected).
    func select(_ place: Place) {
        map.selectPlace(place)
        metrobusLiveTask?.cancel()
        metrobusVehicles = []
        guard place.network == .metrobus else { return }
        let code = String(place.id.dropFirst(3))
        Task {
            var lines: [String] = []
            for arrival in await metrobus.arrivals(code: code) where arrival.line.hasPrefix("MB") && !lines.contains(arrival.line) {
                lines.append(arrival.line)
            }
            for route in await metrobus.routes(for: lines) {
                extraRoutes[route.line] = BusRoute(ida: RouteDirection(shapes: route.shapes, stops: []),
                                                   vuelta: RouteDirection(shapes: [], stops: []))
                extraColors[route.line] = route.color
            }
            guard map.selectedPlace?.id == place.id else { return }
            var withLines = place
            withLines.lines = lines
            map.refreshSelectedPlace(withLines)
            startMetrobusLive(lines: lines, placeId: place.id)
        }
    }

    /// Polls the buses of a Metrobús stop's lines while it stays selected
    /// (their GPS fixes refresh about every 20 s).
    private func startMetrobusLive(lines: [String], placeId: String) {
        metrobusLiveTask?.cancel()
        guard !lines.isEmpty else { return }
        metrobusLiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.map.selectedPlace?.id == placeId else { break }
                if self.metrobusNetwork.stops.isEmpty {
                    // The network loads with the planner a few seconds after launch.
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                let vehicles = await self.metrobus.vehicles(lines: lines, network: self.metrobusNetwork)
                guard !Task.isCancelled, self.map.selectedPlace?.id == placeId else { break }
                self.metrobusVehicles = vehicles
                try? await Task.sleep(for: .seconds(20))
            }
            // No clean-up here: select() clears the list, and the map only
            // shows it while this Metrobús stop is selected.
        }
    }

    private func makePlanner(_ transit: TransitData, emt: EmtClient, metrobusCodes: [Int: String]) -> JourneyPlanner {
        let metrobus = self.metrobus
        return JourneyPlanner(
            transit: transit,
            streetWalk: { a, b in await EmtClient.walkMetrics(a, b) },
            nextBus: { stop, line in
                if let code = metrobusCodes[stop] { return await metrobus.nextBus(code: code, line: line) }
                return await emt.nextBus(stopId: stop, line: line)
            }
        )
    }

    /// Folds the Metrobús lines into the planner, like Android. Fetching
    /// every line's stops takes a few seconds; until then plans use EMT and
    /// Metro only. Retries a few times if the service is unreachable.
    private func startMetrobusPlanner(_ transit: TransitData, emt: EmtClient) {
        Task { [weak self] in
            for attempt in 0..<5 {
                guard let self else { return }
                let network = await self.metrobus.network()
                if !network.stops.isEmpty {
                    let merged = network.merged(into: transit)
                    self.metrobusNetwork = network
                    self.planner = self.makePlanner(merged, emt: emt, metrobusCodes: network.codes)
                    self.planTransit = merged
                    return
                }
                try? await Task.sleep(for: .seconds(60 * (attempt + 1)))
            }
        }
    }

    /// Metrobús has no bulk stop list, but one query from the city centre
    /// with a huge radius returns the whole network (~1100 stops, 400 KB).
    /// Around the user's location it can come back empty (outside the 7 km
    /// default radius), so the stops never showed. Retry every minute until
    /// it loads, then refresh hourly.
    private func startMetrobus() {
        metrobusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let stops = await self.metrobus.stops(lat: 39.4699, lon: -0.3763, radius: 2_000_000)
                if !stops.isEmpty { self.replacePlaces(of: .metrobus, with: stops) }
                try? await Task.sleep(for: .seconds(stops.isEmpty ? 60 : 60 * 60))
            }
        }
    }

    func refreshIncidents(force: Bool = false) async {
        guard let client else { return }
        async let emt = client.incidents(force: force)
        async let fgv = metro.incidents(locale: fgvLocale, stationNames: metroAssets.stationNames)
        async let metrobusAlerts = metrobus.incidents()
        async let rodaliesAlerts = RodaliesAlerts.fetch()
        incidents = await emt + fgv + metrobusAlerts + rodaliesAlerts
    }

    /// FGV translations are keyed ES / EN / VA (English as fallback).
    private var fgvLocale: String {
        Language.of(UserDefaults.standard.string(forKey: "language") ?? Self.defaultLanguage.rawValue).rawValue
    }

    /// Alerts that mention any of `lines` of `network` (one per line, like the
    /// Android sheets). Metro alerts use bare numbers ("3"), stations "M3".
    func incidents(for lines: [String], network: Network = .emt) -> [Incident] {
        var result: [Incident] = []
        for line in lines {
            let key = network == .metro && line.hasPrefix("M") ? String(line.dropFirst()) : line.uppercased()
            if let match = incidents?.first(where: { $0.network == network && $0.lines.contains(key) }), !result.contains(match) {
                result.append(match)
            }
        }
        return result
    }

    nonisolated static func stopKey(_ id: Int) -> String { "emt-\(id)" }

    func isPinned(_ pin: String) -> Bool { pins.contains(pin) }

    func togglePin(_ pin: String) {
        if pins.remove(pin) == nil {
            pins.insert(pin)
            ArrivalAlerts.requestPermission()
        }
        UserDefaults.standard.set(Array(pins), forKey: ArrivalAlerts.pinsKey)
    }

    func isFavorite(_ key: String) -> Bool { favorites.contains(key) }

    /// Saves the order the user dragged the visible saved items into.
    func reorderFavorites(shown: [String]) {
        favorites = Favorites.reorder(favorites, shown: shown)
        UserDefaults.standard.set(favorites, forKey: Self.favoritesKey)
    }

    func toggleFavorite(_ key: String) {
        if let index = favorites.firstIndex(of: key) {
            favorites.remove(at: index)
        } else {
            favorites.append(key)
        }
        UserDefaults.standard.set(favorites, forKey: Self.favoritesKey)
    }

    /// Switches to the map and opens a place there (from Saved, nearby…).
    func openPlace(_ place: Place) {
        tab = .map
        select(place)
    }
}
