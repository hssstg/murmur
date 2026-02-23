# Voice Input Interaction Design

Date: 2026-02-23

## Goal

Replace the static red dot with a real-time audio waveform during recording. After releasing the PTT key, show a brief processing state, then insert text directly with no preview.

## Interaction Flow

| State | Window Behavior |
|---|---|
| idle | Hidden |
| connecting | Appears; status bar "Listening…"; waveform area static (empty bars) |
| listening | Status bar + real-time scrolling waveform |
| processing | Waveform fades out (200ms opacity 1→0, height collapses to 58px); status bar "Processing…" |
| done | Window hides immediately after text insertion; no transcript preview |
| error | Status bar "Error" + red error message (existing behavior) |

## Waveform Visual Spec

- **Bars**: 16 vertical bars, evenly spaced across content width
- **Bar style**: rounded top (`border-radius: 2px`), `rgba(255,255,255,0.75)`
- **Height range**: min 3px, max 32px
- **Scroll direction**: new data appends on the right, old data shifts left
- **Data source**: each `audio:chunk` event (100ms / 1600 samples) → RMS → circular buffer of 16 values
- **Window height**: ~96px during listening (status bar 40px + waveform area 56px); collapses to 58px during processing/done

## Component Architecture

### New: `WaveformVisualizer.tsx`

Props: `levels: number[]` (0–1 normalized), `visible: boolean`

Renders 16 bars. When `visible` becomes false, applies a CSS fade-out transition, then the parent collapses the height.

### Modified: `usePushToTalk.ts`

Expose `audioLevels: number[]` — a rolling buffer of 16 RMS values computed from incoming `audio:chunk` events. Reset to zeros on session start.

RMS formula per chunk:
```
rms = sqrt(mean(samples^2)) / 32768
normalized = clamp(rms * 4, 0, 1)   // amplify for visual
```

### Modified: `FloatingWindow.tsx`

- Show `WaveformVisualizer` when `status === 'listening' || status === 'connecting'`
- Pass `visible={status === 'listening'}` for the fade-out when releasing
- Remove `TranscriptDisplay` from the primary recording flow (no live preview)

### Modified: `floating-window.css`

- Add `.waveform` container: `height: 56px`, `display: flex`, `align-items: flex-end`, `gap: 3px`
- Add `.waveform__bar`: `flex: 1`, `border-radius: 2px 2px 0 0`, `background: rgba(255,255,255,0.75)`, `transition: height 80ms ease`
- Add fade transition: `.waveform--hidden { opacity: 0; transition: opacity 200ms ease }`
- Window height: `min-height: 58px` (idle/processing), auto-expands when waveform is present
