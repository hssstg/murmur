# Voice Input Waveform Interaction Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the static red dot with a real-time audio waveform during recording; hide the window immediately after text is inserted with no transcript preview.

**Architecture:** `usePushToTalk` computes RMS from each `audio:chunk` event and exposes a rolling 16-value `audioLevels` buffer. A new `WaveformVisualizer` component renders these as animated bars. `FloatingWindow` shows the waveform during connecting/listening/processing states and fades it out on processing.

**Tech Stack:** React 19, TypeScript, CSS transitions, Tauri event system (`audio:chunk`)

---

### Task 1: Expose `audioLevels` from `usePushToTalk`

**Files:**
- Modify: `src/hooks/usePushToTalk.ts`

**Step 1: Add state and ref for audio levels**

In `usePushToTalk`, add after the existing refs:

```typescript
const LEVEL_COUNT = 16;
const [audioLevels, setAudioLevels] = useState<number[]>(new Array(LEVEL_COUNT).fill(0));
const levelsBufferRef = useRef<number[]>(new Array(LEVEL_COUNT).fill(0));
```

**Step 2: Compute RMS in the `audio:chunk` listener**

Replace the existing `audio:chunk` listener body:

```typescript
listen<number[]>('audio:chunk', (event) => {
  const client = clientRef.current;
  if (client?.isConnected) {
    const buf = new Int16Array(event.payload).buffer;
    client.sendAudio(buf);
  }
  // Compute RMS for waveform visualization
  if (isSessionActive.current) {
    const samples = event.payload;
    const rms = samples.length > 0
      ? Math.sqrt(samples.reduce((s, x) => s + x * x, 0) / samples.length) / 32768
      : 0;
    const level = Math.min(1, rms * 4); // amplify for visual
    const next = [...levelsBufferRef.current.slice(1), level];
    levelsBufferRef.current = next;
    setAudioLevels([...next]);
  }
}).then((unlisten) => cleanup.push(unlisten));
```

**Step 3: Reset levels on session start**

In the `ptt:start` listener, before `setStatus('connecting')`, add:

```typescript
levelsBufferRef.current = new Array(LEVEL_COUNT).fill(0);
setAudioLevels(new Array(LEVEL_COUNT).fill(0));
```

**Step 4: Return `audioLevels` from the hook**

```typescript
return { status, result, error, audioLevels };
```

**Step 5: Verify build**

```bash
/tmp/build-murmur.sh
```

Expected: frontend builds with no TypeScript errors.

**Step 6: Commit**

```bash
cd /Users/locke/workspace/murmur
git add src/hooks/usePushToTalk.ts
git commit -m "feat: expose audioLevels from usePushToTalk"
```

---

### Task 2: Create `WaveformVisualizer` component

**Files:**
- Create: `src/components/WaveformVisualizer.tsx`

**Step 1: Write the component**

```tsx
interface WaveformVisualizerProps {
  levels: number[];   // 16 values, each 0–1
  fading: boolean;    // true during processing state → triggers CSS fade-out
}

export function WaveformVisualizer({ levels, fading }: WaveformVisualizerProps) {
  return (
    <div className={`waveform${fading ? ' waveform--fading' : ''}`}>
      {levels.map((level, i) => (
        <div
          key={i}
          className="waveform__bar"
          style={{ height: `${Math.max(3, level * 40)}px` }}
        />
      ))}
    </div>
  );
}
```

**Step 2: Verify build**

```bash
/tmp/build-murmur.sh
```

Expected: builds cleanly.

**Step 3: Commit**

```bash
git add src/components/WaveformVisualizer.tsx
git commit -m "feat: add WaveformVisualizer component"
```

---

### Task 3: Add waveform CSS to `floating-window.css`

**Files:**
- Modify: `src/components/floating-window.css`

**Step 1: Remove max-height constraint**

Remove the line:
```css
max-height: 112px;
```

(Transcript is no longer shown during recording, so the 4-line cap is obsolete.)

**Step 2: Add waveform styles**

Append to the end of `floating-window.css`:

```css
/* ============================================
 * Waveform Visualizer
 * ============================================ */

.waveform {
  display: flex;
  align-items: flex-end;
  gap: 3px;
  height: 40px;
  padding: 0 2px 4px;
  opacity: 1;
  transition: opacity 200ms ease;
  flex-shrink: 0;
}

.waveform--fading {
  opacity: 0;
}

.waveform__bar {
  flex: 1;
  background: rgba(255, 255, 255, 0.7);
  border-radius: 2px 2px 0 0;
  transition: height 80ms ease;
}
```

**Step 3: Verify build**

```bash
/tmp/build-murmur.sh
```

**Step 4: Commit**

```bash
git add src/components/floating-window.css
git commit -m "feat: add waveform styles to floating-window"
```

---

### Task 4: Wire waveform into `FloatingWindow`

**Files:**
- Modify: `src/components/FloatingWindow.tsx`

**Step 1: Replace the component body**

```tsx
import { useEffect } from 'react';
import { getCurrentWindow } from '@tauri-apps/api/window';
import { usePushToTalk } from '../hooks/usePushToTalk';
import { StatusIndicator } from './StatusIndicator';
import { WaveformVisualizer } from './WaveformVisualizer';
import { ErrorDisplay } from './ErrorDisplay';
import './floating-window.css';

export function FloatingWindow() {
  const { status, error, audioLevels } = usePushToTalk();

  useEffect(() => {
    const win = getCurrentWindow();
    if (status === 'idle') {
      void win.hide();
    } else {
      void win.show();
    }
  }, [status]);

  const showWaveform =
    status === 'connecting' || status === 'listening' || status === 'processing';
  const waveformFading = status === 'processing';

  return (
    <div className="floating-window">
      <div className="floating-window__content">
        <StatusIndicator status={status} />
        {showWaveform && (
          <WaveformVisualizer levels={audioLevels} fading={waveformFading} />
        )}
        {error && <ErrorDisplay message={error} />}
      </div>
    </div>
  );
}
```

Note: `TranscriptDisplay` is intentionally removed — text is inserted directly with no preview.

**Step 2: Build**

```bash
/tmp/build-murmur.sh
```

Expected: clean build, no TypeScript errors.

**Step 3: Commit**

```bash
git add src/components/FloatingWindow.tsx
git commit -m "feat: wire waveform into FloatingWindow, remove transcript preview"
```

---

### Task 5: Manual verification

**Step 1: Restart the app via Terminal**

```bash
pkill -x murmur 2>/dev/null
osascript -e 'tell application "Terminal" to do script "/Users/locke/workspace/murmur/src-tauri/target/debug/murmur"'
```

**Step 2: Test the interaction**

1. Hold the configured PTT key → window appears, waveform area visible (flat bars at minimum height)
2. Speak → bars animate in real-time with voice volume
3. Release key → waveform fades out (200ms), status shows "Processing…"
4. Text inserted → window disappears immediately

**Step 3: Verify error state**

Disconnect network, try PTT → window shows error message, no waveform.
