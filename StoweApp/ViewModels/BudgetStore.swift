import Foundation
import SwiftUI

@MainActor
@Observable
final class BudgetStore {
    var profile = UserProfile(name: "You")
    var categories: [BudgetCategory] = []
    var expenses: [Expense] = []
    var accounts: [Account] = []
    var plans: [YearlyPlan] = []
    var selectedMonth: Date = .now
    /// Answers from the welcome flow, persisted so they survive relaunch and can be readjusted.
    private(set) var onboarding: OnboardingResult?

    // MARK: Bank sync state
    /// Learned corrections: merchant key → category ID. See `MerchantRule`.
    private(set) var merchantRules: [String: UUID] = [:]
    private(set) var isBankLinked = false
    /// Whether a Sign in with Apple session is saved. Bank features need one.
    private(set) var isSignedIn = SessionKeychain.token != nil
    private(set) var isSyncing = false
    private(set) var lastSyncDate: Date?
    var syncError: String?
    /// Every synced Plaid transaction (including income and transfers), keyed by transaction ID.
    /// Plaid's sync is cursor-based, so this is the only copy; history analysis and re-categorizing use it.
    private(set) var transactionCache: [String: PlaidTransactionDTO] = [:]
    /// How much history Plaid has imported so far (older months arrive after linking).
    private(set) var historyStatus: PlaidHistoryStatus?
    /// Bumped whenever spending or categories change, so observers (spending reminders) can refresh.
    private(set) var dataVersion = 0

    @ObservationIgnored let api = PlaidAPIClient()
    /// IDs of placeholder expenses, removed once real transactions are imported.
    @ObservationIgnored private var sampleExpenseIDs: Set<UUID> = []

    private static let onboardingKey = "onboardingResult"
    private static let expensesKey = "expenses"
    private static let rulesKey = "merchantRules"
    private static let linkedKey = "isBankLinked"
    private static let lastSyncKey = "lastSyncDate"

    init() {
        loadSampleData() // TODO: replace with SwiftData / persistence
        if let data = UserDefaults.standard.data(forKey: Self.onboardingKey),
           let saved = try? JSONDecoder().decode(OnboardingResult.self, from: data) {
            applyOnboarding(saved, persist: false)
        }
        loadBankState()
    }

    // MARK: Derived values
    var calendar: Calendar { .current }

    func expenses(inMonthOf date: Date) -> [Expense] {
        expenses.filter { calendar.isDate($0.date, equalTo: date, toGranularity: .month) }
    }
    func totalSpent(inMonthOf date: Date) -> Decimal {
        expenses(inMonthOf: date).reduce(0) { $0 + $1.amount }
    }
    func spent(in category: BudgetCategory, monthOf date: Date) -> Decimal {
        expenses(inMonthOf: date).filter { $0.categoryID == category.id }.reduce(0) { $0 + $1.amount }
    }
    /// Sum of every category's monthly limit: what the user planned to spend each month.
    var totalMonthlyBudget: Decimal { categories.reduce(0) { $0 + $1.monthlyLimit } }
    /// Budget left this month across all categories. Negative when over budget.
    /// Uncategorized spending counts too: it's real money out, just not sorted yet.
    func leftToSpend(inMonthOf date: Date) -> Decimal { totalMonthlyBudget - totalSpent(inMonthOf: date) }
    func left(in category: BudgetCategory, monthOf date: Date) -> Decimal {
        category.monthlyLimit - spent(in: category, monthOf: date)
    }
    var totalSavings: Decimal {
        accounts.filter { $0.type != .checking }.reduce(0) { $0 + $1.balance }
    }
    func plan(for date: Date) -> MonthlyPlan? {
        let c = calendar.dateComponents([.year, .month], from: date)
        return plans.first { $0.year == c.year }?.months.first { $0.month == c.month }
    }
    /// Last 6 months, newest first, used by the top carousels (current month is the leftmost page;
    /// swipe right-to-left to go back in time).
    var recentMonths: [Date] {
        (0..<6).compactMap { calendar.date(byAdding: .month, value: -$0, to: .now) }
    }

    func expenses(in categoryID: UUID, monthOf date: Date) -> [Expense] {
        expenses(inMonthOf: date).filter { $0.categoryID == categoryID }.sorted { $0.date > $1.date }
    }
    /// Imported transactions no tier could categorize.
    var needsReview: [Expense] {
        expenses.filter { $0.categoryID == BudgetCategory.uncategorizedID }.sorted { $0.date > $1.date }
    }

