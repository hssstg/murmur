# Codex Review Fixes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix 6 bugs found by Codex review, ordered high → low severity.

**Architecture:** All bugs are in the Swift-native path (`src-swift/`). Changes touch 4 files: `PushToTalk.swift`, `AppDelegate.swift`, `VolcengineClient.swift`, `VolcengineProtocol.swift`. No new files needed.

**Tech Stack:** Swift 6, `@MainActor`, `Task.detached`, AVAudio, URLSession WebSocket.

---

### Task 1: [HIGH] Stale session generation counter

**Problem:** `handleStop()` calls `TextInserter.insert()` at line 112 *before* the guard at line 115. If a new session starts while ASR/LLM is in progress, the old session's text gets injected into the frontmost app.

**Files:**
- Modify: `src-swift/Sources/MurmurCore/PTT/PushToTalk.swift`

**Step 1: Add generation counter property**

After `private var peakRms: Float = 0` (line 18), add:

```swift
private var sessionGeneration: Int = 0
```

**Step 2: Increment counter in `handleStart()`**

In `handleStart()`, immediately after `guard !isSessionActive else { return }` (line 31), add:

```swift
sessionGeneration += 1
```

**Step 3: Capture generation and guard before insert in `handleStop()`**

In `handleStop()`, immediately after `guard isSessionActive else { return }` (line 85), add:

```swift
let myGeneration = sessionGeneration
```

Then inside the Task body in `handleStop()`, replace the block:

```swift
// BEFORE:
if !textToInsert.isEmpty {
    if cfg.llm_enabled && !cfg.llm_base_url.isEmpty {
        self.setStatus(.polishing)
        textToInsert = await LLMClient.polish(text: textToInsert, config: cfg)
    }
    await TextInserter.insert(textToInsert)
}

guard !self.isSessionActive else { return }
```

with:

```swift
if !textToInsert.isEmpty {
    if cfg.llm_enabled && !cfg.llm_base_url.isEmpty {
        guard self.sessionGeneration == myGeneration else { return }
        self.setStatus(.polishing)
        textToInsert = await LLMClient.polish(text: textToInsert, config: cfg)
    }
    guard self.sessionGeneration == myGeneration else { return }
    await TextInserter.insert(textToInsert)
}

guard self.sessionGeneration == myGeneration else { return }
```

**Step 4: Build and verify**

