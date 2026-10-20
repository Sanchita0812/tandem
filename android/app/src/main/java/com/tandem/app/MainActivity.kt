package com.tandem.app

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.provider.Settings
import android.text.Editable
import android.text.TextWatcher
import android.text.format.Formatter
import android.view.View
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.recyclerview.widget.LinearLayoutManager
import com.tandem.app.ble.BleConnectionState
import com.tandem.app.ble.BleProtocol
import com.tandem.app.ble.DeliveryStatus
import com.tandem.app.ble.DiscoveredDevice
import com.tandem.app.ble.MessageDirection
import com.tandem.app.ble.MessageRecord
import com.tandem.app.ble.TandemBleCentral
import com.tandem.app.databinding.ActivityMainBinding
import com.tandem.app.ui.DeviceAdapter
import com.tandem.app.ui.MessageAdapter
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding
    private lateinit var bleCentral: TandemBleCentral
    private lateinit var deviceAdapter: DeviceAdapter
    private lateinit var messageAdapter: MessageAdapter

    private val discoveredDevices = ArrayList<DiscoveredDevice>()

    // Pending file attachment state
    private var pendingAttachmentUri: Uri? = null
    private var pendingAttachmentName: String? = null
    private var pendingAttachmentSize: Long = 0L
    private var pendingAttachmentMime: String? = null

    private val filePickerLauncher = registerForActivityResult(ActivityResultContracts.GetContent()) { uri: Uri? ->
        if (uri != null) {
            handleSelectedAttachment(uri)
        }
    }

    companion object {
        private const val REQUEST_LOCATION_PERMISSION = 1001
        private const val REQUEST_ENABLE_BT = 1002
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        bleCentral = TandemBleCentral(this)
        setupUI()
        setupBleListeners()
        checkHardwareAndPermissions()
    }

    private fun setupUI() {
        // Discovered Devices RecyclerView
        deviceAdapter = DeviceAdapter { deviceItem ->
            bleCentral.connectToDevice(deviceItem.device)
        }
        binding.rvDiscoveredDevices.layoutManager = LinearLayoutManager(this)
        binding.rvDiscoveredDevices.adapter = deviceAdapter

        // Messages Feed RecyclerView
        messageAdapter = MessageAdapter()
        binding.rvMessagesFeed.layoutManager = LinearLayoutManager(this)
        binding.rvMessagesFeed.adapter = messageAdapter

        messageAdapter.onOpenFileClick = { item ->
            val path = item.localFilePath
            if (path != null) {
                val file = File(path)
                if (file.exists()) {
                    try {
                        val contentUri = FileProvider.getUriForFile(
                            this,
                            "$packageName.fileprovider",
                            file
                        )
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(contentUri, item.mimeType ?: "*/*")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivity(Intent.createChooser(intent, "Open file with"))
                    } catch (e: Exception) {
                        Toast.makeText(this, "Cannot open file: ${e.message}", Toast.LENGTH_SHORT).show()
                    }
                } else {
                    Toast.makeText(this, "File not found on device", Toast.LENGTH_SHORT).show()
                }
            }
        }

        // Scan Button
        binding.btnScan.setOnClickListener {
            if (binding.btnScan.text == getString(R.string.btn_stop_scan)) {
                bleCentral.stopScanning()
                binding.btnScan.text = getString(R.string.btn_scan)
            } else {
                if (ensureLocationPermissionAndGps()) {
                    discoveredDevices.clear()
                    deviceAdapter.updateDevices(discoveredDevices)
                    binding.layoutDiscoveredDevices.visibility = View.VISIBLE
                    bleCentral.startScanning()
                    binding.btnScan.text = getString(R.string.btn_stop_scan)
                }
            }
        }

        // Disconnect Button
        binding.btnDisconnect.setOnClickListener {
            bleCentral.disconnect()
        }

        // Attach File Button (v0.3)
        binding.btnAttachFile.setOnClickListener {
            filePickerLauncher.launch("*/*")
        }

        binding.btnRemoveAttachment.setOnClickListener {
            clearPendingAttachment()
        }

        // Message Input & Byte Counter
        binding.etMessageInput.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                val bytes = s?.toString()?.toByteArray(Charsets.UTF_8)?.size ?: 0
                if (pendingAttachmentUri == null) {
                    binding.tvCharCount.text = "$bytes bytes typed"
                }
            }
            override fun afterTextChanged(s: Editable?) {}
        })

        // Send Button
        binding.btnSend.setOnClickListener {
            val text = binding.etMessageInput.text.toString().trim()
            val uri = pendingAttachmentUri

            if (uri == null && text.isEmpty()) return@setOnClickListener

            val timeStr = SimpleDateFormat("HH:mm:ss", Locale.US).format(Date())

            if (uri != null) {
                // Send Offline File Attachment (v0.3)
                val fileName = pendingAttachmentName ?: "file"
                val mimeType = pendingAttachmentMime ?: "application/octet-stream"
                // Bounded stream read to prevent OutOfMemoryError on large files
                val maxAllowed = BleProtocol.MAX_PAYLOAD_BYTES
                val bytes: ByteArray? = try {
                    contentResolver.openInputStream(uri)?.use { stream ->
                        val buffer = java.io.ByteArrayOutputStream()
                        val chunk = ByteArray(8192)
                        var totalRead = 0
                        var n: Int
                        var exceeded = false
                        while (stream.read(chunk).also { n = it } != -1) {
                            totalRead += n
                            if (totalRead > maxAllowed) {
                                exceeded = true
                                break
                            }
                            buffer.write(chunk, 0, n)
                        }
                        if (exceeded) {
                            val mb = maxAllowed / (1024 * 1024)
                            Toast.makeText(this, "File exceeds $mb MB limit", Toast.LENGTH_LONG).show()
                            null
                        } else {
                            buffer.toByteArray()
                        }
                    }
                } catch (e: Exception) {
                    Toast.makeText(this, "Failed to read file: ${e.message}", Toast.LENGTH_SHORT).show()
                    null
                }

                if (bytes == null || bytes.isEmpty()) return@setOnClickListener

                val msgId = "file-and-" + UUID.randomUUID().toString().take(8)
                val record = MessageRecord(
                    messageId = msgId,
                    text = text,
                    timestamp = timeStr,
                    direction = MessageDirection.OUTGOING,
                    status = DeliveryStatus.PENDING,
                    type = "file",
                    fileName = fileName,
                    fileSize = bytes.size.toLong(),
                    mimeType = mimeType,
                    progress = 0
                )

                messageAdapter.addMessage(record)
                binding.tvEmptyMessages.visibility = View.GONE
                binding.rvMessagesFeed.visibility = View.VISIBLE

                binding.btnSend.isEnabled = false
                binding.btnAttachFile.isEnabled = false
                binding.pbSendProgress.visibility = View.VISIBLE
                binding.etMessageInput.setText("")
                clearPendingAttachment()

                bleCentral.sendFile(fileName, mimeType, bytes, onProgress = { pct ->
                    runOnUiThread {
                        messageAdapter.updateMessageProgress(msgId, (pct * 100).toInt())
                    }
                }) { success, detail ->
                    binding.btnSend.isEnabled = true
                    binding.btnAttachFile.isEnabled = true
                    binding.pbSendProgress.visibility = View.GONE

                    if (success) {
                        messageAdapter.updateMessageStatus(msgId, DeliveryStatus.DELIVERED, detail)
                        Toast.makeText(this, "File '$fileName' delivered to Mac!", Toast.LENGTH_SHORT).show()
                    } else {
                        messageAdapter.updateMessageStatus(msgId, DeliveryStatus.FAILED, detail)
                        Toast.makeText(this, "File delivery failed: $detail", Toast.LENGTH_LONG).show()
                    }
                }

            } else {
                // Send Regular Text Message
                val msgId = "msg-" + UUID.randomUUID().toString().take(12)
                val record = MessageRecord(
                    messageId = msgId,
                    text = text,
                    timestamp = timeStr,
                    direction = MessageDirection.OUTGOING,
                    status = DeliveryStatus.PENDING,
                    type = "text"
                )

                messageAdapter.addMessage(record)
                binding.tvEmptyMessages.visibility = View.GONE
                binding.rvMessagesFeed.visibility = View.VISIBLE

                binding.btnSend.isEnabled = false
                binding.pbSendProgress.visibility = View.VISIBLE
                binding.etMessageInput.setText("")

                bleCentral.sendMessage(text) { success, detail ->
                    binding.btnSend.isEnabled = true
                    binding.pbSendProgress.visibility = View.GONE

                    if (success) {
                        messageAdapter.updateMessageStatus(msgId, DeliveryStatus.DELIVERED, detail)
                        Toast.makeText(this, "Message delivered to Mac!", Toast.LENGTH_SHORT).show()
                    } else {
                        messageAdapter.updateMessageStatus(msgId, DeliveryStatus.FAILED, detail)
                        Toast.makeText(this, "Delivery failed: $detail", Toast.LENGTH_LONG).show()
                    }
                }
            }
        }

        // Clear Logs Button
        binding.btnClearLog.setOnClickListener {
            binding.tvDiagnosticLogs.text = ""
        }
    }

    private fun handleSelectedAttachment(uri: Uri) {
        try {
            var name = "attachment"
            var size = 0L
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (cursor.moveToFirst()) {
                    if (nameIndex != -1) name = cursor.getString(nameIndex)
                    if (sizeIndex != -1) size = cursor.getLong(sizeIndex)
                }
            }
            val mime = contentResolver.getType(uri) ?: "application/octet-stream"

            if (size > BleProtocol.MAX_PAYLOAD_BYTES) {
                val mb = BleProtocol.MAX_PAYLOAD_BYTES / (1024 * 1024)
                Toast.makeText(this, "File too large (Maximum $mb MB over BLE)", Toast.LENGTH_LONG).show()
                return
            }

            pendingAttachmentUri = uri
            pendingAttachmentName = name
            pendingAttachmentSize = size
            pendingAttachmentMime = mime

            binding.layoutAttachmentPreview.visibility = View.VISIBLE
            binding.tvAttachedFileName.text = name
            binding.tvAttachedFileSize.text = Formatter.formatFileSize(this, size)
            binding.btnSend.isEnabled = true
            binding.btnSend.text = "Send File"
        } catch (e: Exception) {
            Toast.makeText(this, "Failed to inspect file: ${e.message}", Toast.LENGTH_SHORT).show()
        }
    }

    private fun clearPendingAttachment() {
        pendingAttachmentUri = null
        pendingAttachmentName = null
        pendingAttachmentSize = 0L
        pendingAttachmentMime = null
        binding.layoutAttachmentPreview.visibility = View.GONE
        binding.btnSend.text = getString(R.string.btn_send)
    }

    private fun setupBleListeners() {
        bleCentral.onStateChanged = { state, detail ->
            binding.tvStatusLabel.text = state.label
            binding.tvSubStatusLabel.text = detail

            when (state) {
                BleConnectionState.CONNECTED_READY -> {
                    binding.viewStatusDot.setBackgroundResource(R.drawable.dot_green)
                    binding.btnDisconnect.isEnabled = true
                    binding.btnSend.isEnabled = true
                    binding.btnAttachFile.isEnabled = true
                    binding.btnScan.text = getString(R.string.btn_scan)
                    binding.layoutDiscoveredDevices.visibility = View.GONE
                }
                BleConnectionState.HANDSHAKE -> {
                    binding.viewStatusDot.setBackgroundResource(R.drawable.dot_amber)
                    binding.btnDisconnect.isEnabled = true
                    binding.btnSend.isEnabled = false
                    binding.btnAttachFile.isEnabled = false
                }
                BleConnectionState.SCANNING -> {
                    binding.viewStatusDot.setBackgroundResource(R.drawable.dot_amber)
                    binding.btnDisconnect.isEnabled = false
                    binding.btnSend.isEnabled = false
                    binding.btnAttachFile.isEnabled = false
                    binding.btnScan.text = getString(R.string.btn_stop_scan)
                }
                BleConnectionState.CONNECTING, BleConnectionState.DISCOVERING_SERVICES -> {
                    binding.viewStatusDot.setBackgroundResource(R.drawable.dot_amber)
                    binding.btnDisconnect.isEnabled = true
                    binding.btnSend.isEnabled = false
                    binding.btnAttachFile.isEnabled = false
                }
                BleConnectionState.IDLE, BleConnectionState.DISCONNECTED -> {
                    binding.viewStatusDot.setBackgroundResource(R.drawable.dot_amber)
                    binding.btnDisconnect.isEnabled = false
                    binding.btnSend.isEnabled = false
                    binding.btnAttachFile.isEnabled = false
                    binding.btnScan.text = getString(R.string.btn_scan)
                    binding.layoutSecurityBadge.visibility = View.GONE
                }
                BleConnectionState.ERROR -> {
                    binding.viewStatusDot.setBackgroundResource(R.drawable.dot_red)
                    binding.btnDisconnect.isEnabled = false
                    binding.btnSend.isEnabled = false
                    binding.btnAttachFile.isEnabled = false
                    binding.btnScan.text = getString(R.string.btn_scan)
                    binding.layoutSecurityBadge.visibility = View.GONE
                }
            }
        }

        bleCentral.onSecurityCodeGenerated = { sas ->
            if (sas != null) {
                binding.layoutSecurityBadge.visibility = View.VISIBLE
                binding.tvSecurityCode.text = "🔒 E2EE Active (AES-256-GCM) • Code: $sas"
            } else {
                binding.layoutSecurityBadge.visibility = View.GONE
            }
        }

        bleCentral.onMessageReceived = { msg ->
            val timeStr = SimpleDateFormat("HH:mm:ss", Locale.US).format(Date())
            val record = MessageRecord(
                messageId = msg.messageId,
                text = msg.payload,
                timestamp = timeStr,
                direction = MessageDirection.INCOMING,
                status = DeliveryStatus.DELIVERED,
                type = "text"
            )
            messageAdapter.addMessage(record)
            binding.tvEmptyMessages.visibility = View.GONE
            binding.rvMessagesFeed.visibility = View.VISIBLE
            Toast.makeText(this, "Message from Mac received!", Toast.LENGTH_SHORT).show()
        }

        bleCentral.onFileReceived = { msg, file ->
            val timeStr = SimpleDateFormat("HH:mm:ss", Locale.US).format(Date())
            val record = MessageRecord(
                messageId = msg.messageId,
                text = "",
                timestamp = timeStr,
                direction = MessageDirection.INCOMING,
                status = DeliveryStatus.DELIVERED,
                type = "file",
                fileName = msg.fileName ?: file.name,
                fileSize = msg.fileSize ?: file.length(),
                mimeType = msg.mimeType,
                localFilePath = file.absolutePath,
                sha256 = msg.sha256
            )
            messageAdapter.addMessage(record)
            binding.tvEmptyMessages.visibility = View.GONE
            binding.rvMessagesFeed.visibility = View.VISIBLE
            Toast.makeText(this, "File '${file.name}' received from Mac!", Toast.LENGTH_SHORT).show()
        }

        bleCentral.onTransferProgress = { msgId, progress ->
            messageAdapter.updateMessageProgress(msgId, (progress * 100).toInt())
        }

        bleCentral.onDeviceDiscovered = { deviceItem ->
            if (discoveredDevices.none { it.address == deviceItem.address }) {
                if (deviceItem.name.contains("TandemMac", ignoreCase = true)) {
                    discoveredDevices.add(0, deviceItem)
                } else {
                    discoveredDevices.add(deviceItem)
                }
                deviceAdapter.updateDevices(discoveredDevices)
            }
        }

        bleCentral.onLog = { logMsg ->
            binding.tvDiagnosticLogs.append(logMsg + "\n")
        }
    }

    // MARK: - Permissions & Hardware Checks for Android 10 (API 29)

    private fun checkHardwareAndPermissions() {
        if (!bleCentral.isBluetoothEnabled) {
            val enableBtIntent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)
            startActivityForResult(enableBtIntent, REQUEST_ENABLE_BT)
        }

        val advSupported = bleCentral.isPeripheralModeSupported
        binding.tvDiagnosticLogs.append("[Hardware] BLE Central: Supported • Multiple Advertisement: $advSupported\n")
    }

    private fun ensureLocationPermissionAndGps(): Boolean {
        val hasPermission = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

        if (!hasPermission) {
            if (ActivityCompat.shouldShowRequestPermissionRationale(this, Manifest.permission.ACCESS_FINE_LOCATION)) {
                AlertDialog.Builder(this)
                    .setTitle("Location Permission Required")
                    .setMessage(getString(R.string.location_permission_rationale))
                    .setPositiveButton("Grant") { _, _ ->
                        ActivityCompat.requestPermissions(
                            this,
                            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION),
                            REQUEST_LOCATION_PERMISSION
                        )
                    }
                    .setNegativeButton("Cancel", null)
                    .show()
            } else {
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(Manifest.permission.ACCESS_FINE_LOCATION),
                    REQUEST_LOCATION_PERMISSION
                )
            }
            return false
        }

        val locationManager = getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        val isGpsEnabled = locationManager?.isProviderEnabled(LocationManager.GPS_PROVIDER) == true ||
                locationManager?.isProviderEnabled(LocationManager.NETWORK_PROVIDER) == true

        if (!isGpsEnabled) {
            AlertDialog.Builder(this)
                .setTitle("Enable Location Services")
                .setMessage(getString(R.string.location_services_disabled_prompt))
                .setPositiveButton("Open Settings") { _, _ ->
                    startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS))
                }
                .setNegativeButton("Cancel", null)
                .show()
            return false
        }

        return true
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_LOCATION_PERMISSION) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                Toast.makeText(this, "Location permission granted for BLE scanning", Toast.LENGTH_SHORT).show()
                binding.btnScan.performClick()
            } else {
                Toast.makeText(this, "Location permission denied; BLE scanning cannot discover devices.", Toast.LENGTH_LONG).show()
            }
        }
    }
}
