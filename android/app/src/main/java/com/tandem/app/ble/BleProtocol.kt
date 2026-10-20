package com.tandem.app.ble

import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID

object BleProtocol {
    val SERVICE_UUID: UUID = UUID.fromString("7A8D0001-B5A3-4F39-B948-2E1F4B5C6D01")
    val RX_CHAR_UUID: UUID = UUID.fromString("7A8D0002-B5A3-4F39-B948-2E1F4B5C6D01")
    val TX_CHAR_UUID: UUID = UUID.fromString("7A8D0003-B5A3-4F39-B948-2E1F4B5C6D01")
    val DEVICE_INFO_CHAR_UUID: UUID = UUID.fromString("7A8D0004-B5A3-4F39-B948-2E1F4B5C6D01")
    val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    const val TARGET_MAC_NAME = "TandemMac"
    const val PROTOCOL_VERSION = 3
    const val MAX_PAYLOAD_BYTES = 5 * 1024 * 1024 // 5 MB for offline files and attachments

    const val MAGIC_SINGLE: Byte = 0xAA.toByte()
    const val MAGIC_MULTI: Byte = 0xAB.toByte()
    const val MAGIC_FINAL: Byte = 0xAC.toByte()
    const val MAGIC_EXT_MULTI: Byte = 0xAD.toByte()
    const val MAGIC_EXT_FINAL: Byte = 0xAE.toByte()

    fun currentIsoTimestamp(): String {
        val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        sdf.timeZone = TimeZone.getTimeZone("UTC")
        return sdf.format(Date())
    }
}

data class TandemMessage(
    val version: Int = BleProtocol.PROTOCOL_VERSION,
    val type: String = "text", // "text", "file", "encrypted", "handshake", "handshake_ack"
    val messageId: String = UUID.randomUUID().toString(),
    val timestamp: String = BleProtocol.currentIsoTimestamp(),
    val sender: String = "android",
    val payload: String,
    val fileName: String? = null,
    val fileSize: Long? = null,
    val mimeType: String? = null,
    val sha256: String? = null
) {
    fun toJsonString(): String {
        val obj = JSONObject()
        obj.put("version", version)
        obj.put("type", type)
        obj.put("message_id", messageId)
        obj.put("timestamp", timestamp)
        obj.put("sender", sender)
        obj.put("payload", payload)
        if (fileName != null) obj.put("file_name", fileName)
        if (fileSize != null) obj.put("file_size", fileSize)
        if (mimeType != null) obj.put("mime_type", mimeType)
        if (sha256 != null) obj.put("sha256", sha256)
        return obj.toString()
    }

    companion object {
        fun fromJsonString(jsonStr: String): TandemMessage? {
            return try {
                val obj = JSONObject(jsonStr)
                TandemMessage(
                    version = obj.optInt("version", BleProtocol.PROTOCOL_VERSION),
                    type = obj.getString("type"),
                    messageId = obj.getString("message_id"),
                    timestamp = obj.getString("timestamp"),
                    sender = obj.optString("sender", "android"),
                    payload = obj.getString("payload"),
                    fileName = if (obj.has("file_name") && !obj.isNull("file_name")) obj.getString("file_name") else null,
                    fileSize = if (obj.has("file_size") && !obj.isNull("file_size")) obj.getLong("file_size") else null,
                    mimeType = if (obj.has("mime_type") && !obj.isNull("mime_type")) obj.getString("mime_type") else null,
                    sha256 = if (obj.has("sha256") && !obj.isNull("sha256")) obj.getString("sha256") else null
                )
            } catch (e: Exception) {
                null
            }
        }
    }
}

data class TandemAck(
    val version: Int = BleProtocol.PROTOCOL_VERSION,
    val type: String = "ack",
    val messageId: String,
    val status: String,
    val code: Int,
    val error: String? = null
) {
    fun toJsonString(): String {
        val obj = JSONObject()
        obj.put("version", version)
        obj.put("type", type)
        obj.put("message_id", messageId)
        obj.put("status", status)
        obj.put("code", code)
        if (error != null) obj.put("error", error)
        return obj.toString()
    }

    companion object {
        fun fromJsonString(jsonStr: String): TandemAck? {
            return try {
                val obj = JSONObject(jsonStr)
                TandemAck(
                    version = obj.optInt("version", BleProtocol.PROTOCOL_VERSION),
                    type = obj.optString("type", "ack"),
                    messageId = obj.getString("message_id"),
                    status = obj.getString("status"),
                    code = obj.getInt("code"),
                    error = if (obj.has("error") && !obj.isNull("error")) obj.getString("error") else null
                )
            } catch (e: Exception) {
                null
            }
        }
    }
}
