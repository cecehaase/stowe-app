import Foundation

/// Maps Plaid's personal finance categories onto the user's own budget categories.
///
/// Users name their categories freely during onboarding ("Dining & Restaurants", "Fun", …), so instead of
/// a fixed ID table we match keywords against the *words* of each category name. Entries are ordered
/// most-specific first: a detailed code like `FOOD_AND_DRINK_GROCERIES` is tried before its primary.
enum PlaidCategoryMap {
    private static let table: [(prefix: String, keywords: [String])] = [
        // Food
        ("FOOD_AND_DRINK_GROCERIES", ["grocer", "food"]),
        ("FOOD_AND_DRINK_BEER_WINE_AND_LIQUOR", ["bar", "alcohol", "drink", "entertain"]),
        ("FOOD_AND_DRINK_COFFEE", ["coffee", "dining", "restaurant", "eating"]),
        ("FOOD_AND_DRINK", ["dining", "restaurant", "eating", "takeout", "food"]),
        // Housing & bills
        ("RENT_AND_UTILITIES_RENT", ["housing", "rent", "mortgage", "home"]),
        ("RENT_AND_UTILITIES_TELEPHONE", ["phone", "internet", "utility", "utilities"]),
        ("RENT_AND_UTILITIES_INTERNET_AND_CABLE", ["internet", "phone", "cable", "utility", "utilities"]),
        ("RENT_AND_UTILITIES", ["utility", "utilities", "bills", "housing"]),
        ("HOME_IMPROVEMENT", ["home", "housing", "household"]),
        ("LOAN_PAYMENTS_MORTGAGE_PAYMENT", ["housing", "mortgage", "home", "debt"]),
        ("LOAN_PAYMENTS", ["debt", "loan", "loans"]),
        ("BANK_FEES", ["fees", "fee", "bank", "debt"]),
        // Getting around
        ("TRANSPORTATION", ["transport", "transportation", "car", "gas", "commute", "auto"]),
        ("TRAVEL", ["travel", "vacation", "trips"]),
        // Fun
        ("ENTERTAINMENT_TV_AND_MOVIES", ["subscriptions", "streaming", "entertain", "fun"]),
        ("ENTERTAINMENT_MUSIC_AND_AUDIO", ["subscriptions", "streaming", "entertain", "fun"]),
        ("ENTERTAINMENT", ["entertain", "entertainment", "fun", "hobbies", "hobby"]),
        // Stuff
        ("GENERAL_MERCHANDISE_PET_SUPPLIES", ["pets", "pet"]),
        ("GENERAL_MERCHANDISE_CLOTHING_AND_ACCESSORIES", ["clothing", "clothes", "shopping"]),
        ("GENERAL_MERCHANDISE", ["shopping", "stuff", "household"]),
        // Self
        ("PERSONAL_CARE_GYMS_AND_FITNESS_CENTERS", ["gym", "exercise", "fitness", "health"]),
        ("PERSONAL_CARE_HAIR_AND_BEAUTY", ["beauty", "hair", "personal"]),
        ("PERSONAL_CARE", ["personal", "beauty", "self"]),
        ("MEDICAL", ["medical", "health", "healthcare", "doctor"]),
        // Services
        ("GENERAL_SERVICES_INSURANCE", ["insurance"]),
        ("GENERAL_SERVICES_CHILDCARE", ["childcare", "kids", "children"]),
        ("GENERAL_SERVICES_EDUCATION", ["education", "school", "tuition", "classes"]),
        ("GENERAL_SERVICES_AUTOMOTIVE", ["transport", "transportation", "car", "auto"]),
        ("GOVERNMENT_AND_NON_PROFIT_DONATIONS", ["gifts", "donations", "giving", "charity"]),
    ]

    /// Plaid categories that move money between accounts or bring it in — not spending.
    /// Credit-card payments are excluded so card purchases aren't counted twice.
    private static let nonSpendingPrefixes = [
        "INCOME", "TRANSFER_IN", "TRANSFER_OUT", "LOAN_DISBURSEMENTS",
        "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT",
    ]

    static func isSpending(_ pfc: PlaidPersonalFinanceCategory?) -> Bool {
        guard let pfc else { return true }
        return !nonSpendingPrefixes.contains { pfc.detailed.hasPrefix($0) || pfc.primary == $0 }
    }

    /// Best matching user category for a Plaid category, or nil if nothing fits.
    static func match(_ pfc: PlaidPersonalFinanceCategory, in categories: [BudgetCategory]) -> BudgetCategory? {
        match(pfc, names: categories.map(\.name)).map { categories[$0] }
    }

    /// Index of the best matching name, or nil. Used where categories aren't `BudgetCategory`s yet
    /// (e.g. onboarding presets).
    static func match(_ pfc: PlaidPersonalFinanceCategory, names: [String]) -> Int? {
        let indexed = names.map { words(in: $0) }
        for entry in table where pfc.detailed.hasPrefix(entry.prefix) || pfc.primary == entry.prefix {
            // Keyword order expresses preference, so scan keywords first, then categories.
            for keyword in entry.keywords {
                if let hit = indexed.firstIndex(where: { $0.contains { $0.hasPrefix(keyword) } }) { return hit }
            }
        }
        return nil
    }

    /// Lowercased words of a category name, e.g. "Dining & Restaurants" → ["dining", "restaurants"].
    /// Word-prefix matching avoids false hits like "car" inside "childcare".
    private static func words(in name: String) -> [String] {
        name.lowercased().split { !$0.isLetter }.map(String.init)
    }
}
