import SwiftUI
import OpenTransportCore

/// Port of `LineSheet` in EmtApp.kt: a focused line, its live buses and the
/// minutes to each stop along it.
struct LineSheet: View {
    let line: String

    @Environment(AppModel.self) private var model
    @Environment(\.strings) private var s
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let buses = model.map.live.buses.filter { $0.line == line }
        let direction = buses.first?.direction ?? "ida"
        let stops = stopsAlong(direction)
        let etas = etas(buses)

        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        LineBadge(line: line)
                        Text("\(s.liveBuses(buses.count)) · \(s.directionLabel(direction))")
                            .foregroundStyle(.secondary)
                    }
                }
                if !buses.isEmpty {
                    // Tap a bus to follow it (on the map it is a small target).
                    Section(s.liveBusesTitle) {
                        ForEach(buses.sorted { $0.number < $1.number }, id: \.number) { bus in
                            // Same row as a live Metrobús bus in a stop's sheet.
                            Button {
                                model.map.followBus(bus.number)
                            } label: {
                                HStack(spacing: 12) {
                                    LineBadge(line: bus.line)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(bus.destination.isEmpty ? s.busTitle(bus.number) : bus.destination).lineLimit(1)
                                        if let next = model.transit?.stopsById[String(bus.nextStop)] {
                                            Text(s.nextStopName(next.cleanName)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                }
                            }
                            .tint(.primary)
                        }
                    }
                }
                Section(s.stops) {
                    // Circular lines can list a stop twice: key rows by position.
                    ForEach(Array(stops.enumerated()), id: \.offset) { _, stop in
                        Button {
                            model.map.selectStop(stop.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "mappin.circle.fill").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(stop.cleanName).foregroundStyle(.primary).lineLimit(1)
                                    LineBadges(lines: stop.lines)
                                }
                                Spacer()
                                if let eta = etas[stop.id] {
                                    Text("\(eta) min").foregroundStyle(Color.accentColor).monospacedDigit()
                                } else {
                                    Text("—").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                }
            }
            .navigationTitle(s.lineTitle(line))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(s.close) { dismiss() }
                }
            }
        }
    }

    private func stopsAlong(_ direction: String) -> [Stop] {
        guard let transit = model.transit, let route = transit.routes[line] else { return [] }
        return (direction == "vuelta" ? route.vuelta : route.ida).stops.compactMap { transit.stopsById[$0] }
    }

    /// Minutes for each stop along the line, from the live buses on it.
    private func etas(_ buses: [BusPosition]) -> [Int: Int] {
        guard let transit = model.transit else { return [:] }
        var result: [Int: Int] = [:]
        for bus in buses where bus.route != nil {
            let upcoming = TransitMotion.upcoming(transit.routes, stopsById: transit.stopsById, line: bus.line,
                                                  dir: bus.direction ?? "ida", next: bus.nextStop, position: bus.render)
            for item in upcoming {
                result[item.stop.id] = min(result[item.stop.id] ?? Int.max, item.minutes)
            }
        }
        return result
    }
}
