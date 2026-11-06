import SwiftUI
import OpenTransportCore

/// A stop's timetable, pushed inside its sheet: departures grouped by hour,
/// each with its line and direction, filterable by line. For today, past
/// departures are dimmed, the next one is marked and the list opens on it.
struct TimetableView: View {
    /// Departures for a day (ignored when `byDay` is false).
    let load: (Date) async -> [ScheduledDeparture]
    /// Whether the source has a timetable per date (Metrobús) or one usual
    /// day (the bundled Rodalies table).
    var byDay = true
    /// Shown under the list, e.g. where the times come from.
    var note: String?

    @Environment(\.strings) private var s
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var schedule: [ScheduledDeparture]?
    @State private var line: String?
    @State private var choseDay = false
    @State private var now = Date()

    private var today: Date { Calendar.current.startOfDay(for: now) }
    private var tomorrow: Date { Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today }
    private var isToday: Bool { !byDay || Calendar.current.isDate(day, inSameDayAs: now) }
    private var minuteNow: Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    var body: some View {
        let all = schedule ?? []
        let lines = Array(Set(all.map(\.line))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let shown = all.filter { line == nil || $0.line == line }
        let next = isToday ? shown.firstIndex { $0.minuteOfDay >= minuteNow && !$0.dropOffOnly } : nil

        ScrollViewReader { proxy in
            List {
                if byDay {
                    Section { dayPicker }
                }
                if lines.count > 1 {
                    Section { lineFilter(lines) }
                        .listRowInsets(EdgeInsets())
                }
                if schedule == nil {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if shown.isEmpty {
                    Text(s.noDeparturesThisDay).foregroundStyle(.secondary)
                } else {
                    let indexed = Array(shown.enumerated())
                    ForEach(Dictionary(grouping: indexed, by: \.element.hour).sorted { $0.key < $1.key }, id: \.key) { hour, items in
                        Section(String(format: "%02d:00", hour)) {
                            ForEach(items, id: \.offset) { index, departure in
                                row(departure, isNext: index == next,
                                    isPast: isToday && departure.minuteOfDay < minuteNow)
                                    .id(index)
                            }
                        }
                    }
                }
                if let note {
                    Section {} footer: { Text(note) }
                }
            }
            .onChange(of: schedule) { _, _ in scrollToNext(proxy, next) }
            .onChange(of: line) { _, _ in scrollToNext(proxy, next) }
        }
        .navigationTitle(s.timetable)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: day) { await loadDay() }
        // Keeps "past" and "next" current while the screen stays open.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                now = Date()
            }
        }
    }

    private func row(_ departure: ScheduledDeparture, isNext: Bool, isPast: Bool) -> some View {
        HStack(spacing: 12) {
            Text(String(format: "%02d:%02d", departure.hour, departure.minute))
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .frame(width: 52, alignment: .leading)
            LineBadge(line: departure.line)
            Text(departure.destination.isEmpty ? "—" : departure.destination)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if isNext {
                Text(s.nextDeparture)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            } else if departure.dropOffOnly {
                Text(s.dropOffOnly).font(.caption).foregroundStyle(.secondary)
            }
        }
        .opacity(isPast || departure.dropOffOnly ? 0.45 : 1)
        .accessibilityElement(children: .combine)
    }

    private var dayPicker: some View {
        HStack(spacing: 8) {
            chip(s.today, isOn: Calendar.current.isDate(day, inSameDayAs: today)) { pick(today) }
            chip(s.tomorrow, isOn: Calendar.current.isDate(day, inSameDayAs: tomorrow)) { pick(tomorrow) }
            Spacer(minLength: 0)
            DatePicker(s.day, selection: Binding(get: { day }, set: { pick($0) }), in: today..., displayedComponents: .date)
                .labelsHidden()
        }
    }

    private func lineFilter(_ lines: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(s.all, isOn: line == nil) { line = nil }
                ForEach(lines, id: \.self) { item in
                    Button {
                        line = line == item ? nil : item
                    } label: {
                        LineBadge(line: item)
                            .padding(3)
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(line == item ? Color.accentColor : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(line == item ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(isOn ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground), in: Capsule())
                .overlay(Capsule().strokeBorder(isOn ? Color.accentColor : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func pick(_ date: Date) {
        choseDay = true
        day = Calendar.current.startOfDay(for: date)
    }

    private func scrollToNext(_ proxy: ScrollViewProxy, _ next: Int?) {
        guard let next else { return }
        // After the rows are laid out, or the scroll has nothing to land on.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation { proxy.scrollTo(next, anchor: .top) }
        }
    }

    private func loadDay() async {
        schedule = nil
        let loaded = await load(day)
        // The Metrobús service only lists days with departures left: with none
        // left today, open on the next day that has some (up to a week ahead).
        if byDay, loaded.isEmpty, !choseDay {
            for offset in 1...7 {
                guard let date = Calendar.current.date(byAdding: .day, value: offset, to: day) else { break }
                let found = await load(date)
                if Task.isCancelled { return }
                if !found.isEmpty {
                    choseDay = true
                    day = date // runs this again for that day
                    return
                }
            }
        }
        choseDay = true
        if !Task.isCancelled {
            if let line, !loaded.contains(where: { $0.line == line }) { self.line = nil }
            schedule = loaded
        }
    }
}
