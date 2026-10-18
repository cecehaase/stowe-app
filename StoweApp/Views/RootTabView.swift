import SwiftUI

struct RootTabView: View {
    init() {
        let a = UITabBarAppearance()
        a.configureWithOpaqueBackground()
        a.backgroundColor = UIColor(Theme.ink)
        UITabBar.appearance().standardAppearance = a
        UITabBar.appearance().scrollEdgeAppearance = a
    }
    var body: some View {
        TabView {
            SpendingView().tabItem { Label("Spending", systemImage: "chart.pie.fill") }
            SavingsView().tabItem { Label("Savings", systemImage: "banknote.fill") }
            GoalsView().tabItem { Label("Plan", systemImage: "calendar") }
            ProfileView().tabItem { Label("Profile", systemImage: "person.crop.circle") }
        }
    }
}

#Preview {
    RootTabView()
        .environment(BudgetStore())
        .environment(AlertManager())
        .preferredColorScheme(.dark)
        .tint(Theme.marine)
}
