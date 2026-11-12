import SwiftUI
import WidgetKit

private struct Appointment: Decodable {
    let title: String
    let kind: String
    let allDay: Bool
    let start: Date
    let end: Date

    var color: Color {
        switch kind {
        case "todo": return Color(red: 0.63, green: 0.43, blue: 0.15)
        case "occasion": return Color(red: 0.66, green: 0.35, blue: 0.45)
        default: return Color(red: 0.28, green: 0.46, blue: 0.34)
        }
    }

    func time(use24Hour: Bool) -> String {
        if allDay { return "All day" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = use24Hour ? "HH:mm" : "h:mm a"
        return formatter.string(from: start)
    }
}

private struct CalendarSnapshot: Decodable {
    let use24Hour: Bool
    let expiresAt: Date
    let days: [String: [Appointment]]
    let appointments: [Appointment]

    static func load() -> Self? {
        guard let directory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.jeethsuresh.spacetime"
        ), let data = try? Data(contentsOf: directory.appendingPathComponent("calendar-widget.json")) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(Self.self, from: data)
    }

    static func sample(at date: Date) -> Self {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: date)
        let start = calendar.date(byAdding: .hour, value: 11, to: today) ?? today
        let next = Appointment(title: "Design review", kind: "event", allDay: false,
                               start: start, end: start.addingTimeInterval(3_600))
        let todo = Appointment(title: "Send agenda", kind: "todo", allDay: true,
                               start: today, end: start)
        var days = [dateKey(today): [todo, next]]
        for offset in [2, 4, 5] {
            if let day = calendar.date(byAdding: .day, value: offset, to: today) {
                days[dateKey(day)] = [next]
            }
        }
        return Self(use24Hour: false, expiresAt: .distantFuture, days: days, appointments: [next])
    }
}

