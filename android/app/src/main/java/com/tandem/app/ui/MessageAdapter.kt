package com.tandem.app.ui

import android.graphics.BitmapFactory
import android.text.format.Formatter
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.core.content.ContextCompat
import androidx.recyclerview.widget.RecyclerView
import com.tandem.app.R
import com.tandem.app.ble.DeliveryStatus
import com.tandem.app.ble.MessageDirection
import com.tandem.app.ble.MessageRecord
import com.tandem.app.databinding.ItemMessageBinding
import java.io.File

class MessageAdapter : RecyclerView.Adapter<MessageAdapter.MessageViewHolder>() {

    private val messages = ArrayList<MessageRecord>()
    var onOpenFileClick: ((MessageRecord) -> Unit)? = null

    fun addMessage(record: MessageRecord) {
        messages.add(0, record)
        notifyItemInserted(0)
    }

    fun updateMessageStatus(messageId: String, status: DeliveryStatus, detail: String) {
        val index = messages.indexOfFirst { it.messageId == messageId }
        if (index != -1) {
            messages[index].status = status
            messages[index].statusDetail = detail
            if (status == DeliveryStatus.DELIVERED) {
                messages[index].progress = 100
            }
            notifyItemChanged(index)
        }
    }

    fun updateMessageProgress(messageId: String, progress: Int) {
        val index = messages.indexOfFirst { it.messageId == messageId }
        if (index != -1) {
            messages[index].progress = progress
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

        fun bind(item: MessageRecord) {
            val context = binding.root.context
            binding.tvMessageTimestamp.text = item.timestamp
            binding.tvMessageId.text = item.messageId.take(12)

            // 1. Sender Badge
            if (item.direction == MessageDirection.INCOMING) {
                binding.tvSenderBadge.text = "MacBook (BLE)"
                binding.tvSenderBadge.setTextColor(ContextCompat.getColor(context, R.color.accent_primary_light))
                binding.tvDeliveryBadge.text = "Received (Verified)"
                binding.tvDeliveryBadge.setTextColor(ContextCompat.getColor(context, R.color.accent_success))
                binding.cardMessageRoot.setBackgroundResource(R.drawable.bg_card)
            } else {
                binding.tvSenderBadge.text = "Tablet (You)"
                binding.tvSenderBadge.setTextColor(ContextCompat.getColor(context, R.color.accent_success))
                
                when (item.status) {
                    DeliveryStatus.DELIVERED -> {
                        binding.tvDeliveryBadge.text = "Delivered (Ack 200)"
                        binding.tvDeliveryBadge.setTextColor(ContextCompat.getColor(context, R.color.accent_success))
                    }
                    DeliveryStatus.PENDING -> {
                        val pct = item.progress
                        binding.tvDeliveryBadge.text = if (pct in 1..99) "Sending $pct%..." else "Sending..."
                        binding.tvDeliveryBadge.setTextColor(ContextCompat.getColor(context, R.color.accent_warning))
                    }
                    DeliveryStatus.FAILED -> {
                        binding.tvDeliveryBadge.text = if (item.statusDetail.isNotBlank()) "Failed: ${item.statusDetail}" else "Failed"
                        binding.tvDeliveryBadge.setTextColor(ContextCompat.getColor(context, R.color.accent_error))
                    }
                }
            }

            // 2. Message Content: Text vs File Attachment
            if (item.type == "file") {
                if (item.text.isNotBlank()) {
                    binding.tvMessagePayload.text = item.text
                    binding.tvMessagePayload.visibility = View.VISIBLE
                } else {
                    binding.tvMessagePayload.visibility = View.GONE
                }

                binding.layoutFileAttachment.visibility = View.VISIBLE
                val filename = item.fileName ?: "File Attachment"
                binding.tvFileName.text = filename

                val sizeStr = if (item.fileSize != null && item.fileSize > 0) {
                    Formatter.formatFileSize(context, item.fileSize)
                } else "Attachment"
                val shaStr = if (!item.sha256.isNullOrEmpty()) " • ✓ SHA-256 Verified" else ""
                binding.tvFileSize.text = "$sizeStr$shaStr"

                val isImage = item.mimeType?.startsWith("image/") == true ||
                    listOf("jpg", "jpeg", "png", "gif", "webp").any { filename.endsWith(it, ignoreCase = true) }
                binding.tvFileIcon.text = if (isImage) "🖼️" else "📄"

                // Load image thumbnail if image file exists locally
                val localPath = item.localFilePath
                if (isImage && localPath != null) {
                    val file = File(localPath)
                    if (file.exists()) {
                        try {
                            val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                            BitmapFactory.decodeFile(file.absolutePath, options)
                            val sampleSize = calculateInSampleSize(options, 400, 240)
                            val decodeOpts = BitmapFactory.Options().apply { inSampleSize = sampleSize }
                            val bmp = BitmapFactory.decodeFile(file.absolutePath, decodeOpts)
                            if (bmp != null) {
                                binding.ivAttachmentThumbnail.setImageBitmap(bmp)
                                binding.ivAttachmentThumbnail.visibility = View.VISIBLE
                            } else {
                                binding.ivAttachmentThumbnail.visibility = View.GONE
                            }
                        } catch (_: Exception) {
                            binding.ivAttachmentThumbnail.visibility = View.GONE
                        }
                    } else {
                        binding.ivAttachmentThumbnail.visibility = View.GONE
                    }
                } else {
                    binding.ivAttachmentThumbnail.visibility = View.GONE
                }

                // Transfer progress bar
                if (item.status == DeliveryStatus.PENDING && item.progress < 100) {
                    binding.pbTransferProgress.visibility = View.VISIBLE
                    binding.pbTransferProgress.progress = item.progress
                } else {
                    binding.pbTransferProgress.visibility = View.GONE
                }

                binding.btnOpenFile.setOnClickListener {
                    onOpenFileClick?.invoke(item)
                }
            } else {
                binding.tvMessagePayload.text = item.text
                binding.tvMessagePayload.visibility = View.VISIBLE
                binding.layoutFileAttachment.visibility = View.GONE
            }
        }

        private fun calculateInSampleSize(options: BitmapFactory.Options, reqWidth: Int, reqHeight: Int): Int {
            val (height: Int, width: Int) = options.run { outHeight to outWidth }
            var inSampleSize = 1
            if (height > reqHeight || width > reqWidth) {
                val halfHeight: Int = height / 2
                val halfWidth: Int = width / 2
                while (halfHeight / inSampleSize >= reqHeight && halfWidth / inSampleSize >= reqWidth) {
                    inSampleSize *= 2
                }
            }
            return inSampleSize
        }
    }
}
