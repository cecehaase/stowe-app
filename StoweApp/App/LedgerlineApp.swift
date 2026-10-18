import SwiftUI

@main
struct LedgerlineApp: App {
    @State private var store: BudgetStore
    @State private var alerts: AlertManager
    @State private var appLock = AppLock()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = BudgetStore()
        let alerts = AlertManager()
        alerts.store = store
        _store = State(initialValue: store)
        _alerts = State(initialValue: alerts)
        // Started here rather than in a view: iOS may relaunch the app in the background for a
        // place event without creating any UI, and events only reach an open monitor.
        Task { await alerts.startMonitoring() }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboarding {
                    RootTabView()
                } else {
                    OnboardingFlowView {
                        appLock.unlockWithoutPrompt()
                        hasCompletedOnboarding = true
                    }
                }
            }
            // Only lock once onboarding is done; there's no data to protect before then.
            .overlay {
                if hasCompletedOnboarding && appLock.isLocked {
                    LockScreenView(lock: appLock)
                }
            }
            .environment(store)
            .environment(alerts)
            .preferredColorScheme(.dark)
            .tint(Theme.marine)
            // Spending reminders carry amounts, so re-schedule them whenever the budget changes.
            .onChange(of: store.dataVersion) { Task { await alerts.refreshAll() } }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                if hasCompletedOnboarding { Task { await appLock.unlockIfNeeded() } }
                Task { await alerts.refreshAll() }
            case .background:
                appLock.lock()
                Task { await AlertManager.scheduleBackgroundRefresh() }
            default: break
            }
        }
        // Periodic background refresh: pull new transactions, then update reminder amounts.
        .backgroundTask(.appRefresh(AlertManager.refreshTaskID)) { [store, alerts] in
            await store.syncTransactions()
            await alerts.refreshAll()
            await AlertManager.scheduleBackgroundRefresh()
        }
    }
}
