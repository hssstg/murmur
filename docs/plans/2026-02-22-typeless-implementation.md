# Typeless Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Port open-typeless from Electron to Tauri v2, using Rust (rdev + enigo) for system-level operations and TypeScript for ASR + audio recording.

**Architecture:** Rust backend listens for global keyboard events via rdev, emits Tauri events to the frontend. Frontend records audio with Web Audio API, streams to Volcengine via native WebSocket, and calls back into Rust to insert final text via enigo. See `docs/plans/2026-02-22-typeless-design.md` for full design.

**Tech Stack:** Tauri v2, Rust (rdev 0.5, enigo 0.2), React 19, TypeScript, Vite, pako (browser gzip), eventemitter3, Volcengine BigASR WebSocket V3

**Source to port from:** `/Users/locke/workspace/open-typeless/src/`

---

### Task 1: Scaffold Tauri v2 project

**Files:**
- Create: `package.json`, `index.html`, `vite.config.ts`, `tsconfig.json`, `src/main.tsx`, `src/App.tsx`
- Create: `src-tauri/Cargo.toml`, `src-tauri/tauri.conf.json`, `src-tauri/src/lib.rs`, `src-tauri/src/main.rs`

**Step 1: Scaffold in a temp dir then merge**

```bash
cd /Users/locke/workspace
pnpm create tauri-app@latest typeless-scaffold -- --template react-ts --manager pnpm --yes
```

If `--yes` is not accepted, run interactively and choose:
- App name: `typeless`
- Template: `React` / `TypeScript`

**Step 2: Merge scaffold into existing typeless/ directory**

```bash
# Copy everything except docs/ which already exists
cp -r typeless-scaffold/. typeless/
rm -rf typeless-scaffold
cd typeless
```

**Step 3: Install dependencies**

```bash
pnpm install
```

**Step 4: Verify it builds**

```bash
pnpm tauri dev
```

Expected: Default Tauri window opens with React counter UI.

**Step 5: Commit**

```bash
git add -A
git commit -m "chore: scaffold Tauri v2 + React TS project"
```

---

### Task 2: Configure floating window

**Files:**
- Modify: `src-tauri/tauri.conf.json`
- Modify: `src-tauri/capabilities/default.json` (or wherever window permissions are declared)

**Step 1: Replace window config in tauri.conf.json**

Find the `"windows"` array and replace with:

```json
{
  "label": "main",
  "title": "Typeless",
  "width": 360,
  "height": 130,
  "minWidth": 360,
  "minHeight": 58,
  "resizable": false,
  "decorations": false,
  "transparent": true,
  "alwaysOnTop": true,
  "skipTaskbar": true,
  "visible": false,
  "focus": false,
  "center": true
}
```

**Step 2: Configure CSP to allow Volcengine WebSocket**

In `tauri.conf.json` under `"app"` → `"security"`:

```json
"security": {
  "csp": "default-src 'self'; connect-src wss://openspeech.bytedance.com; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'"
}
```

**Step 3: Add window permissions to capabilities**

Open `src-tauri/capabilities/default.json`. Add to the `"permissions"` array:

```json
"window:allow-show",
"window:allow-hide",
"window:allow-set-focus",
"window:allow-set-always-on-top"
```

**Step 4: Verify build still works**

```bash
pnpm tauri build --debug 2>&1 | tail -20
```

Expected: No errors.

**Step 5: Commit**

```bash
git add src-tauri/tauri.conf.json src-tauri/capabilities/
git commit -m "feat: configure transparent always-on-top floating window"
```

---

### Task 3: Rust keyboard service (rdev)

**Files:**
- Modify: `src-tauri/Cargo.toml`
- Create: `src-tauri/src/keyboard.rs`
- Modify: `src-tauri/src/lib.rs`

**Step 1: Add rdev to Cargo.toml**

```toml
[dependencies]
rdev = "0.5"
```

**Step 2: Create src-tauri/src/keyboard.rs**

