# Codex Review Round 2 Fixes

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix 5 bugs found in second Codex review pass, ordered high → low severity.

**Tech Stack:** Swift 6, CGEventTap, `@MainActor`, URLSession WebSocket.

---

### Task 1: [HIGH] CGEvent leak — passRetained → passUnretained

**Problem:** `KeyboardMonitor.handle()` and `handleFlagsChanged()` use `Unmanaged.passRetained(event)` when forwarding events. The tap callback's contract is to return events *unretained* — the system holds its own reference. `passRetained` bumps the retain count with no corresponding release, leaking every forwarded keyboard/mouse event. Since the tap sees all HID traffic, this leaks continuously while the app runs.

**Files:**
- Modify: `src-swift/Sources/MurmurCore/Keyboard/KeyboardMonitor.swift`

**Step 1: Fix all three passRetained sites**

Replace every `Unmanaged.passRetained(event)` with `Unmanaged.passUnretained(event)`:

- Line 115 (in `handle()` default return)
- Line 132 (in `handleFlagsChanged()` non-modifier hotkey path)
- Line 143 (in `handleFlagsChanged()` after updating lastFlags)

All three should become `Unmanaged.passUnretained(event)`.

**Step 2: Build and verify**

```bash
cd /Users/locke/workspace/murmur/src-swift && swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

**Step 3: Commit**

```bash
cd /Users/locke/workspace/murmur
git add src-swift/Sources/MurmurCore/Keyboard/KeyboardMonitor.swift
git commit -m "fix(keyboard): use passUnretained in event tap callback to stop CGEvent leak"
```

---

### Task 2: [HIGH] start→stop→start race: stale task can still call handleStart()

**Problem:** Scenario: press → release (sets `pttStopRequestedDuringStart=true`, nils `activeStartTask`) → press again (resets flag to false, `activeStartTask == nil` so guard passes, launches task 2). Task 1 is still running. When task 1 wakes, it sees `activeStartTask==nil` (task 2 already stored the new task there) and `pttStopRequestedDuringStart=false` (reset by press 2) → `shouldStop=false` → calls `handleStart()`. Task 2 also calls `handleStart()`. Two ghost sessions.

**Root cause:** The stop handler nils `activeStartTask` eagerly, so the second press sees it as clear and resets the flag before task 1 finishes.

**Fix:** Stop handler sets the flag but does NOT nil `activeStartTask` — let the task nil itself. The second press then sees `activeStartTask != nil` → guard exits early → no flag reset, no new task.

**Files:**
- Modify: `src-swift/Sources/App/AppDelegate.swift`

**Step 1: Change onPTTStart — move flag reset after the guard**

```swift
// BEFORE:
keyboard.onPTTStart = { [weak self] in
    Task { @MainActor [weak self] in
        guard let self else { return }
        self.pttStopRequestedDuringStart = false   // ← resets before guard
        guard self.activeStartTask == nil else { return }
        ...
    }
}

// AFTER:
keyboard.onPTTStart = { [weak self] in
    Task { @MainActor [weak self] in
        guard let self else { return }
        guard self.activeStartTask == nil else { return }  // check first
        self.pttStopRequestedDuringStart = false            // reset only if truly clear
        ...
    }
}
```

**Step 2: Change onPTTStop — don't nil activeStartTask, let the task nil itself**

```swift
// BEFORE:
keyboard.onPTTStop = { [weak self] in
    Task { @MainActor [weak self] in
        guard let self else { return }
        if self.activeStartTask != nil {
            self.pttStopRequestedDuringStart = true
            self.activeStartTask = nil   // ← eager nil causes the race
            return
        }
        self.audio.stop()
        self.ptt.handleStop()
    }
}

// AFTER:
keyboard.onPTTStop = { [weak self] in
    Task { @MainActor [weak self] in
        guard let self else { return }
        if self.activeStartTask != nil {
            self.pttStopRequestedDuringStart = true
            // Do NOT nil activeStartTask — let the task clear it when done,
            // so a subsequent press stays blocked until the task fully exits.
            return
        }
        self.audio.stop()
        self.ptt.handleStop()
    }
}
```

**Step 3: Build and verify**

```bash
cd /Users/locke/workspace/murmur/src-swift && swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

**Step 4: Commit**

```bash
cd /Users/locke/workspace/murmur
git add src-swift/Sources/App/AppDelegate.swift
git commit -m "fix(ptt): keep activeStartTask set until task exits to prevent flag reset race"
```

---

### Task 3: [HIGH] PushToTalk error paths not generation-scoped

**Problem:** `onError` callback and `connect()` catch in `handleStart()` unconditionally set `.error`, clear `client`, and flip `isSessionActive = false` without checking `sessionGeneration`. If session 1's socket fails late (after session 2 has started), it tears down session 2.

**Files:**
- Modify: `src-swift/Sources/MurmurCore/PTT/PushToTalk.swift`

**Step 1: Capture myGeneration at top of handleStart()**

In `handleStart()`, immediately after `sessionGeneration += 1`, add:

```swift
let myGeneration = sessionGeneration
```

**Step 2: Guard the onError callback**

In the Task body of `handleStart()`, update `client.onError`:

