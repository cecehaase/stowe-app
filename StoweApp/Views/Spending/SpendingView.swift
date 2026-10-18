import SwiftUI

struct SpendingView: View {
    @Environment(BudgetStore.self) var store
    @State private var month: Date = Calendar.current.startOfMonth(.now)
    @State private var showAdd = false
    @State private var showAddCategory = false
    @State private var editingCategory: BudgetCategory?
    @State private var deletingCategory: BudgetCategory?
    /// Short confirmation like "12 transactions moved to Coffee"; clears itself.
    @State private var toast: String?

    var body: some View {
        CarouselListLayout(title: "Spending",
                           items: store.recentMonths.map(Calendar.current.startOfMonth),
                           selection: $month) { m in
            MonthSpendCard(month: m)
        } list: {
            Section("Total") {
                row("Total spending", store.totalSpent(inMonthOf: month), icon: "sum")
                let left = store.leftToSpend(inMonthOf: month)
                row(left >= 0 ? "Left to spend" : "Over budget", abs(left),
                    icon: left >= 0 ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(left >= 0 ? Theme.textPrimary : Theme.overspend)
            }
            if !store.needsReview.isEmpty {
                Section("Needs review") {
                    NavigationLink {
                        TransactionListView(title: "Needs review", expenses: { $0.needsReview })
                    } label: {
                        Label("\(store.needsReview.count) uncategorized", systemImage: "questionmark.circle")
                    }
                    .listRowBackground(Theme.evergreen)
                }
            }
            Section("By category") {
                ForEach(store.categories) { c in
                    NavigationLink {
                        TransactionListView(title: c.name, expenses: { [month] in $0.expenses(in: c.id, monthOf: month) })
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            row(c.name, store.spent(in: c, monthOf: month), icon: c.icon)
                            ProgressBar(value: c.monthlyLimit > 0 ? store.spent(in: c, monthOf: month).double / c.monthlyLimit.double : 0,
                                        tint: Theme.sage)
                            let left = store.left(in: c, monthOf: month)
                            Text(left >= 0
                                 ? "\(left.currency) left of \(c.monthlyLimit.currency)"
                                 : "\((-left).currency) over \(c.monthlyLimit.currency) budget")
                                .font(.caption)
                                .foregroundStyle(left >= 0 ? Theme.sage : Theme.overspend)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash") { deletingCategory = c }
                            .tint(Theme.amaranth)
                        Button("Edit", systemImage: "pencil") { editingCategory = c }
                            .tint(Theme.marine)
                    }
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { editingCategory = c }
                        Button("Delete", systemImage: "trash", role: .destructive) { deletingCategory = c }
                    }
                }
                Button { showAddCategory = true } label: {
                    Label("Add category", systemImage: "plus.circle.fill")
                        .foregroundStyle(Theme.sage)
                }
            }
            .listRowBackground(Theme.evergreen)
        }
        .refreshable { await store.syncTransactions() }
        .overlay(alignment: .bottomTrailing) {
            Button { showAdd = true } label: {
                Image(systemName: "plus").font(.title2.bold()).padding(18)
                    .background(Theme.marine, in: Circle()).foregroundStyle(.white)
            }.padding(24)
        }
        .overlay(alignment: .top) { toastView }
        .sheet(isPresented: $showAdd) { AddExpenseSheet() }
        .sheet(isPresented: $showAddCategory) {
            CategoryEditorSheet(onSorted: showToast)
        }
        .sheet(item: $editingCategory) { c in
            CategoryEditorSheet(category: c, bucket: store.bucket(for: c.id), onSorted: showToast)
        }
        .sheet(item: $deletingCategory) { c in
            DeleteCategorySheet(category: c)
        }
    }

    // MARK: Toast

    @ViewBuilder private var toastView: some View {
        if let toast {
            Label(toast, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Theme.marine, in: Capsule())
                .foregroundStyle(.white)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: toast) {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation { self.toast = nil }
                }
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private func showToast(_ message: String) {
        withAnimation { toast = message }
    }

    private func row(_ title: String, _ amount: Decimal, icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(amount.currency).bold()
        }
        .listRowBackground(Theme.evergreen)
    }
}

struct MonthSpendCard: View {
    @Environment(BudgetStore.self) var store
    let month: Date
    var body: some View {
        let spent = store.totalSpent(inMonthOf: month)
        let income = store.plan(for: month)?.income ?? 0
        // Track against the category budgets; fall back to income if no budgets are set yet.
        let budget = store.totalMonthlyBudget > 0 ? store.totalMonthlyBudget : income
        let left = budget - spent
        let isCurrentMonth = Calendar.current.isDate(month, equalTo: .now, toGranularity: .month)
        HeroCard {
            Text(month.formatted(.dateTime.month(.wide).year())).font(.cardTitle).foregroundStyle(Theme.sage)
            Text(spent.currency).font(.heroNumber)
            Text("spent of \(budget.currency) budgeted").foregroundStyle(Theme.sage)
            Spacer()
            HStack(alignment: .firstTextBaseline) {
                Text(left >= 0
                     ? "\(left.currency) \(isCurrentMonth ? "left" : "under budget")"
                     : "\((-left).currency) over budget")
                    .font(.headline)
                    .foregroundStyle(left >= 0 ? Theme.textPrimary : Theme.overspend)
                Spacer()
                Text("\(income.currency) income").font(.caption).foregroundStyle(Theme.sage)
            }
            ProgressBar(value: budget == 0 ? 0 : spent.double / budget.double)
        }
    }
}

struct AddExpenseSheet: View {
    @Environment(BudgetStore.self) var store
    @Environment(\.dismiss) var dismiss
    @State private var amount: Decimal = 0
    @State private var categoryID: UUID?
    @State private var note = ""
    @State private var date = Date.now

    var body: some View {
        NavigationStack {
            Form {
                TextField("Amount", value: $amount, format: .currency(code: store.profile.currencyCode)).keyboardType(.decimalPad)
                Picker("Category", selection: $categoryID) {
                    ForEach(store.categories) { Text($0.name).tag(Optional($0.id)) }
                }
                DatePicker("Date", selection: $date, displayedComponents: .date)
                TextField("Note", text: $note)
            }
            .navigationTitle("New expense")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let id = categoryID { store.addExpense(.init(amount: amount, categoryID: id, date: date, note: note)) }
                        dismiss()
                    }.disabled(categoryID == nil || amount <= 0)
                }
            }
        }
    }
}

extension Calendar {
    func startOfMonth(_ d: Date) -> Date { date(from: dateComponents([.year, .month], from: d)) ?? d }
}

#Preview {
    SpendingView()
        .environment(BudgetStore())
        .preferredColorScheme(.dark)
        .tint(Theme.marine)
}
