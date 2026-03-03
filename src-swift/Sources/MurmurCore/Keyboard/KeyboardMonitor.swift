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
    private var pttActive = false
    private var lastFlags: CGEventFlags = []

    public init(hotkey: String, mouseEnterBtn: String? = nil) {
        self.hotkey = hotkey
        self.mouseEnterBtn = mouseEnterBtn
    }

    public func start() {
        let eventMask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue)

        let selfPtr = Unmanaged.passRetained(self).toOpaque()
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
            CFRunLoopAddSource(CFRunLoopGetCurrent(), self.runLoopSource, .commonModes)
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

        let (flagBit, expectedKeyCode): (CGEventFlags, Int64) = {
            switch hotkey {
            case "ROption":  return (.maskAlternate, 61)
            case "LOption":  return (.maskAlternate, 58)
            case "RControl": return (.maskControl,   62)
            case "LControl": return (.maskControl,   59)
            case "CapsLock": return (.maskAlphaShift, 57)
            case "F13": return ([], 105)
            case "F14": return ([], 107)
            case "F15": return ([], 113)
            default: return (.maskAlternate, 61)
            }
        }()

        if keyCode == expectedKeyCode {
            let hadFlag = lastFlags.contains(flagBit)
            let hasFlag = flags.contains(flagBit)
            if !flagBit.isEmpty {
                if !hadFlag && hasFlag  { triggerStart() }
                if  hadFlag && !hasFlag { triggerStop()  }
            } else {
                // Function keys: use raw flags changed event — detect press only via EV_FLAGS_CHANGED
                // keyCode match + no modifier flag means key down; if pttActive, key up
                if !pttActive { triggerStart() } else { triggerStop() }
            }
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
