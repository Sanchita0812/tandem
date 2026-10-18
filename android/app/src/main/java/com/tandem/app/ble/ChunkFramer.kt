package com.tandem.app.ble

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap

object ChunkFramer {

    private val incomingBuffers = ConcurrentHashMap<Long, MutableMap<Int, ByteArray>>()
    private val bufferDeadlines = ConcurrentHashMap<Long, Long>()

    /**
     * Splits payload bytes into framed BLE chunks if payload exceeds maxChunkSize.
     * Header layout (11 bytes):
     * [0]: Magic (0xAA single, 0xAB multi, 0xAC final)
     * [1]: Sequence index (0..total-1)
     * [2]: Total chunks
     * [3..10]: 8-byte message hash
     * [11..N]: Payload chunk
     */
    fun framePayload(payload: ByteArray, messageId: String, maxChunkSize: Int): List<ByteArray> {
        val usableChunkCapacity = (maxChunkSize - 11).coerceAtLeast(10)
        
        // If payload fits comfortably in one write without framing, return single framed packet
        if (payload.size <= usableChunkCapacity) {
            val packet = ByteArray(11 + payload.size)
            packet[0] = BleProtocol.MAGIC_SINGLE
            packet[1] = 0 // seq
            packet[2] = 1 // total
            val hashBytes = getHashBytes(messageId)
            System.arraycopy(hashBytes, 0, packet, 3, 8)
            System.arraycopy(payload, 0, packet, 11, payload.size)
            return listOf(packet)
        }

        val totalChunks = (payload.size + usableChunkCapacity - 1) / usableChunkCapacity
        val chunks = ArrayList<ByteArray>(totalChunks)
        val hashBytes = getHashBytes(messageId)

        var offset = 0
        for (i in 0 until totalChunks) {
            val length = (payload.size - offset).coerceAtMost(usableChunkCapacity)
            val packet = ByteArray(11 + length)
            packet[0] = if (i == totalChunks - 1) BleProtocol.MAGIC_FINAL else BleProtocol.MAGIC_MULTI
            packet[1] = i.toByte()
            packet[2] = totalChunks.toByte()
            System.arraycopy(hashBytes, 0, packet, 3, 8)
            System.arraycopy(payload, offset, packet, 11, length)
            chunks.add(packet)
            offset += length
        }

        return chunks
    }

    /**
     * Reassembles incoming notifications from Mac into a complete payload.
     */
    fun processIncomingPacket(packet: ByteArray): ByteArray? {
        if (packet.isEmpty()) return null
        val firstByte = packet[0]

        // Direct JSON string (starts with '{')
        if (firstByte == '{'.code.toByte()) {
            return packet
        }

        // Single binary framed packet
        if (firstByte == BleProtocol.MAGIC_SINGLE && packet.size > 11) {
            val payload = ByteArray(packet.size - 11)
            System.arraycopy(packet, 11, payload, 0, payload.size)
            return payload
        }

        // Multi-chunk frame
        if ((firstByte == BleProtocol.MAGIC_MULTI || firstByte == BleProtocol.MAGIC_FINAL) && packet.size >= 11) {
            val seqIndex = packet[1].toInt() and 0xFF
            val totalChunks = packet[2].toInt() and 0xFF
            if (totalChunks <= 0 || totalChunks > 64 || seqIndex < 0 || seqIndex >= totalChunks) {
                return null
            }

            val buffer = ByteBuffer.wrap(packet, 3, 8).order(ByteOrder.LITTLE_ENDIAN)
            val hashValue = buffer.long
            val chunkLen = packet.size - 11
            val chunkData = ByteArray(chunkLen)
            System.arraycopy(packet, 11, chunkData, 0, chunkLen)

            // Purge expired buffers (5 second timeout)
            val now = System.currentTimeMillis()
            bufferDeadlines.entries.removeIf { it.value < now }
            incomingBuffers.keys.retainAll(bufferDeadlines.keys)

            val chunkMap = incomingBuffers.computeIfAbsent(hashValue) {
                bufferDeadlines[hashValue] = now + 5000L
                ConcurrentHashMap()
            }
            chunkMap[seqIndex] = chunkData

            if (chunkMap.size == totalChunks) {
                var totalBytes = 0
                for (i in 0 until totalChunks) {
                    totalBytes += chunkMap[i]?.size ?: 0
                }
                val fullPayload = ByteArray(totalBytes)
                var destPos = 0
                for (i in 0 until totalChunks) {
                    val c = chunkMap[i] ?: return null
                    System.arraycopy(c, 0, fullPayload, destPos, c.size)
                    destPos += c.size
                }
                incomingBuffers.remove(hashValue)
                bufferDeadlines.remove(hashValue)
                return fullPayload
            }
            return null
        }

        return packet
    }

    private fun getHashBytes(messageId: String): ByteArray {
        val hash = messageId.hashCode().toLong()
        val buffer = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN)
        buffer.putLong(hash)
        return buffer.array()
    }
}