```rust
use rdev::{listen, Event, EventType, Key};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tauri::AppHandle;

pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        let is_held = Arc::new(AtomicBool::new(false));
        let is_held_clone = is_held.clone();

        let callback = move |event: Event| {
            match event.event_type {
                EventType::KeyPress(Key::AltGr) => {
                    if !is_held_clone.load(Ordering::SeqCst) {
                        is_held_clone.store(true, Ordering::SeqCst);
                        let _ = app.emit("ptt:start", ());
                    }
                }
                EventType::KeyRelease(Key::AltGr) => {
                    if is_held_clone.load(Ordering::SeqCst) {
                        is_held_clone.store(false, Ordering::SeqCst);
                        let _ = app.emit("ptt:stop", ());
                    }
                }
                _ => {}
            }
        };

        if let Err(e) = listen(callback) {
            eprintln!("[keyboard] rdev listen error: {:?}", e);
        }
    });
}
```

> **Note on macOS key codes:** `Key::AltGr` maps to Right Option on macOS in rdev. If it doesn't fire, print all key events first to find the correct variant:
> ```rust
> EventType::KeyPress(k) => { println!("Key: {:?}", k); }
> ```

**Step 3: Wire keyboard::start into lib.rs setup**

In `src-tauri/src/lib.rs`, in the `run()` function, add a `.setup()` call:

```rust
.setup(|app| {
    crate::keyboard::start(app.handle().clone());
    Ok(())
})
```

Also add `mod keyboard;` at the top of `lib.rs`.

**Step 4: Verify compilation**

```bash
cd src-tauri && cargo build 2>&1 | grep -E "^error"
```

Expected: No output (no errors).

**Step 5: Commit**

```bash
cd ..
git add src-tauri/src/keyboard.rs src-tauri/src/lib.rs src-tauri/Cargo.toml
git commit -m "feat(rust): add rdev global keyboard listener for push-to-talk"
```

---

### Task 4: Rust text insertion command (enigo)

**Files:**
- Modify: `src-tauri/Cargo.toml`
- Create: `src-tauri/src/text.rs`
- Modify: `src-tauri/src/lib.rs`

**Step 1: Add enigo to Cargo.toml**

```toml
enigo = "0.2"
```

**Step 2: Create src-tauri/src/text.rs**

```rust
use enigo::{Direction, Enigo, Key, Keyboard, Settings};

#[tauri::command]
pub fn insert_text(text: String) -> Result<(), String> {
    // Give time for the floating window to hide and focus to return to target app
    std::thread::sleep(std::time::Duration::from_millis(150));

    let mut enigo = Enigo::new(&Settings::default()).map_err(|e| e.to_string())?;
    enigo.text(&text).map_err(|e| e.to_string())?;
    Ok(())
}
```

**Step 3: Register command in lib.rs**

Add `mod text;` at the top. In `tauri::Builder::default()`:

```rust
.invoke_handler(tauri::generate_handler![crate::text::insert_text])
```

**Step 4: Verify compilation**

```bash
cd src-tauri && cargo build 2>&1 | grep -E "^error"
```

Expected: No output.

**Step 5: Add insert_text permission to capabilities**

In `src-tauri/capabilities/default.json`, add:

```json
"core:window:allow-show",
"core:window:allow-hide"
```

Also add the custom command capability. In Tauri v2, custom commands are allowed by default in dev mode; verify in the `default.json` that `invoke` is permitted.

**Step 6: Commit**

```bash
cd ..
git add src-tauri/src/text.rs src-tauri/src/lib.rs src-tauri/Cargo.toml
git commit -m "feat(rust): add insert_text command via enigo"
```

---

### Task 5: Frontend types and constants

**Files:**
- Create: `src/asr/types.ts`
- Create: `src/asr/constants.ts`

**Step 1: Create src/asr/types.ts**

Port from `open-typeless/src/shared/types/asr.ts` and `open-typeless/src/renderer/src/modules/asr/types.ts`. Combine relevant types:

