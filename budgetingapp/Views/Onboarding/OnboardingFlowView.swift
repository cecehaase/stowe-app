import SwiftUI

/// Welcome flow: income → split → connect bank → (prefill from history) → categories → monthly allocations.
/// Shown on first launch and from Profile to readjust (pre-filled with saved answers).
struct OnboardingFlowView: View {
    @Environment(BudgetStore.self) var store
    @State private var model: OnboardingViewModel
    var onCancel: (() -> Void)?
    var onFinish: () -> Void

    init(prefill: OnboardingResult? = nil, onCancel: (() -> Void)? = nil, onFinish: @escaping () -> Void) {
        _model = State(initialValue: OnboardingViewModel(prefill: prefill))
        self.onCancel = onCancel
        self.onFinish = onFinish
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ProgressView(value: Double(model.step.rawValue + 1), total: Double(OnboardingViewModel.Step.allCases.count))
                    .padding(.horizontal)

                Group {
                    switch model.step {
                    case .income: IncomeStep(model: model)
                    case .split: SplitStep(model: model)
                    case .connect: ConnectBankStep(model: model)
                    case .prefill: PrefillStep(model: model)
                    case .categories: CategoriesStep(model: model)
                    case .allocation: AllocationStep(model: model)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)).combined(with: .opacity))
            }
            .safeAreaInset(edge: .bottom) { navigationButtons }
            .background(Theme.background.ignoresSafeArea())
            .foregroundStyle(Theme.textPrimary)
            .toolbar {
                if let onCancel {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                }
            }
            .animation(.snappy, value: model.step)
            .onAppear { model.isBankLinked = store.isBankLinked }
        }
    }

    private var navigationButtons: some View {
        HStack(spacing: 12) {
            if model.step != .income {
                Button("Back") { model.back() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
            if model.step == .prefill {
                // Detected-income choice (made on the page) applies either way.
                Button("No thanks") { model.next() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                let summary = PrefillStep.summary(model: model, store: store)
                Button("Use these") {
                    model.applyPrefill(summary)
                    model.next()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(summary.suggestions.isEmpty)
            } else {
                Button(primaryTitle) {
                    if model.isLastStep {
                        store.applyOnboarding(model.makeResult())
                        onFinish()
                    } else {
                        model.next()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(!model.canAdvance)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var primaryTitle: String {
        if model.isLastStep { return "Finish" }
        if model.step == .connect && !store.isBankLinked { return "Skip for now" }
        return "Next"
    }
}

#Preview {
    OnboardingFlowView {}
        .environment(BudgetStore())
        .preferredColorScheme(.dark)
        .tint(Theme.marine)
}
