# Android Murmur IME — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build an Android input method (IME) that lets users hold a mic button, stream audio to Volcengine BigASR, and insert the transcription into the focused input field.

**Architecture:** `InputMethodService` hosts a single `MicKeyboardView` (big mic button, deep-dark background). `AudioStreamer` captures 16kHz PCM via `AudioRecord`. `VolcengineClient` manages an OkHttp WebSocket using the same binary protocol as the macOS Swift version. All async work runs in Kotlin coroutines scoped to the IME lifecycle.

**Tech Stack:** Kotlin, Android SDK 26+, OkHttp 4.12, kotlinx-coroutines-android 1.8, `java.util.zip.GZIPOutputStream` (built-in, for gzip compression).

---

### Task 1: Project scaffold

**Files:**
- Create: `src-android/settings.gradle.kts`
- Create: `src-android/build.gradle.kts`
- Create: `src-android/app/build.gradle.kts`
- Create: `src-android/app/src/main/AndroidManifest.xml`
- Create: `src-android/app/src/main/res/xml/method.xml`

**Step 1: Create `src-android/settings.gradle.kts`**

```kotlin
rootProject.name = "murmur-android"
include(":app")
```

**Step 2: Create `src-android/build.gradle.kts`**

```kotlin
plugins {
    id("com.android.application") version "8.3.2" apply false
    id("org.jetbrains.kotlin.android") version "1.9.23" apply false
}
```

**Step 3: Create `src-android/app/build.gradle.kts`**

```kotlin
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.locke.murmur"
    compileSdk = 34
    defaultConfig {
        applicationId = "com.locke.murmur"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.0")
}
```

**Step 4: Create `src-android/app/src/main/AndroidManifest.xml`**

```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.RECORD_AUDIO" />

    <application
        android:label="Murmur"
        android:icon="@mipmap/ic_launcher">

        <!-- Transparent activity used to request RECORD_AUDIO at runtime -->
        <activity
            android:name=".PermissionActivity"
            android:theme="@android:style/Theme.Translucent.NoTitleBar"
            android:exported="false" />

        <service
            android:name=".MurmurIME"
            android:label="Murmur Voice"
            android:permission="android.permission.BIND_INPUT_METHOD"
            android:exported="true">
            <intent-filter>
                <action android:name="android.view.InputMethod" />
            </intent-filter>
            <meta-data
                android:name="android.view.im"
                android:resource="@xml/method" />
        </service>
    </application>
</manifest>
```

**Step 5: Create `src-android/app/src/main/res/xml/method.xml`**

```xml
<?xml version="1.0" encoding="utf-8"?>
<input-method xmlns:android="http://schemas.android.com/apk/res/android">
    <subtype
        android:label="Murmur Voice"
        android:imeSubtypeLocale="zh_CN"
        android:imeSubtypeMode="voice" />
</input-method>
```

**Step 6: Add placeholder launcher icon so it builds**

Create a 48×48 placeholder PNG at:
- `src-android/app/src/main/res/mipmap-mdpi/ic_launcher.png`

Any solid-color 48×48 PNG works (can generate with any image tool or copy from another project).

**Step 7: Create placeholder `MurmurIME.kt` so manifest resolves**

Create `src-android/app/src/main/java/com/locke/murmur/MurmurIME.kt`:

```kotlin
package com.locke.murmur

import android.inputmethodservice.InputMethodService
import android.view.View

class MurmurIME : InputMethodService() {
    override fun onCreateInputView(): View = View(this)
}
```

Also create `src-android/app/src/main/java/com/locke/murmur/PermissionActivity.kt`:

```kotlin
package com.locke.murmur

import android.app.Activity
import android.os.Bundle

class PermissionActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        finish()
    }
}
```

**Step 8: Build and verify**

```bash
cd /Users/locke/workspace/murmur/src-android
./gradlew assembleDebug 2>&1 | tail -5
```

Expected: `BUILD SUCCESSFUL`

**Step 9: Commit**

```bash
cd /Users/locke/workspace/murmur
git add src-android/
git commit -m "feat(android): project scaffold — Gradle, manifest, IME metadata"
```

