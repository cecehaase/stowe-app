import Foundation
import SwiftUI

@MainActor
@Observable
final class OnboardingViewModel {
    enum Step: Int, CaseIterable {
        case income, split, connect, prefill, categories, allocation
        var title: String {
            switch self {
            case .income: "Your income"
            case .split: "Split your income"
            case .connect: "Connect your bank"
            case .prefill: "Prefill from history"
            case .categories: "Spending categories"
            case .allocation: "Monthly allocations"
            }
        }
    }

    var step: Step = .income
    var income: Double = 0
    var period: IncomePeriod = .yearly
    var estimateTaxes = false
    var taxInputs = TaxInputs()
    var split = BudgetSplit()
    /// Selected categories, in the order the user picked them.
    var selected: [OnboardingCategory] = []

    /// Mirrors `BudgetStore.isBankLinked`; the prefill step only appears once a bank is connected.
    var isBankLinked = false
    /// History window for prefilling: 1 = last month … 12 = 12-month average.
    var prefillMonths = 3
    /// What the user typed before switching to detected income, so the toggle can be undone.
    private var enteredIncome: (income: Double, period: IncomePeriod, estimateTaxes: Bool)?
    var isUsingDetectedIncome: Bool { enteredIncome != nil }

    init(prefill: OnboardingResult? = nil) {
        guard let prefill else { return }
        income = prefill.income
        period = prefill.period
        estimateTaxes = prefill.estimateTaxes
        taxInputs = prefill.taxInputs
        split = prefill.split
        selected = prefill.categories
    }

    // MARK: Income
    /// Taxes only apply to a pre-tax yearly salary; monthly entries are treated as take-home.
    var taxEstimate: TaxEstimate? {
        guard period == .yearly, estimateTaxes, income > 0 else { return nil }
        return TaxEstimator.estimate(annualGross: income, inputs: taxInputs)
    }
    var annualTakeHome: Double {
        if let taxEstimate { return taxEstimate.annualNet }
        return period == .yearly ? income : income * 12
    }
    var monthlyTakeHome: Double { annualTakeHome / 12 }

    /// Switches income to the monthly deposits found in bank history (already after tax), or restores
    /// what the user typed.
    func setUseDetectedIncome(_ on: Bool, monthly: Double) {
        if on {
            if enteredIncome == nil { enteredIncome = (income, period, estimateTaxes) }
            period = .monthly
            income = (monthly / 10).rounded() * 10
            estimateTaxes = false
        } else if let saved = enteredIncome {
            (income, period, estimateTaxes) = saved
            enteredIncome = nil
        }
    }

    // MARK: Split
    func annual(for bucket: BudgetBucket) -> Double { annualTakeHome * split[bucket] / 100 }
    func monthly(for bucket: BudgetBucket) -> Double { annual(for: bucket) / 12 }

    // MARK: Categories
    func isSelected(_ preset: CategoryPreset) -> Bool { selected.contains { $0.name == preset.name } }

    func toggle(_ preset: CategoryPreset) {
        if let i = selected.firstIndex(where: { $0.name == preset.name }) {
            selected.remove(at: i)
        } else {
            selected.append(.init(name: preset.name, icon: preset.icon, bucket: preset.bucket))
        }
    }

    /// Categories the user typed in themselves (not part of the preset list).
    var customCategories: [OnboardingCategory] {
        selected.filter { c in !CategoryPreset.all.contains { $0.name == c.name } }
    }

    func addCustom(named name: String, bucket: BudgetBucket, icon: String = "tag.fill") {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !selected.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        selected.append(.init(name: trimmed, icon: icon, bucket: bucket))
    }

    func remove(_ category: OnboardingCategory) { selected.removeAll { $0.id == category.id } }

    // MARK: Prefill
    /// Everything history can be matched against: anything already selected (custom categories, or
    /// the saved setup when readjusting, with their keywords) plus the presets.
    /// Selected come first so the user's own category wins a name clash with a preset.
    var prefillCandidates: [CategoryCandidate] {
        var seen = Set<String>()
        let all = selected.map { CategoryCandidate(name: $0.name, icon: $0.icon, bucket: $0.bucket, keywords: $0.keywords) }
            + CategoryPreset.all.map { CategoryCandidate(name: $0.name, icon: $0.icon, bucket: $0.bucket) }
        return all.filter { seen.insert($0.name.lowercased()).inserted }
    }

    /// Selects each suggested category and sets its monthly amount (rounded to $5).
    /// Existing selections keep their position and settings; only the amount is updated.
    func applyPrefill(_ summary: HistorySummary) {
        for s in summary.suggestions {
            let amount = (s.monthlyAverage / 5).rounded() * 5
            if let i = selected.firstIndex(where: { $0.name.caseInsensitiveCompare(s.candidate.name) == .orderedSame }) {
                selected[i].monthlyAmount = amount
            } else {
                var c = OnboardingCategory(name: s.candidate.name, icon: s.candidate.icon, bucket: s.candidate.bucket)
                c.monthlyAmount = amount
                selected.append(c)
            }
        }
    }

    // MARK: Allocation
    var totalAllocated: Double { selected.reduce(0) { $0 + $1.monthlyAmount } }
    var allocatedFraction: Double { monthlyTakeHome > 0 ? totalAllocated / monthlyTakeHome : 0 }
    func allocated(in bucket: BudgetBucket) -> Double {
        selected.filter { $0.bucket == bucket }.reduce(0) { $0 + $1.monthlyAmount }
    }

    // MARK: Navigation
    var canAdvance: Bool {
        switch step {
        case .income: income > 0
        case .split: split.isValid
        case .connect, .prefill: true
        case .categories: !selected.isEmpty
        case .allocation: true
        }
    }
    var isLastStep: Bool { step == Step.allCases.last }

    /// Steps the user actually sees: prefill only applies once a bank is connected.
    private func isVisible(_ s: Step) -> Bool { s != .prefill || isBankLinked }

    func next() { move(by: 1) }
    func back() { move(by: -1) }

    private func move(by delta: Int) {
        var raw = step.rawValue + delta
        while let s = Step(rawValue: raw) {
            if isVisible(s) { step = s; return }
            raw += delta
        }
    }

    func makeResult() -> OnboardingResult {
        OnboardingResult(income: income, period: period, estimateTaxes: estimateTaxes, taxInputs: taxInputs,
                         split: split, categories: selected, annualTakeHome: annualTakeHome)
    }
}
