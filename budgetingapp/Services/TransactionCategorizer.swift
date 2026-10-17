import Foundation
import FoundationModels

/// Decides which budget category an imported Plaid transaction belongs in.
///
/// Tiers, in order:
/// 1. A learned merchant rule (the user corrected this merchant before) — always wins.
/// 2. Plaid's own category, when Plaid is HIGH/VERY_HIGH confident and it maps to a user category.
/// 3. The on-device Foundation Model, constrained to answer with one of the user's category names.
/// 4. Plaid's category at any confidence, as a last resort.
/// Returns nil when nothing fits; the caller files it under "Needs review".
final class TransactionCategorizer {
    struct Result: Equatable {
        let categoryID: UUID
        let source: CategorySource
    }

    /// Pluggable model tier so tests can stub it. Returns a category or nil.
    typealias ModelClassifier = (PlaidTransactionDTO, [BudgetCategory]) async -> BudgetCategory?

    private let modelClassifier: ModelClassifier?

    init(modelClassifier: ModelClassifier? = FoundationModelClassifier.makeIfAvailable()) {
        self.modelClassifier = modelClassifier
    }

    func categorize(_ t: PlaidTransactionDTO,
                    categories: [BudgetCategory],
                    rules: [String: UUID]) async -> Result? {
        let validIDs = Set(categories.map(\.id))

        if let key = t.merchantKey, let id = rules[key], validIDs.contains(id) {
            return Result(categoryID: id, source: .rule)
        }

        let plaidMatch = t.personalFinanceCategory.flatMap { PlaidCategoryMap.match($0, in: categories) }
        if let plaidMatch, t.personalFinanceCategory?.confidenceLevel?.isHigh == true {
            return Result(categoryID: plaidMatch.id, source: .plaid)
        }

        if let modelClassifier, let c = await modelClassifier(t, categories) {
            return Result(categoryID: c.id, source: .model)
        }

        if let plaidMatch { return Result(categoryID: plaidMatch.id, source: .plaid) }
        return nil
    }
}

/// Tier 3: Apple's on-device language model with guided generation.
/// The user's category names are dynamic, so we build a string-enum schema at runtime
/// rather than a fixed `@Generable` enum. The model can only answer with one of those names (or "None").
enum FoundationModelClassifier {
    private static let noneChoice = "None"

    private static let instructions = """
        You sort bank transactions into a person's budget categories. \
        Pick the single best category for the transaction. \
        Answer "None" if no category is a reasonable fit, or if it is income or a transfer.

        Examples:
        Merchant: Trader Joe's. Bank category: FOOD_AND_DRINK_GROCERIES → Groceries
        Merchant: Netflix. Bank category: ENTERTAINMENT_TV_AND_MOVIES → Subscriptions
        Merchant: Shell. Bank category: TRANSPORTATION_GAS → Transportation
        Merchant: Venmo. Bank category: TRANSFER_OUT_ACCOUNT_TRANSFER → None
        """

    /// Returns a classifier only when the on-device model can run (Apple Intelligence enabled, model ready).
    static func makeIfAvailable() -> TransactionCategorizer.ModelClassifier? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        return { t, categories in await classify(t, categories: categories) }
    }

    static func classify(_ t: PlaidTransactionDTO, categories: [BudgetCategory]) async -> BudgetCategory? {
        guard !categories.isEmpty else { return nil }
        let names = categories.map(\.name)
        do {
            let root = DynamicGenerationSchema(name: "BudgetCategory",
                                               description: "One of the person's budget categories",
                                               anyOf: names + [noneChoice])
            let schema = try GenerationSchema(root: root, dependencies: [])
            // Fresh session per transaction keeps the context window small and results independent.
            let session = LanguageModelSession(instructions: instructions)
            let prompt = """
                Categories: \(names.joined(separator: ", "))
                Merchant: \(t.displayMerchant). Description: \(t.name). \
                Amount: \(t.amount). Bank category: \(t.personalFinanceCategory?.detailed ?? "unknown")
                """
            let response = try await session.respond(to: prompt, schema: schema)
            let answer = try response.content.value(String.self)
            return categories.first { $0.name == answer }
        } catch {
            // Refusals, guardrails, rate limits, or schema errors: fall through to the next tier.
            return nil
        }
    }
}
