package com.tandem.app

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Bundle
import android.provider.Settings
import android.text.Editable
import android.text.TextWatcher
import android.view.View
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.recyclerview.widget.LinearLayoutManager
import com.tandem.app.ble.BleConnectionState
import com.tandem.app.ble.BleProtocol
import com.tandem.app.ble.DeliveryStatus
import com.tandem.app.ble.DiscoveredDevice
import com.tandem.app.ble.MessageDirection
import com.tandem.app.ble.MessageRecord
import com.tandem.app.ble.SentMessageRecord
import com.tandem.app.ble.TandemBleCentral
import com.tandem.app.databinding.ActivityMainBinding
import com.tandem.app.ui.DeviceAdapter
import com.tandem.app.ui.MessageAdapter
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
            bleCentral.connect(deviceItem.device)
        }
        binding.rvDiscoveredDevices.layoutManager = LinearLayoutManager(this)
        binding.rvDiscoveredDevices.adapter = deviceAdapter

        // Messages Feed RecyclerView
        messageAdapter = MessageAdapter()
        binding.rvMessagesFeed.layoutManager = LinearLayoutManager(this)
        binding.rvMessagesFeed.adapter = messageAdapter

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

        // Message Input & Byte Counter
        binding.etMessageInput.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                val bytes = s?.toString()?.toByteArray(Charsets.UTF_8)?.size ?: 0
                binding.tvCharCount.text = "$bytes / ${BleProtocol.MAX_PAYLOAD_BYTES} bytes"
            }
            override fun afterTextChanged(s: Editable?) {}
        })

        // Send Button
        binding.btnSend.setOnClickListener {
            val text = binding.etMessageInput.text.toString().trim()
            if (text.isEmpty()) return@setOnClickListener

            val msgId = "msg-" + UUID.randomUUID().toString().take(12)
            val timeStr = SimpleDateFormat("HH:mm:ss", Locale.US).format(Date())

            val record = SentMessageRecord(
                messageId = msgId,
                text = text,
                timestamp = timeStr,
                status = DeliveryStatus.PENDING
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

        // Clear Logs Button
        binding.btnClearLog.setOnClickListener {
            binding.tvDiagnosticLogs.text = ""
        }
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
                    binding.btnScan.text = getString(R.string.btn_scan)
                    binding.layoutDiscoveredDevices.visibility = View.GONE
                }
                BleConnectionState.HANDSHAKE -> {
                    binding.viewStatusDot.setBackgroundResource(R.drawable.dot_amber)
                    binding.btnDisconnect.isEnabled = true
                    binding.btnSend.isEnabled = false
                }
                BleConnectionState.SCANNING -> {
                    binding.viewStatusDot.setBackgroundResource(R.drawable.dot_amber)
                    binding.btnDisconnect.isEnabled = false
                    binding.btnSend.isEnabled = false
                    binding.btnScan.text = getString(R.string.btn_stop_scan)
                }
                BleConnectionState.CONNECTING, BleConnectionState.DISCOVERING_SERVICES -> {
                    binding.viewStatusDot.setBackgroundResource(R.drawable.dot_amber)
                    binding.btnDisconnect.isEnabled = true
                    binding.btnSend.isEnabled = false
                }
                BleConnectionState.IDLE, BleConnectionState.DISCONNECTED -> {
                    binding.viewStatusDot.setBackgroundResource(R.drawable.dot_amber)
                    binding.btnDisconnect.isEnabled = false
                    binding.btnSend.isEnabled = false
                    binding.btnScan.text = getString(R.string.btn_scan)
                    binding.layoutSecurityBadge.visibility = View.GONE
                }
                BleConnectionState.ERROR -> {
                    binding.viewStatusDot.setBackgroundResource(R.drawable.dot_red)
                    binding.btnDisconnect.isEnabled = false
                    binding.btnSend.isEnabled = false
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
                status = DeliveryStatus.DELIVERED
            )
            messageAdapter.addMessage(record)
            binding.tvEmptyMessages.visibility = View.GONE
            binding.rvMessagesFeed.visibility = View.VISIBLE
            Toast.makeText(this, "Message from Mac received!", Toast.LENGTH_SHORT).show()
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
        // 1. Check ACCESS_FINE_LOCATION runtime permission (Mandatory on Android 10 for BLE scan)
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

        // 2. Check System Location Services (GPS) toggle on Android 10
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