---

### Task 2: AudioStreamer

**Files:**
- Create: `src-android/app/src/main/java/com/locke/murmur/AudioStreamer.kt`

**Step 1: Create `AudioStreamer.kt`**

```kotlin
package com.locke.murmur

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

class AudioStreamer(private val onChunk: (ByteArray) -> Unit) {

    private val sampleRate = 16000
    private val bufferSize = AudioRecord.getMinBufferSize(
        sampleRate,
        AudioFormat.CHANNEL_IN_MONO,
        AudioFormat.ENCODING_PCM_16BIT
    ).coerceAtLeast(3200) // at least 100ms of audio

    private var audioRecord: AudioRecord? = null
    private var recordingJob: Job? = null

    fun start(scope: CoroutineScope) {
        val ar = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            bufferSize
        )
        audioRecord = ar
        ar.startRecording()

        recordingJob = scope.launch(Dispatchers.IO) {
            val buffer = ByteArray(bufferSize)
            while (ar.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                val read = ar.read(buffer, 0, buffer.size)
                if (read > 0) onChunk(buffer.copyOf(read))
            }
        }
    }

    fun stop() {
        recordingJob?.cancel()
        recordingJob = null
        audioRecord?.stop()
        audioRecord?.release()
        audioRecord = null
    }
}
```

**Step 2: Build and verify**

```bash
cd /Users/locke/workspace/murmur/src-android
./gradlew assembleDebug 2>&1 | tail -5
```

Expected: `BUILD SUCCESSFUL`

**Step 3: Commit**

```bash
cd /Users/locke/workspace/murmur
git add src-android/app/src/main/java/com/locke/murmur/AudioStreamer.kt
git commit -m "feat(android): AudioStreamer — 16kHz PCM capture via AudioRecord"
```

---

### Task 3: VolcengineProtocol + VolcengineClient

This is a Kotlin port of the macOS Swift implementation in:
- `src-swift/Sources/MurmurCore/ASR/VolcengineProtocol.swift`
- `src-swift/Sources/MurmurCore/ASR/VolcengineClient.swift`

The protocol uses a 4-byte binary header + big-endian Int32 payload size. Init packet JSON is gzip-compressed; audio packets are raw PCM (no compression).

**Files:**
- Create: `src-android/app/src/main/java/com/locke/murmur/VolcengineProtocol.kt`
- Create: `src-android/app/src/main/java/com/locke/murmur/VolcengineClient.kt`

**Step 1: Create `VolcengineProtocol.kt`**