```typescript
export type ASRStatus =
  | 'idle'
  | 'connecting'
  | 'listening'
  | 'processing'
  | 'done'
  | 'error';

export interface ASRResult {
  type: 'interim' | 'final';
  text: string;
  isFinal: boolean;
}

export type ConnectionState =
  | 'disconnected'
  | 'connecting'
  | 'connected'
  | 'error';

export interface VolcengineClientConfig {
  appId: string;
  accessToken: string;
  resourceId: string;
}

export type AudioChunkCallback = (chunk: ArrayBuffer) => void;
```

**Step 2: Create src/asr/constants.ts**

Port from `open-typeless/src/renderer/src/modules/asr/constants.ts`:

```typescript
export const AUDIO_CONFIG = {
  sampleRate: 16000,
  channelCount: 1,
  bitsPerSample: 16,
  bufferSize: 4096,
} as const;

export const VOLCENGINE_CONSTANTS = {
  ENDPOINT: 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel',
  DEFAULT_RESOURCE_ID: 'volc.bigasr.sauc',
} as const;
```

**Step 3: Type check**

```bash
pnpm tsc --noEmit 2>&1 | head -20
```

Expected: 0 errors (or only errors from unrelated scaffold files).

**Step 4: Commit**

```bash
git add src/asr/types.ts src/asr/constants.ts
git commit -m "feat(asr): add shared types and constants"
```

---

### Task 6: Port pcm-converter.ts

**Files:**
- Create: `src/asr/pcm-converter.ts`

**Step 1: Create src/asr/pcm-converter.ts**

Direct port from `open-typeless/src/renderer/src/modules/asr/lib/pcm-converter.ts` — pure JS math, no Node.js dependencies:

```typescript
export function float32ToInt16(float32Array: Float32Array): Int16Array {
  const int16Array = new Int16Array(float32Array.length);
  for (let i = 0; i < float32Array.length; i++) {
    const sample = Math.max(-1, Math.min(1, float32Array[i]));
    int16Array[i] = sample < 0 ? sample * 0x8000 : sample * 0x7fff;
  }
  return int16Array;
}

export function int16ToArrayBuffer(int16Array: Int16Array): ArrayBuffer {
  const buffer = new ArrayBuffer(int16Array.byteLength);
  new Int16Array(buffer).set(int16Array);
  return buffer;
}

export function float32ToArrayBuffer(float32Array: Float32Array): ArrayBuffer {
  return int16ToArrayBuffer(float32ToInt16(float32Array));
}
```

**Step 2: Commit**

```bash
git add src/asr/pcm-converter.ts
git commit -m "feat(asr): add PCM converter (Float32 to Int16)"
```

---

### Task 7: Port audio-recorder.ts

**Files:**
- Create: `src/asr/audio-recorder.ts`

**Step 1: Create src/asr/audio-recorder.ts**

Port from `open-typeless/src/renderer/src/modules/asr/lib/audio-recorder.ts`. Remove `electron-log` (use `console`), remove the constants/types imports (inline or use local ones):

