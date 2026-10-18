import SwiftUI
import LocalAuthentication

/// Gates the app behind Face ID / Touch ID with passcode fallback (`.deviceOwnerAuthentication`).
/// The app starts locked and re-locks whenever it goes to the background.
@MainActor
@Observable
final class AppLock {
    /// The lock is compiled out on the Simulator so development isn't interrupted by
    /// auth prompts. This is a compile-time check, so device builds are always locked.
    #if targetEnvironment(simulator)
    static let isEnabled = false
    #else
    static let isEnabled = true
    #endif

    private(set) var isLocked = AppLock.isEnabled
    private(set) var isAuthenticating = false
    private(set) var errorMessage: String?

    /// Set once we've auto-prompted for the current foreground session. The system auth sheet
    /// itself bounces the scene through `.inactive` → `.active`, so without this a cancelled
    /// prompt would immediately re-prompt in a loop.
    private var hasAutoPrompted = false

    func lock() {
        guard Self.isEnabled else { return }
        isLocked = true
        hasAutoPrompted = false
        errorMessage = nil
    }

    /// Used right after onboarding finishes, so the user isn't challenged mid-session.
    func unlockWithoutPrompt() {
        isLocked = false
        errorMessage = nil
    }

    /// Called when the scene becomes active; prompts once per foreground session.
    func unlockIfNeeded() async {
        guard isLocked, !hasAutoPrompted else { return }
        hasAutoPrompted = true
        await authenticate()
    }

    func authenticate() async {
        guard isLocked, !isAuthenticating else { return }
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            // No passcode set on the device — there's nothing to authenticate against.
            if (policyError as? LAError)?.code == .passcodeNotSet {
                isLocked = false
            } else {
                errorMessage = policyError?.localizedDescription
            }
            return
        }

        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                             localizedReason: "Unlock Stowe to view your finances.")
            isLocked = false
            errorMessage = nil
        } catch let error as LAError where error.code == .userCancel || error.code == .appCancel || error.code == .systemCancel {
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Full-screen cover shown while the app is locked. Also hides content in the app switcher snapshot.
struct LockScreenView: View {
    let lock: AppLock

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.marine)
                Text("Stowe is locked")
                    .font(.title2.bold())
                if let message = lock.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button("Unlock") {
                    Task { await lock.authenticate() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(lock.isAuthenticating)
            }
            .padding()
        }
    }
}
