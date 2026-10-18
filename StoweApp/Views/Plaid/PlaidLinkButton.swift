import LinkKit
import SwiftUI

/// "Connect bank" button: fetches a link token from the backend, prepares a Plaid Link session,
/// and on success hands the public token to the store to exchange and sync.
struct PlaidLinkButton: View {
    // Qualified: LinkKit also declares an `Environment` type.
    @SwiftUI.Environment(BudgetStore.self) var store
    var title = "Connect bank account"

    @State private var linkSession: PlaidLinkSession?
    @State private var isPresentingLink = false
    @State private var isPreparing = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Task { await prepareAndPresent() }
            } label: {
                HStack {
                    Label(title, systemImage: "building.columns.fill")
                    Spacer()
                    if isPreparing || store.isSyncing { ProgressView() }
                }
            }
            .disabled(isPreparing || store.isSyncing)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .sheet(isPresented: $isPresentingLink) {
            if let linkSession { linkSession.sheet() }
        }
    }

    /// Fetches a link token and starts loading Link in the background.
    /// The sheet is presented from `onLoad`, once Link is ready, so it never opens blank.
    private func prepareAndPresent() async {
        isPreparing = true
        errorMessage = nil
        do {
            let token = try await store.api.createLinkToken()
            linkSession = try Plaid.createPlaidLinkSession(configuration: configuration(token: token))
        } catch {
            isPreparing = false
            errorMessage = error.localizedDescription
        }
    }

    private func configuration(token: String) -> LinkTokenConfiguration {
        LinkTokenConfiguration(
            token: token,
            onSuccess: { success in
                isPresentingLink = false
                Task { await store.completeBankLink(publicToken: success.publicToken) }
            },
            onExit: { exit in
                // Also called if Link fails to initialize, so clear the loading state here too.
                isPresentingLink = false
                isPreparing = false
                if let error = exit.error {
                    errorMessage = error.displayMessage ?? "Couldn't connect your bank."
                }
            },
            onEvent: { _ in },
            onLoad: {
                isPreparing = false
                isPresentingLink = true
            }
        )
    }
}
