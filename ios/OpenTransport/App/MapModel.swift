import Foundation
import Observation
import OpenTransportCore

/// What the bottom sheet over the map is showing. Only one at a time, like
/// the panes stacked over the map in EmtApp.kt.
enum MapSheet: Identifiable, Hashable {
    case stop(Int)
    case line(String)
    case bus(Int)
    case place(String)
    /// A live Metrobús bus, opened from the selected Metrobús stop.
    case metrobusBus(Int)
    case nearby
    case journey

    var id: String {
        switch self {
        case .stop(let id): return "stop-\(id)"
        case .line(let line): return "line-\(line)"
        case .bus(let number): return "bus-\(number)"
        case .place(let id): return "place-\(id)"
        case .metrobusBus(let id): return "metrobus-bus-\(id)"
        case .nearby: return "nearby"
        case .journey: return "journey"
        }
    }
}

/// A one-shot camera move; `id` changes on every request so the map view can
/// tell a new request from a re-render.
struct CameraRequest: Equatable {
    enum Kind: Equatable {
        case center(LonLat, zoom: Double)
        case fit(LngLatBounds)
        /// Tilt for the 3D perspective (0 = flat).
        case pitch(Double)
        /// North up, framing `bounds` when given (Android's resetView).
        case reset(LngLatBounds?)
    }

    let id: Int
    let kind: Kind
}

/// Map selection state: selected stop, focused line, followed bus.
@MainActor
@Observable
final class MapModel {
    /// Set by the methods below (and cleared by the sheet binding on dismiss).
    var sheet: MapSheet?
    private(set) var currentLine: String?
    private(set) var cameraRequest: CameraRequest?
    /// 3D perspective of the free map (Android's tilt button, 55°).
    private(set) var tilted = false
    let live = LiveBuses()

    @ObservationIgnored private var transit: TransitData?
    @ObservationIgnored private var lastPresented: MapSheet?

    func configure(transit: TransitData, client: EmtClient) {
        self.transit = transit
        live.configure(transit: transit, client: client)
    }

    var selectedStopId: Int? {
        if case .stop(let id) = sheet { return id }
        return nil
    }

    /// The trip chosen in Plan, drawn on the map with its own sheet.
    private(set) var journey: PlannedJourney?

    /// The selected Metro/Valenbisi/… point (kept whole: places reload often).
    private(set) var selectedPlace: Place?


    func selectStop(_ id: Int) {
        guard let stop = transit?.stopsById[String(id)] else { return }
        currentLine = nil
        live.track(line: nil)
        present(.stop(id))
        move(.center(LonLat(lon: stop.lon, lat: stop.lat), zoom: 16.5))
    }

    func selectPlace(_ place: Place) {
        currentLine = nil
        live.track(line: nil)
        selectedPlace = place
        present(.place(place.id))
        move(.center(LonLat(lon: place.lon, lat: place.lat), zoom: 16.5))
    }

    /// Same place with fresh data (no camera move, sheet stays).
    func refreshSelectedPlace(_ place: Place) {
        guard selectedPlace?.id == place.id else { return }
        selectedPlace = place
    }

    func selectLine(_ line: String) {
        guard let route = transit?.routes[line] else { return }
        if currentLine != line { live.track(line: line) }
        currentLine = line
        present(.line(line))
        if let bounds = route.bounds { move(.fit(bounds)) }
    }

    func showJourney(_ planned: PlannedJourney) {
        currentLine = nil
        live.track(line: nil)
        journey = planned
        present(.journey)
        if let bounds = planned.bounds { move(.fit(bounds)) }
    }

    /// "Stops near me" (Android pops it on the first location fix and on the
    /// location button).
    func showNearby() {
        currentLine = nil
        live.track(line: nil)
        present(.nearby)
    }

    /// Follows one live bus of the focused line; the camera tracks it.
    /// Opens a live Metrobús bus of the selected stop and centres on it.
    func selectMetrobusBus(_ vehicle: MetrobusVehicle) {
        guard selectedPlace?.network == .metrobus else { return }
        present(.metrobusBus(vehicle.id))
        move(.center(LonLat(lon: vehicle.lon, lat: vehicle.lat), zoom: 15.5))
    }

    /// Opens a live EMT bus and centres on it once, leaving the map free:
    /// the same as a Metrobús bus (`selectMetrobusBus`).
    func followBus(_ number: Int) {
        guard let bus = live.buses.first(where: { $0.number == number }) else { return }
        present(.bus(number))
        move(.center(bus.render, zoom: 15.5))
    }

    private func present(_ next: MapSheet) {
        switch next {
        case .place, .metrobusBus: break // the bus belongs to the selected stop
        default: selectedPlace = nil
        }
        if case .journey = next {} else { journey = nil }
        lastPresented = next
        sheet = next
    }

    /// Called when the sheet goes away (swiped down or closed).
    func sheetDismissed() {
        guard sheet == nil else { return }
        // Leaving a followed bus goes back to its line, as on Android.
        if case .bus = lastPresented, let line = currentLine {
            present(.line(line))
            return
        }
        // Leaving a Metrobús bus goes back to its stop.
        if case .metrobusBus = lastPresented, let place = selectedPlace {
            present(.place(place.id))
            return
        }
        currentLine = nil
        selectedPlace = nil
        journey = nil
        live.track(line: nil)
    }

    func close() {
        lastPresented = nil
        sheet = nil
        sheetDismissed()
    }

    func toggleTilt() {
        tilted.toggle()
        move(.pitch(tilted ? 55 : 0))
    }

    /// North up, keeping the tilt: flattening is the 2D/3D button's job.
    func resetView() {
        move(.reset(currentLine.flatMap { transit?.routes[$0]?.bounds }))
    }

    func move(_ kind: CameraRequest.Kind) {
        cameraRequest = CameraRequest(id: (cameraRequest?.id ?? 0) + 1, kind: kind)
    }
}

/// Polls EMT for the focused line's buses and feeds the tracker. The map reads
/// `tracker` every animation frame; sheets observe `buses`, refreshed per poll.
@MainActor
@Observable
final class LiveBuses {
    private(set) var buses: [BusPosition] = []
    private(set) var line: String?

    @ObservationIgnored private(set) var tracker: BusTracker?
    @ObservationIgnored private var client: EmtClient?
    @ObservationIgnored private var task: Task<Void, Never>?

    static let pollInterval: Duration = .seconds(1)

    func configure(transit: TransitData, client: EmtClient) {
        tracker = BusTracker(transit: transit)
        self.client = client
    }

    func track(line: String?) {
        task?.cancel()
        task = nil
        // Drop the previous line's buses at once so a stale one can't be tapped.
        tracker?.clear()
        buses = []
        self.line = line
        guard let line, let tracker, let client else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                if let fixes = try? await client.fetchBuses(line: line), !Task.isCancelled {
                    tracker.merge(fixes)
                    self?.buses = tracker.buses
                }
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }
}