    // MARK: Mutations
    func addExpense(_ e: Expense) {
        var e = e
        e.categorySource = e.categorySource ?? .manual
        expenses.append(e)
        saveExpenses()
    }
    func addAccount(_ a: Account) { accounts.append(a) }
    func upsertPlan(_ p: YearlyPlan) {
        if let i = plans.firstIndex(where: { $0.year == p.year }) { plans[i] = p } else { plans.append(p) }
    }

    /// Replaces categories and this year's plan with what the user entered in the welcome flow.
    func applyOnboarding(_ result: OnboardingResult, persist: Bool = true) {
        onboarding = result
        dataVersion += 1
        categories = result.categories.map {
            BudgetCategory(id: $0.id, name: $0.name, icon: $0.icon, monthlyLimit: Decimal($0.monthlyAmount),
                           keywords: $0.keywords)
        }
        let annual = Decimal(result.annualTakeHome)
        let savings = Decimal(result.annualTakeHome * result.split.savings / 100)
        upsertPlan(.evenlySplit(year: calendar.component(.year, from: .now), income: annual, savings: savings))
        if persist, let data = try? JSONEncoder().encode(result) {
            UserDefaults.standard.set(data, forKey: Self.onboardingKey)
        }
        // Categories were replaced, so re-sort imported transactions into the new ones.
        // Skipped when restoring at launch (persist == false): nothing changed and the cache isn't loaded yet.
        if persist { Task { await recategorizeImported() } }
    }

    func resetOnboarding() {
        onboarding = nil
        UserDefaults.standard.removeObject(forKey: Self.onboardingKey)
    }

    // MARK: Category management
    // Categories are rebuilt from the saved onboarding setup at launch, so every change is mirrored
    // there too (which also keeps Profile → Readjust in sync).

    /// Whether another category (case-insensitive) already uses this name.
    func hasCategory(named name: String, excluding id: UUID? = nil) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return categories.contains { $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// Needs/Wants for a category, from the saved setup (defaults to Wants when unknown).
    func bucket(for id: UUID) -> BudgetBucket {
        onboarding?.categories.first { $0.id == id }?.bucket ?? .wants
    }

    /// Adds a spending category from the Spending tab. Returns the new category, or nil if the
    /// name was blank or already taken.
    @discardableResult
    func addCategory(name: String, icon: String, bucket: BudgetBucket, monthlyLimit: Decimal,
                     keywords: [String] = []) -> BudgetCategory? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !hasCategory(named: trimmed) else { return nil }
        let category = BudgetCategory(name: trimmed, icon: icon, monthlyLimit: monthlyLimit,
                                      keywords: CategoryKeywords.cleaned(keywords))
        categories.append(category)

        if var result = onboarding {   // nil with sample data only: nothing to persist into
            var saved = OnboardingCategory(name: trimmed, icon: icon, bucket: bucket)
            saved.id = category.id
            saved.monthlyAmount = monthlyLimit.double
            saved.keywords = category.keywords
            result.categories.append(saved)
            saveOnboarding(result)
        }
        return category
    }

    /// Edits a category in place. The ID is unchanged, so its transactions and merchant rules stay attached.
    func updateCategory(_ id: UUID, name: String, icon: String, bucket: BudgetBucket, monthlyLimit: Decimal,
                        keywords: [String]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = categories.firstIndex(where: { $0.id == id }), !trimmed.isEmpty,
              !hasCategory(named: trimmed, excluding: id) else { return }
        let cleanedKeywords = CategoryKeywords.cleaned(keywords)
        categories[i].name = trimmed
        categories[i].icon = icon
        categories[i].monthlyLimit = monthlyLimit
        categories[i].keywords = cleanedKeywords

        if var result = onboarding, let j = result.categories.firstIndex(where: { $0.id == id }) {
            result.categories[j].name = trimmed
            result.categories[j].icon = icon
            result.categories[j].bucket = bucket
            // Yearly-goal categories keep their mode; the monthly figure is always what's stored.
            result.categories[j].monthlyAmount = monthlyLimit.double
            result.categories[j].keywords = cleanedKeywords
            saveOnboarding(result)
        }
    }

