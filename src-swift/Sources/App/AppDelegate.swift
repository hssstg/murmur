import AppKit
import SwiftUI
import AVFoundation
import MurmurCore

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var floatingWindow: FloatingWindow!
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private var ptt: PushToTalk!
    private var keyboard: KeyboardMonitor!
    private var audio: AudioCapture!
    private let configStore = ConfigStore()
    private let historyStore = HistoryStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // no Dock icon

        floatingWindow = FloatingWindow()

        ptt = PushToTalk(config: configStore.config)
        setupPTTCallbacks()
        setupAudio()
        setupKeyboard()
        setupTray()

        // Request microphone permission early so it's ready on first PTT press
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                fputs("[murmur] microphone permission denied\n", stderr)
            }
        }
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
            // Record completed transcription to history
            if status == .done {
                let text = self.ptt.currentText
                self.historyStore.add(text: text)
            }
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
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try self.audio.start(deviceUID: self.configStore.config.microphone)
                } catch {
                    fputs("[murmur] audio.start failed: \(error)\n", stderr)
                }
                self.ptt.handleStart()
            }
        }
        keyboard.onPTTStop = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.audio.stop()
                self.ptt.handleStop()
            }
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
        // Audio is started on PTT press and stopped on PTT release
    }

    // MARK: - Tray

    private func setupTray() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Murmur")
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "历史记录...", action: #selector(openHistory), keyEquivalent: "h"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "设置...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func openHistory() {
        if let w = historyWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(
            rootView: HistoryView(store: historyStore)
        )
        let win = NSWindow(contentViewController: hosting)
        win.title = "Murmur 历史记录"
        win.setContentSize(NSSize(width: 540, height: 480))
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.center()
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        historyWindow = win
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
            onSave: { [weak self] in
                guard let self = self else { return }
                try? self.configStore.save()
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
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
        win.title = "Murmur 设置"
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
        if (notification.object as? NSWindow) === historyWindow {
            historyWindow = nil
        }
    }
}
