import Foundation

enum ConversationTimeBucket: String, CaseIterable, Identifiable {
    case today
    case last7Days
    case earlier

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return String(localized: "今天")
        case .last7Days: return String(localized: "近 7 天")
        case .earlier: return String(localized: "更早")
        }
    }

    static func bucket(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ConversationTimeBucket {
        if calendar.isDate(date, inSameDayAs: now) || date > now {
            return .today
        }
        let todayStart = calendar.startOfDay(for: now)
        if let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: todayStart),
           date >= sevenDaysAgo {
            return .last7Days
        }
        return .earlier
    }

    static func group<T>(
        _ items: [T],
        date: (T) -> Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [(bucket: ConversationTimeBucket, items: [T])] {
        var todayItems: [T] = []
        var recentItems: [T] = []
        var earlierItems: [T] = []

        for item in items {
            switch bucket(for: date(item), now: now, calendar: calendar) {
            case .today:
                todayItems.append(item)
            case .last7Days:
                recentItems.append(item)
            case .earlier:
                earlierItems.append(item)
            }
        }

        var result: [(bucket: ConversationTimeBucket, items: [T])] = []
        if !todayItems.isEmpty { result.append((.today, todayItems)) }
        if !recentItems.isEmpty { result.append((.last7Days, recentItems)) }
        if !earlierItems.isEmpty { result.append((.earlier, earlierItems)) }
        return result
    }
}
