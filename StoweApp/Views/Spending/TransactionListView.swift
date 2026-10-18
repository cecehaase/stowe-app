import SwiftUI

/// Transactions for one category (or the "Needs review" bucket). Tap one to move it;
/// the move is remembered for that merchant.
struct TransactionListView: View {
    @Environment(BudgetStore.self) var store
    let title: String
    /// Reads from the store each render so rows disappear as soon as they're recategorized.
    let expenses: (BudgetStore) -> [Expense]

    @State private var editing: Expense?

    var body: some View {
        let items = expenses(store)
        List {
            if items.isEmpty {
                ContentUnavailableView("No transactions", systemImage: "tray")
                    .listRowBackground(Color.clear)
            }
            ForEach(items) { e in
                Button { editing = e } label: { TransactionRow(expense: e) }
                    .listRowBackground(Theme.evergreen)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(title)
        .refreshable { await store.syncTransactions() }
        .sheet(item: $editing) { RecategorizeSheet(expense: $0) }
    }
}

struct TransactionRow: View {
    let expense: Expense

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(expense.displayTitle).foregroundStyle(Theme.textPrimary)
                HStack(spacing: 6) {
                    Text(expense.date.formatted(date: .abbreviated, time: .omitted))
                    if let badge { Text("· \(badge)") }
                }
                .font(.caption)
                .foregroundStyle(Theme.sage)
            }
            Spacer()
            Text(expense.amount.currency).bold().foregroundStyle(Theme.textPrimary)
        }
    }

    /// Shows where the category came from, so auto-sorted items are easy to spot and fix.
    private var badge: String? {
        switch expense.categorySource {
        case .rule: "Your rule"
        case .keyword: "Your keyword"
        case .plaid: "Auto"
        case .model: "Auto (AI)"
        case .manual, nil: nil
        }
    }
}

struct RecategorizeSheet: View {
    @Environment(BudgetStore.self) var store
    @Environment(\.dismiss) var dismiss
    let expense: Expense
    /// Move every auto-sorted transaction from this merchant (and remember it), or just this one.
    @State private var applyToMatching = true

    var body: some View {
        let matching = store.matchingTransactions(for: expense)
        NavigationStack {
            List {
                Section {
                    LabeledContent("Amount", value: expense.amount.currency)
                    if let plaid = expense.plaidCategory {
                        LabeledContent("Bank category", value: plaid.replacingOccurrences(of: "_", with: " ").capitalized)
                    }
                }
                if expense.merchantKey != nil {
                    Section {
                        Picker("Apply to", selection: $applyToMatching) {
                            Text(matching.isEmpty
                                 ? "All from \(expense.displayTitle)"
                                 : "All \(matching.count + 1) from \(expense.displayTitle)")
                                .tag(true)
                            Text("Only this transaction").tag(false)
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: {
                        Text("Apply to")
                    } footer: {
                        Text(applyToMatching
                             ? "Moves matching transactions you haven't sorted by hand, and future ones from \(expense.displayTitle)."
                             : "Only this transaction moves. Others from \(expense.displayTitle) stay where they are.")
                    }
                }
                Section {
                    ForEach(store.categories) { c in
                        Button {
                            store.recategorize(expense.id, to: c.id, applyToMatching: applyToMatching)
                            dismiss()
                        } label: {
                            HStack {
                                Label(c.name, systemImage: c.icon)
                                Spacer()
                                if c.id == expense.categoryID { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } header: {
                    Text("Move to")
                }
            }
            .navigationTitle(expense.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
