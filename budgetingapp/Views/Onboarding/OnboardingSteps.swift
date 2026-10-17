import SwiftUI

// MARK: - Step 1: Income

struct IncomeStep: View {
    @Bindable var model: OnboardingViewModel
    @Environment(BudgetStore.self) var store

    var body: some View {
        Form {
            Section {
                OnboardingStepHeader(title: "Welcome to Ledgerline",
                                     subtitle: "Let's start with how much you earn.")
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }

            Section {
                Picker("Period", selection: $model.period) {
                    ForEach(IncomePeriod.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField(model.period == .yearly ? "Yearly salary" : "Monthly take-home",
                          value: $model.income, format: .currency(code: store.profile.currencyCode).precision(.fractionLength(0)))
                    .keyboardType(.decimalPad)
                    .font(.title2.weight(.semibold))
            } footer: {
                Text(model.period == .yearly ? "Your yearly salary." : "What lands in your account each month, after taxes.")
            }

            if model.period == .yearly {
                Section {
                    Toggle("This is my pre-tax salary — estimate taxes", isOn: $model.estimateTaxes)
                    if model.estimateTaxes {
                        Picker("Location", selection: $model.taxInputs.stateCode) {
                            Text("Not sure").tag(String?.none)
                            ForEach(TaxEstimator.states) { Text($0.name).tag(Optional($0.code)) }
                        }
                        Picker("Marital status", selection: $model.taxInputs.maritalStatus) {
                            Text("Prefer not to say").tag(MaritalStatus?.none)
                            ForEach(MaritalStatus.allCases) { Text($0.label).tag(Optional($0)) }
                        }
                        HStack {
                            Text("401(k) contribution")
                            Spacer()
                            TextField("Don't know", value: $model.taxInputs.contribution401kPercent, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 100)
                            Text("%").foregroundStyle(Theme.textMuted)
                        }
                    }
                } footer: {
                    if model.estimateTaxes {
                        Text("Leave anything you're not sure about — we'll use a general estimate for your location.")
                    }
                }
            }

            if model.income > 0 {
                Section("Estimate") { summary }
            }
        }
        .scrollContentBackground(.hidden)
        .listRowBackground(Theme.evergreen)
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder private var summary: some View {
        if let t = model.taxEstimate {
            LabeledContent("Taken out per paycheck", value: "≈ \(t.perPaycheckTaxes.currency)")
            LabeledContent("Take-home per paycheck", value: "≈ \(t.perPaycheckNet.currency)")
            LabeledContent("Take-home per month", value: "≈ \(t.monthlyNet.currency)")
            Text(estimateNote(t)).font(.caption).foregroundStyle(Theme.textMuted)
        } else {
            LabeledContent("Per year", value: model.annualTakeHome.currency)
            LabeledContent("Per month", value: "≈ \(model.monthlyTakeHome.currency)")
        }
    }

    private func estimateNote(_ t: TaxEstimate) -> String {
        let place = model.taxInputs.stateCode.flatMap(TaxEstimator.state(for:))?.name ?? "the US"
        let kind = t.isGeneralEstimate ? "General estimate for \(place)" : "Estimate for \(place)"
        return "\(kind), assuming biweekly paychecks · ~\(Int((t.effectiveRate * 100).rounded()))% effective tax rate. Rough estimate, not tax advice."
    }
}

// MARK: - Step 2: Needs / Wants / Savings split

struct SplitStep: View {
    @Bindable var model: OnboardingViewModel
    @State private var page: BudgetBucket = .needs

    var body: some View {
        VStack(spacing: 16) {
            OnboardingStepHeader(title: "Split your income",
                                 subtitle: "Based on \(model.monthlyTakeHome.currency) / month take-home.")
                .padding(.horizontal)

            Label("Most people follow the 50/30/20 rule: 50% needs, 30% wants and 20% savings.", systemImage: "lightbulb.fill")
                .font(.subheadline)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.evergreen, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)

            TabView(selection: $page) {
                ForEach(BudgetBucket.allCases) { bucket in
                    slide(for: bucket).padding(.horizontal).tag(bucket)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            HStack {
                Text("Total \(Int(model.split.total.rounded()))%")
                    .font(.headline)
                    .foregroundStyle(model.split.isValid ? Theme.sage : .red)
                if !model.split.isValid {
                    Text(model.split.total > 100 ? "— reduce by \(Int((model.split.total - 100).rounded()))%"
                                                 : "— add \(Int((100 - model.split.total).rounded()))%")
                        .font(.subheadline).foregroundStyle(.red)
                }
                Spacer()
                Button("Reset to 50/30/20") { model.split = BudgetSplit() }
                    .font(.subheadline)
            }
            .padding(.horizontal)
        }
    }

    private func slide(for bucket: BudgetBucket) -> some View {
        HeroCard {
            Label(bucket.title, systemImage: bucket.icon).font(.cardTitle).foregroundStyle(Theme.sage)
            Text(bucket.blurb).font(.subheadline).foregroundStyle(Theme.textMuted)
            Spacer()
            Text("\(Int(model.split[bucket].rounded()))%").font(.heroNumber)
            Slider(value: $model.split[bucket], in: 0...100, step: 1) { Text(bucket.title) }
            Text("\(model.annual(for: bucket).currency) / year").font(.headline)
            Text("≈ \(model.monthly(for: bucket).currency) / month").font(.subheadline).foregroundStyle(Theme.textMuted)
        }
    }
}

// MARK: - Step 3: Categories

struct CategoriesStep: View {
    @Bindable var model: OnboardingViewModel
    @State private var customName = ""
    @State private var customBucket: BudgetBucket = .wants

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                OnboardingStepHeader(title: "Where does it go?",
                                     subtitle: "Pick your main spending categories. You can choose as many as you like.")

                grid(CategoryPreset.all.filter { !$0.isSuggested })

                Text("Suggested").font(.cardTitle).foregroundStyle(Theme.sage)
                grid(CategoryPreset.all.filter(\.isSuggested))

                Text("Your own").font(.cardTitle).foregroundStyle(Theme.sage)
                if !model.customCategories.isEmpty {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(model.customCategories) { c in
                            CategoryChip(name: c.name, icon: c.icon, isSelected: true) { model.remove(c) }
                        }
                    }
                }
                HStack {
                    TextField("Add a category", text: $customName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addCustom)
                    Picker("Type", selection: $customBucket) {
                        ForEach([BudgetBucket.needs, .wants]) { Text($0.title).tag($0) }
                    }
                    Button("Add", action: addCustom)
                        .disabled(customName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func grid(_ presets: [CategoryPreset]) -> some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(presets) { p in
                CategoryChip(name: p.name, icon: p.icon, isSelected: model.isSelected(p)) { model.toggle(p) }
            }
        }
    }

    private func addCustom() {
        model.addCustom(named: customName, bucket: customBucket)
        customName = ""
    }
}

// MARK: - Step 4: Monthly allocation per category

struct AllocationStep: View {
    @Bindable var model: OnboardingViewModel
    @Environment(BudgetStore.self) var store
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 12) {
            OnboardingStepHeader(title: "Set monthly budgets",
                                 subtitle: "Choose how much of your \(model.monthlyTakeHome.currency) goes to each category.")
                .padding(.horizontal)

            tabStrip

            TabView(selection: $selection) {
                ForEach($model.selected) { $category in
                    page(for: $category).padding(.horizontal).tag(Optional(category.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .safeAreaInset(edge: .bottom) {
            AllocationBar(segments: segments, allocated: model.totalAllocated, monthlyIncome: model.monthlyTakeHome)
                .padding(.horizontal)
        }
        .onAppear { if selection == nil { selection = model.selected.first?.id } }
    }

    private var tabStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(model.selected.enumerated()), id: \.element.id) { index, c in
                        Button {
                            selection = c.id
                        } label: {
                            Label(c.name, systemImage: c.icon)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(selection == c.id ? color(at: index) : Theme.evergreen, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .id(c.id)
                    }
                }
                .padding(.horizontal)
            }
            .onChange(of: selection) { _, id in
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func page(for category: Binding<OnboardingCategory>) -> some View {
        let c = category.wrappedValue
        let bucketBudget = model.monthly(for: c.bucket)
        let bucketLeft = bucketBudget - model.allocated(in: c.bucket)
        let share = model.monthlyTakeHome > 0 ? c.monthlyAmount / model.monthlyTakeHome : 0

        return HeroCard {
            Label(c.name, systemImage: c.icon).font(.cardTitle).foregroundStyle(Theme.sage)
            Text(c.bucket.title).font(.caption.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Theme.ink.opacity(0.5), in: Capsule())
            Spacer()
            TextField("Amount", value: category.monthlyAmount,
                      format: .currency(code: store.profile.currencyCode).precision(.fractionLength(0)))
                .keyboardType(.decimalPad)
                .font(.heroNumber)
            Text("per month · \(Int((share * 100).rounded()))% of income").foregroundStyle(Theme.textMuted)
            Slider(value: category.monthlyAmount, in: 0...max(model.monthlyTakeHome, c.monthlyAmount, 1), step: 5) {
                Text(c.name)
            }
            Text(bucketLeft >= 0
                 ? "\(bucketLeft.currency) left of your \(bucketBudget.currency) \(c.bucket.rawValue) budget"
                 : "\((-bucketLeft).currency) over your \(bucketBudget.currency) \(c.bucket.rawValue) budget")
                .font(.footnote)
                .foregroundStyle(bucketLeft >= 0 ? Theme.textMuted : .red)
        }
        .padding(.bottom, -24) // HeroCard reserves space for page dots, which are hidden here
    }

    private var segments: [AllocationBar.Segment] {
        model.selected.enumerated().map { index, c in
            .init(id: c.id,
                  fraction: model.monthlyTakeHome > 0 ? c.monthlyAmount / model.monthlyTakeHome : 0,
                  color: color(at: index))
        }
    }

    private func color(at index: Int) -> Color { Theme.categoryColors[index % Theme.categoryColors.count] }
}