    /// Deletes a category. Its transactions move to `destination` (as if the user moved them by hand),
    /// or to Needs review when nil. Merchant rules pointing at it follow the same choice.
    func deleteCategory(_ id: UUID, moveTransactionsTo destination: UUID?) {
        guard categories.contains(where: { $0.id == id }), destination != id else { return }
        categories.removeAll { $0.id == id }

        for i in expenses.indices where expenses[i].categoryID == id {
            expenses[i].categoryID = destination ?? BudgetCategory.uncategorizedID
            expenses[i].categorySource = destination == nil ? nil : .manual
        }
        for (key, target) in merchantRules where target == id {
            merchantRules[key] = destination   // nil removes the rule
        }
        saveRules()
        saveExpenses()

        if var result = onboarding {
            result.categories.removeAll { $0.id == id }
            saveOnboarding(result)
        }
    }

    /// Pulls existing transactions into a category after it's added or its keywords change.
    /// - Auto-sorted transactions (Plaid/AI/keyword) whose merchant matches its keywords move to it.
    ///   Hand-picked ones and merchant rules are never overridden.
    /// - Everything in Needs review is run through the full categorizer again, since a new category
    ///   can also match by name.
    /// Returns how many transactions ended up in the category.
    func sortExistingTransactions(into id: UUID) async -> Int {
        guard let category = categories.first(where: { $0.id == id }) else { return 0 }
        var moved = 0

        if !category.keywords.isEmpty {
            for i in expenses.indices {
                let e = expenses[i]
                guard let pid = e.plaidTransactionID, e.categoryID != id,
                      e.categorySource != .manual, e.categorySource != .rule,
                      CategoryKeywords.matches(category.keywords, in: [e.merchantName, transactionCache[pid]?.name])
                else { continue }
                expenses[i].categoryID = id
                expenses[i].categorySource = .keyword
                moved += 1
            }
        }

        let categorizer = TransactionCategorizer()
        let reviewIDs = expenses.compactMap { $0.categoryID == BudgetCategory.uncategorizedID ? $0.plaidTransactionID : nil }
        for pid in reviewIDs {
            guard let t = transactionCache[pid] else { continue }
            await upsert(t, using: categorizer)
            if expenses.first(where: { $0.plaidTransactionID == pid })?.categoryID == id { moved += 1 }
        }

        saveExpenses()
        return moved
    }

    private func saveOnboarding(_ result: OnboardingResult) {
        onboarding = result
        dataVersion += 1
        if let data = try? JSONEncoder().encode(result) {
            UserDefaults.standard.set(data, forKey: Self.onboardingKey)
        }
    }

    // MARK: Account

    /// Exchanges a Sign in with Apple identity token for a server session.
    func signIn(identityToken: String, nonce: String) async throws {
        try await api.signIn(identityToken: identityToken, nonce: nonce)
        isSignedIn = true
    }

    /// Deletes the server account (which disconnects every bank at Plaid), then clears the
    /// bank data stored on this device. Throws if the server couldn't delete the account.
    func deleteAccount() async throws {
        try await api.deleteAccount()
        isSignedIn = false
        clearBankData()
    }

    /// Records an API failure; a rejected or missing session flips the app back to signed out.
    func noteAPIError(_ error: Error) -> String {
        if case PlaidAPIClient.APIError.signedOut = error { isSignedIn = false }
        return error.localizedDescription
    }

