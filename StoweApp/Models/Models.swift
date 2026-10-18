import Foundation
import CoreLocation

struct BudgetCategory: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var icon: String          // SF Symbol
    var monthlyLimit: Decimal
    /// Merchants or words that always land here, e.g. ["Zola", "The Knot", "florist"].
    var keywords: [String]
    init(id: UUID = UUID(), name: String, icon: String, monthlyLimit: Decimal, keywords: [String] = []) {
        self.id = id; self.name = name; self.icon = icon; self.monthlyLimit = monthlyLimit; self.keywords = keywords
    }
}

extension BudgetCategory {
    /// Sentinel category ID for imported transactions no tier could place. Never stored in `categories`.
    static let uncategorizedID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}

/// How an expense ended up in its category.
enum CategorySource: String, Codable {
    case manual   // user picked it (add sheet or correction)
    case rule     // a learned merchant rule
    case keyword  // matched one of the category's merchants/keywords
    case plaid    // Plaid's personal_finance_category mapping
    case model    // on-device Foundation Models fallback
}

/// Matches user-entered merchants/keywords against transaction text.
enum CategoryKeywords {
    /// True if any keyword appears at the start of a word in any of `texts`.
    /// Word-start matching avoids false hits like "gas" inside "Vegas"; multi-word keywords
    /// ("the knot") and punctuation ("Zola.com" → "zola com") are handled by normalizing both sides.
    static func matches(_ keywords: [String], in texts: [String?]) -> Bool {
        let haystacks = texts.compactMap { $0 }.map { " " + normalize($0) }
        return keywords.map { normalize($0) }.contains { keyword in
            !keyword.isEmpty && haystacks.contains { $0.contains(" " + keyword) }
        }
    }

    /// Lowercased, with anything that isn't a letter or digit collapsed to single spaces.
    static func normalize(_ s: String) -> String {
        s.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }

    /// Trims, drops blanks and case-insensitive duplicates, keeping the user's order.
    static func cleaned(_ keywords: [String]) -> [String] {
        var seen = Set<String>()
        return keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert(normalize($0)).inserted }
    }
}

struct Expense: Identifiable, Codable {
    let id: UUID
    var amount: Decimal
    var categoryID: UUID
    var date: Date
    var note: String
    // Plaid import metadata (nil for manually entered expenses).
    var plaidTransactionID: String?
    var merchantName: String?
    var merchantEntityID: String?
    var plaidCategory: String?
    var categorySource: CategorySource?

    init(id: UUID = UUID(), amount: Decimal, categoryID: UUID, date: Date = .now, note: String = "",
         plaidTransactionID: String? = nil, merchantName: String? = nil, merchantEntityID: String? = nil,
         plaidCategory: String? = nil, categorySource: CategorySource? = nil) {
        self.id = id; self.amount = amount; self.categoryID = categoryID; self.date = date; self.note = note
        self.plaidTransactionID = plaidTransactionID; self.merchantName = merchantName
        self.merchantEntityID = merchantEntityID; self.plaidCategory = plaidCategory; self.categorySource = categorySource
    }

    /// Key used to match merchant rules: Plaid's stable entity ID, else the normalized merchant name.
    var merchantKey: String? { MerchantRule.key(entityID: merchantEntityID, name: merchantName) }

    var displayTitle: String { merchantName ?? (note.isEmpty ? "Expense" : note) }
}

/// A user correction remembered per merchant: "always put this merchant in that category".
struct MerchantRule: Codable, Hashable {
    var merchantKey: String
    var categoryID: UUID

    static func key(entityID: String?, name: String?) -> String? {
        if let entityID, !entityID.isEmpty { return "id:\(entityID)" }
        if let name = name?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty { return "name:\(name)" }
        return nil
    }
}

enum AccountType: String, Codable, CaseIterable { case checking, savings, investment, retirement, cash, other }

struct Account: Identifiable, Codable {
    let id: UUID
    var name: String
    var type: AccountType
    var balance: Decimal
    /// User-entered type when `type == .other`, e.g. "HSA" or "529 plan".
    var customTypeName: String?
    init(id: UUID = UUID(), name: String, type: AccountType, balance: Decimal, customTypeName: String? = nil) {
        self.id = id; self.name = name; self.type = type; self.balance = balance; self.customTypeName = customTypeName
    }

    var typeLabel: String {
        if type == .other, let custom = customTypeName, !custom.isEmpty { return custom }
        return type.rawValue.capitalized
    }
}

/// Monthly slice of a yearly plan.
struct MonthlyPlan: Identifiable, Codable {
    var id: Int { month }
    let month: Int            // 1...12
    var income: Decimal
    var savingsGoal: Decimal
}

/// Yearly plan: income + savings goals broken down by month.
struct YearlyPlan: Identifiable, Codable {
    var id: Int { year }
    let year: Int
    var annualIncome: Decimal
    var annualSavingsGoal: Decimal
    var months: [MonthlyPlan]

    static func evenlySplit(year: Int, income: Decimal, savings: Decimal) -> YearlyPlan {
        let months = (1...12).map { MonthlyPlan(month: $0, income: income / 12, savingsGoal: savings / 12) }
        return YearlyPlan(year: year, annualIncome: income, annualSavingsGoal: savings, months: months)
    }
}

// MARK: Alerts
enum AlertTrigger: Codable, Hashable {
    case calendar(date: Date, repeatsMonthly: Bool)
    /// Repeats every week on the given weekdays (Calendar numbering: 1 = Sunday … 7 = Saturday).
    case weekly(weekdays: [Int], hour: Int, minute: Int)
    case location(name: String, latitude: Double, longitude: Double, radiusMeters: Double, onEntry: Bool)
}

/// Turns an alert into a budget check-in: its message is generated from how much is left to spend.
struct SpendingReminder: Codable, Hashable {
    /// Categories the reminder covers. Empty means the whole budget.
    var categoryIDs: [UUID] = []
    /// Place alerts only: expected visits per week, used to split what's left into a per-trip target.
    /// nil = just say how much is left.
    var visitsPerWeek: Double?
    /// Place alerts only: compute the amount at the moment of arrival (needs Always location access).
    /// Otherwise the amount comes from Ledgerline's most recent refresh.
    var liveOnArrival = false
}

struct PersonalAlert: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var message: String
    var trigger: AlertTrigger
    var isEnabled: Bool
    /// When set, the notification text is generated from the budget instead of `message`.
    var spending: SpendingReminder?
    init(id: UUID = UUID(), title: String, message: String, trigger: AlertTrigger, isEnabled: Bool = true,
         spending: SpendingReminder? = nil) {
        self.id = id; self.title = title; self.message = message; self.trigger = trigger; self.isEnabled = isEnabled
        self.spending = spending
    }
}

struct UserProfile: Codable {
    var name: String
    var currencyCode: String = Locale.current.currency?.identifier ?? "USD"
}
