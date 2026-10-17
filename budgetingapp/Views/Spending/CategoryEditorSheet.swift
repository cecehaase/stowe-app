import SwiftUI

/// Adds a spending category, or edits one (pass `category`), from the Spending tab.
/// After saving, existing transactions are sorted into it and `onSorted` reports how many moved.
struct CategoryEditorSheet: View {
    @Environment(BudgetStore.self) var store
    @Environment(\.dismiss) var dismiss
    let category: BudgetCategory?
    var onSorted: (String) -> Void = { _ in }

    @State private var name: String
    @State private var bucket: BudgetBucket
    @State private var monthlyLimit: Decimal
    @State private var icon: String
    @State private var keywords: [String]
    @State private var newKeyword = ""
    @State private var showDelete = false

    init(category: BudgetCategory? = nil, bucket: BudgetBucket = .wants, onSorted: @escaping (String) -> Void = { _ in }) {
        self.category = category
        self.onSorted = onSorted
        _name = State(initialValue: category?.name ?? "")
        _bucket = State(initialValue: bucket)
        _monthlyLimit = State(initialValue: category?.monthlyLimit ?? 0)
        _icon = State(initialValue: category?.icon ?? "tag.fill")
        _keywords = State(initialValue: category?.keywords ?? [])
    }

    private var isEditing: Bool { category != nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isDuplicate: Bool { !trimmedName.isEmpty && store.hasCategory(named: trimmedName, excluding: category?.id) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Category name", text: $name)
                        .textInputAutocapitalization(.words)
                    Picker("Type", selection: $bucket) {
                        ForEach([BudgetBucket.needs, .wants]) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField("Monthly budget", value: $monthlyLimit,
                              format: .currency(code: store.profile.currencyCode).precision(.fractionLength(0)))
                        .keyboardType(.decimalPad)
                } footer: {
                    if isDuplicate { Text("You already have a category called \(trimmedName).").foregroundStyle(.red) }
                }

                keywordsSection

                Section("Icon") {
                    IconPicker(selection: $icon).padding(.vertical, 4)
                }

                if isEditing {
                    Section {
                        Button("Delete category", role: .destructive) { showDelete = true }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit category" : "New category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add", action: save)
                        .disabled(trimmedName.isEmpty || isDuplicate)
                }
            }
            .sheet(isPresented: $showDelete) {
                if let category {
                    DeleteCategorySheet(category: category) { dismiss() }
                }
            }
        }
    }

    // MARK: Keywords

    private var keywordsSection: some View {
        Section {
            ForEach(keywords, id: \.self) { Text($0) }
                .onDelete { keywords.remove(atOffsets: $0) }
            HStack {
                TextField("Add a merchant or keyword", text: $newKeyword)
                    .textInputAutocapitalization(.words)
                    .onSubmit(addKeyword)
                Button("Add", action: addKeyword)
                    .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Merchants & keywords")
        } footer: {
            Text("Transactions whose merchant or description contains one of these always go here, e.g. \"Zola\", \"The Knot\" or \"florist\" for a Wedding category. Swipe to remove.")
        }
    }

    private func addKeyword() {
        keywords = CategoryKeywords.cleaned(keywords + [newKeyword])
        newKeyword = ""
    }

    // MARK: Save

    private func save() {
        // Count a keyword typed but not yet added.
        let finalKeywords = CategoryKeywords.cleaned(keywords + [newKeyword])
        let id: UUID
        if let category {
            store.updateCategory(category.id, name: trimmedName, icon: icon, bucket: bucket,
                                 monthlyLimit: monthlyLimit, keywords: finalKeywords)
            id = category.id
        } else {
            guard let added = store.addCategory(name: trimmedName, icon: icon, bucket: bucket,
                                                monthlyLimit: monthlyLimit, keywords: finalKeywords) else { return }
            id = added.id
        }
        dismiss()

        // New categories, or changed keywords, may claim transactions that are already imported.
        let keywordsChanged = Set(finalKeywords.map(CategoryKeywords.normalize))
            != Set((category?.keywords ?? []).map(CategoryKeywords.normalize))
        guard !isEditing || keywordsChanged else { return }
        let categoryName = trimmedName
        let onSorted = onSorted
        Task {
            let moved = await store.sortExistingTransactions(into: id)
            if moved > 0 { onSorted("\(moved) transaction\(moved == 1 ? "" : "s") moved to \(categoryName)") }
        }
    }
}

/// Confirms deleting a category and asks where its transactions should go.
struct DeleteCategorySheet: View {
    @Environment(BudgetStore.self) var store
    @Environment(\.dismiss) var dismiss
    let category: BudgetCategory
    var onDeleted: () -> Void = {}

    /// nil = Needs review.
    @State private var destination: UUID?

    var body: some View {
        let count = store.expenses.filter { $0.categoryID == category.id }.count
        let others = store.categories.filter { $0.id != category.id }
        NavigationStack {
            Form {
                Section {
                    Label(category.name, systemImage: category.icon)
                } footer: {
                    Text(count == 0
                         ? "This category has no transactions."
                         : "It has \(count) transaction\(count == 1 ? "" : "s"). Choose where \(count == 1 ? "it goes" : "they go").")
                }
                if count > 0 {
                    Section("Move transactions to") {
                        Picker("Move to", selection: $destination) {
                            Label("Needs review", systemImage: "questionmark.circle").tag(UUID?.none)
                            ForEach(others) { Label($0.name, systemImage: $0.icon).tag(Optional($0.id)) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
                Section {
                    Button("Delete \(category.name)", role: .destructive) {
                        store.deleteCategory(category.id, moveTransactionsTo: destination)
                        dismiss()
                        onDeleted()
                    }
                } footer: {
                    Text("Merchants you'd set to always go to \(category.name) will follow your choice above.")
                }
            }
            .navigationTitle("Delete category?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