    private func clearBankData() {
        isBankLinked = false
        lastSyncDate = nil
        historyStatus = nil
        syncError = nil
        transactionCache = [:]
        merchantRules = [:]
        expenses.removeAll { $0.plaidTransactionID != nil }
        try? FileManager.default.removeItem(at: Self.transactionCacheURL)
        for key in [Self.linkedKey, Self.lastSyncKey, Self.expensesKey, Self.rulesKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        dataVersion += 1
    }

    // MARK: Plaid

    /// Called from Link's onSuccess: trade the public token server-side, then pull transactions.
    func completeBankLink(publicToken: String) async {
        do {
            try await api.exchange(publicToken: publicToken)
            if !isBankLinked {
                // First real account: drop placeholder spending so totals reflect the bank.
                expenses.removeAll { sampleExpenseIDs.contains($0.id) }
                sampleExpenseIDs = []
            }
            isBankLinked = true
            UserDefaults.standard.set(true, forKey: Self.linkedKey)

            // Plaid needs a few seconds to pull a new Item's history, so the first sync is often
            // empty. Retry briefly until transactions arrive; after that, pull-to-refresh covers it.
            for attempt in 0..<6 {
                if attempt > 0 { try await Task.sleep(for: .seconds(3)) }
                let received = await syncTransactions()
                if received > 0 || syncError != nil { break }
            }
        } catch {
            syncError = noteAPIError(error)
        }
    }

    /// Pulls new/changed/removed transactions from the backend and categorizes the new ones.
    /// Returns how many added/modified transactions the server sent.
    @discardableResult
    func syncTransactions() async -> Int {
        guard isBankLinked, isSignedIn, !isSyncing else { return 0 }
        isSyncing = true
        syncError = nil
        defer { isSyncing = false }
        do {
            let response = try await api.syncTransactions()
            let categorizer = TransactionCategorizer()

            let removed = Set(response.removed)
            expenses.removeAll { $0.plaidTransactionID.map(removed.contains) ?? false }
            for id in removed { transactionCache[id] = nil }
            for t in response.added + response.modified { transactionCache[t.transactionID] = t }
            if let status = response.updateStatus { historyStatus = status }
            saveTransactionCache()

            for t in response.added + response.modified {
                await upsert(t, using: categorizer)
            }
            lastSyncDate = .now
            UserDefaults.standard.set(lastSyncDate, forKey: Self.lastSyncKey)
            saveExpenses()
            return response.added.count + response.modified.count
        } catch {
            syncError = noteAPIError(error)
            return 0
        }
    }

    private func upsert(_ t: PlaidTransactionDTO, using categorizer: TransactionCategorizer) async {
        let existingIndex = expenses.firstIndex { $0.plaidTransactionID == t.transactionID }
        // Pending items get re-issued with a new ID once posted; refunds/income aren't spending.
        guard t.isSpending else {
            if let existingIndex { expenses.remove(at: existingIndex) }
            return
        }

        if let existingIndex {
            expenses[existingIndex].amount = t.amount
            expenses[existingIndex].date = t.parsedDate
            expenses[existingIndex].merchantName = t.displayMerchant
            // Never override a category the user chose by hand.
            if expenses[existingIndex].categorySource == .manual { return }
        }

        let result = await categorizer.categorize(t, categories: categories, rules: merchantRules)
        let categoryID = result?.categoryID ?? BudgetCategory.uncategorizedID

        // Re-find after the await: the user may have edited expenses while the model ran.
        if let existingIndex = expenses.firstIndex(where: { $0.plaidTransactionID == t.transactionID }) {
            if expenses[existingIndex].categorySource == .manual { return }
            expenses[existingIndex].categoryID = categoryID
            expenses[existingIndex].categorySource = result?.source
            expenses[existingIndex].plaidCategory = t.personalFinanceCategory?.detailed
        } else {
            expenses.append(Expense(amount: t.amount, categoryID: categoryID, date: t.parsedDate,
                                    plaidTransactionID: t.transactionID, merchantName: t.displayMerchant,
                                    merchantEntityID: t.merchantEntityID,
                                    plaidCategory: t.personalFinanceCategory?.detailed,
                                    categorySource: result?.source))
        }
    }

    /// Other transactions from the same merchant that "apply to all matching" would move
    /// (hand-picked ones are never touched).
    func matchingTransactions(for expense: Expense) -> [Expense] {
        guard let key = expense.merchantKey else { return [] }
        return expenses.filter { $0.id != expense.id && $0.merchantKey == key && $0.categorySource != .manual }
    }

    /// User moved a transaction.
    /// - `applyToMatching`: also move that merchant's other auto-categorized transactions and remember
    ///   the choice for future imports. Otherwise only this transaction changes.
    func recategorize(_ expenseID: UUID, to categoryID: UUID, applyToMatching: Bool = true) {
        guard let i = expenses.firstIndex(where: { $0.id == expenseID }) else { return }
        expenses[i].categoryID = categoryID
        expenses[i].categorySource = .manual

        if applyToMatching, let key = expenses[i].merchantKey {
            merchantRules[key] = categoryID
            for j in expenses.indices where j != i
                && expenses[j].merchantKey == key
                && expenses[j].categorySource != .manual {
                expenses[j].categoryID = categoryID
                expenses[j].categorySource = .rule
            }
            saveRules()
        }
        saveExpenses()
    }

    /// Re-sorts imported transactions after the category list changes (e.g. onboarding finished).
    /// Hand-picked categories are kept unless that category no longer exists.
    func recategorizeImported() async {
        guard !transactionCache.isEmpty else { return }
        let validIDs = Set(categories.map(\.id))
        for i in expenses.indices where expenses[i].plaidTransactionID != nil
            && expenses[i].categorySource == .manual
            && !validIDs.contains(expenses[i].categoryID) {
            expenses[i].categoryID = BudgetCategory.uncategorizedID
            expenses[i].categorySource = nil
        }

        let categorizer = TransactionCategorizer()
        let ids = expenses.compactMap { $0.categorySource == .manual ? nil : $0.plaidTransactionID }
        for id in ids {
            if let t = transactionCache[id] { await upsert(t, using: categorizer) }
        }
        saveExpenses()
    }

    /// Learned rules as merchant key → category *name*, for matching against categories that don't
    /// exist yet (onboarding presets).
    var merchantRuleNames: [String: String] {
        let names = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return merchantRules.compactMapValues { names[$0] }
    }

    // MARK: Persistence (UserDefaults until the SwiftData TODO lands)

    /// The raw transaction cache can hold years of history, so it lives in a file rather than UserDefaults.
    private static var transactionCacheURL: URL {
        URL.applicationSupportDirectory.appending(path: "transactions.json")
    }

    private func saveTransactionCache() {
        do {
            try FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Array(transactionCache.values))
            try data.write(to: Self.transactionCacheURL, options: [.atomic, .completeFileProtection])
        } catch {
            syncError = "Couldn't save transactions: \(error.localizedDescription)"
        }
    }