```bash
cd /Users/locke/workspace/murmur/src-swift && swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

**Step 5: Add test**

In `src-swift/Tests/MurmurTests/PushToTalkTests.swift`, add after existing test:

```swift
// Fast double-press: second handleStart() should increment generation,
// so any pending handleStop() from generation 1 will bail before inserting.
let ptt2 = PushToTalk(config: AppConfig())
ptt2.handleStart()
ptt2.handleStop()
ptt2.handleStart()  // second session begins; generation is now 2
// Can't easily test async insert bail-out in sync test, but verify state is clean:
check(ptt2.isSessionActive, "second session is active after rapid double-press")
```

**Step 6: Run tests**

```bash
cd /Users/locke/workspace/murmur/src-swift && swift run MurmurTests 2>&1
```

Expected: all `[PASS]` lines, no `[FAIL]`.

**Step 7: Commit**

```bash
cd /Users/locke/workspace/murmur
git add src-swift/Sources/MurmurCore/PTT/PushToTalk.swift src-swift/Tests/MurmurTests/PushToTalkTests.swift
git commit -m "fix(ptt): add session generation counter to prevent stale text injection"
```

---

### Task 2: [HIGH] Start/stop sequencing race

**Problem:** `audio.start()` runs in `Task.detached`; on a quick press-release, `audio.stop()` + `ptt.handleStop()` fire first (no-ops since session hasn't started), then `ptt.handleStart()` completes and creates a ghost session that never gets stopped.

**Files:**
- Modify: `src-swift/Sources/App/AppDelegate.swift`

**Step 1: Add tracking properties**

In `AppDelegate`, after `private let hotwordStore = HotwordStore()` (line 40), add:

```swift
private var activeStartTask: Task<Void, Never>?
private var pttStopRequestedDuringStart = false
```

**Step 2: Rewrite `onPTTStart` handler**

Replace the entire `keyboard.onPTTStart = { ... }` block (lines 101-120) with:

```swift
keyboard.onPTTStart = { [weak self] in
    Task { @MainActor [weak self] in
        guard let self else { return }
        self.pttStopRequestedDuringStart = false
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
```

**Step 3: Rewrite `onPTTStop` handler**

Replace the `keyboard.onPTTStop = { ... }` block (lines 121-127) with:

```swift
keyboard.onPTTStop = { [weak self] in
    Task { @MainActor [weak self] in
        guard let self else { return }
        if self.activeStartTask != nil {
            // Start is still in flight — flag it to abort when it lands
            self.pttStopRequestedDuringStart = true
            self.activeStartTask = nil
        }
        self.audio.stop()
        self.ptt.handleStop()
    }
}
```

**Step 4: Build and verify**

```bash
cd /Users/locke/workspace/murmur/src-swift && swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

**Step 5: Commit**

```bash
cd /Users/locke/workspace/murmur
git add src-swift/Sources/App/AppDelegate.swift
git commit -m "fix(ptt): prevent ghost session on quick press-release by coordinating start/stop tasks"
```

---

### Task 3: [MEDIUM-HIGH] Buffer audio chunks before client is ready

**Problem:** `AVAudioEngine` starts firing chunks immediately, but `PushToTalk.client` isn't assigned until the `Task { @MainActor }` in `handleStart()` runs. Chunks arriving during that gap are silently dropped.

**Files:**
- Modify: `src-swift/Sources/MurmurCore/PTT/PushToTalk.swift`

**Step 1: Add pending chunks buffer**

After `private var sessionGeneration: Int = 0`, add:

```swift
private var pendingChunks: [Data] = []
```

**Step 2: Buffer chunks when client is nil**

Replace `handleAudioChunk(_:)` (lines 126-141) — change only the first line of the method body:

```swift
// BEFORE:
public func handleAudioChunk(_ data: Data) {
    client?.sendAudio(data)
```

```swift
// AFTER:
public func handleAudioChunk(_ data: Data) {
    if let client = client {
        client.sendAudio(data)
    } else if isSessionActive {
        pendingChunks.append(data)
    }
```

**Step 3: Flush buffer after client is assigned in `handleStart()`**

In `handleStart()`, inside the Task body, immediately after `self.client = client` (line 71), add:

```swift
// Flush any audio chunks that arrived before the client was ready
let buffered = pendingChunks
pendingChunks = []
for chunk in buffered { client.sendAudio(chunk) }
```

**Step 4: Clear buffer in `handleStop()`**

In `handleStop()`, after `isSessionActive = false` (line 90), add:

```swift
pendingChunks = []
```

**Step 5: Build and verify**

```bash
cd /Users/locke/workspace/murmur/src-swift && swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

**Step 6: Commit**

```bash
cd /Users/locke/workspace/murmur
git add src-swift/Sources/MurmurCore/PTT/PushToTalk.swift
git commit -m "fix(ptt): buffer audio chunks arriving before VolcengineClient is ready"
```

---

### Task 4: [MEDIUM] WebSocket receive errors propagate as error, not idle

**Problem:** `startReceiveLoop` failure case calls `onStatus(.idle)` instead of `onError` + `.error`. Broken sockets silently become idle rather than showing an error state.

**Files:**
- Modify: `src-swift/Sources/MurmurCore/ASR/VolcengineClient.swift`

**Step 1: Fix the failure case in `startReceiveLoop`**

Replace the `case .failure:` block (lines 188-194):

```swift
// BEFORE:
case .failure:
    let state = self.lock.withLock { self.connectionState }
    if state != "disconnected" {
        self.lock.withLock { self.connectionState = "disconnected" }
        let cb = self.lock.withLock { self.onStatus }
        cb?(.idle)
    }
```

```swift
// AFTER:
case .failure(let error):
    let state = self.lock.withLock { self.connectionState }
    if state != "disconnected" {
        self.lock.withLock { self.connectionState = "disconnected" }
        let (onErrorCb, onStatusCb) = self.lock.withLock { (self.onError, self.onStatus) }
        onErrorCb?(error)
        onStatusCb?(.error)
    }
```

**Step 2: Build and verify**

```bash
cd /Users/locke/workspace/murmur/src-swift && swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

**Step 3: Commit**

```bash
cd /Users/locke/workspace/murmur
git add src-swift/Sources/MurmurCore/ASR/VolcengineClient.swift
git commit -m "fix(asr): propagate WebSocket receive failures as error instead of silent idle"
```

---

### Task 5: [MEDIUM] Unaligned memory read in protocol parser

**Problem:** `ptr.load(fromByteOffset:as:)` requires alignment that `Data` doesn't guarantee. Can trap or return wrong values on arm64.

**Files:**
- Modify: `src-swift/Sources/MurmurCore/ASR/VolcengineProtocol.swift`

**Step 1: Replace `dataToInt32` with safe copy-based implementation**

Replace `dataToInt32` (lines 46-50):

```swift
// BEFORE:
public static func dataToInt32(_ data: Data, offset: Int = 0) -> Int32 {
    return data.withUnsafeBytes { ptr in
        ptr.load(fromByteOffset: offset, as: Int32.self).bigEndian
    }
}
```

```swift
// AFTER:
public static func dataToInt32(_ data: Data, offset: Int = 0) -> Int32 {
    var v: Int32 = 0
    withUnsafeMutableBytes(of: &v) { dest in
        _ = data.copyBytes(to: dest, from: offset..<(offset + 4))
    }
    return Int32(bigEndian: v)
}
```

**Step 2: Build and verify**

```bash
cd /Users/locke/workspace/murmur/src-swift && swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

**Step 3: Verify existing protocol tests still pass**

```bash
cd /Users/locke/workspace/murmur/src-swift && swift run MurmurTests 2>&1
```

Expected: all `[PASS]`.

**Step 4: Commit**

```bash
cd /Users/locke/workspace/murmur
git add src-swift/Sources/MurmurCore/ASR/VolcengineProtocol.swift
git commit -m "fix(protocol): use copyBytes for unaligned Int32 read in protocol parser"
```

---

### Task 6: [LOW-MEDIUM] Surface settings save failures in UI

**Problem:** `try? self.configStore.save()` in AppDelegate silently discards errors; UI shows no feedback when save fails.

**Files:**
- Modify: `src-swift/Sources/App/AppDelegate.swift`

**Step 1: Replace silent `try?` with error-surfacing `do-catch`**

In `openSettings()`, replace the `onSave` closure body (lines 254-262):

```swift
// BEFORE:
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
```

```swift
// AFTER:
onSave: { [weak self] in
    guard let self = self else { return }
    do {
        try self.configStore.save()
    } catch {
        let alert = NSAlert()
        alert.messageText = "无法保存设置"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
        return
    }
    Task { @MainActor [weak self] in
        guard let self = self else { return }
        self.ptt.updateConfig(self.configStore.config)
        self.keyboard.stop()
        self.setupKeyboard()
    }
},
```

**Step 2: Build and verify**

```bash
cd /Users/locke/workspace/murmur/src-swift && swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

**Step 3: Commit**

```bash
cd /Users/locke/workspace/murmur
git add src-swift/Sources/App/AppDelegate.swift
git commit -m "fix(settings): show alert on config save failure instead of silently discarding error"
```
