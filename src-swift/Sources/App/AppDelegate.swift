import AppKit
import SwiftUI
import MurmurCore

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var floatingWindow: FloatingWindow!
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private var ptt: PushToTalk!
    private var keyboard: KeyboardMonitor!
    private var audio: AudioCapture!
    private let configStore = ConfigStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // no Dock icon

        floatingWindow = FloatingWindow()

        ptt = PushToTalk(config: configStore.config)
        setupPTTCallbacks()
        setupAudio()
        setupKeyboard()
        setupTray()
    }

    // MARK: - PTT callbacks

    private func setupPTTCallbacks() {
        ptt.onStatusChange = { [weak self] status in
            guard let self = self else { return }
            self.floatingWindow.update(
                status: status,
                text: self.ptt.currentText,
                levels: self.ptt.audioLevels
            )
        }
        ptt.onTextChange = { [weak self] text in
            guard let self = self else { return }
            self.floatingWindow.update(
                status: self.ptt.status,
                text: text,
                levels: self.ptt.audioLevels
            )
        }
        ptt.onAudioLevels = { [weak self] levels in
            guard let self = self else { return }
            self.floatingWindow.update(
                status: self.ptt.status,
                text: self.ptt.currentText,
                levels: levels
            )
        }
    }

    // MARK: - Keyboard

    private func setupKeyboard() {
        let cfg = configStore.config
        keyboard = KeyboardMonitor(hotkey: cfg.hotkey, mouseEnterBtn: cfg.mouse_enter_btn)

        keyboard.onPTTStart = { [weak self] in
            Task { @MainActor [weak self] in self?.ptt.handleStart() }
        }
        keyboard.onPTTStop = { [weak self] in
            Task { @MainActor [weak self] in self?.ptt.handleStop() }
        }
        keyboard.onCursorPosition = { [weak self] point in
            Task { @MainActor [weak self] in
                self?.floatingWindow.positionNearCursor(point)
            }
        }
        keyboard.onMouseEnter = {
            let src = CGEventSource(stateID: .hidSystemState)
            CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: false)?.post(tap: .cghidEventTap)
        }
        keyboard.start()
    }

    // MARK: - Audio

    private func setupAudio() {
        audio = AudioCapture()
        audio.onChunk = { [weak self] data in
            Task { @MainActor [weak self] in self?.ptt.handleAudioChunk(data) }
        }
        try? audio.start(deviceUID: configStore.config.microphone)
    }

    // MARK: - Tray

    private func setupTray() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Murmur")
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func openSettings() {
        if let w = settingsWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView(
            config: Binding(
                get:  { self.configStore.config },
                set:  { self.configStore.config = $0 }
            ),
            onSave: {
                try? self.configStore.save()
                Task { @MainActor in
                    self.ptt.updateConfig(self.configStore.config)
                    self.keyboard.stop()
                    self.setupKeyboard()
                }
            }
        )
        let hosting = NSHostingController(
            rootView: NavigationStack { view }
                .frame(minWidth: 480, minHeight: 500)
        )
        let win = NSWindow(contentViewController: hosting)
        win.title = "Murmur Settings"
        win.setContentSize(NSSize(width: 500, height: 560))
        win.styleMask = [.titled, .closable, .resizable]
        win.center()
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = win
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow {
            settingsWindow = nil
        }
    }
}
