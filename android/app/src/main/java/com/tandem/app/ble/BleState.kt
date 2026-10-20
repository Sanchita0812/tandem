package com.tandem.app.ble

import android.bluetooth.BluetoothDevice

enum class BleConnectionState(val label: String) {
    IDLE("Idle"),
    SCANNING("Scanning for Mac..."),
    CONNECTING("Connecting to Mac..."),
    DISCOVERING_SERVICES("Negotiating MTU & Services..."),
    HANDSHAKE("Establishing E2EE Handshake..."),
    CONNECTED_READY("Connected (E2EE Active)"),
    DISCONNECTED("Disconnected"),
    ERROR("Connection Error")
}

data class DiscoveredDevice(
    val device: BluetoothDevice,
    val name: String,
    val address: String,
    val rssi: Int
)

enum class DeliveryStatus {
    PENDING,
    DELIVERED,
    FAILED
}

enum class MessageDirection {
    OUTGOING, // Sent by Android to Mac
    INCOMING  // Received from Mac
}

data class MessageRecord(
    val messageId: String,
    val text: String,
    val timestamp: String,
    val direction: MessageDirection = MessageDirection.OUTGOING,
    var status: DeliveryStatus = DeliveryStatus.PENDING,
    var statusDetail: String = "",
    val type: String = "text", // "text" or "file"
    val fileName: String? = null,
    val fileSize: Long? = null,
    val mimeType: String? = null,
    var localFilePath: String? = null,
    val sha256: String? = null,
    var progress: Int = 100
)

typealias SentMessageRecord = MessageRecord