```kotlin
package com.locke.murmur

import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream

object VolcengineProtocol {

    const val ENDPOINT = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel"

    // Message types (high nibble of byte 1)
    private const val MSG_FULL_CLIENT_REQUEST:  Byte = 0x01
    private const val MSG_AUDIO_ONLY_REQUEST:   Byte = 0x02
    private const val MSG_FULL_SERVER_RESPONSE: Byte = 0x09
    private const val MSG_SERVER_ACK:           Byte = 0x0B
    private const val MSG_SERVER_ERROR:         Byte = 0x0F

    // Sequence flags (low nibble of byte 1)
    private const val FLAG_POS_SEQUENCE: Byte = 0x01
    private const val FLAG_NEG_SEQUENCE: Byte = 0x03

    // Serialization (high nibble of byte 2)
    private const val SERIAL_JSON: Byte = 0x01

    // Compression (low nibble of byte 2)
    private const val COMPRESS_NONE: Byte = 0x00
    private const val COMPRESS_GZIP: Byte = 0x01

    private fun buildHeader(msgType: Byte, msgFlags: Byte, serial: Byte, compress: Byte): ByteArray {
        return byteArrayOf(
            ((0x01 shl 4) or 0x01).toByte(),        // version=1, headerSize=1
            ((msgType.toInt() shl 4) or msgFlags.toInt()).toByte(),
            ((serial.toInt() shl 4) or compress.toInt()).toByte(),
            0x00
        )
    }

    private fun int32ToBytes(value: Int): ByteArray =
        ByteBuffer.allocate(4).putInt(value).array()

    private fun bytesToInt32(bytes: ByteArray, offset: Int = 0): Int =
        ByteBuffer.wrap(bytes, offset, 4).int

    fun buildInitPacket(payload: JSONObject, sequence: Int): ByteArray {
        val jsonBytes = payload.toString().toByteArray(Charsets.UTF_8)
        val compressed = gzip(jsonBytes)

        val out = ByteArrayOutputStream()
        out.write(buildHeader(MSG_FULL_CLIENT_REQUEST, FLAG_POS_SEQUENCE, SERIAL_JSON, COMPRESS_GZIP))
        out.write(int32ToBytes(sequence))
        out.write(int32ToBytes(compressed.size))
        out.write(compressed)
        return out.toByteArray()
    }

    fun buildAudioPacket(audio: ByteArray, sequence: Int, isLast: Boolean): ByteArray {
        val flag = if (isLast) FLAG_NEG_SEQUENCE else FLAG_POS_SEQUENCE
        val seqValue = if (isLast) -sequence else sequence

        val out = ByteArrayOutputStream()
        out.write(buildHeader(MSG_AUDIO_ONLY_REQUEST, flag, SERIAL_JSON, COMPRESS_NONE))
        out.write(int32ToBytes(seqValue))
        out.write(int32ToBytes(audio.size))
        out.write(audio)
        return out.toByteArray()
    }

    data class ParsedResponse(
        val kind: Kind,
        val sequence: Int,
        val text: String? = null,
        val isFinal: Boolean = false,
        val errorMessage: String? = null
    ) {
        enum class Kind { ACK, RESULT, ERROR }
    }

    fun parseResponse(data: ByteArray): ParsedResponse? {
        if (data.size < 4) return null
        val msgType  = (data[1].toInt() ushr 4) and 0x0F
        val msgFlags =  data[1].toInt() and 0x0F
        val compress =  data[2].toInt() and 0x0F

        return when (msgType.toByte()) {
            MSG_SERVER_ERROR -> {
                if (data.size < 12) return null
                val msgSize = bytesToInt32(data, 8)
                if (msgSize < 0 || data.size < 12 + msgSize) return null
                val raw = data.copyOfRange(12, 12 + msgSize)
                val msg = if (compress == COMPRESS_GZIP.toInt()) ungzip(raw)?.toString(Charsets.UTF_8) ?: ""
                          else raw.toString(Charsets.UTF_8)
                ParsedResponse(ParsedResponse.Kind.ERROR, 0, errorMessage = msg)
            }
            MSG_SERVER_ACK -> {
                if (data.size < 8) return null
                val seq = bytesToInt32(data, 4)
                ParsedResponse(ParsedResponse.Kind.ACK, seq)
            }
            MSG_FULL_SERVER_RESPONSE -> {
                if (data.size < 12) return null
                val seq = bytesToInt32(data, 4)
                val payloadSize = bytesToInt32(data, 8)
                if (payloadSize < 0 || data.size < 12 + payloadSize) return null
                val rawPayload = data.copyOfRange(12, 12 + payloadSize)
                val payloadBytes = if (compress == COMPRESS_GZIP.toInt()) ungzip(rawPayload) ?: return null
                                   else rawPayload
                val json = runCatching { JSONObject(payloadBytes.toString(Charsets.UTF_8)) }.getOrNull() ?: return null
                val isFinal = seq < 0 || msgFlags == FLAG_NEG_SEQUENCE.toInt()
                var text = ""
                val result = json.optJSONObject("result")
                if (result != null) {
                    text = result.optString("text", "")
                    if (text.isEmpty()) {
                        val utts = result.optJSONArray("utterances")
                        if (utts != null) {
                            val sb = StringBuilder()
                            for (i in 0 until utts.length()) sb.append(utts.getJSONObject(i).optString("text", ""))
                            text = sb.toString()
                        }
                    }
                }
                ParsedResponse(ParsedResponse.Kind.RESULT, seq, text = text, isFinal = isFinal)
            }
            else -> null
        }
    }

    private fun gzip(data: ByteArray): ByteArray {
        val bos = ByteArrayOutputStream()
        GZIPOutputStream(bos).use { it.write(data) }
        return bos.toByteArray()
    }

    private fun ungzip(data: ByteArray): ByteArray? = runCatching {
        GZIPInputStream(data.inputStream()).use { it.readBytes() }
    }.getOrNull()
}
```

