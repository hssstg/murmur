package com.locke.murmur

import kotlinx.coroutines.channels.Channel
import okhttp3.*
import okio.ByteString.Companion.toByteString
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

sealed class AsrEvent {
    data class Result(val text: String, val isFinal: Boolean) : AsrEvent()
    object Error : AsrEvent()
}

class VolcengineClient {

    companion object {
        private const val APP_ID       = "7232385834"
        private const val ACCESS_TOKEN = "5lSRCDzbb2KgBjEtKJbT9NIsU-z2z-F_"
        private const val RESOURCE_ID  = "volc.bigasr.sauc.duration"
        private val http = OkHttpClient()
    }

    val events = Channel<AsrEvent>(Channel.UNLIMITED)

    @Volatile private var webSocket: WebSocket? = null
    private val sequence = AtomicInteger(1)

    fun connect() {
        sequence.set(1)
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
                val packet = VolcengineProtocol.buildInitPacket(payload, sequence.get())
                sequence.set(2)
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
        val packet = VolcengineProtocol.buildAudioPacket(pcm, sequence.getAndIncrement(), isLast = false)
        webSocket?.send(packet.toByteString())
    }

    fun finish() {
        val packet = VolcengineProtocol.buildAudioPacket(ByteArray(0), sequence.get(), isLast = true)
        webSocket?.send(packet.toByteString())
    }

    fun disconnect() {
        webSocket?.close(1000, null)
        webSocket = null
        events.close()
    }
}
