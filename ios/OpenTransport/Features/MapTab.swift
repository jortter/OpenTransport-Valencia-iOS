import SwiftUI
import OpenTransportCore

struct MapTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.strings) private var s
    @Environment(\.colorScheme) private var colorScheme
    @State private var recenterRequest = 0
    @State private var showSearch = false
    @State private var showLayers = false
    /// Line and bus sheets open low so the live buses stay in view.
    @State private var detent = MapTab.peek
    static let peek = PresentationDetent.fraction(0.32)
    /// The nearby sheet pops once, on the first location fix (until closed).
    @State private var nearbyShown = false
    @AppStorage(MapPreferences.networksKey) private var networksSetting = MapPreferences.defaultNetworks
    @AppStorage(MapPreferences.styleKey) private var styleSetting = MapStyle.auto.rawValue

    var body: some View {
        @Bindable var map = model.map
        ZStack {
            if let transit = model.transit {
                TransitMapView(
                    scene: scene(transit),
                    routes: model.mapRoutes,
                    metroColors: model.lineColors,
                    live: map.live,
                    dark: (MapStyle(rawValue: styleSetting) ?? .auto).isDark(system: colorScheme),
                    cameraRequest: map.cameraRequest,
                    sheetFraction: detent == MapTab.peek ? 0.32 : 0.5,
                    recenterRequest: recenterRequest,
                    onSelectStop: { map.selectStop($0) },
                    onSelectBus: { map.followBus($0) },
                    onSelectPlace: { id in if let place = model.place(id) { model.select(place) } },
                    onSelectMetrobusBus: { map.selectMetrobusBus($0) }
                )
                .ignoresSafeArea(edges: .top)
                .overlay(alignment: .top) { searchButton }
                .overlay(alignment: .bottomTrailing) { mapButtons }
            } else if let error = model.loadError {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            } else {
                ProgressView(s.loading)
            }
        }
        .sheet(item: $map.sheet, onDismiss: { map.sheetDismissed() }) { sheet in
            Group {
                switch sheet {
                case .stop(let id): StopSheet(stopId: id)
                case .line(let line): LineSheet(line: line)
                case .bus(let number): FollowSheet(number: number)
                case .metrobusBus(let id): MetrobusBusSheet(id: id)
                case .place: if let place = map.selectedPlace { PlaceSheet(place: place) }
                case .nearby: NearbySheet()
                case .journey: if let journey = map.journey { JourneySheet(option: journey.option) }
                }
            }
            .presentationDetents([MapTab.peek, .medium, .large], selection: $detent)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .onChange(of: map.sheet?.id) { _, _ in
            switch map.sheet {
            case .line, .bus, .metrobusBus: detent = MapTab.peek
            case .some: detent = .medium
            case nil: break
            }
        }
        .onChange(of: model.location.location != nil) { _, located in
            if located, !nearbyShown, model.map.sheet == nil, model.tab == .map, !showSearch, !showLayers,
               !AppModel.hasDemoSelection {
                nearbyShown = true
                model.map.showNearby()
            }
        }
        .sheet(isPresented: $showLayers) {
            LayersSheet().presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $showSearch) {
            SearchView(
                onPickStop: { id in pick { map.selectStop(id) } },
                onPickLine: { line in pick { map.selectLine(line) } },
                onPickPlace: { place in pick { model.select(place) } }
            )
        }
    }

    /// Layers, 3D, north-up and "my location", bottom right like Android.
    private var mapButtons: some View {
        GlassGroup(spacing: 12) {
            VStack(spacing: 12) {
                roundButton("square.3.layers.3d", label: s.mapLayers) { present { showLayers = true } }
                roundButton(model.map.tilted ? "view.2d" : "view.3d", label: s.view3D) { model.map.toggleTilt() }
                roundButton("location.north.line.fill", label: s.northUp) { model.map.resetView() }
                roundButton("location.fill", label: s.myLocation) {
                    recenterRequest += 1
                    model.map.showNearby()
                }
            }
        }
        .padding(.trailing, 16)
        .padding(.bottom, 40) // clear of MapLibre's attribution button
    }

    private func roundButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 48, height: 48)
                .glassBackground(in: Circle())
        }
        .accessibilityLabel(label)
    }

    /// Only one presentation at a time: close the open sheet first.
    private func present(_ show: @escaping () -> Void) {
        if model.map.sheet != nil {
            model.map.close()
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                show()
            }
        } else {
            show()
        }
    }

    private var searchButton: some View {
        Button {
            present { showSearch = true }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                Text(s.searchStop)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(height: 48)
            .glassBackground(in: Capsule())
        }
        .buttonStyle(.plain) // keep the placeholder grey, not accent-tinted
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// Dismisses the search, then selects once the cover has gone (presenting
    /// the sheet while the cover is still animating out would be dropped).
    private func pick(_ select: @escaping () -> Void) {
        showSearch = false
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            select()
        }
    }

    /// Which stops, places and routes the map shows, mirroring `visibleStops`,
    /// `places` and `contextLines` in EmtApp.kt: a focused line or bus shows only
    /// its stops, a selected stop or place only itself plus its lines' routes.
    private func scene(_ transit: TransitData) -> MapScene {
        let map = model.map
        if let journey = map.journey {
            // While a trip is shown, only its own stops stay on the map.
            return MapScene(stopsKey: "journey:\(journey.id)",
                            stops: transit.stops.filter { journey.stopIds.contains($0.id) },
                            mainLine: nil, contextLines: [], sheetVisible: true,
                            placesKey: "none", places: [], journey: journey)
        }
        if let line = map.currentLine {
            return MapScene(stopsKey: "line:\(line)",
                            stops: transit.stops.filter { !$0.metro && $0.lines.contains(line) },
                            mainLine: line, contextLines: [], sheetVisible: map.sheet != nil,
                            placesKey: "none", places: [])
        }
        if let id = map.selectedStopId, let stop = transit.stopsById[String(id)] {
            return MapScene(stopsKey: "stop:\(id)", stops: [stop], mainLine: nil,
                            contextLines: unique(stop.lines), sheetVisible: true,
                            placesKey: "none", places: [])
        }
        if let place = map.selectedPlace {
            return MapScene(stopsKey: "none", stops: [], mainLine: nil,
                            contextLines: unique(place.lines), sheetVisible: true,
                            placesKey: "place:\(place.id)", places: [place],
                            metrobusVehicles: place.network == .metrobus ? model.metrobusVehicles : [])
        }
        let networks = MapPreferences.networks(networksSetting)
        return MapScene(stopsKey: networks.contains(.emt) ? "all" : "none",
                        stops: networks.contains(.emt) ? transit.stops.filter { !$0.metro } : [],
                        mainLine: nil, contextLines: [], sheetVisible: map.sheet != nil,
                        placesKey: "all:\(model.placesVersion):\(networksSetting)",
                        places: model.places.filter { networks.contains($0.network) })
    }

    private func unique(_ lines: [String]) -> [String] {
        lines.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }
}
