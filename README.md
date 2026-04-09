# Murmur

Local push-to-talk voice input for macOS. Hold a hotkey to speak, release to insert recognized text at your cursor — no app switching needed. **Fully offline, no cloud required.**

[Website](https://murmurtype.com) | [Download](https://github.com/hssstg/murmur/releases/latest) | [中文说明](README.zh-CN.md)

## Features

- **Push-to-Talk**: Hold a hotkey to record, release to recognize and insert text at your cursor
- **Offline ASR**: Powered by SenseVoice (sherpa-onnx) — Chinese, English, Japanese, Korean, Cantonese with built-in punctuation and ITN
- **Capsule Overlay**: Real-time audio waveform during recording, non-intrusive floating window
- **LLM Polish** (optional): Post-recognition cleanup via any OpenAI-compatible API
- **History**: All transcriptions persisted locally with search
- **Hotwords**: Local hotword management, AI-powered suggestions from history
- **Statistics**: 30-day usage charts and hourly distribution
- **Mouse Remap**: Map a mouse side button to Enter

## Hotkeys

`Right/Left Option`, `Right/Left Control`, `CapsLock`, `F13–F15`, Mouse Middle, Mouse Side M4/M5

## Tech Stack

| Layer | Technology |
|---|---|
| Language / Framework | Swift 6 + AppKit (native, no Electron/Tauri) |
| Speech Recognition | SenseVoice (sherpa-onnx offline, ~228 MB model) |
| Text Insertion | CGEventPost |
| Audio Capture | AVAudioEngine 16 kHz PCM |
| LLM | OpenAI-compatible API (optional, local or cloud) |
| Build | Swift Package Manager |

## Requirements

- macOS 14+
- Xcode Command Line Tools (`xcode-select --install`)
- **Accessibility permission**: System Settings → Privacy & Security → Accessibility — add Murmur
- **Microphone permission**: Granted on first launch

## Model Download

Download the SenseVoice model (~228 MB, not included in the repo) before building:

```bash
cd models/sense-voice-zh-en
curl -LO https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/model.int8.onnx
```

You also need the sherpa-onnx prebuilt library (see `src-swift/LocalPackages/SherpaOnnx/`).

## Build & Run

```bash
cd src-swift
swift build
# Launch from the repo root (model paths require it)
cd .. && src-swift/.build/debug/murmur
```

Release build + DMG:

```bash
bash scripts/build-dmg.sh
```

## Configuration

After first launch, click the menu bar icon → Settings:

| Field | Description |
|---|---|
| Hotkey | Key to trigger recording (default: Right Option) |
| Microphone | Recording device (default: system input) |
| LLM Base URL / Model | OpenAI-compatible endpoint (optional, for text polish) |

Config is stored at `~/Library/Application Support/com.murmurtype/config.json`.

## Project Structure

```
src-swift/
├── Sources/
│   ├── App/               # AppKit UI (AppDelegate, FloatingWindow, settings/history/stats)
│   └── MurmurCore/        # Core logic (ASR, audio, keyboard, LLM, history, hotwords)
├── LocalPackages/SherpaOnnx/  # sherpa-onnx C library SPM wrapper
├── Tests/
├── Package.swift
└── Makefile
models/                    # ASR model files (download separately)
scripts/                   # Build and helper scripts
website/                   # Product page
```

## License

MIT — see [LICENSE](LICENSE)
