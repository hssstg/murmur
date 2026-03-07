import AppKit
import SwiftUI
import AVFoundation
import MurmurCore

// NSWindow that closes itself when ESC is pressed
private class EscapableWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
}

// Wrapper that holds config as @State so SwiftUI re-renders immediately on
// every picker/toggle change, without waiting for an explicit Save press.
@MainActor
private struct SettingsRoot: View {
    @State var config: AppConfig
    let onSave: () -> Void
    let onConfigChange: (AppConfig) -> Void

    var body: some View {
        SettingsView(
            config: Binding(get: { config }, set: { config = $0; onConfigChange($0) }),
            onSave: onSave
        )
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var floatingWindow: FloatingWindow!
    private var settingsWindow: NSWindow?
    private var historyWindow:  NSWindow?
    private var hotwordsWindow: NSWindow?
    private var statsWindow:    NSWindow?
    private var statusItem: NSStatusItem!
    private var ptt: PushToTalk!
    private var keyboard: KeyboardMonitor!
    private var audio: AudioCapture!
    private let configStore   = ConfigStore()
    private let historyStore  = HistoryStore()
    private let hotwordStore  = HotwordStore()
    private var activeStartTask: Task<Void, Never>?
    private var pttStopRequestedDuringStart = false

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
                self.pttStopRequestedDuringStart = false
                guard self.activeStartTask == nil else { return }
                let audio = self.audio!
                let deviceUID = self.configStore.config.microphone
                let ptt = self.ptt!
                let task = Task.detached(priority: .userInitiated) {
                    do {
                        try audio.start(deviceUID: deviceUID)
                    } catch {
                        fputs("[murmur] audio.start failed: \(error)\n", stderr)
                    }
                    // Hop back to main actor to check if PTT was released during startup
                    let shouldStop = await MainActor.run { [weak self] () -> Bool in
                        guard let self = self else { return true }
                        self.activeStartTask = nil
                        return self.pttStopRequestedDuringStart
                    }
                    if shouldStop {
                        // Stop already fired — undo the start and bail
                        audio.stop()
                        return
                    }
                    await ptt.handleStart()
                }
                self.activeStartTask = task
            }
        }
        keyboard.onPTTStop = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.activeStartTask != nil {
                    // Start is still in flight — flag it to abort when it lands
                    self.pttStopRequestedDuringStart = true
                    self.activeStartTask = nil
                    return
                }
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
            let trayImage: NSImage? = {
                // Debug (SPM) builds: load from SPM resource bundle next to binary
                let execDir = Bundle.main.executableURL?.deletingLastPathComponent()
                let spmBundle = execDir.flatMap {
                    Bundle(url: $0.appendingPathComponent("murmur_murmur.bundle"))
                }
                // Prefer @2x for Retina; set logical size to 18pt so it renders sharp
                if let url2x = spmBundle?.url(forResource: "tray@2x", withExtension: "png", subdirectory: "Resources"),
                   let img = NSImage(contentsOf: url2x) {
                    img.size = NSSize(width: 18, height: 18)
                    return img
                }
                if let url = spmBundle?.url(forResource: "tray", withExtension: "png", subdirectory: "Resources") {
                    return NSImage(contentsOf: url)
                }
                // Release (.app) builds: load from main bundle resources
                return NSImage(named: "tray")
            }()
            if let img = trayImage {
                img.isTemplate = true
                btn.image = img
            } else {
                btn.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Murmur")
            }
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: L("menu.history"),  action: #selector(openHistory),   keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: L("menu.hotwords"), action: #selector(openHotwords), keyEquivalent: "w"))
        menu.addItem(NSMenuItem(title: L("menu.stats"),    action: #selector(openStats),    keyEquivalent: "u"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("menu.settings"), action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("menu.quit"),     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func openStats() {
        if let w = statsWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let hosting = NSHostingController(rootView: StatsView(store: historyStore))
        let win = EscapableWindow(contentViewController: hosting)
        win.title = L("window.stats.title")
        win.setContentSize(NSSize(width: 640, height: 640))
        win.styleMask = [.titled, .closable, .resizable]
        win.center()
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        statsWindow = win
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
        let win = EscapableWindow(contentViewController: hosting)
        win.title = L("window.history.title")
        win.setContentSize(NSSize(width: 640, height: 560))
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.center()
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        historyWindow = win
    }

    @objc private func openHotwords() {
        if let w = hotwordsWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(
            rootView: HotwordsView(store: hotwordStore, historyStore: historyStore, config: configStore.config)
        )
        let win = EscapableWindow(contentViewController: hosting)
        win.title = L("window.hotwords.title")
        win.setContentSize(NSSize(width: 520, height: 500))
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.center()
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        hotwordsWindow = win
    }

    @objc private func openSettings() {
        if let w = settingsWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = SettingsRoot(
            config: configStore.config,
            onSave: { [weak self] in
                guard let self = self else { return }
                try? self.configStore.save()
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.ptt.updateConfig(self.configStore.config)
                    self.keyboard.stop()
                    self.setupKeyboard()
                }
            },
            onConfigChange: { [weak self] newConfig in
                self?.configStore.config = newConfig
            }
        )
        let hosting = NSHostingController(
            rootView: NavigationStack { root }
                .frame(minWidth: 560, minHeight: 620)
        )
        let win = EscapableWindow(contentViewController: hosting)
        win.title = L("window.settings.title")
        win.setContentSize(NSSize(width: 580, height: 640))
        win.styleMask = [.titled, .closable, .resizable]
        win.center()
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = win
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow { settingsWindow = nil }
        if (notification.object as? NSWindow) === historyWindow  { historyWindow  = nil }
        if (notification.object as? NSWindow) === hotwordsWindow { hotwordsWindow = nil }
        if (notification.object as? NSWindow) === statsWindow    { statsWindow    = nil }
    }
}
