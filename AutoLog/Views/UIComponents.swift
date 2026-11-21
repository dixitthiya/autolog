import SwiftUI
import UIKit

// MARK: - Formats

/// One place for how numbers, money and dates read on screen.
enum Fmt {
    /// "117,356 mi"
    static func miles(_ value: Double) -> String {
        "\(Int(value).formatted()) mi"
    }

    /// "—" when there is no odometer yet (0 means "unknown", not a real reading).
    static func milesOrDash(_ value: Double) -> String {
        value > 0 ? miles(value) : "—"
    }

    /// Always two decimals: "$9.72", "$1,204.00".
    static func money(_ value: Double) -> String {
        value.formatted(.currency(code: "USD"))
    }

    /// "Nov 20, 2026"
    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    /// "Nov 20, 2026 at 11:03 PM" (follows the phone's 12/24-hour setting)
    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Error wording

extension Error {
    /// What a person should read when something fails. The raw details are
    /// already in the log; they are never shown on screen.
    var userMessage: String {
        if NetworkMonitor.isOfflineError(self) {
            return "Can't reach the database — check your connection."
        }
        if self is URLError {
            return "Couldn't reach the database. Try again in a moment."
        }
        if let message = (self as? LocalizedError)?.errorDescription, !message.isEmpty {
            return message
        }
        return "Something went wrong. Please try again."
    }
}

// MARK: - Toast

/// A short message at the bottom of the screen that dismisses itself
/// (~5 seconds for errors). Replaces the hand-built red capsules.
struct ToastModifier: ViewModifier {
    @Binding var message: String?
    var seconds: Double = 5

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.9), in: Capsule())
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: message)
            .task(id: message) {
                guard message != nil else { return }
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if !Task.isCancelled { message = nil }
            }
    }
}

extension View {
    /// Show `message` as an auto-dismissing toast (errors, ~5 s).
    func errorToast(_ message: Binding<String?>) -> some View {
        modifier(ToastModifier(message: message))
    }

    /// One "Done" button above the keyboard, for number and decimal pads
    /// (they have no return key).
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
    }
}