```typescript
import { AUDIO_CONFIG } from './constants';
import { float32ToArrayBuffer } from './pcm-converter';
import type { AudioChunkCallback } from './types';

interface AudioResources {
  stream: MediaStream;
  audioContext: AudioContext;
  sourceNode: MediaStreamAudioSourceNode;
  processorNode: ScriptProcessorNode;
}

export class AudioRecorder {
  private resources: AudioResources | null = null;
  private onAudioChunk: AudioChunkCallback;

  constructor(onAudioChunk: AudioChunkCallback) {
    this.onAudioChunk = onAudioChunk;
  }

  get isRecording(): boolean {
    return this.resources !== null;
  }

  async start(): Promise<void> {
    if (this.resources) return;

    const stream = await navigator.mediaDevices.getUserMedia({
      audio: {
        sampleRate: AUDIO_CONFIG.sampleRate,
        channelCount: AUDIO_CONFIG.channelCount,
        echoCancellation: true,
        noiseSuppression: true,
      },
    });

    const audioContext = new AudioContext({ sampleRate: AUDIO_CONFIG.sampleRate });
    const sourceNode = audioContext.createMediaStreamSource(stream);
    const processorNode = audioContext.createScriptProcessor(
      AUDIO_CONFIG.bufferSize,
      AUDIO_CONFIG.channelCount,
      AUDIO_CONFIG.channelCount
    );

    const onChunk = this.onAudioChunk;
    processorNode.onaudioprocess = (e: AudioProcessingEvent) => {
      onChunk(float32ToArrayBuffer(e.inputBuffer.getChannelData(0)));
    };

    sourceNode.connect(processorNode);
    processorNode.connect(audioContext.destination);

    this.resources = { stream, audioContext, sourceNode, processorNode };
    console.log('[AudioRecorder] started');
  }

  stop(): void {
    if (!this.resources) return;
    const { processorNode, sourceNode, stream, audioContext } = this.resources;
    processorNode.disconnect();
    sourceNode.disconnect();
    stream.getTracks().forEach((t) => t.stop());
    void audioContext.close();
    this.resources = null;
    console.log('[AudioRecorder] stopped');
  }
}
```

**Step 2: Type check**

```bash
pnpm tsc --noEmit 2>&1 | head -20
```

Expected: 0 errors.

**Step 3: Commit**

```bash
git add src/asr/audio-recorder.ts
git commit -m "feat(asr): add AudioRecorder (Web Audio API)"
```

---

### Task 8: Port volcengine-client.ts (browser-compatible)

**Files:**
- Create: `src/asr/volcengine-client.ts`

**Step 1: Install pako and eventemitter3**

```bash
pnpm add pako eventemitter3
pnpm add -D @types/pako
```

**Step 2: Create src/asr/volcengine-client.ts**

Port from `open-typeless/src/main/services/asr/lib/volcengine-client.ts` with these substitutions:

| Original (Node.js) | Browser replacement |
|---|---|
| `import WebSocket from 'ws'` | Remove — use native `WebSocket` |
| `import { EventEmitter } from 'events'` | `import EventEmitter from 'eventemitter3'` |
| `import * as zlib from 'zlib'` | `import pako from 'pako'` |
| `zlib.gzipSync(buf)` | `pako.gzip(buf)` → returns `Uint8Array` |
| `zlib.gunzipSync(buf)` | `pako.ungzip(buf)` → returns `Uint8Array` |
| `Buffer.alloc(n)` | `new Uint8Array(n)` |
| `Buffer.concat([...])` | `concatUint8Arrays([...])` (helper below) |
| `buf.writeInt32BE(v, 0)` | `new DataView(buf.buffer).setInt32(0, v)` |
| `buf.readInt32BE(offset)` | `new DataView(data.buffer).getInt32(offset)` |
| `Buffer.from(str, 'utf-8')` | `new TextEncoder().encode(str)` |
| `data.slice(a, b)` (Buffer) | `data.slice(a, b)` (Uint8Array — same API) |
| `import { randomUUID } from 'crypto'` | Remove — use `crypto.randomUUID()` |
| `import { HttpsProxyAgent }` | Remove entirely |
| `log.scope(...)` / electron-log | `console.log / console.error` |

Add this helper at the top of the file:

```typescript
function concatUint8Arrays(arrays: Uint8Array[]): Uint8Array {
  const total = arrays.reduce((sum, a) => sum + a.length, 0);
  const result = new Uint8Array(total);
  let offset = 0;
  for (const arr of arrays) {
    result.set(arr, offset);
    offset += arr.length;
  }
  return result;
}
```

Replace all `Buffer.concat([a, b, c])` calls with `concatUint8Arrays([a, b, c])`.