**Step 2: Create `VolcengineClient.kt`**

```kotlin
package com.locke.murmur

import kotlinx.coroutines.channels.Channel
import okhttp3.*
import okio.ByteString.Companion.toByteString
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

sealed class AsrEvent {
    data class Result(val text: String, val isFinal: Boolean) : AsrEvent()
    object Error : AsrEvent()
}

class VolcengineClient {

    companion object {
        private const val APP_ID       = "7232385834"
        private const val ACCESS_TOKEN = "5lSRCDzbb2KgBjEtKJbT9NIsU-z2z-F_"
        private const val RESOURCE_ID  = "volc.bigasr.sauc.duration"
    }

    val events = Channel<AsrEvent>(Channel.UNLIMITED)

    private val http = OkHttpClient()
    @Volatile private var webSocket: WebSocket? = null
    @Volatile private var sequence = 1

    fun connect() {
        val requestId = UUID.randomUUID().toString()
        val request = Request.Builder()
            .url(VolcengineProtocol.ENDPOINT)
            .header("X-Api-App-Key",      APP_ID)
            .header("X-Api-Access-Key",   ACCESS_TOKEN)
            .header("X-Api-Resource-Id",  RESOURCE_ID)
            .header("X-Api-Connect-Id",   requestId)
            .build()

        webSocket = http.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(ws: WebSocket, response: Response) {
                val payload = JSONObject().apply {
                    put("user", JSONObject().put("uid", "murmur_user"))
                    put("audio", JSONObject().apply {
                        put("format", "pcm")
                        put("sample_rate", 16000)
                        put("channel", 1)
                        put("bits", 16)
                        put("codec", "raw")
                    })
                    put("request", JSONObject().apply {
                        put("model_name", "bigmodel")
                        put("language", "zh-CN")
                        put("enable_punc", true)
                        put("enable_itn", true)
                        put("enable_ddc", false)
                        put("show_utterances", true)
                        put("result_type", "full")
                    })
                }
                val packet = VolcengineProtocol.buildInitPacket(payload, sequence)
                sequence = 2
                ws.send(packet.toByteString())
            }

            override fun onMessage(ws: WebSocket, bytes: okio.ByteString) {
                val parsed = VolcengineProtocol.parseResponse(bytes.toByteArray()) ?: return
                when (parsed.kind) {
                    VolcengineProtocol.ParsedResponse.Kind.RESULT ->
                        events.trySend(AsrEvent.Result(parsed.text ?: "", parsed.isFinal))
                    VolcengineProtocol.ParsedResponse.Kind.ERROR ->
                        events.trySend(AsrEvent.Error)
                    VolcengineProtocol.ParsedResponse.Kind.ACK -> { /* ignore */ }
                }
            }

            override fun onFailure(ws: WebSocket, t: Throwable, response: Response?) {
                events.trySend(AsrEvent.Error)
            }
        })
    }

    fun sendAudio(pcm: ByteArray) {
        val packet = VolcengineProtocol.buildAudioPacket(pcm, sequence++, isLast = false)
        webSocket?.send(packet.toByteString())
    }

    fun finish() {
        val packet = VolcengineProtocol.buildAudioPacket(ByteArray(0), sequence, isLast = true)
        webSocket?.send(packet.toByteString())
    }

    fun disconnect() {
        webSocket?.close(1000, null)
        webSocket = null
        events.close()
    }
}
```

**Step 3: Build and verify**

```bash
cd /Users/locke/workspace/murmur/src-android
./gradlew assembleDebug 2>&1 | tail -5
```

Expected: `BUILD SUCCESSFUL`

**Step 4: Commit**

