import SwiftUI

/// Grid of SF Symbols for choosing a category icon. Shared by the Spending tab's category editor
/// and onboarding's custom categories.
struct IconPicker: View {
    @Binding var selection: String

    static let icons = [
        "tag.fill", "cart.fill", "fork.knife", "cup.and.saucer.fill", "car.fill", "fuelpump.fill",
        "house.fill", "bolt.fill", "wifi", "bag.fill", "tshirt.fill", "gift.fill",
        "heart.fill", "cross.case.fill", "figure.run", "pawprint.fill", "gamecontroller.fill", "airplane",
        "book.fill", "graduationcap.fill", "music.note", "film.fill", "wrench.and.screwdriver.fill", "creditcard.fill",
    ]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Self.icons, id: \.self) { symbol in
                Button { selection = symbol } label: {
                    Image(systemName: symbol)
                        .font(.title3)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(selection == symbol ? Theme.marine : Theme.evergreen,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(Theme.textPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(symbol.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " "))
                .accessibilityAddTraits(selection == symbol ? .isSelected : [])
            }
        }
    }
}
