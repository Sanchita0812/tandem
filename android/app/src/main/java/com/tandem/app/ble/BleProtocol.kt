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
    const val PROTOCOL_VERSION = 2
    const val MAX_PAYLOAD_BYTES = 4096

    const val MAGIC_SINGLE: Byte = 0xAA.toByte()
    const val MAGIC_MULTI: Byte = 0xAB.toByte()
    const val MAGIC_FINAL: Byte = 0xAC.toByte()

    fun currentIsoTimestamp(): String {
        val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        sdf.timeZone = TimeZone.getTimeZone("UTC")
        return sdf.format(Date())
    }
}

data class TandemMessage(
    val version: Int = BleProtocol.PROTOCOL_VERSION,
    val type: String = "text",
    val messageId: String = UUID.randomUUID().toString(),
    val timestamp: String = BleProtocol.currentIsoTimestamp(),
    val sender: String = "android",
    val payload: String
) {
    fun toJsonString(): String {
        val obj = JSONObject()
        obj.put("version", version)
        obj.put("type", type)
        obj.put("message_id", messageId)
        obj.put("timestamp", timestamp)
        obj.put("sender", sender)
        obj.put("payload", payload)
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
                    payload = obj.getString("payload")
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
