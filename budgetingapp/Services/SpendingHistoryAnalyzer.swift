import Foundation

/// A category the analyzer can suggest: an onboarding preset or one the user already has.
struct CategoryCandidate: Hashable {
    let name: String
    let icon: String
    let bucket: BudgetBucket
}

/// Average monthly spending per category (and income) over a window of past months.
struct HistorySummary: Equatable {
    struct Suggestion: Identifiable, Equatable {
        var id: String { candidate.name }
        let candidate: CategoryCandidate
        let monthlyAverage: Double
    }

    /// How many months the average actually spans (may be less than requested).
    let monthsCovered: Int
    /// Full calendar months of history available, used to disable longer range options.
    let fullMonthsAvailable: Int
    /// True when there wasn't a full month of history and the last 30 days were used instead.
    let isApproximate: Bool
    /// Sorted largest first; only categories averaging at least `SpendingHistoryAnalyzer.minimumMonthly`.
    let suggestions: [Suggestion]
    /// Monthly spending no candidate matched.
    let unmatchedMonthly: Double
    /// Average monthly income deposits, or nil if none were found.
    let monthlyIncome: Double?

    static let empty = HistorySummary(monthsCovered: 0, fullMonthsAvailable: 0, isApproximate: false,
                                      suggestions: [], unmatchedMonthly: 0, monthlyIncome: nil)
}

/// Turns raw Plaid transactions into budget suggestions for onboarding.
///
/// Deliberately uses only learned rules + Plaid's categories (no Foundation Models): it can run over
/// a year of transactions every time the range changes, and an estimate doesn't need the extra precision.
enum SpendingHistoryAnalyzer {
    static let minimumMonthly = 10.0

    /// - Parameters:
    ///   - months: requested window, e.g. 1 (last month) … 12. Ends with the last full calendar month.
    ///   - rules: learned merchant rules as merchant key → category *name*.
    static func summarize(_ transactions: [PlaidTransactionDTO],
                          candidates: [CategoryCandidate],
                          rules: [String: String] = [:],
                          months: Int,
                          now: Date = .now,
                          calendar: Calendar = .current) -> HistorySummary {
        let posted = transactions.filter { !$0.pending }
        guard let earliest = posted.map(\.parsedDate).min() else { return .empty }

        // Window = the `months` full calendar months before the current one.
        let thisMonth = startOfMonth(now, calendar)
        let requested = max(1, min(months, 24))
        // History starts mid-month, so the first month only counts if it began on the 1st.
        let firstFull = calendar.component(.day, from: earliest) == 1
            ? startOfMonth(earliest, calendar)
            : calendar.date(byAdding: .month, value: 1, to: startOfMonth(earliest, calendar))!
        let fullAvailable = max(0, calendar.dateComponents([.month], from: firstFull, to: thisMonth).month ?? 0)

        let windowStart: Date, windowEnd: Date, covered: Int, approximate: Bool
        if fullAvailable == 0 {
            // Brand-new history: fall back to the last 30 days as a one-month estimate.
            windowEnd = now
            windowStart = calendar.date(byAdding: .day, value: -30, to: now)!
            covered = 1
            approximate = true
        } else {
            covered = min(requested, fullAvailable)
            windowEnd = thisMonth
            windowStart = calendar.date(byAdding: .month, value: -covered, to: thisMonth)!
            approximate = false
        }

        let inWindow = posted.filter { (windowStart..<windowEnd).contains($0.parsedDate) }
        let names = candidates.map(\.name)
        let lowerNames = names.map { $0.lowercased() }

        var totals = [Double](repeating: 0, count: candidates.count)
        var unmatched = 0.0
        var income = 0.0

        for t in inWindow {
            if t.isIncome { income += abs(t.amount.double); continue }
            guard t.isSpending else { continue }

            var index: Int?
            if let key = t.merchantKey, let ruleName = rules[key] {
                index = lowerNames.firstIndex(of: ruleName.lowercased())
            }
            if index == nil, let pfc = t.personalFinanceCategory {
                index = PlaidCategoryMap.match(pfc, names: names)
            }
            if let index { totals[index] += t.amount.double } else { unmatched += t.amount.double }
        }

        let divisor = Double(covered)
        let suggestions = zip(candidates, totals)
            .map { HistorySummary.Suggestion(candidate: $0, monthlyAverage: $1 / divisor) }
            .filter { $0.monthlyAverage >= minimumMonthly }
            .sorted { $0.monthlyAverage > $1.monthlyAverage }

        return HistorySummary(monthsCovered: covered,
                              fullMonthsAvailable: fullAvailable,
                              isApproximate: approximate,
                              suggestions: suggestions,
                              unmatchedMonthly: unmatched / divisor,
                              monthlyIncome: income > 0 ? income / divisor : nil)
    }

    private static func startOfMonth(_ d: Date, _ calendar: Calendar) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: d)) ?? d
    }
}