For int writing, replace:
```typescript
// Original
const buf = Buffer.alloc(4);
buf.writeInt32BE(value, 0);
```
With:
```typescript
const buf = new Uint8Array(4);
new DataView(buf.buffer).setInt32(0, value, false); // false = big-endian
```

For int reading:
```typescript
// Original
buf.readInt32BE(offset)
```
With:
```typescript
new DataView(data.buffer, data.byteOffset).getInt32(offset, false)
```

The `sendAudio(chunk: ArrayBuffer)` method receives ArrayBuffer from AudioRecorder — convert to Uint8Array:
```typescript
const audioBuffer = new Uint8Array(chunk);
```

Add config loader at the bottom of the file:

```typescript
export function loadConfig(): VolcengineClientConfig {
  const appId = import.meta.env.VITE_VOLCENGINE_APP_ID as string;
  const accessToken = import.meta.env.VITE_VOLCENGINE_ACCESS_TOKEN as string;
  const resourceId = (import.meta.env.VITE_VOLCENGINE_RESOURCE_ID as string) ?? VOLCENGINE_CONSTANTS.DEFAULT_RESOURCE_ID;
  if (!appId || !accessToken) {
    throw new Error('Missing VITE_VOLCENGINE_APP_ID or VITE_VOLCENGINE_ACCESS_TOKEN in .env');
  }
  return { appId, accessToken, resourceId };
}
```

**Step 3: Type check**

```bash
pnpm tsc --noEmit 2>&1 | head -30
```

Fix any remaining type errors (typically DataView buffer offsets or Uint8Array/ArrayBuffer mismatches).

**Step 4: Commit**

```bash
git add src/asr/volcengine-client.ts package.json pnpm-lock.yaml
git commit -m "feat(asr): add browser-compatible Volcengine WebSocket client"
```

---

### Task 9: usePushToTalk hook

**Files:**
- Create: `src/hooks/usePushToTalk.ts`

**Step 1: Create src/hooks/usePushToTalk.ts**

```typescript
import { useEffect, useRef, useState } from 'react';
import { listen } from '@tauri-apps/api/event';
import { invoke } from '@tauri-apps/api/core';
import { AudioRecorder } from '../asr/audio-recorder';
import { VolcengineClient, loadConfig } from '../asr/volcengine-client';
import type { ASRResult, ASRStatus } from '../asr/types';

export function usePushToTalk() {
  const [status, setStatus] = useState<ASRStatus>('idle');
  const [result, setResult] = useState<ASRResult | null>(null);
  const [error, setError] = useState<string | null>(null);

  const recorderRef = useRef<AudioRecorder | null>(null);
  const clientRef = useRef<VolcengineClient | null>(null);
  // Use a ref to capture latest transcript for the stop handler
  const resultRef = useRef<ASRResult | null>(null);

  useEffect(() => {
    const cleanup: Array<() => void> = [];

    listen<void>('ptt:start', async () => {
      setStatus('connecting');
      setResult(null);
      setError(null);
      resultRef.current = null;

      try {
        const config = loadConfig();
        const client = new VolcengineClient(config);
        clientRef.current = client;

        client.on('result', (r: ASRResult) => {
          setResult(r);
          resultRef.current = r;
        });

        client.on('error', (err: Error) => {
          setError(err.message);
          setStatus('error');
        });

        await client.connect();
        setStatus('listening');

        const recorder = new AudioRecorder((chunk) => {
          client.sendAudio(chunk);
        });
        recorderRef.current = recorder;
        await recorder.start();
      } catch (err) {
        setError(err instanceof Error ? err.message : String(err));
        setStatus('error');
      }
    }).then((unlisten) => cleanup.push(unlisten));

    listen<void>('ptt:stop', async () => {
      setStatus('processing');

      recorderRef.current?.stop();
      recorderRef.current = null;

      clientRef.current?.finishAudio();

      // Wait for isFinal result — handled via 'result' event
      // The client will emit a final result after finishAudio
      const client = clientRef.current;
      if (!client) return;

      // Poll for final result (max 10s)
      const finalResult = await new Promise<ASRResult | null>((resolve) => {
        const timeout = setTimeout(() => resolve(null), 10_000);

        client.on('result', (r: ASRResult) => {
          if (r.isFinal) {
            clearTimeout(timeout);
            resolve(r);
          }
        });

        client.on('status', (s: ASRStatus) => {
          if (s === 'done') {
            clearTimeout(timeout);
            resolve(resultRef.current);
          }
        });
      });

      clientRef.current = null;

      if (finalResult?.text) {
        try {
          await invoke('insert_text', { text: finalResult.text });
        } catch (err) {
          setError(err instanceof Error ? err.message : String(err));
        }
      }

      setStatus('done');
      setTimeout(() => {
        setStatus('idle');
        setResult(null);
      }, 800);
    }).then((unlisten) => cleanup.push(unlisten));

    return () => {
      cleanup.forEach((fn) => fn());
    };
  }, []);

  return { status, result, error };
}
```

