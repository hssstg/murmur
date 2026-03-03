import CoreGraphics
import Foundation

public enum TextInserter {
    /// Insert text into the frontmost application.
    /// Waits 150ms first so the floating window finishes hiding and the target app regains focus.
    /// Do NOT call win.makeKey() or similar before this — it would type into the murmur window.
    public static func insert(_ text: String) async {
        guard !text.isEmpty else { return }
        try? await Task.sleep(nanoseconds: 150_000_000)  // 150ms

        let source = CGEventSource(stateID: .hidSystemState)
        for scalar in text.unicodeScalars {
            var char = UniChar(scalar.value & 0xFFFF)
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
               let up   = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &char)
                up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &char)
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
        }
    }
}
