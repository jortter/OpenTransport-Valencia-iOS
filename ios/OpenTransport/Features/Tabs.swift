import SwiftUI
import OpenTransportCore

struct SavedTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.strings) private var s
    @State private var service: Network?

    /// A saved row: an EMT stop or a place of another network.
    enum Saved: Identifiable {
        case stop(Stop)
        case place(Place)

        var id: String {
            switch self {
            case .stop(let stop): return AppModel.stopKey(stop.id)
            case .place(let place): return place.id
            }
        }

        var network: Network {
            switch self {
            case .stop: return .emt
            case .place(let place): return place.network
            }
        }
    }

    var body: some View {
        let items: [Saved] = model.favorites.compactMap { key in
            if key.hasPrefix("emt-"), let stop = model.transit?.stopsById[String(key.dropFirst(4))] { return .stop(stop) }
            return model.place(key).map(Saved.place)
        }
        let shown = items.filter { service == nil || $0.network == service }

        NavigationStack {
            VStack(spacing: 0) {
                ServiceFilter(selected: $service)
                if shown.isEmpty {
                    ContentUnavailableView(s.starToSave, systemImage: "star").frame(maxHeight: .infinity)
                } else {
                    List {
                        ForEach(shown) { item in
                            Button {
                                switch item {
                                case .stop(let stop): model.openStop(stop.id)
                                case .place(let place): model.openPlace(place)
                                }
                            } label: {
                                SavedRow(item: item)
                            }
                            .tint(.primary)
                            .swipeActions {
                                Button(role: .destructive) {
                                    model.toggleFavorite(item.id)
                                } label: {
                                    Label(s.remove, systemImage: "trash")
                                }
                            }
                        }
                        // Touch and hold a row, then drag it; or "Edit" for the handles.
                        .onMove { from, to in
                            var ids = shown.map(\.id)
                            ids.move(fromOffsets: from, toOffset: to)
                            model.reorderFavorites(shown: ids)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(s.saved)
            .toolbar {
                if !shown.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) { EditButton() }
                }
            }
        }
    }

    /// Shows the next arrival once loaded (Android's `SavedRow`).
    struct SavedRow: View {
        let item: Saved

        @Environment(AppModel.self) private var model
        @Environment(\.strings) private var s
        @State private var next: String?

        var body: some View {
            HStack(spacing: 12) {
                ServiceLogo(network: item.network, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).lineLimit(1)
                    Text(next.map(s.nextLabel) ?? subtitle)
                        .font(.caption)
                        .foregroundStyle(next == nil ? Color.secondary : Color.accentColor)
                        .lineLimit(1)
                }
            }
            .task(id: item.id) { next = await loadNext() }
        }

        private var title: String {
            switch item {
            case .stop(let stop): return stop.cleanName
            case .place(let place): return place.name
            }
        }

        private var subtitle: String {
            switch item {
            case .stop(let stop): return stop.lines.joined(separator: " · ")
            case .place(let place): return placeSubtitle(place, s)
            }
        }

        private func loadNext() async -> String? {
            switch item {
            case .stop(let stop):
                guard let first = await model.client?.stop(id: stop.id)?.arrivals.first else { return nil }
                return "\(first.line) · \(EmtClient.etaLabel(first))"
            case .place(let place) where place.network == .metrobus:
                guard let first = await model.metrobus.arrivals(code: String(place.id.dropFirst(3))).first else { return nil }
                return "\(first.line.dropFirst(2)) · \(first.minutes)"
            case .place:
                return nil
            }
        }
    }
}