**Step 2: Type check**

```bash
pnpm tsc --noEmit 2>&1 | head -20
```

Expected: 0 errors.

**Step 3: Commit**

```bash
git add src/hooks/usePushToTalk.ts
git commit -m "feat: add usePushToTalk hook coordinating Tauri events + ASR"
```

---

### Task 10: Port UI components

**Files:**
- Create: `src/components/StatusIndicator.tsx`
- Create: `src/components/TranscriptDisplay.tsx`
- Create: `src/components/ErrorDisplay.tsx`

**Step 1: Create StatusIndicator.tsx**

Direct port from `open-typeless/src/renderer/src/modules/asr/components/StatusIndicator.tsx`. Only change: update the import path for `ASRStatus`:

```typescript
import type { ASRStatus } from '../asr/types';
```

Rest is identical to the original.

**Step 2: Create TranscriptDisplay.tsx**

Port from `open-typeless/src/renderer/src/modules/asr/components/TranscriptDisplay.tsx`.

Remove the `window.api.floatingWindow.setContentHeight(scrollHeight)` call — in Tauri v2 our window has a CSS-constrained max-height, so dynamic resize is not needed for v0.1. Remove that `useEffect` entirely. Keep the rest identical.

**Step 3: Create ErrorDisplay.tsx**

Direct port from `open-typeless/src/renderer/src/modules/asr/components/ErrorDisplay.tsx`. No changes needed.

**Step 4: Commit**

```bash
git add src/components/
git commit -m "feat: port StatusIndicator, TranscriptDisplay, ErrorDisplay components"
```

---

### Task 11: FloatingWindow component + CSS

**Files:**
- Create: `src/components/FloatingWindow.tsx`
- Create: `src/components/floating-window.css`

**Step 1: Create FloatingWindow.tsx**

```typescript
import { useEffect } from 'react';
import { getCurrentWindow } from '@tauri-apps/api/window';
import { usePushToTalk } from '../hooks/usePushToTalk';
import { StatusIndicator } from './StatusIndicator';
import { TranscriptDisplay } from './TranscriptDisplay';
import { ErrorDisplay } from './ErrorDisplay';
import './floating-window.css';

export function FloatingWindow() {
  const { status, result, error } = usePushToTalk();

  useEffect(() => {
    const win = getCurrentWindow();
    if (status === 'idle') {
      void win.hide();
    } else {
      void win.show();
    }
  }, [status]);

  const hasTranscript =
    Boolean(result?.text) &&
    (status === 'listening' || status === 'processing' || status === 'done');

  return (
    <div className="floating-window">
      <div className="floating-window__content">
        <StatusIndicator status={status} />
        {hasTranscript && result && (
          <TranscriptDisplay text={result.text} interim={!result.isFinal} />
        )}
        {error && <ErrorDisplay message={error} />}
      </div>
    </div>
  );
}
```

**Step 2: Create floating-window.css**

