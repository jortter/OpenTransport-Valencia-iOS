import SwiftUI
import OpenTransportCore

/// A live EMT bus: laid out and behaving like a live Metrobús bus
/// (`MetrobusBusSheet`), so both networks feel the same. The map centres on
/// the bus when it opens and stays free; the bus keeps moving on it.
struct FollowSheet: View {
    let number: Int

    @Environment(AppModel.self) private var model
    @Environment(\.strings) private var s
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let bus = model.map.live.buses.first { $0.number == number }
        let next = bus.map(upcoming) ?? []

        NavigationStack {
            List {
                if let bus {
                    Section {
                        HStack(spacing: 12) {
                            LineBadge(line: bus.line)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bus.destination.isEmpty ? s.lineTitle(bus.line) : bus.destination)
                                    .font(.headline)
                                    .lineLimit(2)
                                Text(s.directionLabel(bus.direction ?? "ida"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        // Where Metrobús shows the distance to the stop, EMT has the bus's next stop.
                        if let first = next.first {
                            LabeledContent(first.stop.cleanName) {
                                Text("\(first.minutes) min").monospacedDigit()
                            }
                        }
                    } footer: {
                        Text(s.emtPositionNote)
                    }
                    Section {
                        Button {
                            model.map.move(.center(bus.render, zoom: 15.5))
                        } label: {
                            Label(s.centerOnBus, systemImage: "scope")
                        }
                        let pin = ArrivalAlerts.stopPin(bus.nextStop, bus.line)
                        Button {
                            model.togglePin(pin)
                        } label: {
                            Label(s.alertAtNextStop, systemImage: model.isPinned(pin) ? "bell.fill" : "bell")
                        }
                        Button {
                            openInMaps(lat: bus.render.lat, lon: bus.render.lon, name: s.busTitle(number))
                        } label: {
                            Label(s.openPositionInMaps, systemImage: "map")
                        }
                    }
                    if next.count > 1 {
                        Section(s.nextStops) {
                            ForEach(Array(next.dropFirst().enumerated()), id: \.offset) { _, item in
                                HStack(spacing: 12) {
                                    Image(systemName: "mappin.circle.fill").foregroundStyle(.secondary)
                                    Text(item.stop.cleanName).lineLimit(1)
                                    Spacer()
                                    Text("\(item.minutes) min").foregroundStyle(Color.accentColor).monospacedDigit()
                                }
                            }
                        }
                    }
                } else {
                    Text(s.busLeftMap).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(s.busTitle(number))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(s.close) { dismiss() }
                }
            }
        }
    }

    private func upcoming(_ bus: BusPosition) -> [UpcomingStop] {
        guard let transit = model.transit, bus.route != nil else { return [] }
        return TransitMotion.upcoming(transit.routes, stopsById: transit.stopsById, line: bus.line,
                                      dir: bus.direction ?? "ida", next: bus.nextStop, position: bus.render)
    }
}
