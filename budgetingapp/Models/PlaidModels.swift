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

    var parsedDate: Date {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: date) ?? .now
    }

    var displayMerchant: String { merchantName ?? name }
    var merchantKey: String? { MerchantRule.key(entityID: merchantEntityID, name: merchantName ?? name) }
}

struct PlaidSyncResponse: Codable {
    let added: [PlaidTransactionDTO]
    let modified: [PlaidTransactionDTO]
    let removed: [String]   // transaction IDs
}
