import CoreGraphics
import AppKit

public class KeyboardMonitor {
    public var onPTTStart: (@Sendable () -> Void)?
    public var onPTTStop: (@Sendable () -> Void)?
    public var onCursorPosition: (@Sendable (CGPoint) -> Void)?
    public var onMouseEnter: (@Sendable () -> Void)?

    private let hotkey: String
    private let mouseEnterBtn: String?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var pttActive = false
    private var lastFlags: CGEventFlags = []

    public init(hotkey: String, mouseEnterBtn: String? = nil) {
        self.hotkey = hotkey
        self.mouseEnterBtn = mouseEnterBtn
    }

    private static let functionKeyCodes: Set<Int64> = [105, 107, 113] // F13, F14, F15

    public func start() {
        let eventMask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, userInfo -> Unmanaged<CGEvent>? in
                let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userInfo!).takeUnretainedValue()
                return monitor.handle(proxy: proxy, type: type, event: event)
            },
            userInfo: selfPtr
        )

        guard let tap = eventTap else {
            print("[KeyboardMonitor] Failed to create event tap — grant Accessibility permission")
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        tapThread = Thread {
            let rl = CFRunLoopGetCurrent()
            self.tapRunLoop = rl
            CFRunLoopAddSource(rl, self.runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        tapThread?.start()
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        eventTap = nil
        if let rl = tapRunLoop { CFRunLoopStop(rl) }
        tapRunLoop = nil
        tapThread?.cancel()
        tapThread = nil
    }

    // MARK: - Private event handling

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let loc = NSEvent.mouseLocation
        onCursorPosition?(loc)

        switch type {
        case .flagsChanged:
            return handleFlagsChanged(event: event)

        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if isFunctionKeyHotkey(keyCode: keyCode) {
                triggerStart()
                return nil
            }

        case .keyUp:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if isFunctionKeyHotkey(keyCode: keyCode) {
                triggerStop()
                return nil
            }

        case .otherMouseDown:
            let btn = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            if isHotkeyMouseButton(btn) { triggerStart(); return nil }
            if isEnterMouseButton(btn)  { onMouseEnter?(); return nil }

        case .otherMouseUp:
            let btn = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            if isHotkeyMouseButton(btn) { triggerStop(); return nil }
            if isEnterMouseButton(btn)  { return nil }

        default:
            break
        }
        return Unmanaged.passRetained(event)
    }

    private func handleFlagsChanged(event: CGEvent) -> Unmanaged<CGEvent>? {
        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        let (flagBit, expectedKeyCode): (CGEventFlags, Int64)
        switch hotkey {
        case "ROption":  (flagBit, expectedKeyCode) = (.maskAlternate,  61)
        case "LOption":  (flagBit, expectedKeyCode) = (.maskAlternate,  58)
        case "RControl": (flagBit, expectedKeyCode) = (.maskControl,    62)
        case "LControl": (flagBit, expectedKeyCode) = (.maskControl,    59)
        case "CapsLock": (flagBit, expectedKeyCode) = (.maskAlphaShift, 57)
        default:
            // Hotkey is a mouse button or F-key — ignore flagsChanged entirely
            lastFlags = flags
            return Unmanaged.passRetained(event)
        }

        if keyCode == expectedKeyCode {
            let hadFlag = lastFlags.contains(flagBit)
            let hasFlag = flags.contains(flagBit)
            if !hadFlag && hasFlag  { triggerStart() }
            if  hadFlag && !hasFlag { triggerStop()  }
        }

        lastFlags = flags
        return Unmanaged.passRetained(event)
    }

    private func isHotkeyMouseButton(_ btn: Int) -> Bool {
        switch hotkey {
        case "MouseMiddle":   return btn == 2
        case "MouseSideBack": return btn == 3
        case "MouseSideFwd":  return btn == 4
        default: return false
        }
    }

    private func isEnterMouseButton(_ btn: Int) -> Bool {
        switch mouseEnterBtn {
        case "MouseMiddle":   return btn == 2
        case "MouseSideBack": return btn == 3
        case "MouseSideFwd":  return btn == 4
        default: return false
        }
    }

    private func isFunctionKeyHotkey(keyCode: Int64) -> Bool {
        switch hotkey {
        case "F13": return keyCode == 105
        case "F14": return keyCode == 107
        case "F15": return keyCode == 113
        default: return false
        }
    }

    private func triggerStart() {
        guard !pttActive else { return }
        pttActive = true
        let cb = onPTTStart
        DispatchQueue.main.async { cb?() }
    }

    private func triggerStop() {
        guard pttActive else { return }
        pttActive = false
        let cb = onPTTStop
        DispatchQueue.main.async { cb?() }
    }
}