struct AlertsTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.strings) private var s
    @Environment(\.openURL) private var openURL
    @State private var service: Network?

    var body: some View {
        let shown = model.incidents?.filter { service == nil || $0.network == service }
        NavigationStack {
            VStack(spacing: 0) {
                // Valenbisi publishes no alerts, so it has no filter.
                ServiceFilter(selected: $service, exclude: [.valenbisi])
                Group {
                    if let shown {
                        if shown.isEmpty {
                            ContentUnavailableView(s.noServiceUpdates, systemImage: "checkmark.circle")
                        } else {
                            List(shown, id: \.self) { incident in
                                // Only notices with a document (Metrobús PDFs) are tappable.
                                if let url = URL(string: incident.url), !incident.url.isEmpty {
                                    Button { openURL(url) } label: { IncidentRow(incident: incident) }
                                        .tint(.primary)
                                } else {
                                    IncidentRow(incident: incident)
                                }
                            }
                            .listStyle(.plain)
                        }
                    } else {
                        ProgressView(s.loading).frame(maxHeight: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .navigationTitle(s.serviceUpdates)
            .refreshable { await model.refreshIncidents(force: true) }
        }
    }
}

private struct IncidentRow: View {
    let incident: Incident

    @Environment(\.strings) private var s

    /// Renfe repeats the (cut) header at the start of the description: show
    /// the full text once instead of twice.
    private var repeatsTitle: Bool {
        !incident.detail.isEmpty && incident.detail.hasPrefix(String(incident.title.prefix(40)))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ServiceLogo(network: incident.network, size: 24)
            VStack(alignment: .leading, spacing: 6) {
                Text(repeatsTitle ? incident.detail : incident.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if !incident.detail.isEmpty, !repeatsTitle {
                    Text(incident.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                }
                if !incident.date.isEmpty {
                    Text(incident.date).font(.caption).foregroundStyle(.secondary)
                }
                if !incident.lines.isEmpty {
                    // Metro alerts carry bare line numbers; show them as Metro badges.
                    LineBadges(lines: incident.lines
                        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                        .map { incident.network == .metro ? "M\($0)" : $0 })
                }
            }
            Spacer(minLength: 0)
            if !incident.url.isEmpty {
                Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
                    .accessibilityLabel(s.openNotice)
            }
        }
        .padding(.vertical, 4)
    }
}

/// "All" plus one chip per network (Android's `ServiceFilterRow`).
struct ServiceFilter: View {
    @Binding var selected: Network?
    var exclude: Set<Network> = []

    @Environment(\.strings) private var s

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(s.all, logo: nil, isOn: selected == nil) { selected = nil }
                ForEach(Network.allCases.filter { !exclude.contains($0) }, id: \.self) { network in
                    chip(network.label, logo: network, isOn: selected == network) {
                        selected = selected == network ? nil : network
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func chip(_ title: String, logo: Network?, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let logo { ServiceLogo(network: logo, size: 16) }
                Text(title).font(.subheadline)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(isOn ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground), in: Capsule())
            .overlay(Capsule().strokeBorder(isOn ? Color.accentColor : .clear))
        }
        .buttonStyle(.plain)
    }
}

struct SettingsTab: View {
    @Environment(\.strings) private var s
    @AppStorage("language") private var languageCode = AppModel.defaultLanguage.rawValue
    @AppStorage("theme") private var theme = AppTheme.system.rawValue
    @AppStorage(MapPreferences.styleKey) private var mapStyle = MapStyle.auto.rawValue
    @AppStorage(ArrivalAlerts.minutesKey) private var alertMinutes = ArrivalAlerts.defaultMinutes

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        if let logo = BundledAsset.image("OpenTransport_logo.png") {
                            Image(uiImage: logo).resizable().scaledToFit().frame(height: 72)
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                Picker(s.languageTitle, selection: $languageCode) {
                    ForEach(Language.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker(s.appearance, selection: $theme) {
                    ForEach(AppTheme.allCases) { Text($0.label(s)).tag($0.rawValue) }
                }
                Picker(s.mapStyle, selection: $mapStyle) {
                    ForEach(MapStyle.allCases) { Text($0.label(s)).tag($0.rawValue) }
                }
                Section {
                    Picker(s.arrivalAlerts, selection: $alertMinutes) {
                        ForEach([5, 10, 15], id: \.self) { Text("\($0) min").tag($0) }
                    }
                } header: {
                    Text(s.arrivalAlerts)
                } footer: {
                    Text("\(s.arrivalAlertsDesc) \(s.alertsWhileOpen)")
                }
                Section {
                    NavigationLink(s.diagnostics) { DiagnosticsView() }
                }
                Section(s.aboutSources) {
                    Text(s.aboutUnofficial).font(.footnote).foregroundStyle(.secondary)
                    Text(s.aboutData).font(.footnote).foregroundStyle(.secondary)
                    Text(s.aboutWarranty).font(.footnote).foregroundStyle(.secondary)
                    Text("© 2026 OpenTransport Valencia").font(.footnote)
                }
            }
            .navigationTitle(s.settings)
        }
    }
}
