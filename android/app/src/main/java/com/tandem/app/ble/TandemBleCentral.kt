package com.tandem.app.ble

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Base64
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentLinkedQueue

class TandemBleCentral(private val context: Context) {

    private val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val bluetoothAdapter: BluetoothAdapter? = bluetoothManager?.adapter
    private val mainHandler = Handler(Looper.getMainLooper())

    private var bluetoothGatt: BluetoothGatt? = null
    private var rxCharacteristic: BluetoothGattCharacteristic? = null
    private var txCharacteristic: BluetoothGattCharacteristic? = null

    private var negotiatedMtu = 23
    private var isScanning = false
    private var currentState: BleConnectionState = BleConnectionState.IDLE

    // Callbacks for UI
    var onStateChanged: ((BleConnectionState, String) -> Unit)? = null
    var onDeviceDiscovered: ((DiscoveredDevice) -> Unit)? = null
    var onMessageReceived: ((TandemMessage) -> Unit)? = null
    var onSecurityCodeGenerated: ((String?) -> Unit)? = null
    var onLog: ((String) -> Unit)? = null

    // Outgoing write queue and pending ACKs
    private val writeQueue = ConcurrentLinkedQueue<ByteArray>()
    private var isWriting = false
    private var pendingSendCallback: ((Boolean, String) -> Unit)? = null
    private var pendingMessageId: String? = null
    private var ackTimeoutRunnable: Runnable? = null

    val isBluetoothEnabled: Boolean
        get() = bluetoothAdapter?.isEnabled == true

    val isPeripheralModeSupported: Boolean
        get() = bluetoothAdapter?.isMultipleAdvertisementSupported == true

    private fun log(message: String) {
        val formatted = "[${BleProtocol.currentIsoTimestamp().substring(11, 19)}] $message"
        mainHandler.post { onLog?.invoke(formatted) }
    }

    private fun updateState(state: BleConnectionState, detail: String = "") {
        currentState = state
        mainHandler.post { onStateChanged?.invoke(state, detail) }
    }

    // MARK: - Scanning

    fun startScanning() {
        val scanner = bluetoothAdapter?.bluetoothLeScanner
        if (scanner == null || !isBluetoothEnabled) {
            log("Cannot scan: Bluetooth is disabled or unavailable.")
            updateState(BleConnectionState.ERROR, "Bluetooth is disabled")
            return
        }

        if (isScanning) return
        isScanning = true
        updateState(BleConnectionState.SCANNING, "Searching for TandemMac...")
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        scanner.startScan(null, settings, scanCallback)

        mainHandler.postDelayed({
            if (isScanning) {
                stopScanning()
                if (currentState == BleConnectionState.SCANNING) {
                    updateState(BleConnectionState.IDLE, "Scan completed.")
                    log("Scan timed out after 12 seconds.")
                }
            }
        }, 12000)
    }

    fun stopScanning() {
        if (!isScanning) return
        isScanning = false
        bluetoothAdapter?.bluetoothLeScanner?.stopScan(scanCallback)
        log("BLE scanning stopped.")
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device
            val name = device.name ?: result.scanRecord?.deviceName ?: "Unknown BLE Device"
            val address = device.address
            val rssi = result.rssi

            log("Discovered device: '$name' [$address], RSSI: ${rssi}dBm")
            val item = DiscoveredDevice(device, name, address, rssi)
            mainHandler.post { onDeviceDiscovered?.invoke(item) }
        }