```bash
cd /Users/locke/workspace/murmur
git add src-android/app/src/main/java/com/locke/murmur/VolcengineProtocol.kt \
        src-android/app/src/main/java/com/locke/murmur/VolcengineClient.kt
git commit -m "feat(android): VolcengineProtocol + VolcengineClient — BigASR WebSocket port from Swift"
```

---

### Task 4: MicKeyboardView

**Files:**
- Create: `src-android/app/src/main/java/com/locke/murmur/MicKeyboardView.kt`

**Step 1: Create `MicKeyboardView.kt`**

```kotlin
package com.locke.murmur

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.view.MotionEvent
import android.view.View

class MicKeyboardView(context: Context, private val listener: Listener) : View(context) {

    interface Listener {
        fun onPressStart()
        fun onPressEnd()
    }

    enum class State { IDLE, RECORDING, PROCESSING }

    var state: State = State.IDLE
        set(value) { field = value; invalidate() }

    private val bgPaint = Paint().apply {
        color = Color.parseColor("#141416")
        style = Paint.Style.FILL
    }
    private val circlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
    }
    private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#888888")
        textAlign = Paint.Align.CENTER
        textSize = 13 * resources.displayMetrics.scaledDensity
    }
    private val micPath = Path()

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN  -> listener.onPressStart()
            MotionEvent.ACTION_UP,
            MotionEvent.ACTION_CANCEL -> listener.onPressEnd()
        }
        return true
    }

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat()
        val h = height.toFloat()

        // Background
        canvas.drawRect(0f, 0f, w, h, bgPaint)

        val cx = w / 2f
        val cy = h / 2f
        val dp = resources.displayMetrics.density
        val radius = 36 * dp

        // Circle color per state
        circlePaint.color = when (state) {
            State.IDLE       -> Color.parseColor("#3A3A3C")
            State.RECORDING  -> Color.parseColor("#FF3B30")
            State.PROCESSING -> Color.parseColor("#2C2C2E")
        }
        canvas.drawCircle(cx, cy, radius, circlePaint)

        // Mic icon (simplified: capsule body + stand)
        val iconPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = when (state) {
                State.IDLE      -> Color.parseColor("#EBEBF5")
                State.RECORDING -> Color.WHITE
                State.PROCESSING -> Color.parseColor("#636366")
            }
            style = Paint.Style.FILL
        }
        val mw = 9 * dp
        val mh = 14 * dp
        val mt = cy - mh * 0.65f
        // Capsule body
        val bodyRect = RectF(cx - mw / 2, mt, cx + mw / 2, mt + mh)
        canvas.drawRoundRect(bodyRect, mw / 2, mw / 2, iconPaint)
        // Stand arc
        val standPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = iconPaint.color
            style = Paint.Style.STROKE
            strokeWidth = 1.8f * dp
            strokeCap = Paint.Cap.ROUND
        }
        val standR = mw * 0.9f
        val standTop = mt + mh - mw / 2
        val arcRect = RectF(cx - standR, standTop - standR, cx + standR, standTop + standR)
        canvas.drawArc(arcRect, 0f, 180f, false, standPaint)
        // Stand pole
        canvas.drawLine(cx, standTop + standR, cx, standTop + standR + 4 * dp, standPaint)

        // Hint label (idle only)
        if (state == State.IDLE) {
            canvas.drawText("按住说话", cx, cy + radius + 18 * dp, labelPaint)
        }
    }
}
```

**Step 2: Build and verify**

```bash
cd /Users/locke/workspace/murmur/src-android
./gradlew assembleDebug 2>&1 | tail -5
```

Expected: `BUILD SUCCESSFUL`

**Step 3: Commit**

```bash
cd /Users/locke/workspace/murmur
git add src-android/app/src/main/java/com/locke/murmur/MicKeyboardView.kt
git commit -m "feat(android): MicKeyboardView — mic button with idle/recording/processing states"
```

---

### Task 5: PermissionActivity + MurmurIME (wiring)

