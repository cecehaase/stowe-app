import Foundation

/// Builds the text for spending-reminder notifications.
///
/// Pure functions over plain numbers so they're easy to test; `BudgetStore` supplies the amounts.
enum SpendingReminderText {
    struct Message: Equatable {
        let title: String
        let body: String
    }

    // MARK: Periods

    /// Weeks left in `date`'s month (including the current one) that still contain one of `weekdays`.
    /// For a weekend-only reminder this is "weekends left". Always at least 1.
    static func weeksLeft(from date: Date, weekdays: [Int], calendar: Calendar = .current) -> Int {
        guard let monthEnd = calendar.dateInterval(of: .month, for: date)?.end else { return 1 }
        let days = Set(weekdays.isEmpty ? Array(1...7) : weekdays)
        var weeks = Set<[Int]>()
        var day = calendar.startOfDay(for: date)
        while day < monthEnd {
            if days.contains(calendar.component(.weekday, from: day)) {
                let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: day)
                weeks.insert([c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0])
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return max(1, weeks.count)
    }

    /// Expected trips left this month at `visitsPerWeek`, counting today. Always at least 1.
    static func visitsLeft(visitsPerWeek: Double, from date: Date, calendar: Calendar = .current) -> Int {
        guard let monthEnd = calendar.dateInterval(of: .month, for: date)?.end else { return 1 }
        let daysLeft = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: monthEnd).day ?? 1
        return max(1, Int((Double(daysLeft) / 7 * visitsPerWeek).rounded()))
    }

    static func isWeekendOnly(_ weekdays: [Int]) -> Bool { !weekdays.isEmpty && Set(weekdays).isSubset(of: [1, 7]) }

    // MARK: Messages

    /// "Groceries", "Dining & Fun", "Dining, Fun & 2 more", or "your budget" for all categories.
    static func phrase(for names: [String]) -> String {
        switch names.count {
        case 0: "your budget"
        case 1: names[0]
        case 2: "\(names[0]) & \(names[1])"
        default: "\(names[0]), \(names[1]) & \(names.count - 2) more"
        }
    }

    /// Weekly schedule: "Aim for $80 this weekend — you have $240 left this month for Dining & Fun."
    static func weekly(left: Double, names: [String], weeksLeft: Int, weekendOnly: Bool, title: String) -> Message {
        if let over = overBudget(left: left, names: names, title: title) { return over }
        let period = weekendOnly ? "weekend" : "week"
        return Message(title: title.isEmpty ? "Spending check-in" : title,
                       body: "Aim for \((left / Double(weeksLeft)).currency) this \(period). You have \(left.currency) left this month for \(phrase(for: names)).")
    }

    /// Monthly or one-time schedule: "You have $240 left this month for Dining — about $60 a week."
    static func monthly(left: Double, names: [String], weeksLeft: Int, title: String) -> Message {
        if let over = overBudget(left: left, names: names, title: title) { return over }
        return Message(title: title.isEmpty ? "Spending check-in" : title,
                       body: "You have \(left.currency) left this month for \(phrase(for: names)), about \((left / Double(weeksLeft)).currency) a week.")
    }

    /// Place: "You have $180 left for Groceries this month — aim for about $30 this trip (≈6 trips left)."
    static func place(left: Double, names: [String], visitsLeft: Int?, placeName: String, title: String) -> Message {
        let heading = title.isEmpty ? (placeName.isEmpty ? "Before you shop" : "At \(placeName)") : title
        if let over = overBudget(left: left, names: names, title: heading) { return over }
        guard let visitsLeft else {
            return Message(title: heading, body: "You have \(left.currency) left for \(phrase(for: names)) this month.")
        }
        return Message(title: heading,
                       body: "You have \(left.currency) left for \(phrase(for: names)) this month. Aim for about \((left / Double(visitsLeft)).currency) this trip (≈\(visitsLeft) trip\(visitsLeft == 1 ? "" : "s") left).")
    }

    private static func overBudget(left: Double, names: [String], title: String) -> Message? {
        guard left <= 0 else { return nil }
        let body = left == 0
            ? "You've used your whole \(phrase(for: names)) budget this month."
            : "You're \((-left).currency) over your \(phrase(for: names)) budget this month."
        return Message(title: title.isEmpty ? "Budget check-in" : title, body: body)
    }

    /// Rounds a measured visit rate to a friendly suggestion (nearest ½, at least ½ a week).
    static func recommendedVisits(_ measured: Double) -> Double {
        max(0.5, (measured * 2).rounded() / 2)
    }
}

// MARK: - Budget numbers for reminders

extension BudgetStore {
    /// Budget left in these categories for `date`'s month (negative when over).
    /// Empty = the whole budget, which also counts uncategorized spending.
    func remaining(in categoryIDs: [UUID], monthOf date: Date) -> Decimal {
        guard !categoryIDs.isEmpty else { return leftToSpend(inMonthOf: date) }
        return categories.filter { categoryIDs.contains($0.id) }
            .reduce(0) { $0 + left(in: $1, monthOf: date) }
    }

    /// Names for the given IDs in display order; skips categories that no longer exist.
    func categoryNames(for ids: [UUID]) -> [String] {
        categories.filter { ids.contains($0.id) }.map(\.name)
    }

    /// How many separate days a week you've spent in these categories, over up to the last 12 weeks.
    /// Used to suggest a visits-per-week split for place reminders. nil when there's no history.
    func measuredVisitsPerWeek(in categoryIDs: [UUID], now: Date = .now) -> Double? {
        guard let start = calendar.date(byAdding: .weekOfYear, value: -12, to: now) else { return nil }
        let relevant = expenses.filter { e in
            e.date >= start && e.date <= now
                && (categoryIDs.isEmpty ? e.categoryID != BudgetCategory.uncategorizedID : categoryIDs.contains(e.categoryID))
        }
        guard let earliest = relevant.map(\.date).min() else { return nil }
        let days = Set(relevant.map { calendar.startOfDay(for: $0.date) }).count
        let weeks = max(1, now.timeIntervalSince(earliest) / (7 * 24 * 3600))
        return Double(days) / weeks
    }
}
