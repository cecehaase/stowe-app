import SwiftUI

/// Shared layout: paging carousel on the top half, list on the bottom.
struct CarouselListLayout<Item: Hashable, Card: View, ListContent: View>: View {
    let title: String
    let items: [Item]
    @Binding var selection: Item
    @ViewBuilder let card: (Item) -> Card
    @ViewBuilder let list: () -> ListContent

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    TabView(selection: $selection) {
                        ForEach(items, id: \.self) { item in
                            card(item).padding(.horizontal, 20).tag(item)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .always))
                    .frame(height: geo.size.height * 0.45)

                    List { list() }
                        .scrollContentBackground(.hidden)
                        .listStyle(.insetGrouped)
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(title)
            .toolbarBackground(Theme.ink, for: .navigationBar)
        }
    }
}

struct HeroCard<Content: View>: View {
    var fill: Color = Theme.evergreen
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.corner))
            .foregroundStyle(Theme.textPrimary)
            .padding(.bottom, 36) // room for page dots
    }
}

struct ProgressBar: View {
    let value: Double // 0...1+
    var tint: Color = Theme.marine
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(value > 1 ? Theme.blackCherry : Theme.ink.opacity(0.6))
                Capsule().fill(value > 1 ? Theme.amaranth : tint).frame(width: g.size.width * min(value, 1))
            }
        }.frame(height: 8)
    }
}

#Preview {
    HeroCard {
        Text("Hero card").font(.cardTitle)
        Text(Decimal(1234).currency).font(.heroNumber)
        Spacer()
        ProgressBar(value: 0.6)
    }
    .frame(height: 280)
    .padding()
    .background(Theme.background)
        .preferredColorScheme(.dark)
        .tint(Theme.marine)
}