**Files:**
- Modify: `src-android/app/src/main/java/com/locke/murmur/PermissionActivity.kt`
- Modify: `src-android/app/src/main/java/com/locke/murmur/MurmurIME.kt`

**Step 1: Rewrite `PermissionActivity.kt`**

This transparent activity is launched from the IME to request `RECORD_AUDIO` (cannot call `requestPermissions` from a Service).

```kotlin
package com.locke.murmur

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Bundle

class PermissionActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            finish()
        } else {
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 1)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        finish() // result visible immediately when user opens keyboard again
    }
}
```

**Step 2: Rewrite `MurmurIME.kt`**

```kotlin
package com.locke.murmur

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.inputmethodservice.InputMethodService
import android.view.View
import kotlinx.coroutines.*

class MurmurIME : InputMethodService(), MicKeyboardView.Listener {

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private lateinit var keyboardView: MicKeyboardView

    private var audioStreamer: AudioStreamer? = null
    private var volcengineClient: VolcengineClient? = null
    private var eventJob: Job? = null

    override fun onCreateInputView(): View {
        keyboardView = MicKeyboardView(this, this)
        return keyboardView
    }

    // MARK: - MicKeyboardView.Listener

    override fun onPressStart() {
        if (!hasAudioPermission()) {
            requestAudioPermission()
            return
        }
        startSession()
    }

    override fun onPressEnd() {
        stopSession()
    }

    // MARK: - Session lifecycle

    private fun startSession() {
        keyboardView.state = MicKeyboardView.State.RECORDING

        val vc = VolcengineClient()
        volcengineClient = vc
        vc.connect()

        val streamer = AudioStreamer { pcm -> vc.sendAudio(pcm) }
        audioStreamer = streamer
        streamer.start(scope)

        eventJob = scope.launch {
            for (event in vc.events) {
                when (event) {
                    is AsrEvent.Result -> {
                        if (event.isFinal) {
                            if (event.text.isNotEmpty()) {
                                currentInputConnection?.commitText(event.text, 1)
                            }
                            finishSession()
                        }
                    }
                    AsrEvent.Error -> finishSession()
                }
            }
        }
    }

    private fun stopSession() {
        keyboardView.state = MicKeyboardView.State.PROCESSING
        audioStreamer?.stop()
        audioStreamer = null
        volcengineClient?.finish()
        // eventJob stays running — waits for isFinal result from server
    }

    private fun finishSession() {
        keyboardView.state = MicKeyboardView.State.IDLE
        eventJob?.cancel()
        eventJob = null
        volcengineClient?.disconnect()
        volcengineClient = null
    }

    // MARK: - Permissions

    private fun hasAudioPermission() =
        checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun requestAudioPermission() {
        val intent = Intent(this, PermissionActivity::class.java)
        intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
        startActivity(intent)
    }

    // MARK: - Lifecycle

    override fun onDestroy() {
        scope.cancel()
        audioStreamer?.stop()
        volcengineClient?.disconnect()
        super.onDestroy()
    }
}
```

**Step 3: Build**

```bash
cd /Users/locke/workspace/murmur/src-android
./gradlew assembleDebug 2>&1 | tail -5
```

Expected: `BUILD SUCCESSFUL`

**Step 4: Install on emulator/device and smoke test**

```bash
cd /Users/locke/workspace/murmur/src-android
./gradlew installDebug
```

Then on the device:
1. Settings → General Management → Keyboard → On-screen keyboards → Add Murmur Voice
2. Open any text field, switch input method to Murmur
3. Tap the keyboard area (first use) — permission dialog should appear
4. Grant permission, switch back to Murmur keyboard
5. Hold the mic button → button turns red
6. Speak: "你好世界"
7. Release → button shows processing state
8. Text "你好世界" should appear in the text field

**Step 5: Commit**

```bash
cd /Users/locke/workspace/murmur
git add src-android/app/src/main/java/com/locke/murmur/MurmurIME.kt \
        src-android/app/src/main/java/com/locke/murmur/PermissionActivity.kt
git commit -m "feat(android): MurmurIME — wires AudioStreamer + VolcengineClient, hold-to-record PTT"
```