        override fun onScanFailed(errorCode: Int) {
            log("Scan failed with error code: $errorCode")
            isScanning = false
            updateState(BleConnectionState.ERROR, "Scan error: $errorCode")
        }
    }

    // MARK: - Connection Lifecycle

    fun connect(device: BluetoothDevice) {
        stopScanning()
        disconnect()

        log("Initiating GATT connection to ${device.name ?: device.address}...")
        updateState(BleConnectionState.CONNECTING, "Connecting to ${device.name ?: device.address}...")

        bluetoothGatt = device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
    }

    fun disconnect() {
        try {
            cancelAckTimeout()
            writeQueue.clear()
            isWriting = false
            pendingSendCallback = null
            pendingMessageId = null

            bluetoothGatt?.disconnect()
            bluetoothGatt?.close()
            bluetoothGatt = null
            rxCharacteristic = null
            txCharacteristic = null
            negotiatedMtu = 23
            TandemCrypto.resetKeypair()
            mainHandler.post { onSecurityCodeGenerated?.invoke(null) }
            updateState(BleConnectionState.DISCONNECTED, "Disconnected")
            log("GATT connection closed.")
        } catch (e: Exception) {
            log("Error during disconnect: ${e.message}")
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            log("onConnectionStateChange: status=$status, newState=$newState")
            if (status != BluetoothGatt.GATT_SUCCESS) {
                log("GATT connection failed with status: $status")
                disconnect()
                updateState(BleConnectionState.ERROR, "GATT status error: $status")
                return
            }

            if (newState == BluetoothProfile.STATE_CONNECTED) {
                log("Connected to GATT Server! Requesting MTU 512 & Priority High...")
                updateState(BleConnectionState.DISCOVERING_SERVICES, "Connected; requesting MTU 512...")
                gatt.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH)
                gatt.requestMtu(512)
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                log("Disconnected from GATT Server.")
                disconnect()
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                negotiatedMtu = mtu
                log("Negotiated MTU: $mtu bytes (usable payload: ${mtu - 3} bytes)")
            } else {
                log("MTU request failed with status $status, keeping default $negotiatedMtu bytes.")
            }
            log("Discovering GATT services...")
            gatt.discoverServices()
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                log("Service discovery failed with status $status")
                updateState(BleConnectionState.ERROR, "Service discovery failed: $status")
                return
            }

            val service = gatt.getService(BleProtocol.SERVICE_UUID)
            if (service == null) {
                log("ERROR: Tandem Service ${BleProtocol.SERVICE_UUID} not found on peripheral!")
                updateState(BleConnectionState.ERROR, "Tandem Service not found on Mac")
                return
            }

            rxCharacteristic = service.getCharacteristic(BleProtocol.RX_CHAR_UUID)
            txCharacteristic = service.getCharacteristic(BleProtocol.TX_CHAR_UUID)

            if (rxCharacteristic == null || txCharacteristic == null) {
                log("ERROR: Rx or Tx characteristic missing on Tandem service!")
                updateState(BleConnectionState.ERROR, "Characteristics missing")
                return
            }

            log("Found Tandem Rx and Tx characteristics. Subscribing to Tx notifications...")
            subscribeToTxNotifications(gatt, txCharacteristic!!)
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS && descriptor.uuid == BleProtocol.CCCD_UUID) {
                log("Successfully subscribed to Tx characteristic notifications! Initiating E2EE handshake...")
                initiateHandshake()
            } else {
                log("Failed to write CCCD descriptor: status $status")
            }
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            mainHandler.post {
                isWriting = false
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    processNextWrite()
                } else {
                    log("Characteristic write failed with status: $status")
                    cancelAckTimeout()
                    pendingSendCallback?.invoke(false, "Write failed with status $status")
                    pendingSendCallback = null
                }
            }
        }

        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (characteristic.uuid == BleProtocol.TX_CHAR_UUID) {
                val rawData = characteristic.value ?: return
                val deframed = ChunkFramer.processIncomingPacket(rawData) ?: return
                val jsonStr = String(deframed, Charsets.UTF_8)
                handleInboundNotification(jsonStr)
            }
        }
    }

    private fun subscribeToTxNotifications(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
        gatt.setCharacteristicNotification(characteristic, true)
        val descriptor = characteristic.getDescriptor(BleProtocol.CCCD_UUID)
        if (descriptor != null) {
            descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            gatt.writeDescriptor(descriptor)
        } else {
            log("CCCD descriptor not found on Tx characteristic; initiating handshake directly.")
            initiateHandshake()
        }
    }

    // MARK: - E2EE Handshake & Inbound Processing

    private fun initiateHandshake() {
        updateState(BleConnectionState.HANDSHAKE, "Exchanging ECDH P-256 keys with Mac...")
        TandemCrypto.resetKeypair()
        val pubBytes = TandemCrypto.getLocalRawPublicKey()
        if (pubBytes == null) {
            log("Failed to generate local EC keypair")
            updateState(BleConnectionState.ERROR, "Crypto initialization failed")
            return
        }

        val hsMsg = TandemMessage(
            version = BleProtocol.PROTOCOL_VERSION,
            type = "handshake",
            messageId = "hs-cli-" + UUID.randomUUID().toString().take(8),
            sender = "android",
            payload = Base64.encodeToString(pubBytes, Base64.NO_WRAP)
        )

        val payloadBytes = hsMsg.toJsonString().toByteArray(Charsets.UTF_8)
        val maxChunkCapacity = (negotiatedMtu - 3).coerceAtLeast(20)
        val chunks = ChunkFramer.framePayload(payloadBytes, hsMsg.messageId, maxChunkCapacity)

        log("Dispatching E2EE Handshake request to Mac (${chunks.size} chunks)...")
        writeQueue.addAll(chunks)
        processNextWrite()
    }

    private fun handleInboundNotification(jsonStr: String) {
        try {
            val obj = JSONObject(jsonStr)
            val type = obj.optString("type")

            when (type) {
                "handshake_ack" -> {
                    val serverPubB64 = obj.getString("payload")
                    val serverPubBytes = Base64.decode(serverPubB64, Base64.DEFAULT)
                    val sas = TandemCrypto.completeKeyExchange(serverPubBytes)
                    log("🔒 E2EE Handshake completed! Shared AES-256-GCM session active. Security Code: $sas")
                    mainHandler.post {
                        onSecurityCodeGenerated?.invoke(sas)
                        updateState(BleConnectionState.CONNECTED_READY, "Ready • E2EE Active (Code: $sas)")
                    }
                }
                "ack" -> {
                    handleAckNotification(jsonStr)
                }
                "encrypted" -> {
                    if (!TandemCrypto.isEncrypted) {
                        log("SECURITY REJECT: Received encrypted message before handshake established")
                        return
                    }
                    val ciphertextB64 = obj.getString("payload")
                    val decryptedJson = TandemCrypto.decrypt(ciphertextB64)
                    val innerMsg = TandemMessage.fromJsonString(decryptedJson)
                    if (innerMsg != null) {
                        log("🔒 Valid Encrypted Message Received from Mac: '${innerMsg.payload}'")
                        mainHandler.post {
                            onMessageReceived?.invoke(innerMsg)
                        }
                        sendDirectAck(innerMsg.messageId)
                    }
                }
                "text" -> {
                    val msg = TandemMessage.fromJsonString(jsonStr)
                    if (msg != null) {
                        log("Received Message from Mac: '${msg.payload}'")
                        mainHandler.post {
                            onMessageReceived?.invoke(msg)
                        }
                        sendDirectAck(msg.messageId)
                    }
                }
                else -> {
                    if (obj.has("status") && obj.has("code")) {
                        handleAckNotification(jsonStr)
                    }
                }
            }
        } catch (e: Exception) {
            log("Error handling inbound notification: ${e.message}")
        }
    }

    private fun sendDirectAck(messageId: String) {
        val ack = TandemAck(
            messageId = messageId,
            status = "delivered",
            code = 200
        )
        val ackBytes = ack.toJsonString().toByteArray(Charsets.UTF_8)
        val maxChunkCapacity = (negotiatedMtu - 3).coerceAtLeast(20)
        val chunks = ChunkFramer.framePayload(ackBytes, messageId, maxChunkCapacity)
        log("Sending delivery ACK to Mac for message: $messageId (${chunks.size} chunks)")
        writeQueue.addAll(chunks)
        processNextWrite()
    }

    // MARK: - Outgoing Message Transmission

    fun sendMessage(text: String, onResult: (Boolean, String) -> Unit) {
        val gatt = bluetoothGatt
        val rxChar = rxCharacteristic
        if (gatt == null || rxChar == null || currentState != BleConnectionState.CONNECTED_READY) {
            onResult(false, "Not connected to Mac")
            return
        }

        val trimmed = text.trim()
        if (trimmed.isEmpty()) {
            onResult(false, "Cannot send empty message")
            return
        }

        val msgId = "msg-" + UUID.randomUUID().toString().take(12)
        val timestamp = BleProtocol.currentIsoTimestamp()

        val envelope: TandemMessage
        if (TandemCrypto.isEncrypted) {
            val innerMsg = TandemMessage(
                version = BleProtocol.PROTOCOL_VERSION,
                type = "text",
                messageId = msgId,
                timestamp = timestamp,
                sender = "android",
                payload = trimmed
            )
            val ciphertext = TandemCrypto.encrypt(innerMsg.toJsonString())
            envelope = TandemMessage(
                version = BleProtocol.PROTOCOL_VERSION,
                type = "encrypted",
                messageId = msgId,
                timestamp = timestamp,
                sender = "android",
                payload = ciphertext
            )
        } else {
            envelope = TandemMessage(
                version = BleProtocol.PROTOCOL_VERSION,
                type = "text",
                messageId = msgId,
                timestamp = timestamp,
                sender = "android",
                payload = trimmed
            )
        }

        val jsonPayload = envelope.toJsonString().toByteArray(Charsets.UTF_8)
        if (jsonPayload.size > BleProtocol.MAX_PAYLOAD_BYTES) {
            onResult(false, "Message exceeds ${BleProtocol.MAX_PAYLOAD_BYTES} bytes limit")
            return
        }

        pendingMessageId = msgId
        pendingSendCallback = onResult

        val maxChunkCapacity = (negotiatedMtu - 3).coerceAtLeast(20)
        val chunks = ChunkFramer.framePayload(jsonPayload, msgId, maxChunkCapacity)

        log("Enqueueing message $msgId (${jsonPayload.size} bytes across ${chunks.size} chunks)...")
        writeQueue.addAll(chunks)

        startAckTimeout()
        processNextWrite()
    }

    private fun processNextWrite() {
        mainHandler.post {
            if (isWriting) return@post
            val chunk = writeQueue.poll() ?: return@post

            val gatt = bluetoothGatt ?: return@post
            val rxChar = rxCharacteristic ?: return@post

            isWriting = true
            rxChar.value = chunk
            rxChar.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT

            val initiated = gatt.writeCharacteristic(rxChar)
            if (!initiated) {
                isWriting = false
                log("Failed to initiate characteristic write on BLE stack!")
                cancelAckTimeout()
                pendingSendCallback?.invoke(false, "Write failed on BLE stack")
                pendingSendCallback = null
            }
        }
    }

    private fun startAckTimeout() {
        cancelAckTimeout()
        ackTimeoutRunnable = Runnable {
            log("ACK timeout: No delivery confirmation received within 5.0 seconds.")
            pendingSendCallback?.invoke(false, "Delivery timeout (no ACK from Mac)")
            pendingSendCallback = null
            pendingMessageId = null
        }
        mainHandler.postDelayed(ackTimeoutRunnable!!, 5000)
    }

    private fun cancelAckTimeout() {
        ackTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        ackTimeoutRunnable = null
    }

    private fun handleAckNotification(jsonStr: String) {
        val ack = TandemAck.fromJsonString(jsonStr) ?: return
        if (ack.messageId == pendingMessageId) {
            cancelAckTimeout()
            if (ack.status == "delivered" && ack.code == 200) {
                log("SUCCESS: Mac confirmed delivery of message ${ack.messageId}")
                mainHandler.post {
                    pendingSendCallback?.invoke(true, "Delivered (Ack 200)")
                    pendingSendCallback = null
                    pendingMessageId = null
                }
            } else {
                log("FAILURE: Mac returned error: code=${ack.code}, error=${ack.error}")
                mainHandler.post {
                    pendingSendCallback?.invoke(false, "Error ${ack.code}: ${ack.error}")
                    pendingSendCallback = null
                    pendingMessageId = null
                }
            }
        }
    }
}
