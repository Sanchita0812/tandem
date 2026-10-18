package com.tandem.app.ui

import android.graphics.Color
import android.view.LayoutInflater
import android.view.ViewGroup
import androidx.core.content.ContextCompat
import androidx.recyclerview.widget.RecyclerView
import com.tandem.app.R
import com.tandem.app.ble.DeliveryStatus
import com.tandem.app.ble.SentMessageRecord
import com.tandem.app.databinding.ItemMessageBinding

class MessageAdapter : RecyclerView.Adapter<MessageAdapter.MessageViewHolder>() {

    private val messages = ArrayList<SentMessageRecord>()

    fun addMessage(record: SentMessageRecord) {
        messages.add(0, record)
        notifyItemInserted(0)
    }

    fun updateMessageStatus(messageId: String, status: DeliveryStatus, detail: String) {
        val index = messages.indexOfFirst { it.messageId == messageId }
        if (index != -1) {
            messages[index].status = status
            messages[index].statusDetail = detail
            notifyItemChanged(index)
        }
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): MessageViewHolder {
        val binding = ItemMessageBinding.inflate(LayoutInflater.from(parent.context), parent, false)
        return MessageViewHolder(binding)
    }

    override fun onBindViewHolder(holder: MessageViewHolder, position: Int) {
        holder.bind(messages[position])
    }

    override fun getItemCount(): Int = messages.size

    inner class MessageViewHolder(private val binding: ItemMessageBinding) :
        RecyclerView.ViewHolder(binding.root) {

        fun bind(item: SentMessageRecord) {
            binding.tvMessagePayload.text = item.text
            binding.tvMessageTimestamp.text = item.timestamp
            binding.tvMessageId.text = item.messageId.take(12)

            when (item.status) {
                DeliveryStatus.DELIVERED -> {
                    binding.tvDeliveryBadge.text = "Delivered (Ack 200)"
                    binding.tvDeliveryBadge.setTextColor(ContextCompat.getColor(binding.root.context, R.color.accent_success))
                }
                DeliveryStatus.PENDING -> {
                    binding.tvDeliveryBadge.text = "Sending..."
                    binding.tvDeliveryBadge.setTextColor(ContextCompat.getColor(binding.root.context, R.color.accent_warning))
                }
                DeliveryStatus.FAILED -> {
                    binding.tvDeliveryBadge.text = if (item.statusDetail.isNotBlank()) "Failed: ${item.statusDetail}" else "Failed"
                    binding.tvDeliveryBadge.setTextColor(ContextCompat.getColor(binding.root.context, R.color.accent_error))
                }
            }
        }
    }
}
