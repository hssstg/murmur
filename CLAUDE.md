# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Build & test (Swift)
cd src-swift && swift build
cd src-swift && swift run MurmurTests

# Release build + DMG
bash scripts/build-dmg.sh

# Install to /Applications (after build-dmg.sh)
# The script copies the .app bundle automatically

# Launch release binary (via Ghostty for mic TCC inheritance)
pkill murmur 2>/dev/null; sleep 0.5
open -na Ghostty --args -e '/Applications/Murmur.app/Contents/MacOS/Murmur'

# Version bump
bash scripts/bump-version.sh <version>
```

## Architecture

Murmur is a native macOS push-to-talk dictation app. Swift 6, no external dependencies, menu-bar-only (`.accessory` activation policy).

### Two-window model

`AppDelegate` manages a `FloatingWindow` (pill UI, always-on-top, never steals focus) and an on-demand `SettingsWindow`. The floating window shows status during dictation and hides when idle.

### Event flow for push-to-talk

```
CGEventTap (KeyboardMonitor)
  → AudioCapture.start() (AVAudioEngine, 16kHz mono PCM)
  → VolcengineClient WebSocket connect
  → PCM chunks streamed to BigASR
  → final ASR result received
  → if llm_enabled: LLMClient.polish()
  → TextInserter.insert() (CGEvent keystrokes to frontmost app)
```

### Core modules (`src-swift/Sources/MurmurCore/`)

| Module | Responsibility |
|---|---|
| `Keyboard/KeyboardMonitor.swift` | CGEventTap listener; detects hotkey press/release; supports modifier keys, function keys, mouse buttons |
| `Audio/AudioCapture.swift` | AVAudioEngine capture; 16kHz mono PCM; emits audio chunks via callback |
| `ASR/VolcengineClient.swift` | WebSocket client for Volcengine BigASR streaming API |
| `ASR/VolcengineProtocol.swift` | Binary protocol encode/decode for ASR packets |
| `LLM/LLMClient.swift` | OpenAI-compatible API client for text polishing and hotword extraction |
| `PTT/PushToTalk.swift` | Session orchestration; state machine with generation counters for race safety |
| `Config/AppConfig.swift` | JSON config at `~/Library/Application Support/com.murmurtype/config.json` |
| `Text/TextInserter.swift` | CGEvent keystroke injection to frontmost app |
| `History/HistoryStore.swift` | Local dictation history persistence |
| `Hotwords/` | HotwordStore + VolcHotwordsClient for Volcengine hot words API |

### App layer (`src-swift/Sources/App/`)

| File | Responsibility |
|---|---|
| `AppDelegate.swift` | Tray menu, window lifecycle, PTT callbacks, accessibility/mic permission flow |
| `FloatingWindow.swift` | Pill UI; waveform during listening, text during processing |
| `SettingsView.swift` | Config UI (ASR, Hotkey, LLM, Hotwords tabs) |
| `HistoryView.swift` | Dictation history browser |
| `HotwordsView.swift` | Hot words management |
| `StatsView.swift` | Usage statistics charts |

### ASR status flow

`idle → connecting → listening → processing → [polishing] → done → idle`

- `polishing` only occurs when `llm_enabled = true`
- The floating window hides in `idle`; shown in all other states

### Focus / insert mechanism

`TextInserter` sends keystrokes via `CGEvent` to whichever app is currently frontmost. The floating window hides before insertion so the target app regains focus. **Do not insert text while the floating window is visible** — keystrokes would go to the wrong app.

### Hotkey options

Supported: `ROption`, `LOption`, `RControl`, `LControl`, `CapsLock`, `F13`, `F14`, `F15`, `MouseMiddle`, `MouseSideBack`, `MouseSideFwd`.

Modifier keys detected via `EV_FLAGS_CHANGED` + flag bit transitions. Mouse buttons via `EV_OTHER_MOUSE_DOWN/UP` (suppressed to prevent system side effects).

### TCC permissions

- **Accessibility**: `AXIsProcessTrustedWithOptions` prompts on first launch; retry timer polls until granted
- **Microphone**: Ad-hoc signed .app on Sequoia may not trigger TCC dialog. Workaround: launch from Ghostty to inherit terminal's mic permission

### Android (`src-android/`)

Kotlin Android IME implementation sharing the same Volcengine ASR backend. Core classes: `MurmurIME`, `MicKeyboardView`, `AudioStreamer`, `VolcengineClient`, `PermissionActivity`.

### CI/CD (`.gitlab-ci.yml`)

Three stages: `test` → `build-release` → `deploy-website`. Runs on macOS GitLab Runner. Deploys DMG + website to Cloudflare Pages.
