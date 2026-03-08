# Android Murmur — Design Doc

**Date:** 2026-03-08
**Goal:** Android 版 Murmur，以输入法（IME）形式实现 PTT 语音录入，识别完直接填入当前输入框。

---

## 范围

v1 只做核心功能：**按住录音 → Volcengine BigASR → 插入文字**。

不做：LLM 润色、历史记录、热词管理、Settings UI（凭证硬编码）。

---

## 架构

```
InputMethodService (MurmurIME)
  ├── MicKeyboardView     ← 键盘 View，只有一个麦克风按钮
  ├── AudioStreamer        ← AudioRecord 封装，推 16kHz PCM
  └── VolcengineClient    ← OkHttp WebSocket，协议移植自 Swift 版
```

**状态机：** `idle → recording → processing → idle`

**生命周期：** 录音绑定 IME 生命周期，不需要后台 Service。

---

## 键盘 UI

- 全屏深色背景，中央单个圆形麦克风按钮
- 键盘高度固定 ~200dp
- 三个视觉状态：
  - **idle**：灰色麦克风，提示文字「按住说话」
  - **recording**：红色按钮 + 波形动画，同时流式推送 PCM
  - **processing**：按钮禁用 + 旋转动画，等待 ASR 最终结果

---

## PTT 交互流程

1. `onTouchEvent(DOWN)` → 申请 `RECORD_AUDIO` 权限（首次）→ 打开 WebSocket → 开始 `AudioRecord`
2. 每帧 PCM（16kHz, 16bit, mono）→ `VolcengineClient.sendAudio()`
3. `onTouchEvent(UP)` → `AudioRecord` 停止 → 发 finish packet
4. 等待 WebSocket 返回 `is_final=true` 的结果
5. `InputConnection.commitText(text, 1)` 填入输入框
6. 关闭 WebSocket，状态回 idle

---

## VolcengineClient 协议

移植自 `src-swift/Sources/MurmurCore/ASR/VolcengineClient.swift`：

- **Endpoint：** `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel`
- **握手：** 发 full client request（App ID、Token、语言 zh-CN、采样率 16000）
- **流式：** binary WebSocket message，raw PCM bytes
- **结束：** finish packet（协议同 Swift 版）
- **接收：** 解析 JSON，取 `result.utterances[].text` 拼接
- **错误：** 关闭连接，状态回 idle，不显示任何错误 UI（v1）

Kotlin 实现：`OkHttp WebSocket` + `kotlinx.coroutines`，用 `Channel<AsrEvent>` 向 IME 传递事件。

---

## 项目结构

```
src-android/
├── app/
│   ├── src/main/
│   │   ├── java/com/locke/murmur/
│   │   │   ├── MurmurIME.kt
│   │   │   ├── MicKeyboardView.kt
│   │   │   ├── AudioStreamer.kt
│   │   │   └── VolcengineClient.kt
│   │   ├── res/xml/method.xml
│   │   └── AndroidManifest.xml
│   └── build.gradle.kts
├── build.gradle.kts
└── settings.gradle.kts
```

**依赖：**
```kotlin
implementation("com.squareup.okhttp3:okhttp:4.12.0")
implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.0")
```

**权限：**
```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
```

---

## 凭证

v1 硬编码在 `VolcengineClient.kt`：
- `APP_ID = "7232385834"`
- `ACCESS_TOKEN = "5lSRCDzbb2KgBjEtKJbT9NIsU-z2z-F_"`
- `RESOURCE_ID = "volc.bigasr.sauc.duration"`
