import CoreGraphics
import Foundation

public enum TextInserter {
    /// Insert text into the frontmost application.
    /// Runs on a detached task to avoid blocking the main actor.
    /// Waits 150ms first so the floating window finishes hiding and the target app regains focus.
    public static func insert(_ text: String) async {
        guard !text.isEmpty else { return }
        // Run CGEvent posting off the main actor to prevent blocking it
        await Task.detached {
            // 150ms for focus return — use usleep since Thread.sleep is unavailable in async context
            usleep(150_000)

            let source = CGEventSource(stateID: .hidSystemState)
            for scalar in text.unicodeScalars {
                var chars = Array(String(scalar).utf16)
                if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                   let up   = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                    down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
                    up.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
                    down.post(tap: .cghidEventTap)
                    up.post(tap: .cghidEventTap)
                }
            }
        }.value
    }
}
