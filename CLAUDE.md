# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Build & test (Swift)
cd src-swift && swift build
cd src-swift && swift run MurmurTests

# Release build + DMG
bash scripts/build-dmg.sh

# Launch debug binary (via Ghostty for mic TCC inheritance)
pkill murmur 2>/dev/null; sleep 0.5
open -na Ghostty --args -e /bin/bash -c "cd /path/to/murmur && src-swift/.build/arm64-apple-macosx/debug/murmur"

# Version bump
bash scripts/bump-version.sh <version>
```

## Architecture

Murmur is a native macOS push-to-talk dictation app. Swift 6, no external dependencies, menu-bar-only (`.accessory` activation policy). Fully offline ASR via SenseVoice (sherpa-onnx).

### Two-window model

`AppDelegate` manages a `FloatingWindow` (capsule UI, always-on-top, never steals focus) and on-demand settings/history/hotwords/stats windows. The floating window shows waveform during recording and text after recognition.

### Event flow for push-to-talk

```
CGEventTap (KeyboardMonitor)
  → PushToTalk.handleStart() (immediate, shows floating window)
  → AudioCapture.start() (AVAudioEngine, 16kHz mono PCM, nonisolated)
  → PCM chunks accumulated in SherpaRecognizer
  → PTT release → SherpaRecognizer.finishAudio()
  → SenseVoice offline decode on background thread (~20-50ms)
  → if llm_enabled: LLMClient.polish() (shows "Refining...")
  → TextInserter.insert() (CGEvent keystrokes to frontmost app)
```

### Core modules (`src-swift/Sources/MurmurCore/`)

| Module | Responsibility |
|---|---|
| `Keyboard/KeyboardMonitor.swift` | CGEventTap listener; detects hotkey press/release; supports modifier keys, function keys, mouse buttons |
| `Audio/AudioCapture.swift` | AVAudioEngine capture; 16kHz mono PCM; emits audio chunks via callback |
| `ASR/SherpaRecognizer.swift` | SenseVoice offline recognizer; accumulates audio, decodes on PTT release; RMS silence detection |
| `LLM/LLMClient.swift` | OpenAI-compatible API client for text polishing and hotword extraction |
| `PTT/PushToTalk.swift` | Session orchestration; generation counters for race safety; WAV recording |
| `Config/AppConfig.swift` | JSON config at `~/Library/Application Support/com.murmurtype/config.json` |
| `Text/TextInserter.swift` | CGEvent keystroke injection to frontmost app (runs on detached task) |
| `History/HistoryStore.swift` | Local dictation history persistence |
| `Hotwords/HotwordStore.swift` | Local hot words list |

### App layer (`src-swift/Sources/App/`)

| File | Responsibility |
|---|---|
| `AppDelegate.swift` | Tray menu, window lifecycle, PTT callbacks, accessibility/mic permission flow |
| `FloatingWindow.swift` | Capsule UI (NSPanel + NSVisualEffectView); 5-bar waveform during listening, text on completion |
| `SettingsView.swift` | Config UI (General + LLM tabs) |
| `HistoryView.swift` | Dictation history browser |
| `HotwordsView.swift` | Hot words management |
| `StatsView.swift` | Usage statistics charts |

### ASR status flow

`idle → listening → processing → [polishing] → done → idle`

- `polishing` only occurs when `llm_enabled = true`
- The floating window hides in `idle`; shown in all other states

### Focus / insert mechanism

`TextInserter` sends keystrokes via `CGEvent` to whichever app is currently frontmost. The floating window uses `NSPanel` with `.nonactivatingPanel` so it never steals focus. Text insertion runs on a detached task with 150ms delay for focus settlement.

### Hotkey options

Supported: `ROption`, `LOption`, `RControl`, `LControl`, `CapsLock`, `F13`, `F14`, `F15`, `MouseMiddle`, `MouseSideBack`, `MouseSideFwd`.

Modifier keys detected via `EV_FLAGS_CHANGED` + flag bit transitions. Mouse buttons via `EV_OTHER_MOUSE_DOWN/UP` (suppressed to prevent system side effects).

### TCC permissions

- **Accessibility**: `AXIsProcessTrustedWithOptions` prompts on first launch; retry timer polls until granted
- **Microphone**: Ad-hoc signed .app on Sequoia may not trigger TCC dialog. Workaround: launch from Ghostty to inherit terminal's mic permission

### CI/CD (`.gitlab-ci.yml`)

Three stages: `test` → `build-release` → `deploy-website`. Runs on macOS GitLab Runner. Deploys DMG + website to Cloudflare Pages.
