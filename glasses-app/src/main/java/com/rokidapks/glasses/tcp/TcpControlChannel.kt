package com.rokidapks.glasses.tcp

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.net.Socket

/**
 * JSON control channel over a plain TCP socket.
 *
 * Wire format is identical to the original Kotlin SppControlChannel used for Android phones:
 *   [4-byte big-endian Int32 length][UTF-8 JSON body]
 *
 * This replaces the Bluetooth SPP socket channel so the glasses companion can communicate
 * with the iOS RokidAPKsPhone app, which advertises itself over Bonjour.
 */
class TcpControlChannel(socket: Socket) {
    private val input = DataInputStream(socket.getInputStream())
    private val output = DataOutputStream(socket.getOutputStream())

    // ── Reading ──────────────────────────────────────────────────────────────

    /**
     * Blocks until the iOS phone sends the transfer offer JSON.
     * Returns a parsed [CompanionTransferOffer].
     */
    suspend fun awaitOffer(): CompanionTransferOffer = withContext(Dispatchers.IO) {
        val payload = readJson()
        if (payload.optString("type") != "offer") {
            throw IOException("Expected offer message, got: ${payload.optString("type")}")
        }
        CompanionTransferOffer(
            transportMode = payload.optString("transportMode", "wifi_lan"),
            hostIp = payload.optString("hostIp").ifBlank { null },
            port = payload.optInt("port").takeIf { it > 0 },
            apkSize = payload.getLong("apkSize"),
            md5Hex = payload.getString("md5"),
            fileName = payload.optString("fileName", "transfer.apk"),
        )
    }

    // ── Writing ──────────────────────────────────────────────────────────────

    /**
     * Sends the install result back to the iOS phone.
     */
    suspend fun sendResult(success: Boolean, message: String) = withContext(Dispatchers.IO) {
        val payload = JSONObject()
            .put("type", "result")
            .put("success", success)
            .put("message", message)
        writeJson(payload)
    }

    // ── Framing helpers ──────────────────────────────────────────────────────

    private fun writeJson(payload: JSONObject) {
        val body = payload.toString().toByteArray(Charsets.UTF_8)
        output.writeInt(body.size)
        output.write(body)
        output.flush()
    }

    private fun readJson(): JSONObject {
        val length = input.readInt()
        if (length <= 0 || length > 65_536) {
            throw IOException("Invalid control payload length: $length")
        }
        val body = ByteArray(length)
        input.readFully(body)
        return JSONObject(String(body, Charsets.UTF_8))
    }
}

// ── Shared data class (mirrors original SppControlChannel) ──────────────────

data class CompanionTransferOffer(
    val transportMode: String,
    val hostIp: String? = null,
    val port: Int? = null,
    val apkSize: Long,
    val md5Hex: String,
    val fileName: String,
)
