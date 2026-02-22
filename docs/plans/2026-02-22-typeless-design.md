# Typeless Design Document

**Date:** 2026-02-22
**Status:** Approved

## Overview

A macOS voice input tool built with Tauri v2 + Rust. Hold Right Option key to record, release to insert transcribed text at cursor. Ports the core functionality of `open-typeless` while replacing Electron with Tauri for a lighter, more native binary.

## Goals

- Feature parity with open-typeless (push-to-talk, floating window, cursor insertion)
- Replace Electron with Tauri v2
- Keep Volcengine BigASR WebSocket (port existing TypeScript client)
- Keep Web Audio API for audio capture

## Architecture

### Layers

**Rust backend (`src-tauri/`)**
- Global keyboard hook via `rdev` crate — detects Right Option keydown/keyup system-wide
- Text insertion via `enigo` crate — types transcribed text at current cursor position
- Exposes Tauri commands and events to the frontend

**Frontend (`src/`)**
- React + TypeScript
- Web Audio API: captures microphone input as PCM 16-bit 16kHz mono
- Volcengine WebSocket client (ported from open-typeless): streams audio, receives transcription
- Floating window UI: always-on-top, non-focusable, shows status and live transcript

### Event / Command Flow

```
keydown (Right Option)
  Rust (rdev) → Tauri event "ptt:start" → Frontend
  Frontend: open WebSocket + start Web Audio recording
  Frontend → Volcengine: stream PCM chunks
  Volcengine → Frontend: interim transcript → update UI

keyup (Right Option)
  Rust (rdev) → Tauri event "ptt:stop" → Frontend
  Frontend: stop recording, send final audio frame
  Volcengine → Frontend: final transcript
  Frontend → Rust: Tauri command "insert_text(text)"
  Rust (enigo): type text at cursor
  Frontend: hide floating window
```

### IPC Interface

**Tauri events (Rust → Frontend)**
- `ptt:start` — trigger key pressed, begin recording
- `ptt:stop` — trigger key released, finalize and insert

**Tauri commands (Frontend → Rust)**
- `insert_text(text: string)` — insert text at cursor via enigo

## Tech Stack

| Concern | Original (Electron) | New (Tauri) |
|---|---|---|
| Framework | Electron | Tauri v2 |
| Global keyboard | uiohook-napi (Node) | rdev (Rust) |
| Text insertion | node-insert-text (Node) | enigo (Rust) |
| Audio capture | Web Audio API | Web Audio API (unchanged) |
| ASR WebSocket | TypeScript | TypeScript (ported) |
| UI | React | React (ported) |

## Project Structure

```
typeless/
├── src-tauri/
│   ├── src/
│   │   ├── main.rs          # Tauri app setup
│   │   ├── keyboard.rs      # rdev global keyboard hook
│   │   └── text.rs          # enigo text insertion command
│   ├── Cargo.toml
│   └── tauri.conf.json
└── src/
    ├── main.tsx
    ├── App.tsx              # Floating window root
    ├── asr/
    │   ├── volcengine-client.ts   # Ported from open-typeless
    │   ├── audio-recorder.ts      # Ported from open-typeless
    │   └── pcm-converter.ts       # Ported from open-typeless
    ├── hooks/
    │   └── usePushToTalk.ts       # Coordinates ptt events + ASR
    └── components/
        └── FloatingWindow.tsx     # Status + transcript UI
```

## Key Rust Crates

- `tauri` v2
- `rdev` — cross-platform global keyboard/mouse hook
- `enigo` — cross-platform keyboard/mouse input simulation

## Environment Config

Same as open-typeless, loaded via `.env`:
- `VOLCENGINE_APP_ID`
- `VOLCENGINE_ACCESS_TOKEN`
- `VOLCENGINE_RESOURCE_ID` (optional, default: `volc.bigasr.sauc`)

## macOS Permissions Required

- Microphone — for Web Audio recording
- Accessibility — for global keyboard hook (rdev) and text insertion (enigo)
