package com.tandem.app.ui

import android.view.LayoutInflater
import android.view.ViewGroup
import androidx.recyclerview.widget.RecyclerView
import com.tandem.app.ble.DiscoveredDevice
import com.tandem.app.databinding.ItemDeviceBinding

class DeviceAdapter(
    private val onConnectClick: (DiscoveredDevice) -> Unit
) : RecyclerView.Adapter<DeviceAdapter.DeviceViewHolder>() {

    private val devices = ArrayList<DiscoveredDevice>()

    fun updateDevices(newDevices: List<DiscoveredDevice>) {
        devices.clear()
        devices.addAll(newDevices)
        notifyDataSetChanged()
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): DeviceViewHolder {
        val binding = ItemDeviceBinding.inflate(LayoutInflater.from(parent.context), parent, false)
        return DeviceViewHolder(binding)
    }

    override fun onBindViewHolder(holder: DeviceViewHolder, position: Int) {
        holder.bind(devices[position])
    }

    override fun getItemCount(): Int = devices.size

    inner class DeviceViewHolder(private val binding: ItemDeviceBinding) :
        RecyclerView.ViewHolder(binding.root) {

        fun bind(item: DiscoveredDevice) {
            binding.tvDeviceName.text = item.name
            binding.tvDeviceAddress.text = "${item.address} • ${item.rssi} dBm"
            binding.btnConnectDevice.setOnClickListener {
                onConnectClick(item)
            }
        }
    }
}