Direct copy from `open-typeless/src/renderer/src/styles/components/floating-window.css`. No changes needed — it's pure CSS.

**Step 3: Commit**

```bash
git add src/components/FloatingWindow.tsx src/components/floating-window.css
git commit -m "feat: add FloatingWindow with frosted glass UI"
```

---

### Task 12: Wire App.tsx, main.tsx, and .env config

**Files:**
- Modify: `src/App.tsx`
- Modify: `src/main.tsx`
- Create: `.env`
- Create: `.env.example`
- Modify: `.gitignore`

**Step 1: Replace src/App.tsx**

```typescript
import { FloatingWindow } from './components/FloatingWindow';

export default function App() {
  return <FloatingWindow />;
}
```

**Step 2: Verify src/main.tsx**

Should just mount App — remove any default Vite/Tauri template boilerplate:

```typescript
import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App';

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
```

**Step 3: Create .env**

Copy credentials from open-typeless and rename keys to VITE_ prefix:

```bash
# Read the existing open-typeless .env
cat /Users/locke/workspace/open-typeless/.env
```

Then create `/Users/locke/workspace/typeless/.env`:

```
VITE_VOLCENGINE_APP_ID=<value from open-typeless>
VITE_VOLCENGINE_ACCESS_TOKEN=<value from open-typeless>
VITE_VOLCENGINE_RESOURCE_ID=volc.bigasr.sauc
```

**Step 4: Create .env.example**

```
VITE_VOLCENGINE_APP_ID=your_app_id
VITE_VOLCENGINE_ACCESS_TOKEN=your_access_token
VITE_VOLCENGINE_RESOURCE_ID=volc.bigasr.sauc
```

**Step 5: Update .gitignore to exclude .env**

Add `.env` to `.gitignore` if not already present.

**Step 6: Commit**

```bash
git add src/App.tsx src/main.tsx .env.example .gitignore
git commit -m "feat: wire App.tsx and add env config"
```

---

### Task 13: End-to-end manual test

**Step 1: Start dev build**

```bash
pnpm tauri dev
```

Expected: App starts with no visible window. No crash in terminal.

**Step 2: Grant macOS permissions**

Open System Settings → Privacy & Security and add the running app binary to:
1. **Microphone** — for audio recording
2. **Accessibility** — for rdev keyboard hook + enigo text insertion
3. **Input Monitoring** — may be required for rdev on macOS 15+

The dev binary is typically at: `src-tauri/target/debug/<app-name>` or the Tauri dev runner process.

**Step 3: Test keyboard events**

Before testing full flow, verify keyboard events fire:
- Open terminal, run `pnpm tauri dev`
- Check terminal output for `[keyboard]` logs when pressing Right Option

If no events:
- Confirm Accessibility + Input Monitoring permissions
- Try printing all keys in `keyboard.rs` to find correct `Key` variant:
  ```rust
  EventType::KeyPress(k) => { println!("Key pressed: {:?}", k); }
  ```
  Then look for what prints when pressing Right Option.

**Step 4: Test push-to-talk**

1. Open TextEdit or any text field
2. Click to place cursor in the text field
3. Hold Right Option → floating window should appear with "Listening..."
4. Speak a short sentence
5. Release Right Option → "Processing...", window hides, text appears at cursor

**Step 5: Troubleshoot common issues**

If text insertion fails:
- Confirm Accessibility permission for the dev binary
- Try `enigo.key(Key::Unicode('a'), Direction::Click)` in a test command first

If WebSocket connection fails:
- Check CSP in tauri.conf.json allows `wss://openspeech.bytedance.com`
- Check browser console (right-click floating window → Inspect if devtools enabled)

If window shows but steals focus:
- Add `win.setFocus(false)` after `win.show()` in FloatingWindow.tsx

**Step 6: Final commit**

```bash
git add -A
git commit -m "feat: typeless v0.1 — Tauri push-to-talk voice input complete"
```
