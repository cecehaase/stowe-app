import Foundation

/// Plaid's machine-learned category for a transaction (PFC taxonomy).
struct PlaidPersonalFinanceCategory: Codable, Hashable {
    enum Confidence: String, Codable {
        case veryHigh = "VERY_HIGH", high = "HIGH", medium = "MEDIUM", low = "LOW", unknown = "UNKNOWN"

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Confidence(rawValue: raw) ?? .unknown
        }

        var isHigh: Bool { self == .veryHigh || self == .high }
    }

    let primary: String     // e.g. FOOD_AND_DRINK
    let detailed: String    // e.g. FOOD_AND_DRINK_GROCERIES
    let confidenceLevel: Confidence?

    enum CodingKeys: String, CodingKey {
        case primary, detailed
        case confidenceLevel = "confidence_level"
    }
}

/// A transaction as returned by the Ledgerline backend's trimmed `/transactions/sync`.
struct PlaidTransactionDTO: Codable, Hashable {
    let transactionID: String
    let accountID: String
    /// Plaid convention: positive = money leaving the account.
    let amount: Decimal
    let date: String        // yyyy-MM-dd
    let name: String
    let merchantName: String?
    let merchantEntityID: String?
    let personalFinanceCategory: PlaidPersonalFinanceCategory?
    let pending: Bool

    enum CodingKeys: String, CodingKey {
        case transactionID = "transaction_id"
        case accountID = "account_id"
        case amount, date, name, pending
        case merchantName = "merchant_name"
        case merchantEntityID = "merchant_entity_id"
        case personalFinanceCategory = "personal_finance_category"
    }

    /// Plaid dates are calendar days ("yyyy-MM-dd"), interpreted in the user's time zone.
    var parsedDate: Date { Self.dateFormatter.date(from: date) ?? .now }

    // Shared: formatters are expensive and the history analyzer parses thousands of dates.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var displayMerchant: String { merchantName ?? name }
    var merchantKey: String? { MerchantRule.key(entityID: merchantEntityID, name: merchantName ?? name) }

    /// Posted money out that counts toward the budget (not income, transfers or card payments).
    var isSpending: Bool { !pending && amount > 0 && PlaidCategoryMap.isSpending(personalFinanceCategory) }

    /// Posted money in that Plaid classifies as income (paychecks, etc.). Plaid inflows are negative.
    var isIncome: Bool { !pending && amount < 0 && personalFinanceCategory?.primary == "INCOME" }
}

struct PlaidSyncResponse: Codable {
    let added: [PlaidTransactionDTO]
    let modified: [PlaidTransactionDTO]
    let removed: [String]   // transaction IDs
    /// How much history Plaid has imported. Optional so older servers still decode.
    let updateStatus: PlaidHistoryStatus?

    enum CodingKeys: String, CodingKey {
        case added, modified, removed
        case updateStatus = "update_status"
    }
}

/// Plaid's `transactions_update_status`: recent data arrives first, older history up to a few minutes later.
enum PlaidHistoryStatus: String, Codable, Comparable {
    case notReady = "NOT_READY"
    case initialComplete = "INITIAL_UPDATE_COMPLETE"
    case historicalComplete = "HISTORICAL_UPDATE_COMPLETE"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PlaidHistoryStatus(rawValue: raw) ?? .notReady
    }

    private var rank: Int {
        switch self {
        case .notReady: 0
        case .initialComplete: 1
        case .historicalComplete: 2
        }
    }
    static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}
