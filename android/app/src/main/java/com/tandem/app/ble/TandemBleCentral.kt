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
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.util.Base64
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
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
    var onFileReceived: ((TandemMessage, File) -> Unit)? = null
    var onTransferProgress: ((String, Float) -> Unit)? = null
    var onSecurityCodeGenerated: ((String?) -> Unit)? = null
    var onLog: ((String) -> Unit)? = null

    // Outgoing write queue and pending ACKs
    private val writeQueue = ConcurrentLinkedQueue<ByteArray>()
    private var isWriting = false
    private var pendingSendCallback: ((Boolean, String) -> Unit)? = null
    private var pendingProgressCallback: ((Float) -> Unit)? = null
    private var pendingMessageId: String? = null
    private var totalChunksCount = 0
    private var sentChunksCount = 0
    private var ackTimeoutRunnable: Runnable? = null

    // Anti-replay and deduplication cache (SEC-04 / SEC-07)
    private val recentMessageIds = java.util.Collections.synchronizedList(mutableListOf<String>())
    private val maxRecentIds = 64

    val isBluetoothEnabled: Boolean
        get() = bluetoothAdapter?.isEnabled == true

    val isPeripheralModeSupported: Boolean
        get() = bluetoothAdapter?.isMultipleAdvertisementSupported == true

    private fun log(message: String) {
        val timestamp = BleProtocol.currentIsoTimestamp().substringAfter("T").substringBefore("Z")
        val formatted = "[$timestamp] $message"
        android.util.Log.d("TandemBleCentral", formatted)
        mainHandler.post { onLog?.invoke(formatted) }
    }

    private fun updateState(state: BleConnectionState, detail: String) {
        currentState = state
        log("State changed: ${state.label} - $detail")
        mainHandler.post { onStateChanged?.invoke(state, detail) }
    }

    // MARK: - Scanning & Connection

    fun startScanning() {
        val adapter = bluetoothAdapter
        if (adapter == null || !adapter.isEnabled) {
            updateState(BleConnectionState.ERROR, "Bluetooth is disabled")
            log("Cannot start scan: Bluetooth adapter unavailable or turned off.")
            return
        }

        val scanner = adapter.bluetoothLeScanner
        if (scanner == null) {
            updateState(BleConnectionState.ERROR, "BLE Scanner unavailable")
            return
        }

        if (isScanning) {
            log("Scan already running.")
            return
        }

        isScanning = true
        updateState(BleConnectionState.SCANNING, "Searching for TandemMac...")

        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        scanner.startScan(null, settings, scanCallback)
        log("BLE scan started with SCAN_MODE_LOW_LATENCY.")

        mainHandler.postDelayed({
            if (isScanning) {
                stopScanning()
                if (currentState == BleConnectionState.SCANNING) {
                    updateState(BleConnectionState.IDLE, "Scan timed out (12s).")
                }
            }
        }, 12000)
    }

    fun stopScanning() {
        if (!isScanning) return
        isScanning = false
        try {
            bluetoothAdapter?.bluetoothLeScanner?.stopScan(scanCallback)
            log("BLE scan stopped.")
        } catch (e: Exception) {
            log("Error stopping scan: ${e.message}")
        }
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult?) {
            result ?: return
            val device = result.device
            val name = result.scanRecord?.deviceName ?: device.name ?: "Unknown BLE Device"
            val address = device.address ?: "00:00:00:00:00:00"
            val rssi = result.rssi

            val serviceUuids = result.scanRecord?.serviceUuids
            val hasTandemUuid = serviceUuids?.any { it.uuid == BleProtocol.SERVICE_UUID } == true
            val isTandemNamed = name.contains("Tandem", ignoreCase = true)

            if (hasTandemUuid || isTandemNamed) {
                log("Found candidate device: $name ($address, RSSI: $rssi dBm)")
                val discovered = DiscoveredDevice(device, name, address, rssi)
                mainHandler.post { onDeviceDiscovered?.invoke(discovered) }
            }
        }

        override fun onScanFailed(errorCode: Int) {
            isScanning = false
            log("BLE Scan failed with errorCode: $errorCode")
            updateState(BleConnectionState.ERROR, "Scan failed: code $errorCode")
        }
    }

    fun connectToDevice(device: BluetoothDevice) {
        stopScanning()
        updateState(BleConnectionState.CONNECTING, "Connecting to ${device.name ?: device.address}...")
        log("Initiating GATT connection to ${device.address} (autoConnect=false, TRANSPORT_LE)...")

        bluetoothGatt = device.connectGatt(
            context,
            false,
            gattCallback,
            BluetoothDevice.TRANSPORT_LE
        )
    }

    fun disconnect() {
        log("Disconnecting from GATT server...")
        cancelAckTimeout()
        writeQueue.clear()
        isWriting = false
        pendingSendCallback = null
        pendingProgressCallback = null
        pendingMessageId = null

        try {
            bluetoothGatt?.disconnect()
            bluetoothGatt?.close()
            bluetoothGatt = null
            rxCharacteristic = null
            txCharacteristic = null
            negotiatedMtu = 23
            TandemCrypto.resetKeypair()
            recentMessageIds.clear()
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
                    sentChunksCount++
                    if (totalChunksCount > 0) {
                        val pct = sentChunksCount.toFloat() / totalChunksCount.toFloat()
                        pendingProgressCallback?.invoke(pct)
                        pendingMessageId?.let { onTransferProgress?.invoke(it, pct) }
                    }

                    if (writeQueue.isEmpty()) {
                        log("All $totalChunksCount chunks written to GATT. Awaiting delivery ACK from Mac...")
                        startAckTimeout(15000L)
                    } else {
                        processNextWrite()
                    }
                } else {
                    log("Characteristic write failed with status: $status")
                    cancelAckTimeout()
                    pendingSendCallback?.invoke(false, "Write failed with status $status")
                    pendingSendCallback = null
                    pendingProgressCallback = null
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
                        if (isDuplicateOrReplay(innerMsg)) {
                            sendDirectAck(innerMsg.messageId)
                            return
                        }
                        if (innerMsg.type == "file") {
                            handleIncomingFile(innerMsg)
                        } else {
                            log("🔒 Valid Encrypted Message Received from Mac: id=${innerMsg.messageId}, bytes=${innerMsg.payload.toByteArray().size}")
                            mainHandler.post {
                                onMessageReceived?.invoke(innerMsg)
                            }
                            sendDirectAck(innerMsg.messageId)
                        }
                    }
                }
                "text" -> {
                    if (TandemCrypto.isEncrypted) {
                        log("SECURITY REJECT: Received unencrypted plaintext message while E2EE session is active.")
                        return
                    }
                    val msg = TandemMessage.fromJsonString(jsonStr)
                    if (msg != null) {
                        if (isDuplicateOrReplay(msg)) {
                            sendDirectAck(msg.messageId)
                            return
                        }
                        log("Valid Message Received from Mac: id=${msg.messageId}, bytes=${msg.payload.toByteArray().size}")
                        mainHandler.post {
                            onMessageReceived?.invoke(msg)
                        }
                        sendDirectAck(msg.messageId)
                    }
                }
                "file" -> {
                    if (TandemCrypto.isEncrypted) {
                        log("SECURITY REJECT: Received unencrypted plaintext file while E2EE session is active.")
                        return
                    }
                    val msg = TandemMessage.fromJsonString(jsonStr)
                    if (msg != null) {
                        if (isDuplicateOrReplay(msg)) {
                            sendDirectAck(msg.messageId)
                            return
                        }
                        handleIncomingFile(msg)
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

    private fun sanitizeFilename(raw: String, fallbackId: String): String {
        var cleaned = File(raw).name
        cleaned = cleaned.replace("[^a-zA-Z0-9._-]".toRegex(), "_")
        cleaned = cleaned.replace("^\\.+".toRegex(), "")
        if (cleaned.isEmpty() || cleaned == "." || cleaned == "..") {
            cleaned = "tandem_$fallbackId.bin"
        }
        if (cleaned.length > 120) {
            val ext = cleaned.substringAfterLast('.', "")
            val base = cleaned.substringBeforeLast('.')
            cleaned = if (ext.isNotEmpty()) "${base.take(110)}.$ext" else base.take(120)
        }
        return cleaned
    }

    private fun getUniqueDestinationFile(dir: File, safeName: String): File {
        var file = File(dir, safeName)
        if (!file.exists()) return file

        val nameWithoutExt = safeName.substringBeforeLast('.')
        val ext = safeName.substringAfterLast('.', "")
        val extSuffix = if (ext.isNotEmpty()) ".$ext" else ""

        var counter = 1
        while (file.exists() && counter < 1000) {
            file = File(dir, "${nameWithoutExt}_$counter$extSuffix")
            counter++
        }
        return file
    }

    private fun handleIncomingFile(message: TandemMessage) {
        try {
            val rawBytes = Base64.decode(message.payload, Base64.DEFAULT)
            val computedSha = computeSha256(rawBytes)
            if (!message.sha256.isNullOrEmpty() && !computedSha.equals(message.sha256, ignoreCase = true)) {
                log("SECURITY REJECT: SHA-256 checksum mismatch! Computed: $computedSha, Expected: ${message.sha256}")
                sendDirectAck(message.messageId, status = "error", code = 400, error = "SHA-256 mismatch")
                return
            }
            log("✓ SHA-256 Verified for incoming file: $computedSha")

            val rawName = message.fileName ?: "tandem_${message.messageId}"
            val safeName = sanitizeFilename(rawName, message.messageId.take(8))

            val tandemDir = File(context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), "Tandem")
            if (!tandemDir.exists()) tandemDir.mkdirs()

            val destFile = getUniqueDestinationFile(tandemDir, safeName)
            destFile.writeBytes(rawBytes)
            log("📁 File saved safely: ${destFile.absolutePath} (${rawBytes.size} bytes)")

            mainHandler.post {
                onFileReceived?.invoke(message, destFile)
                onMessageReceived?.invoke(message)
            }
            sendDirectAck(message.messageId)
        } catch (e: Exception) {
            log("FILE ERROR: Failed to save incoming file: ${e.message}")
            sendDirectAck(message.messageId, status = "error", code = 500, error = "Save failed: ${e.message}")
        }
    }

    private fun isDuplicateOrReplay(msg: TandemMessage): Boolean {
        try {
            val sdf = java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", java.util.Locale.US)
            sdf.timeZone = java.util.TimeZone.getTimeZone("UTC")
            val cleanTimestamp = msg.timestamp.substringBefore('.').substringBefore('Z')
            val msgDate = sdf.parse(cleanTimestamp)
            if (msgDate != null) {
                val drift = Math.abs(System.currentTimeMillis() - msgDate.time)
                if (drift > 600_000L) {
                    log("SECURITY REJECT: Message timestamp drift ${drift / 1000}s exceeds 10-minute anti-replay window.")
                    return true
                }
            }
        } catch (_: Exception) {}

        synchronized(recentMessageIds) {
            if (recentMessageIds.contains(msg.messageId)) {
                log("Ignoring duplicate messageId: ${msg.messageId}")
                return true
            }
            recentMessageIds.add(msg.messageId)
            if (recentMessageIds.size > maxRecentIds) {
                recentMessageIds.removeAt(0)
            }
        }
        return false
    }

    private fun sendDirectAck(messageId: String, status: String = "delivered", code: Int = 200, error: String? = null) {
        val ack = TandemAck(
            messageId = messageId,
            status = status,
            code = code,
            error = error
        )
        val ackBytes = ack.toJsonString().toByteArray(Charsets.UTF_8)
        val maxChunkCapacity = (negotiatedMtu - 3).coerceAtLeast(20)
        val chunks = ChunkFramer.framePayload(ackBytes, messageId, maxChunkCapacity)
        log("Sending delivery ACK to Mac for message: $messageId (${chunks.size} chunks, status=$status)")
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
        pendingProgressCallback = null

        val maxChunkCapacity = (negotiatedMtu - 3).coerceAtLeast(20)
        val chunks = ChunkFramer.framePayload(jsonPayload, msgId, maxChunkCapacity)

        log("Enqueueing message $msgId (${jsonPayload.size} bytes across ${chunks.size} chunks)...")
        totalChunksCount = chunks.size
        sentChunksCount = 0

        writeQueue.addAll(chunks)
        processNextWrite()
    }

    // MARK: - Outgoing File & Attachment Transmission (v0.3)

    fun sendFile(
        fileName: String,
        mimeType: String,
        fileBytes: ByteArray,
        onProgress: ((Float) -> Unit)? = null,
        onResult: (Boolean, String) -> Unit
    ) {
        val gatt = bluetoothGatt
        val rxChar = rxCharacteristic
        if (gatt == null || rxChar == null || currentState != BleConnectionState.CONNECTED_READY) {
            onResult(false, "Not connected to Mac")
            return
        }

        if (fileBytes.isEmpty()) {
            onResult(false, "Cannot send empty file")
            return
        }

        if (fileBytes.size > BleProtocol.MAX_PAYLOAD_BYTES) {
            val mb = BleProtocol.MAX_PAYLOAD_BYTES / (1024 * 1024)
            onResult(false, "File exceeds $mb MB size limit")
            return
        }

        val msgId = "file-and-" + UUID.randomUUID().toString().take(8)
        val timestamp = BleProtocol.currentIsoTimestamp()
        val sha256Hex = computeSha256(fileBytes)
        val b64Payload = Base64.encodeToString(fileBytes, Base64.NO_WRAP)

        val innerMsg = TandemMessage(
            version = BleProtocol.PROTOCOL_VERSION,
            type = "file",
            messageId = msgId,
            timestamp = timestamp,
            sender = "android",
            payload = b64Payload,
            fileName = fileName,
            fileSize = fileBytes.size.toLong(),
            mimeType = mimeType,
            sha256 = sha256Hex
        )

        val envelope: TandemMessage
        if (TandemCrypto.isEncrypted) {
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
            envelope = innerMsg
        }

        val jsonPayload = envelope.toJsonString().toByteArray(Charsets.UTF_8)
        val maxChunkCapacity = (negotiatedMtu - 3).coerceAtLeast(20)
        val chunks = ChunkFramer.framePayload(jsonPayload, msgId, maxChunkCapacity)

        log("Enqueueing outbound file '$fileName' (${fileBytes.size} bytes across ${chunks.size} chunks)...")
        pendingMessageId = msgId
        pendingSendCallback = onResult
        pendingProgressCallback = onProgress
        totalChunksCount = chunks.size
        sentChunksCount = 0

        writeQueue.addAll(chunks)
        processNextWrite()
    }

    private fun computeSha256(bytes: ByteArray): String {
        val md = MessageDigest.getInstance("SHA-256")
        val digest = md.digest(bytes)
        return digest.joinToString("") { "%02x".format(it) }
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
                pendingProgressCallback = null
            }
        }
    }

    private fun startAckTimeout(timeoutMs: Long = 10000L) {
        cancelAckTimeout()
        ackTimeoutRunnable = Runnable {
            log("ACK timeout: No delivery confirmation received within ${timeoutMs / 1000} seconds.")
            pendingSendCallback?.invoke(false, "Delivery timeout (no ACK from Mac)")
            pendingSendCallback = null
            pendingProgressCallback = null
            pendingMessageId = null
        }
        mainHandler.postDelayed(ackTimeoutRunnable!!, timeoutMs)
    }

    private fun cancelAckTimeout() {
        ackTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        ackTimeoutRunnable = null
    }

    private fun handleAckNotification(jsonStr: String) {
        val ack = TandemAck.fromJsonString(jsonStr) ?: return
        if (ack.messageId == pendingMessageId) {
            cancelAckTimeout()
            pendingProgressCallback?.invoke(1.0f)
            if (ack.status == "delivered" && ack.code == 200) {
                log("SUCCESS: Mac confirmed delivery of message ${ack.messageId}")
                mainHandler.post {
                    pendingSendCallback?.invoke(true, "Delivered (Ack 200)")
                    pendingSendCallback = null
                    pendingProgressCallback = null
                    pendingMessageId = null
                }
            } else {
                log("FAILURE: Mac returned error: code=${ack.code}, error=${ack.error}")
                mainHandler.post {
                    pendingSendCallback?.invoke(false, "Error ${ack.code}: ${ack.error}")
                    pendingSendCallback = null
                    pendingProgressCallback = null
                    pendingMessageId = null
                }
            }
        }
    }
}
