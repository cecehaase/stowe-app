import AuthenticationServices
import CryptoKit
import LinkKit
import SwiftUI

/// "Connect bank" button: fetches a link token from the backend, prepares a Plaid Link session,
/// and on success hands the public token to the store to exchange and sync.
/// Signed out, it shows Sign in with Apple first and opens Link as soon as sign-in succeeds.
struct PlaidLinkButton: View {
    // Qualified: LinkKit also declares an `Environment` type.
    @SwiftUI.Environment(BudgetStore.self) var store
    var title = "Connect bank account"

    @State private var linkSession: PlaidLinkSession?
    @State private var isPresentingLink = false
    @State private var isPreparing = false
    @State private var errorMessage: String?
    /// Raw nonce for the in-flight Apple ID request; Apple receives only its SHA-256.
    @State private var nonce = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.isSignedIn {
                linkButton
            } else {
                signInButton
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .sheet(isPresented: $isPresentingLink) {
            if let linkSession { linkSession.sheet() }
        }
    }

    private var linkButton: some View {
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
    }

    private var signInButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            SignInWithAppleButton(.continue) { request in
                // No name or email requested: the server only needs Apple's stable user ID.
                nonce = Self.randomNonce()
                request.nonce = Self.sha256(nonce)
            } onCompletion: { result in
                Task { await finishSignIn(result) }
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 48)
            .disabled(isPreparing)

            Text("Sign in to connect your bank securely.")
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
        }
    }

    private func finishSignIn(_ result: Result<ASAuthorization, Error>) async {
        errorMessage = nil
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken else {
                errorMessage = "Sign in with Apple didn't return a token. Try again."
                return
            }
            isPreparing = true
            do {
                try await store.signIn(identityToken: String(decoding: tokenData, as: UTF8.self), nonce: nonce)
                await prepareAndPresent()
            } catch {
                isPreparing = false
                errorMessage = store.noteAPIError(error)
            }
        case .failure(let error):
            // Dismissing the Apple sheet isn't an error worth showing.
            if (error as? ASAuthorizationError)?.code != .canceled {
                errorMessage = error.localizedDescription
            }
        }
    }

    private static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    private static func sha256(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
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
            errorMessage = store.noteAPIError(error)
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
