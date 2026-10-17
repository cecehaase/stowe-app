import Foundation
import Testing
@testable import budgetingapp

// MARK: - Helpers

private let calendar = Calendar.current
/// "Today" for every test: Oct 17 2026, so "last month" is September.
private let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17))!

private func txn(_ date: String, _ amount: Decimal, _ detailed: String? = "FOOD_AND_DRINK_GROCERIES",
                 primary: String? = nil, merchant: String = "Shop", entityID: String? = nil,
                 confidence: PlaidPersonalFinanceCategory.Confidence = .veryHigh,
                 pending: Bool = false) -> PlaidTransactionDTO {
    let pfc = detailed.map {
        PlaidPersonalFinanceCategory(primary: primary ?? String($0.split(separator: "_").prefix(3).joined(separator: "_")),
                                     detailed: $0, confidenceLevel: confidence)
    }
    return PlaidTransactionDTO(transactionID: UUID().uuidString, accountID: "acc", amount: amount, date: date,
                               name: merchant, merchantName: merchant, merchantEntityID: entityID,
                               personalFinanceCategory: pfc, pending: pending)
}

private let candidates = [
    CategoryCandidate(name: "Groceries", icon: "cart.fill", bucket: .needs),
    CategoryCandidate(name: "Dining & Restaurants", icon: "fork.knife", bucket: .wants),
    CategoryCandidate(name: "Childcare", icon: "figure.and.child.holdinghands", bucket: .needs),
]

private func amount(_ s: HistorySummary, _ name: String) -> Double? {
    s.suggestions.first { $0.candidate.name == name }?.monthlyAverage
}

// MARK: - SpendingHistoryAnalyzer

@MainActor
struct SpendingHistoryAnalyzerTests {
    @Test func lastMonthUsesOnlyThePreviousCalendarMonth() {
        let txns = [txn("2026-08-01", 300), txn("2026-09-03", 100), txn("2026-09-20", 50), txn("2026-10-02", 999)]
        let s = SpendingHistoryAnalyzer.summarize(txns, candidates: candidates, months: 1, now: now)
        #expect(s.monthsCovered == 1)
        #expect(amount(s, "Groceries") == 150)
    }

    @Test func averagesOnlyTheMonthsAvailable() {
        let txns = [txn("2026-08-01", 100), txn("2026-09-10", 200)]
        let s = SpendingHistoryAnalyzer.summarize(txns, candidates: candidates, months: 3, now: now)
        #expect(s.fullMonthsAvailable == 2)
        #expect(s.monthsCovered == 2)
        #expect(amount(s, "Groceries") == 150)
    }

    @Test func partialFirstMonthIsNotCounted() {
        // History starts mid-August, so August would understate a full month.
        let txns = [txn("2026-08-15", 500), txn("2026-09-10", 120)]
        let s = SpendingHistoryAnalyzer.summarize(txns, candidates: candidates, months: 12, now: now)
        #expect(s.fullMonthsAvailable == 1)
        #expect(amount(s, "Groceries") == 120)
    }

    @Test func brandNewHistoryFallsBackToLast30Days() {
        let txns = [txn("2026-10-05", 80)]
        let s = SpendingHistoryAnalyzer.summarize(txns, candidates: candidates, months: 3, now: now)
        #expect(s.isApproximate)
        #expect(s.fullMonthsAvailable == 0)
        #expect(amount(s, "Groceries") == 80)
    }

    @Test func incomeCountsOnlyIncomeDeposits() {
        let txns = [
            txn("2026-09-01", 50),
            txn("2026-09-15", -3000, "INCOME_WAGES", primary: "INCOME"),
            txn("2026-09-16", -500, "TRANSFER_IN_ACCOUNT_TRANSFER", primary: "TRANSFER_IN"),
        ]
        let s = SpendingHistoryAnalyzer.summarize(txns, candidates: candidates, months: 1, now: now)
        #expect(s.monthlyIncome == 3000)
    }