```swift
// BEFORE:
client.onError = { [weak self] _ in
    Task { @MainActor [weak self] in
        self?.setStatus(.error)
        self?.client = nil
        self?.isSessionActive = false
        self?.scheduleIdleReset(after: 1.5)
    }
}

// AFTER:
client.onError = { [weak self] _ in
    Task { @MainActor [weak self] in
        guard let self, self.sessionGeneration == myGeneration else { return }
        self.setStatus(.error)
        self.client = nil
        self.isSessionActive = false
        self.scheduleIdleReset(after: 1.5)
    }
}
```

**Step 3: Guard the connect() catch block**

```swift
// BEFORE:
} catch {
    self.setStatus(.error)
    self.client = nil
    self.isSessionActive = false
    self.scheduleIdleReset(after: 1.5)
}

// AFTER:
} catch {
    guard self.sessionGeneration == myGeneration else { return }
    self.setStatus(.error)
    self.client = nil
    self.isSessionActive = false
    self.scheduleIdleReset(after: 1.5)
}
```

**Step 4: Build and run tests**

```bash
cd /Users/locke/workspace/murmur/src-swift && swift build 2>&1 | grep -E "error:|Build complete"
swift run MurmurTests 2>&1
```

Expected: `Build complete!`, all tests pass.

**Step 5: Commit**

```bash
cd /Users/locke/workspace/murmur
git add src-swift/Sources/MurmurCore/PTT/PushToTalk.swift
git commit -m "fix(ptt): guard onError and connect() catch with sessionGeneration to prevent stale session teardown"
```

---

### Task 4: [MEDIUM] VolcengineClient: connect() reports .listening after receive loop failure

**Problem:** `startReceiveLoop(task)` is called before the async init-packet exchange completes. If the socket dies immediately, the failure handler sets `connectionState = "disconnected"`. Then `connect()` resumes from the init-packet send and overwrites state to `"connected"`, emitting `.listening`. The UI looks healthy but no audio is actually being processed.

**Files:**
- Modify: `src-swift/Sources/MurmurCore/ASR/VolcengineClient.swift`

**Step 1: Check connectionState before setting "connected"**

In `connect()`, find the block that sets `connectionState = "connected"`:

```swift
// BEFORE:
let hasPendingFinish = lock.withLock { () -> Bool in
    connectionState = "connected"
    let p = pendingFinish
    if p { pendingFinish = false }
    return p
}

if hasPendingFinish {
    sendFinishPacket()
} else {
    let cb = lock.withLock { onStatus }
    cb?(.listening)
}
```

Replace with a guard that throws if the receive loop already failed:

```swift
// AFTER:
let (connected, hasPendingFinish) = lock.withLock { () -> (Bool, Bool) in
    guard connectionState == "connecting" else {
        return (false, false)  // receive loop already failed
    }
    connectionState = "connected"
    let p = pendingFinish
    if p { pendingFinish = false }
    return (true, p)
}

guard connected else {
    throw URLError(.networkConnectionLost)
}

if hasPendingFinish {
    sendFinishPacket()
} else {
    let cb = lock.withLock { onStatus }
    cb?(.listening)
}
```

This makes `connect()` throw if the receive loop already failed, which `PushToTalk.handleStart()` will catch via the existing catch block (which is now generation-guarded from Task 3).

**Step 2: Build and run tests**

```bash
cd /Users/locke/workspace/murmur/src-swift && swift build 2>&1 | grep -E "error:|Build complete"
cd /Users/locke/workspace/murmur/src-swift && swift run MurmurTests 2>&1
```

**Step 3: Commit**

```bash
cd /Users/locke/workspace/murmur
git add src-swift/Sources/MurmurCore/ASR/VolcengineClient.swift
git commit -m "fix(asr): throw from connect() if receive loop already failed, preventing false .listening"
```

---

### Task 5: [MEDIUM] Audio start failure still opens PTT session

**Problem:** In `onPTTStart`'s detached task, `audio.start()` failure is only logged. The task continues and calls `ptt.handleStart()`, opening an ASR session with no audio source. The UI enters recording mode but no chunks can ever arrive.

**Files:**
- Modify: `src-swift/Sources/App/AppDelegate.swift`

**Step 1: Return early from detached task on audio.start() failure**

Find the detached task in `onPTTStart`:

```swift
// BEFORE:
let task = Task.detached(priority: .userInitiated) {
    do {
        try audio.start(deviceUID: deviceUID)
    } catch {
        fputs("[murmur] audio.start failed: \(error)\n", stderr)
    }
    // Hop back to main actor to check if PTT was released during startup
    let shouldStop = await MainActor.run { ...
```

Change to bail on failure (also nil `activeStartTask` so the UI is consistent):

```swift
// AFTER:
let task = Task.detached(priority: .userInitiated) {
    do {
        try audio.start(deviceUID: deviceUID)
    } catch {
        fputs("[murmur] audio.start failed: \(error)\n", stderr)
        await MainActor.run { [weak self] in self?.activeStartTask = nil }
        return  // no audio — don't open a PTT session
    }
    // Hop back to main actor to check if PTT was released during startup
    let shouldStop = await MainActor.run { ...
```

**Step 2: Build and verify**

```bash
cd /Users/locke/workspace/murmur/src-swift && swift build 2>&1 | grep -E "error:|Build complete"
```

**Step 3: Commit**

```bash
cd /Users/locke/workspace/murmur
git add src-swift/Sources/App/AppDelegate.swift
git commit -m "fix(ptt): bail from detached task if audio.start() fails, don't open empty session"
```
