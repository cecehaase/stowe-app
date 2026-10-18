import Foundation

enum IncomePeriod: String, Codable, CaseIterable, Identifiable {
    case yearly, monthly
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum BudgetBucket: String, Codable, CaseIterable, Identifiable {
    case needs, wants, savings
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .needs: "house.fill"
        case .wants: "sparkles"
        case .savings: "banknote.fill"
        }
    }
    var blurb: String {
        switch self {
        case .needs: "Essentials like rent, utilities, groceries and insurance."
        case .wants: "Dining out, shopping, travel, hobbies and fun."
        case .savings: "Emergency fund, investing and paying down debt."
        }
    }
}

/// Percent of take-home income per bucket. Valid when the three add up to 100.
struct BudgetSplit: Codable, Hashable {
    var needs = 50.0
    var wants = 30.0
    var savings = 20.0

    var total: Double { needs + wants + savings }
    var isValid: Bool { abs(total - 100) < 0.5 }

    subscript(bucket: BudgetBucket) -> Double {
        get {
            switch bucket {
            case .needs: needs
            case .wants: wants
            case .savings: savings
            }
        }
        set {
            switch bucket {
            case .needs: needs = newValue
            case .wants: wants = newValue
            case .savings: savings = newValue
            }
        }
    }
}

/// A spending category offered during onboarding.
struct CategoryPreset: Identifiable, Hashable {
    let name: String
    let icon: String
    let bucket: BudgetBucket
    var isSuggested = false
    var id: String { name }

    static let all: [CategoryPreset] = [
        .init(name: "Housing", icon: "house.fill", bucket: .needs),
        .init(name: "Utilities", icon: "bolt.fill", bucket: .needs),
        .init(name: "Groceries", icon: "cart.fill", bucket: .needs),
        .init(name: "Transportation", icon: "car.fill", bucket: .needs),
        .init(name: "Insurance", icon: "shield.fill", bucket: .needs),
        .init(name: "Medical", icon: "cross.case.fill", bucket: .needs),
        .init(name: "Shopping", icon: "bag.fill", bucket: .wants),
        .init(name: "Travel", icon: "airplane", bucket: .wants),
        .init(name: "Dining & Restaurants", icon: "fork.knife", bucket: .wants),
        .init(name: "Hobbies & Classes", icon: "paintpalette.fill", bucket: .wants),
        .init(name: "Beauty", icon: "comb.fill", bucket: .wants),
        .init(name: "Exercise & Gym", icon: "figure.run", bucket: .wants),
        .init(name: "Bars & Entertainment", icon: "music.note", bucket: .wants),
        // Recommended extras
        .init(name: "Phone & Internet", icon: "wifi", bucket: .needs, isSuggested: true),
        .init(name: "Debt Payments", icon: "creditcard.fill", bucket: .needs, isSuggested: true),
        .init(name: "Childcare", icon: "figure.and.child.holdinghands", bucket: .needs, isSuggested: true),
        .init(name: "Pets", icon: "pawprint.fill", bucket: .needs, isSuggested: true),
        .init(name: "Education", icon: "graduationcap.fill", bucket: .needs, isSuggested: true),
        .init(name: "Subscriptions", icon: "play.rectangle.fill", bucket: .wants, isSuggested: true),
        .init(name: "Personal Care", icon: "heart.fill", bucket: .wants, isSuggested: true),
        .init(name: "Gifts & Donations", icon: "gift.fill", bucket: .wants, isSuggested: true),
    ]
}

/// A category the user picked, with its monthly allocation.
struct OnboardingCategory: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var icon: String
    var bucket: BudgetBucket
    /// Always the monthly figure; yearly-budgeted categories store their yearly goal ÷ 12.
    var monthlyAmount: Double = 0
    /// Budgeted as a yearly goal rather than a fixed monthly amount.
    var isYearly = false
    /// Merchants/words that always land in this category (see `CategoryKeywords`).
    var keywords: [String] = []

    /// Travel spending is lumpy, so it can be budgeted as a yearly goal.
    var supportsYearly: Bool { name == "Travel" }

    var yearlyAmount: Double {
        get { monthlyAmount * 12 }
        set { monthlyAmount = newValue / 12 }
    }

    init(name: String, icon: String, bucket: BudgetBucket) {
        self.name = name; self.icon = icon; self.bucket = bucket
    }

    // Custom decoding so setups saved before `isYearly` / `keywords` existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decode(String.self, forKey: .icon)
        bucket = try c.decode(BudgetBucket.self, forKey: .bucket)
        monthlyAmount = try c.decode(Double.self, forKey: .monthlyAmount)
        isYearly = try c.decodeIfPresent(Bool.self, forKey: .isYearly) ?? false
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
    }
}

/// Everything collected by the welcome flow; persisted so Profile can pre-fill a readjustment.
struct OnboardingResult: Codable {
    var income: Double
    var period: IncomePeriod
    var estimateTaxes: Bool
    var taxInputs: TaxInputs
    var split: BudgetSplit
    var categories: [OnboardingCategory]
    var annualTakeHome: Double

    var monthlyTakeHome: Double { annualTakeHome / 12 }
}