private func dateKey(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

private func calendarURL(_ date: Date, view: String = "Daily") -> URL {
    var components = URLComponents()
    components.scheme = "spacetime"
    components.host = "calendar"
    components.queryItems = [URLQueryItem(name: "date", value: dateKey(date)),
                             URLQueryItem(name: "view", value: view)]
    return components.url!
}

private enum CalendarWidgetMode: String {
    case next = "SpacetimeNext"
    case today = "SpacetimeToday"
    case week = "SpacetimeWeek"

    var title: String {
        switch self {
        case .next: return "Next appointment"
        case .today: return "Today"
        case .week: return "Week ahead"
        }
    }

    var detail: String {
        switch self {
        case .next: return "See the next appointment on your calendar."
        case .today: return "See today's events, todos, and occasions."
        case .week: return "See which days have plans and tap a day to open it."
        }
    }
}

private struct CalendarDay {
    let date: Date
    let appointments: [Appointment]
}

private struct CalendarEntry: TimelineEntry {
    let date: Date
    let next: Appointment?
    let days: [CalendarDay]
    let use24Hour: Bool
    let needsRefresh: Bool
}

private struct CalendarProvider: TimelineProvider {
    let mode: CalendarWidgetMode

    private func entry(at date: Date, snapshot: CalendarSnapshot?, preview: Bool = false) -> CalendarEntry {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: date)
        let days = (0..<(mode == .week ? 7 : 1)).compactMap { offset -> CalendarDay? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            return CalendarDay(date: day, appointments: snapshot?.days[dateKey(day)] ?? [])
        }
        let next = snapshot?.appointments.first { preview || $0.end > date }
        return CalendarEntry(date: date, next: next, days: days,
                             use24Hour: snapshot?.use24Hour ?? true,
                             needsRefresh: (snapshot?.expiresAt ?? .distantPast) <= date)
    }

    func placeholder(in context: Context) -> CalendarEntry {
        let date = Date()
        return entry(at: date, snapshot: .sample(at: date), preview: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (CalendarEntry) -> Void) {
        let date = Date()
        completion(entry(at: date, snapshot: context.isPreview ? .sample(at: date) : .load(),
                         preview: context.isPreview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CalendarEntry>) -> Void) {
        let now = Date()
        let snapshot = CalendarSnapshot.load()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(86_400)
        let horizon = calendar.date(byAdding: .day, value: 2, to: today) ?? tomorrow.addingTimeInterval(86_400)
        var dates = [tomorrow]
        if mode == .next, let snapshot {
            dates += snapshot.appointments.map(\.end)
        }
        let future = Set(dates.filter { $0 > now && $0 < horizon }).sorted()
        let boundaries = Array(future.prefix(36))
        let refresh = future.count > boundaries.count ? (boundaries.last ?? horizon) : horizon
        completion(Timeline(entries: ([now] + boundaries).map { entry(at: $0, snapshot: snapshot) },
                            policy: .after(refresh)))
    }
}

private struct CalendarWidgetView: View {
    let mode: CalendarWidgetMode
    let entry: CalendarEntry
    @Environment(\.colorScheme) private var colorScheme

    private var background: Color {
        colorScheme == .dark ? Color(red: 0.10, green: 0.16, blue: 0.13)
            : Color(red: 0.94, green: 0.96, blue: 0.93)
    }

    var body: some View {
        if #available(iOSApplicationExtension 17.0, *) {
            content.containerBackground(for: .widget) { background }
        } else {
            content.padding(14).background(background)
        }
    }

    private var content: some View {
        Group {
            switch mode {
            case .next:
                next.widgetURL(calendarURL(entry.next?.start ?? entry.date))
            case .today:
                today.widgetURL(calendarURL(entry.date))
            case .week:
                week.widgetURL(calendarURL(entry.date, view: "Weekly"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .privacySensitive()
    }

    private var next: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Next", systemImage: "calendar")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 2)
            if let appointment = entry.next {
                Text(appointment.start, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                Text(appointment.title)
                    .font(.headline).lineLimit(2).minimumScaleFactor(0.8)
                Text(appointment.time(use24Hour: entry.use24Hour))
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
            } else {
                Text(entry.needsRefresh ? "Open Spacetime to update" : "No upcoming appointments")
                    .font(.headline).lineLimit(3)
            }
        }
    }

    private var today: some View {
        let appointments = entry.days.first?.appointments ?? []
        return VStack(alignment: .leading, spacing: 5) {
            Text(entry.date, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                .font(.headline).lineLimit(1)
            if appointments.isEmpty {
                Spacer(minLength: 0)
                Text(entry.needsRefresh ? "Open Spacetime to update" : "No events today")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ForEach(Array(appointments.prefix(3).enumerated()), id: \.offset) { _, appointment in
                    HStack(spacing: 7) {
                        Circle().fill(appointment.color).frame(width: 6, height: 6).accessibilityHidden(true)
                        Text(appointment.title).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(appointment.time(use24Hour: entry.use24Hour))
                            .monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    }
                    .font(.subheadline)
                    .accessibilityElement(children: .combine)
                }
                if appointments.count > 3 {
                    Text("Open calendar for more").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var week: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Week ahead").font(.headline)
            if let first = entry.days.first, let last = entry.days.last {
                let start = first.date.formatted(.dateTime.month(.abbreviated).day())
                let end = last.date.formatted(.dateTime.month(.abbreviated).day())
                Text("\(start) – \(end)").font(.caption).foregroundStyle(.secondary)
            }
            if entry.needsRefresh {
                Text("Open Spacetime to update").font(.subheadline).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 3) {
                    ForEach(entry.days, id: \.date) { day in
                        weekDay(day)
                    }
                }
            }
        }
    }

    private func weekDay(_ day: CalendarDay) -> some View {
        Link(destination: calendarURL(day.date)) {
            VStack(spacing: 5) {
                Text(day.date, format: .dateTime.weekday(.narrow)).font(.caption2)
                Text(day.date, format: .dateTime.day())
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                HStack(spacing: 2) {
                    ForEach(Array(day.appointments.prefix(3).enumerated()), id: \.offset) { _, event in
                        Circle().fill(event.color).frame(width: 4, height: 4)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityLabel(day.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
        .accessibilityValue(day.appointments.isEmpty ? "No events" :
            day.appointments.prefix(3).map(\.title).joined(separator: ", "))
    }
}

private extension CalendarWidgetMode {
    var configuration: some WidgetConfiguration {
        let mode = self
        return StaticConfiguration(kind: mode.rawValue, provider: CalendarProvider(mode: mode)) {
            CalendarWidgetView(mode: mode, entry: $0)
        }
        .configurationDisplayName(Text(mode.title))
        .description(Text(mode.detail))
        .supportedFamilies(mode == .next ? [.systemSmall] : [.systemMedium])
    }
}

private struct NextAppointmentWidget: Widget {
    var body: some WidgetConfiguration { CalendarWidgetMode.next.configuration }
}

private struct TodayWidget: Widget {
    var body: some WidgetConfiguration { CalendarWidgetMode.today.configuration }
}

private struct WeekAheadWidget: Widget {
    var body: some WidgetConfiguration { CalendarWidgetMode.week.configuration }
}

@main
struct SpacetimeWidgets: WidgetBundle {
    var body: some Widget {
        NextAppointmentWidget()
        TodayWidget()
        WeekAheadWidget()
    }
}
