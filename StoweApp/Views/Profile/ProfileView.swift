import SwiftUI

struct ProfileView: View {
    @Environment(BudgetStore.self) var store
    @Environment(AlertManager.self) var alerts
    @State private var showNewAlert = false
    @State private var editingAlert: PersonalAlert?
    @State private var showSetup = false
    @State private var confirmStartOver = false
    @State private var confirmDeleteAccount = false
    @State private var isDeletingAccount = false
    @State private var accountError: String?
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            List {
                Section("Profile") {
                    TextField("Name", text: $store.profile.name)
                    TextField("Currency", text: $store.profile.currencyCode)
                }
                Section("Budget setup") {
                    if let setup = store.onboarding {
                        LabeledContent("Take-home", value: "\(setup.monthlyTakeHome.currency) / mo")
                        LabeledContent("Needs / Wants / Savings",
                                       value: "\(Int(setup.split.needs)) / \(Int(setup.split.wants)) / \(Int(setup.split.savings))")
                        LabeledContent("Categories", value: "\(setup.categories.count)")
                    }
                    Button("Readjust income & budget") { showSetup = true }
                    Button("Start over", role: .destructive) { confirmStartOver = true }
                }
                Section("Bank accounts") {
                    PlaidLinkButton(title: store.isBankLinked ? "Connect another account" : "Connect bank account")
                    if store.isBankLinked && store.isSignedIn {
                        Button { Task { await store.syncTransactions() } } label: {
                            Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(store.isSyncing)
                        if let last = store.lastSyncDate {
                            LabeledContent("Last synced", value: last.formatted(.relative(presentation: .named)))
                        }
                    }
                    if let error = store.syncError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                if store.isSignedIn {
                    Section {
                        Button(role: .destructive) { confirmDeleteAccount = true } label: {
                            HStack {
                                Text("Delete account")
                                Spacer()
                                if isDeletingAccount { ProgressView() }
                            }
                        }
                        .disabled(isDeletingAccount)
                        if let accountError {
                            Text(accountError).font(.caption).foregroundStyle(.red)
                        }
                    } header: {
                        Text("Account")
                    } footer: {
                        Text("Signed in with Apple. Deleting your account disconnects your banks and removes your data from Stowe's server.")
                    }
                }
                Section("Permissions") {
                    Button("Enable notifications & location") { Task { await alerts.requestPermissions() } }
                }
                Section {
                    ForEach(alerts.alerts) { a in
                        HStack {
                            // Tap the text to edit; the switch turns the alert on or off.
                            Button { editingAlert = a } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.title.isEmpty ? defaultTitle(for: a) : a.title)
                                        .foregroundStyle(Theme.textPrimary)
                                    Text(a.trigger.summary).font(.caption).foregroundStyle(Theme.sage)
                                    if a.spending != nil {
                                        Label("Spending check-in", systemImage: "dollarsign.circle")
                                            .font(.caption2)
                                            .foregroundStyle(Theme.sage)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            Toggle(a.title, isOn: Binding(get: { a.isEnabled }, set: { _ in alerts.toggle(a) }))
                                .labelsHidden()
                        }
                    }
                    .onDelete { $0.map { alerts.alerts[$0] }.forEach(alerts.remove) }
                } header: {
                    HStack { Text("Personal alerts"); Spacer(); Button("New") { showNewAlert = true } }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Profile")
            .sheet(isPresented: $showNewAlert) { AlertEditorSheet() }
            .sheet(item: $editingAlert) { AlertEditorSheet(alert: $0) }
            .fullScreenCover(isPresented: $showSetup) {
                OnboardingFlowView(prefill: store.onboarding, onCancel: { showSetup = false }) { showSetup = false }
            }
            .confirmationDialog("Start over?", isPresented: $confirmStartOver) {
                Button("Clear setup and start over", role: .destructive) {
                    store.resetOnboarding()
                    hasCompletedOnboarding = false
                }
            } message: {
                Text("This clears your income and budget setup and shows the welcome screens again.")
            }
            .confirmationDialog("Delete your account?", isPresented: $confirmDeleteAccount, titleVisibility: .visible) {
                Button("Delete account", role: .destructive) { Task { await deleteAccount() } }
            } message: {
                Text("Stowe will disconnect every linked bank and delete your account and synced transactions. This can't be undone.")
            }
        }
    }

    private func deleteAccount() async {
        isDeletingAccount = true
        accountError = nil
        defer { isDeletingAccount = false }
        do {
            try await store.deleteAccount()
            // Back to a fresh install: welcome screens with no saved setup.
            store.resetOnboarding()
            hasCompletedOnboarding = false
        } catch {
            accountError = store.noteAPIError(error)
        }
    }

    private func defaultTitle(for alert: PersonalAlert) -> String {
        if case let .location(name, _, _, _, _) = alert.trigger, !name.isEmpty { return "At \(name)" }
        return alert.spending != nil ? "Spending check-in" : "Reminder"
    }
}

extension AlertTrigger {
    var summary: String {
        switch self {
        case let .calendar(d, r):
            return "\(d.formatted(date: .abbreviated, time: .shortened))\(r ? " · monthly" : "")"
        case let .weekly(weekdays, hour, minute):
            let time = Calendar.current.date(from: DateComponents(hour: hour, minute: minute))?
                .formatted(date: .omitted, time: .shortened) ?? ""
            return "\(Weekday.describe(weekdays)) at \(time)"
        case let .location(name, _, _, radius, entry):
            return "\(entry ? "Arriving at" : "Leaving") \(name) (\(Int(radius))m)"
        }
    }
}

/// Weekday helpers (Calendar numbering: 1 = Sunday … 7 = Saturday).
enum Weekday {
    /// Short symbols in the user's locale, ordered from the locale's first weekday.
    static var ordered: [(number: Int, symbol: String)] {
        let cal = Calendar.current
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { offset in
            let n = (cal.firstWeekday - 1 + offset) % 7 + 1
            return (n, symbols[n - 1])
        }
    }

    /// "Every weekend", "Weekdays", "Every day", or e.g. "Mon, Wed".
    static func describe(_ days: [Int]) -> String {
        let set = Set(days)
        if set == [1, 7] { return "Every weekend" }
        if set == [2, 3, 4, 5, 6] { return "Weekdays" }
        if set.count == 7 { return "Every day" }
        let names = Calendar.current.shortWeekdaySymbols
        return ordered.map(\.number).filter(set.contains).map { names[$0 - 1] }.joined(separator: ", ")
    }
}

#Preview {
    ProfileView()
        .environment(BudgetStore())
        .environment(AlertManager())
        .preferredColorScheme(.dark)
        .tint(Theme.marine)
}
