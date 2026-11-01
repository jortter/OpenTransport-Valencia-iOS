import SwiftUI
import OpenTransportCore

/// Port of `PlaceSheet` in EmtApp.kt: a Metro / Valenbisi / Metrobús /
/// Rodalies point. Network-specific bodies are added per network.
struct PlaceSheet: View {
    let place: Place

    @Environment(AppModel.self) private var model
    @Environment(\.strings) private var s
    @Environment(\.dismiss) private var dismiss
    @State private var updatesOpen = true

    var body: some View {
        NavigationStack {
            List {
                Section { header }
                switch place.network {
                case .metro: MetroArrivals(place: place)
                case .valenbisi: BikeStation(place: place)
                case .metrobus: MetrobusArrivals(place: place)
                case .rodalies: RodaliesDepartures(place: place)
                case .emt: EmptyView()
                }
                updatesSection
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        model.toggleFavorite(place.id)
                    } label: {
                        Image(systemName: model.isFavorite(place.id) ? "star.fill" : "star")
                    }
                    .accessibilityLabel(model.isFavorite(place.id) ? s.removeFavourite : s.addFavourite)
                    ShareLink(item: "\(place.name)\nhttps://maps.apple.com/?ll=\(place.lat),\(place.lon)") {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(s.close) { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ServiceLogo(network: place.network, size: 40)
            VStack(alignment: .leading, spacing: 6) {
                Text(place.name)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if !place.detail.isEmpty, place.detail != place.name {
                    Text(place.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                if let distance = model.location.distance(to: place.lat, place.lon) {
                    Text(TransitMotion.formatDistance(distance)).font(.subheadline).foregroundStyle(Color.accentColor)
                }
                if !place.lines.isEmpty { LineBadges(lines: place.lines) }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var updatesSection: some View {
        let relevant = model.incidents(for: place.lines, network: place.network)
        if !relevant.isEmpty {
            Section {
                if updatesOpen {
                    ForEach(relevant, id: \.self) { incident in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(incident.title).font(.subheadline)
                            if !incident.detail.isEmpty {
                                Text(incident.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Label(s.serviceUpdates, systemImage: "exclamationmark.triangle.fill")
                    Spacer()
                    Button(updatesOpen ? s.hide : s.show) { updatesOpen.toggle() }
                        .font(.caption)
                        .textCase(nil)
                }
            }
        }
    }
}

/// Live Metrovalencia arrivals at a station, refreshed every 30 s.
private struct MetroArrivals: View {
    let place: Place

    @Environment(AppModel.self) private var model
    @Environment(\.strings) private var s
    @State private var times: [Arrival]?

    var body: some View {
        Section(s.nextDepartures) {
            if let times {
                if times.isEmpty {
                    Text(s.noTrains).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(times.enumerated()), id: \.offset) { _, arrival in
                        HStack(spacing: 12) {
                            // metroapi says "L3"; the bundled badge is "M3".
                            LineBadge(line: "M" + arrival.line.dropFirst(), height: 30)
                            Text(arrival.destination.isEmpty ? "—" : arrival.destination).lineLimit(1)
                            Spacer()
                            Text(arrival.minutes)
                                .font(.body.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        }
        .task(id: place.id) {
            guard let station = Int(place.id.dropFirst(3)) else {
                times = []
                return
            }
            while !Task.isCancelled {
                let fresh = await model.metro.arrivals(stationId: station)
                if !Task.isCancelled { times = fresh }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}

/// Valenbisi station: bikes and free docks, open state and the docked bikes.
private struct BikeStation: View {
    let place: Place

    @Environment(AppModel.self) private var model
    @Environment(\.strings) private var s
    @State private var bikes: [Bike]?

    var body: some View {
        let total = max(max(place.available, 0) + max(place.free, 0), 1)
        Section {
            HStack(spacing: 12) {
                StatCard(systemImage: "bicycle", value: max(place.available, 0), label: s.bikes,
                         color: Color(hex: 0x22C55E), fraction: Double(max(place.available, 0)) / Double(total))
                StatCard(systemImage: "parkingsign", value: max(place.free, 0), label: s.freeDocks,
                         color: Color(hex: 0x1E88E5), fraction: Double(max(place.free, 0)) / Double(total))
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            .listRowBackground(Color.clear)
            HStack {
                Label(place.open ? s.open : s.closed, systemImage: place.open ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(place.open ? Color.green : Color.secondary)
                Spacer()
                if place.mechanical >= 0, place.electric >= 0 {
                    Text("\(s.mechanicalBikes) \(place.mechanical) · \(s.electricBikes) \(place.electric)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        Section(s.bikes) {
            if let bikes {
                if bikes.isEmpty {
                    Text(s.noBikesDocked).foregroundStyle(.secondary)
                } else {
                    ForEach(bikes, id: \.number) { bike in
                        HStack(spacing: 12) {
                            Image(systemName: bike.type.uppercased().contains("ELECTRIC") ? "bolt.circle.fill" : "bicycle.circle.fill")
                                .font(.title2)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.standTitle(bike.stand)).font(.subheadline.weight(.semibold))
                                Text("\(s.bikeTitle(bike.number)) · \(bike.type.capitalized)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if bike.ratings > 0 {
                                Label("\(Int(bike.rating / 20)) (\(bike.ratings))", systemImage: "star.fill")
                                    .font(.caption)
                            } else {
                                Text(s.noRating).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        }
        .task(id: place.id) {
            guard let number = Int(place.id.dropFirst(3)) else {
                bikes = []
                return
            }
            bikes = await model.valenbisi.bikes(station: number)
        }
    }
}

/// Big number with a progress bar (Android's `StatCard`).
private struct StatCard: View {
    let systemImage: String
    let value: Int
    let label: String
    let color: Color
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(color)
            Text("\(value)").font(.largeTitle.weight(.bold)).foregroundStyle(color)
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            ProgressView(value: min(max(fraction, 0), 1)).tint(color)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Metrobús: live next bus (and occupancy) per line, its live buses and the
/// timetable.
private struct MetrobusArrivals: View {
    let place: Place

    @Environment(AppModel.self) private var model
    @Environment(\.strings) private var s
    @State private var times: [Arrival]?

    private var code: String { String(place.id.dropFirst(3)) }

    /// "33 min · BAJA" from the API, with the occupancy in the app's language.
    private func minutesLabel(_ raw: String) -> String {
        let parts = raw.components(separatedBy: " · ")
        guard parts.count == 2 else { return raw }
        let level = s.occupancyLevel(parts[1])
        return level.isEmpty ? parts[0] : "\(parts[0]) · \(level)"
    }

    /// How far a live bus is from this stop, in a straight line.
    private func distance(to vehicle: MetrobusVehicle) -> String {
        TransitMotion.formatDistance(TransitMotion.distanceMeters(LonLat(lon: place.lon, lat: place.lat),
                                                                   LonLat(lon: vehicle.lon, lat: vehicle.lat)))
    }

    // Sections straight into the List, no Group: a Group hands its modifiers to
    // every child, which ran the polling twice and doubled the timetable sheet.
    var body: some View {
        Section(s.nextDepartures) {
            if let times {
                if times.isEmpty {
                    Text(s.noUpcomingBuses).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(times.enumerated()), id: \.offset) { _, arrival in
                        HStack(spacing: 12) {
                            LineBadge(line: arrival.line)
                            Text(arrival.destination.isEmpty ? "—" : arrival.destination).lineLimit(1)
                            Spacer()
                            Text(minutesLabel(arrival.minutes))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(Color.accentColor)
                            PinButton(pin: ArrivalAlerts.metrobusPin(place.id, arrival.line))
                        }
                    }
                }
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
            // Always there: with no more buses today it shows the next days.
            NavigationLink {
                MetrobusTimetable(code: code)
            } label: {
                Label(s.timetable, systemImage: "clock")
            }
        }
        .task(id: place.id) {
            while !Task.isCancelled {
                let fresh = await model.metrobus.arrivals(code: code)
                if !Task.isCancelled { times = fresh }
                try? await Task.sleep(for: .seconds(30))
            }
        }
        if !model.metrobusVehicles.isEmpty {
            Section(s.liveBusesTitle) {
                ForEach(model.metrobusVehicles) { vehicle in
                    Button {
                        model.map.selectMetrobusBus(vehicle)
                    } label: {
                        HStack(spacing: 12) {
                            LineBadge(line: vehicle.line)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(vehicle.destination.isEmpty ? "—" : vehicle.destination).lineLimit(1)
                                if !vehicle.occupancy.isEmpty {
                                    Text(s.occupancy(vehicle.occupancy)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(distance(to: vehicle)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .tint(.primary)
                }
            }
        }
    }
}

/// A Metrobús stop's timetable for a chosen day, pushed inside the stop sheet.
/// The service only lists days with departures left, so when today has none
/// it opens on the next day that has some.
private struct MetrobusTimetable: View {
    let code: String

    @Environment(AppModel.self) private var model
    @Environment(\.strings) private var s
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var schedule: [MetrobusTime]?
    @State private var choseDay = false

    private var today: Date { Calendar.current.startOfDay(for: Date()) }

    var body: some View {
        List {
            Section {
                DatePicker(s.day, selection: $day, in: today..., displayedComponents: .date)
            }
            if let schedule {
                if schedule.isEmpty {
                    Text(s.noDeparturesThisDay).foregroundStyle(.secondary)
                } else {
                    let hours = Dictionary(grouping: schedule, by: \.hour).sorted { $0.key < $1.key }
                    ForEach(hours, id: \.key) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(format: "%02d:00", item.key)).font(.headline).monospacedDigit()
                            Text(item.value.map { String(format: "%02d %@", $0.minute, String($0.line.dropFirst(2))) }
                                .joined(separator: "   "))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        }
        .navigationTitle(s.timetable)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: day) {
            schedule = nil
            var loaded = await model.metrobus.schedule(code: code, date: day)
            // First open with nothing left today: look ahead up to a week.
            if loaded.isEmpty, !choseDay {
                for offset in 1...7 {
                    guard let next = Calendar.current.date(byAdding: .day, value: offset, to: day) else { break }
                    let found = await model.metrobus.schedule(code: code, date: next)
                    if !found.isEmpty {
                        loaded = found
                        choseDay = true
                        day = next // re-runs this task once, with choseDay set
                        return
                    }
                }
            }
            choseDay = true
            if !Task.isCancelled { schedule = loaded }
        }
    }
}

/// Rodalies: departures in the next 3 hours from the bundled timetable.
private struct RodaliesDepartures: View {
    let place: Place

    @Environment(AppModel.self) private var model
    @Environment(\.strings) private var s
    @State private var now = Date()

    var body: some View {
        let times = model.rodalies?.times(at: place.name, now: now) ?? []
        Section(s.nextDepartures) {
            if times.isEmpty {
                Text(s.noTrains).foregroundStyle(.secondary)
            } else {
                ForEach(Array(times.enumerated()), id: \.offset) { _, arrival in
                    HStack(spacing: 12) {
                        LineBadge(line: arrival.line)
                        Text(arrival.destination.isEmpty ? "—" : arrival.destination).lineLimit(1)
                        Spacer()
                        Text(arrival.minutes)
                            .font(.body.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
        // Re-evaluated every minute so the countdowns stay current.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                now = Date()
            }
        }
    }
}
