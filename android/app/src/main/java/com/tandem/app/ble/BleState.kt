package com.tandem.app.ble

import android.bluetooth.BluetoothDevice

enum class BleConnectionState(val label: String) {
    IDLE("Idle"),
    SCANNING("Scanning for Mac..."),
    CONNECTING("Connecting to Mac..."),
    DISCOVERING_SERVICES("Negotiating MTU & Services..."),
    CONNECTED_READY("Connected to Mac (Ready)"),
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

data class SentMessageRecord(
    val messageId: String,
    val text: String,
    val timestamp: String,
    var status: DeliveryStatus,
    var statusDetail: String = ""
)