    private func loadTransactionCache() {
        guard let data = try? Data(contentsOf: Self.transactionCacheURL),
              let saved = try? JSONDecoder().decode([PlaidTransactionDTO].self, from: data) else { return }
        transactionCache = Dictionary(saved.map { ($0.transactionID, $0) }, uniquingKeysWith: { _, new in new })
    }

    private func loadBankState() {
        let d = UserDefaults.standard
        isBankLinked = d.bool(forKey: Self.linkedKey)
        lastSyncDate = d.object(forKey: Self.lastSyncKey) as? Date
        if let data = d.data(forKey: Self.rulesKey),
           let saved = try? JSONDecoder().decode([MerchantRule].self, from: data) {
            merchantRules = Dictionary(saved.map { ($0.merchantKey, $0.categoryID) }, uniquingKeysWith: { _, new in new })
        }
        if isBankLinked, let data = d.data(forKey: Self.expensesKey),
           let saved = try? JSONDecoder().decode([Expense].self, from: data) {
            expenses = saved
            sampleExpenseIDs = []
        }
        if isBankLinked { loadTransactionCache() }
    }

    /// Only real data is persisted; sample spending is regenerated until a bank is linked.
    private func saveExpenses() {
        dataVersion += 1   // every expense mutation ends here, linked or not
        guard isBankLinked, let data = try? JSONEncoder().encode(expenses) else { return }
        UserDefaults.standard.set(data, forKey: Self.expensesKey)
    }

    private func saveRules() {
        let rules = merchantRules.map { MerchantRule(merchantKey: $0.key, categoryID: $0.value) }
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: Self.rulesKey)
        }
    }

    private func loadSampleData() {
        categories = [
            .init(name: "Housing", icon: "house.fill", monthlyLimit: 1500),
            .init(name: "Groceries", icon: "cart.fill", monthlyLimit: 450),
            .init(name: "Transport", icon: "car.fill", monthlyLimit: 200),
            .init(name: "Dining", icon: "fork.knife", monthlyLimit: 250),
            .init(name: "Fun", icon: "sparkles", monthlyLimit: 150),
        ]
        for offset in 0..<6 {
            let d = calendar.date(byAdding: .month, value: -offset, to: .now)!
            for c in categories { expenses.append(.init(amount: Decimal(Int.random(in: 40...Int(truncating: c.monthlyLimit as NSNumber))), categoryID: c.id, date: d)) }
        }
        sampleExpenseIDs = Set(expenses.map(\.id))
        accounts = [
            .init(name: "Everyday Checking", type: .checking, balance: 2340),
            .init(name: "High-Yield Savings", type: .savings, balance: 8200),
            .init(name: "Roth IRA", type: .retirement, balance: 14650),
        ]
        plans = [.evenlySplit(year: calendar.component(.year, from: .now), income: 72000, savings: 12000)]
    }
}

extension Decimal {
    var currency: String { (self as NSDecimalNumber).doubleValue.formatted(.currency(code: Locale.current.currency?.identifier ?? "USD")) }
    var double: Double { (self as NSDecimalNumber).doubleValue }
}

extension Double {
    var currency: String { formatted(.currency(code: Locale.current.currency?.identifier ?? "USD").precision(.fractionLength(0))) }
}
