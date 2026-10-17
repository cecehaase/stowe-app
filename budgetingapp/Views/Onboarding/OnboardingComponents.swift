import SwiftUI

struct OnboardingStepHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(.largeTitle, design: .rounded).weight(.heavy))
            Text(subtitle).foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Multiselect chip used on the categories step.
struct CategoryChip: View {
    let name: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(name).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if isSelected { Image(systemName: "checkmark.circle.fill") }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Theme.marine : Theme.evergreen, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(Theme.textPrimary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Stacked bar showing how much of monthly income each category takes.
struct AllocationBar: View {
    struct Segment: Identifiable {
        let id: UUID
        let fraction: Double
        let color: Color
    }

    let segments: [Segment]
    let allocated: Double
    let monthlyIncome: Double

    private var totalFraction: Double { monthlyIncome > 0 ? allocated / monthlyIncome : 0 }
    private var isOver: Bool { totalFraction > 1.0001 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(Int((totalFraction * 100).rounded()))% of monthly income")
                    .font(.headline)
                Spacer()
                Text(isOver ? "\((allocated - monthlyIncome).currency) over" : "\((monthlyIncome - allocated).currency) left")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isOver ? .red : Theme.sage)
            }
            GeometryReader { g in
                // Scale segments down when over 100% so the bar never overflows.
                let scale = max(totalFraction, 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.ink.opacity(0.6))
                    HStack(spacing: 1) {
                        ForEach(segments) { s in
                            Rectangle().fill(s.color).frame(width: max(g.size.width * s.fraction / scale - 1, 0))
                        }
                    }
                    .clipShape(Capsule())
                }
                .overlay(Capsule().stroke(isOver ? Color.red : .clear, lineWidth: 2))
            }
            .frame(height: 14)
            Text("\(allocated.currency) of \(monthlyIncome.currency) / month allocated")
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
        }
        .padding()
        .background(Theme.evergreen, in: RoundedRectangle(cornerRadius: Theme.corner))
        .accessibilityElement(children: .combine)
    }
}
