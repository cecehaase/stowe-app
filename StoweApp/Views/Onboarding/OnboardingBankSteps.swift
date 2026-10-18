import SwiftUI

// MARK: - Connect bank (after the split, before categories)

struct ConnectBankStep: View {
    @Bindable var model: OnboardingViewModel
    @Environment(BudgetStore.self) var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                OnboardingStepHeader(title: "Connect your bank?",
                                     subtitle: "Link an account and Stowe will track your spending for you.")

                VStack(alignment: .leading, spacing: 16) {
                    benefit("arrow.triangle.2.circlepath", "Automatic tracking",
                            "Purchases are imported and sorted into your categories. No manual entry.")
                    benefit("wand.and.stars", "A head start on your budget",
                            "We can prefill your categories and monthly amounts from what you actually spend.")
                    benefit("lock.shield.fill", "Read-only and secure",
                            "Connected through Plaid. Stowe can't move money, and never sees your bank password.")
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.evergreen, in: RoundedRectangle(cornerRadius: Theme.corner))

                if store.isBankLinked {
                    Label("Bank connected", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.sage)
                    PlaidLinkButton(title: "Connect another account")
                        .buttonStyle(.bordered)
                } else {
                    PlaidLinkButton(title: "Connect bank account")
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }

                Text("Not now? Skip, and connect any time from Profile.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .onChange(of: store.isBankLinked) { _, linked in
            model.isBankLinked = linked
            // Move on as soon as the link succeeds; transactions keep importing on the next page.
            if linked && model.step == .connect { model.next() }
        }
    }

    private func benefit(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.sage)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(Theme.textMuted)
            }
        }
    }
}

// MARK: - Prefill from history (only after a bank is connected)

struct PrefillStep: View {
    @Bindable var model: OnboardingViewModel
    @Environment(BudgetStore.self) var store
    @State private var isCustomRange = false
    @State private var customMonths = 3

    private static let presetRanges = [1, 3, 6, 12]

    /// Shared with the flow's "Use these" button so both see the same numbers.
    static func summary(model: OnboardingViewModel, store: BudgetStore) -> HistorySummary {
        SpendingHistoryAnalyzer.summarize(Array(store.transactionCache.values),
                                          candidates: model.prefillCandidates,
                                          rules: store.merchantRuleNames,
                                          months: model.prefillMonths)
    }

    var body: some View {
        let summary = Self.summary(model: model, store: store)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                OnboardingStepHeader(title: "Prefill your spending categories?",
                                     subtitle: "We'll suggest categories and monthly amounts from your transactions. You can review and edit everything next.")

                if store.transactionCache.isEmpty {
                    importing
                } else {
                    rangePicker(summary)
                    if let status = store.historyStatus, status < .historicalComplete {
                        Label("Still importing older history. Longer ranges unlock as it arrives.",
                              systemImage: "clock.arrow.circlepath")
                            .font(.footnote)
                            .foregroundStyle(Theme.textMuted)
                    }
                    suggestions(summary)
                    if let income = summary.monthlyIncome { incomeCard(income) }
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .scrollDismissesKeyboard(.interactively)
        // Keep pulling while Plaid imports older months (~2 minutes max, only while this page is visible).
        .task {
            for _ in 0..<24 {
                if store.historyStatus == .historicalComplete { break }
                await store.syncTransactions()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onChange(of: summary.monthlyIncome) { _, newIncome in
            // Keep detected income in step with the chosen range.
            if model.isUsingDetectedIncome, let newIncome { model.setUseDetectedIncome(true, monthly: newIncome) }
        }
    }

    private var importing: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Importing your transactions…").foregroundStyle(Theme.textMuted)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.evergreen, in: RoundedRectangle(cornerRadius: Theme.corner))
    }

    // MARK: Range

    private func rangePicker(_ summary: HistorySummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Based on").font(.cardTitle).foregroundStyle(Theme.sage)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.presetRanges, id: \.self) { months in
                        chip(months == 1 ? "Last month" : "\(months)-mo avg",
                             isSelected: !isCustomRange && model.prefillMonths == months,
                             // "Last month" always works; longer ranges need that much history.
                             isEnabled: months == 1 || months <= summary.fullMonthsAvailable) {
                            isCustomRange = false
                            model.prefillMonths = months
                        }
                    }
                    chip("Other", isSelected: isCustomRange, isEnabled: true) {
                        isCustomRange = true
                        customMonths = model.prefillMonths
                    }
                }
            }
            if isCustomRange {
                HStack {
                    Text("Average of")
                    TextField("3", value: $customMonths, format: .number)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.center)
                        .frame(width: 64)
                    Text("months (1–12)")
                }
                .onChange(of: customMonths) { _, value in model.prefillMonths = min(max(value, 1), 12) }
            }
            Text(coverageNote(summary)).font(.footnote).foregroundStyle(Theme.textMuted)
        }
    }

    private func coverageNote(_ s: HistorySummary) -> String {
        if s.isApproximate { return "Not a full month of history yet, so this uses the last 30 days." }
        if s.monthsCovered < model.prefillMonths {
            return "Only \(s.monthsCovered) full month\(s.monthsCovered == 1 ? "" : "s") available so far. Averaging those."
        }
        return s.monthsCovered == 1 ? "Your spending last month." : "Average of your last \(s.monthsCovered) months."
    }

    private func chip(_ title: String, isSelected: Bool, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(isSelected ? Theme.marine : Theme.evergreen, in: Capsule())
                .foregroundStyle(Theme.textPrimary)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Suggestions

    @ViewBuilder private func suggestions(_ summary: HistorySummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Suggested budgets").font(.cardTitle).foregroundStyle(Theme.sage)
            if summary.suggestions.isEmpty {
                Text("No regular spending found in this range yet.")
                    .foregroundStyle(Theme.textMuted)
            } else {
                VStack(spacing: 0) {
                    ForEach(summary.suggestions) { s in
                        HStack {
                            Label(s.candidate.name, systemImage: s.candidate.icon)
                            Spacer()
                            Text("\(s.monthlyAverage.currency) / mo").bold()
                        }
                        .padding(.vertical, 10)
                        if s.id != summary.suggestions.last?.id { Divider() }
                    }
                }
                .padding(.horizontal)
                .background(Theme.evergreen, in: RoundedRectangle(cornerRadius: Theme.corner))
            }
            if summary.unmatchedMonthly >= SpendingHistoryAnalyzer.minimumMonthly {
                Text("≈ \(summary.unmatchedMonthly.currency) / mo didn't match a category. You can add your own on the next step.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }

    // MARK: Income

    private func incomeCard(_ detected: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Income").font(.cardTitle).foregroundStyle(Theme.sage)
            VStack(alignment: .leading, spacing: 8) {
                Text("Your deposits average ≈ \(detected.currency) / month.")
                    .font(.headline)
                Toggle("Use this as my monthly income", isOn: Binding(
                    get: { model.isUsingDetectedIncome },
                    set: { model.setUseDetectedIncome($0, monthly: detected) }))
                Text(model.isUsingDetectedIncome
                     ? "Using \(model.monthlyTakeHome.currency) / month take-home. Turn off to go back to what you entered."
                     : "You entered ≈ \(model.monthlyTakeHome.currency) / month take-home.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
            }
            .padding()
            .background(Theme.evergreen, in: RoundedRectangle(cornerRadius: Theme.corner))
        }
    }
}
