import SwiftUI

struct SavingsView: View {
    @Environment(BudgetStore.self) var store
    @State private var month: Date = Calendar.current.startOfMonth(.now)
    @State private var showAdd = false

    var body: some View {
        CarouselListLayout(title: "Savings",
                           items: store.recentMonths.map(Calendar.current.startOfMonth),
                           selection: $month) { m in
            let goal = store.plan(for: m)?.savingsGoal ?? 0
            let saved = max(0, (store.plan(for: m)?.income ?? 0) - store.totalSpent(inMonthOf: m))
            HeroCard(fill: Theme.marine) {
                Text(m.formatted(.dateTime.month(.wide).year())).font(.cardTitle)
                Text(saved.currency).font(.heroNumber)
                Text("saved · goal \(goal.currency)")
                Spacer()
                ProgressBar(value: goal == 0 ? 0 : saved.double / goal.double, tint: Theme.sage)
            }
        } list: {
            Section("Total saved") {
                HStack { Text("All savings accounts"); Spacer(); Text(store.totalSavings.currency).bold() }
            }.listRowBackground(Theme.evergreen)
            Section {
                ForEach(store.accounts) { a in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(a.name)
                            Text(a.typeLabel).font(.caption).foregroundStyle(Theme.sage)
                        }
                        Spacer()
                        Text(a.balance.currency).bold()
                    }
                }
            } header: {
                HStack { Text("Accounts"); Spacer(); Button("Add") { showAdd = true } }
            }
            .listRowBackground(Theme.evergreen)
        }
        .sheet(isPresented: $showAdd) { AddAccountSheet() }
    }
}

struct AddAccountSheet: View {
    @Environment(BudgetStore.self) var store
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var type: AccountType = .savings
    @State private var balance: Decimal = 0
    @State private var customType = ""

    private var trimmedCustomType: String { customType.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// "Other" needs a type name; everything else just needs an account name.
    private var canSave: Bool { !name.isEmpty && (type != .other || !trimmedCustomType.isEmpty) }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Type", selection: $type) { ForEach(AccountType.allCases, id: \.self) { Text($0.rawValue.capitalized) } }
                if type == .other {
                    TextField("Account type (e.g. HSA, 529 plan)", text: $customType)
                        .textInputAutocapitalization(.words)
                }
                TextField("Balance", value: $balance, format: .currency(code: store.profile.currencyCode)).keyboardType(.decimalPad)
            }
            .navigationTitle("New account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.addAccount(.init(name: name, type: type, balance: balance,
                                               customTypeName: type == .other ? trimmedCustomType : nil))
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}

#Preview {
    SavingsView()
        .environment(BudgetStore())
        .preferredColorScheme(.dark)
        .tint(Theme.marine)
}
