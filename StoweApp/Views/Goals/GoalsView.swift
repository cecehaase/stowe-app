import SwiftUI

/// Year -> month breakdown of income and savings goals.
struct GoalsView: View {
    @Environment(BudgetStore.self) var store
    @State private var year = Calendar.current.component(.year, from: .now)
    @State private var editing: YearlyPlan?

    var years: [Int] { let y = Calendar.current.component(.year, from: .now); return [y - 1, y, y + 1] }

    var body: some View {
        CarouselListLayout(title: "Plan", items: years, selection: $year) { y in
            let plan = store.plans.first { $0.year == y }
            HeroCard {
                Text(String(y)).font(.cardTitle).foregroundStyle(Theme.sage)
                Text((plan?.annualIncome ?? 0).currency).font(.heroNumber)
                Text("income · save \((plan?.annualSavingsGoal ?? 0).currency)").foregroundStyle(Theme.sage)
                Spacer()
                Button(plan == nil ? "Create plan" : "Edit plan") {
                    editing = plan ?? .evenlySplit(year: y, income: 0, savings: 0)
                }.buttonStyle(.borderedProminent)
            }
        } list: {
            if let plan = store.plans.first(where: { $0.year == year }) {
                Section("Monthly breakdown") {
                    ForEach(plan.months) { m in
                        HStack {
                            Text(Calendar.current.monthSymbols[m.month - 1])
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text(m.income.currency)
                                Text("save \(m.savingsGoal.currency)").font(.caption).foregroundStyle(Theme.sage)
                            }
                        }
                    }
                }.listRowBackground(Theme.evergreen)
            } else {
                Text("No plan for \(String(year)) yet.").listRowBackground(Theme.evergreen)
            }
        }
        .sheet(item: $editing) { PlanEditor(plan: $0) }
    }
}

struct PlanEditor: View {
    @Environment(BudgetStore.self) var store
    @Environment(\.dismiss) var dismiss
    @State var plan: YearlyPlan

    var body: some View {
        NavigationStack {
            Form {
                Section("Year \(String(plan.year))") {
                    TextField("Annual income", value: $plan.annualIncome, format: .number)
                    TextField("Annual savings goal", value: $plan.annualSavingsGoal, format: .number)
                    Button("Split evenly across months") {
                        plan = .evenlySplit(year: plan.year, income: plan.annualIncome, savings: plan.annualSavingsGoal)
                    }
                }
                Section("Per month") {
                    ForEach($plan.months) { $m in
                        HStack {
                            Text(Calendar.current.shortMonthSymbols[m.month - 1]).frame(width: 44, alignment: .leading)
                            TextField("Income", value: $m.income, format: .number)
                            TextField("Save", value: $m.savingsGoal, format: .number)
                        }
                    }
                }
            }
            .navigationTitle("Edit plan")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { store.upsertPlan(plan); dismiss() } }
            }
        }
    }
}

#Preview {
    GoalsView()
        .environment(BudgetStore())
        .preferredColorScheme(.dark)
        .tint(Theme.marine)
}
