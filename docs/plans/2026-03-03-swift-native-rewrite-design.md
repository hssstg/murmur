# Design: Full Swift Native Rewrite

**Date:** 2026-03-03
**Goal:** Replace Tauri + React + TypeScript + WebView with a pure Swift + AppKit app to reduce memory usage and eliminate browser overhead.

## Decision

- Remove: Tauri, React, TypeScript, Vite, node_modules, WebView
- Replace with: Swift + AppKit (floating window) + SwiftUI (settings)
- New code lives in `src-swift/` alongside existing code until fully working, then old dirs deleted

## Technology Choices

| Layer | Choice | Reason |
|---|---|---|
| Floating window UI | AppKit (NSWindow/NSView) | Full control over transparency, window level, no-focus behavior |
| Settings UI | SwiftUI | Clean form layout, less boilerplate |
| Keyboard monitoring | CGEventTap (C API via Swift) | Same as current keyboard.rs |
| Audio capture | AVAudioEngine | Simpler than raw CoreAudio |
| ASR WebSocket | URLSessionWebSocketTask | No dependencies |
| LLM HTTP | URLSession async/await | No dependencies |
| Text insertion | CGEvent (keyboard events) | Same as current enigo approach |
| Config | Codable + JSONEncoder/Decoder | Reads same config.json path |
| Build | Xcode project | Required for entitlements, code signing, Info.plist |

## Project Structure

```
src-swift/
├── murmur.xcodeproj
└── Sources/
    ├── App/
    │   ├── main.swift             # NSApplication.main entry
    │   └── AppDelegate.swift      # App lifecycle, tray (NSStatusItem), window management
    ├── UI/
    │   ├── FloatingWindow.swift   # Transparent, borderless, always-on-top NSWindow
    │   ├── FloatingView.swift     # Pill shape: waveform / status text / transcript display
    │   ├── SettingsWindow.swift   # NSWindow wrapper for settings
    │   └── SettingsView.swift     # SwiftUI form: hotkey, ASR, LLM fields
    ├── Core/
    │   ├── KeyboardMonitor.swift  # CGEventTap, hotkey detection, cursor position
    │   ├── AudioCapture.swift     # AVAudioEngine, PCM chunk emission
    │   ├── PushToTalk.swift       # State machine (idle→connecting→listening→processing→polishing→done)
    │   └── TextInserter.swift     # CGEvent text injection with focus-return delay
    ├── ASR/
    │   └── VolcengineClient.swift # URLSessionWebSocketTask, BigASR streaming protocol
    ├── LLM/
    │   └── LLMClient.swift        # OpenAI-compatible chat completions via URLSession
    └── Config/
        └── AppConfig.swift        # Codable struct, load/save ~/Library/.../config.json
```

## State Machine

```swift
enum PTTState {
    case idle
    case connecting
    case listening
    case processing
    case polishing   // only when llm_enabled
    case done
}
```

Mirrors current `ASRStatus` union in `asr/types.ts`.

## Thread Model

```
Main thread (@MainActor)
  └── AppKit/SwiftUI UI updates

KeyboardMonitor
  └── Dedicated CFRunLoop thread (CGEventTap requirement)
  └── Posts PTT events → PushToTalk via MainActor

AudioCapture
  └── AVAudioEngine internal tap thread
  └── Sends PCM chunks → VolcengineClient

ASRClient
  └── URLSession delegate queue
  └── Publishes results → PushToTalk via MainActor

LLMClient
  └── URLSession async/await (structured concurrency)
```

## Config Compatibility

`AppConfig` reads/writes the same path:
`~/Library/Application Support/com.locke.murmur/config.json`

Same field names preserved — no migration needed for existing config.

## Floating Window Behavior

- `NSWindow.level = .floating` (always on top)
- `NSWindow.styleMask = .borderless`
- `NSWindow.backgroundColor = .clear`
- `NSWindow.isOpaque = false`
- `canBecomeKey = false` — prevents focus steal (same as current `focus: false` in tauri.conf.json)
- Positioned near cursor on PTT trigger (same as current keyboard.rs cursor tracking)

## What Gets Deleted (after new version works)

- `src/` — all React/TypeScript frontend
- `src-tauri/` — Rust backend
- `node_modules/`, `package.json`, `pnpm-lock.yaml`
- `vite.config.ts`, `tsconfig.json`, `tsconfig.node.json`
- `index.html`
