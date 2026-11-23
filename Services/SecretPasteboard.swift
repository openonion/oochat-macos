import AppKit

/// Copies a secret so clipboard managers skip it, then clears it after a delay.
@MainActor
enum SecretPasteboard {
    /// The nspasteboard.org marker that clipboard managers and history tools skip.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let clearDelay: Duration = .seconds(60)
    static let copiedMessage = "Copied \u{00B7} clears in \(clearDelay.components.seconds) s"

    /// The secret still waiting to be cleared, so quitting can clear it early.
    private static var pending: (pasteboard: NSPasteboard, changeCount: Int)?

    /// Kept on this Mac (no Universal Clipboard), with the concealed marker declared alongside the
    /// text, so a clipboard manager never sees the text without it.
    @discardableResult
    static func copy(
        _ secret: String,
        to pasteboard: NSPasteboard = .general,
        clearAfter delay: Duration = clearDelay
    ) -> Bool {
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.declareTypes([concealedType, .string], owner: nil)
        guard pasteboard.setData(Data(), forType: concealedType),
              pasteboard.setString(secret, forType: .string) else {
            return false
        }
        let changeCount = pasteboard.changeCount
        pending = (pasteboard, changeCount)
        Task {
            try? await Task.sleep(for: delay)
            clearIfUnchanged(pasteboard, since: changeCount)
        }
        return true
    }

    /// On quit: the timer won't run once the app is gone, so clear now.
    static func clearPending() {
        guard let pending else {
            return
        }
        clearIfUnchanged(pending.pasteboard, since: pending.changeCount)
    }

    /// Clears the pasteboard only if nothing else was copied since the secret.
    static func clearIfUnchanged(_ pasteboard: NSPasteboard, since changeCount: Int) {
        if pending?.changeCount == changeCount {
            pending = nil
        }
        guard pasteboard.changeCount == changeCount else { return }
        pasteboard.clearContents()
    }
}
