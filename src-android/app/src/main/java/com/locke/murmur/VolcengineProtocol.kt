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