    @Test func learnedRuleBeatsPlaidCategory() {
        let txns = [txn("2026-09-01", 40, entityID: "m1")]   // Plaid says groceries
        let s = SpendingHistoryAnalyzer.summarize(txns, candidates: candidates,
                                                  rules: ["id:m1": "Dining & Restaurants"], months: 1, now: now)
        #expect(amount(s, "Dining & Restaurants") == 40)
        #expect(amount(s, "Groceries") == nil)
    }

    @Test func smallCategoriesAndUnmatchedSpending() {
        let txns = [txn("2026-09-01", 5), txn("2026-09-02", 70, nil)]
        let s = SpendingHistoryAnalyzer.summarize(txns, candidates: candidates, months: 1, now: now)
        #expect(amount(s, "Groceries") == nil)         // below the $10/mo minimum
        #expect(s.unmatchedMonthly == 70)              // no Plaid category at all
    }

    @Test func pendingAndTransfersAreIgnored() {
        let txns = [
            txn("2026-09-01", 100),
            txn("2026-09-02", 100, pending: true),
            txn("2026-09-03", 900, "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT", primary: "LOAN_PAYMENTS"),
        ]
        let s = SpendingHistoryAnalyzer.summarize(txns, candidates: candidates, months: 1, now: now)
        #expect(amount(s, "Groceries") == 100)
        #expect(s.unmatchedMonthly == 0)
    }
}

// MARK: - PlaidCategoryMap

@MainActor
struct PlaidCategoryMapTests {
    @Test func transportationDoesNotMatchChildcare() {
        let pfc = PlaidPersonalFinanceCategory(primary: "TRANSPORTATION", detailed: "TRANSPORTATION_GAS", confidenceLevel: .high)
        #expect(PlaidCategoryMap.match(pfc, names: ["Childcare", "Transportation"]) == 1)
        #expect(PlaidCategoryMap.match(pfc, names: ["Childcare"]) == nil)
    }
}

// MARK: - OnboardingViewModel

@MainActor
struct OnboardingViewModelTests {
    @Test func prefillStepIsSkippedWithoutABank() {
        let m = OnboardingViewModel()
        m.step = .split
        m.next()
        #expect(m.step == .connect)
        m.next()
        #expect(m.step == .categories)
        m.back()
        #expect(m.step == .connect)
    }

    @Test func prefillStepShownOnceLinked() {
        let m = OnboardingViewModel()
        m.isBankLinked = true
        m.step = .connect
        m.next()
        #expect(m.step == .prefill)
    }

    @Test func applyPrefillMergesAndRounds() {
        let m = OnboardingViewModel()
        m.selected = [OnboardingCategory(name: "Groceries", icon: "cart.fill", bucket: .needs)]
        let summary = HistorySummary(
            monthsCovered: 3, fullMonthsAvailable: 3, isApproximate: false,
            suggestions: [
                .init(candidate: candidates[0], monthlyAverage: 412.4),
                .init(candidate: candidates[1], monthlyAverage: 233),
            ],
            unmatchedMonthly: 0, monthlyIncome: nil)
        m.applyPrefill(summary)
        #expect(m.selected.count == 2)
        #expect(m.selected[0].name == "Groceries")       // existing kept in place
        #expect(m.selected[0].monthlyAmount == 410)
        #expect(m.selected[1].monthlyAmount == 235)
    }

    @Test func detectedIncomeCanBeUndone() {
        let m = OnboardingViewModel()
        m.income = 90_000
        m.period = .yearly
        m.estimateTaxes = true
        m.setUseDetectedIncome(true, monthly: 5_234)
        #expect(m.period == .monthly)
        #expect(m.income == 5_230)
        #expect(!m.estimateTaxes)
        m.setUseDetectedIncome(false, monthly: 5_234)
        #expect(m.income == 90_000)
        #expect(m.period == .yearly)
        #expect(m.estimateTaxes)
    }
}
