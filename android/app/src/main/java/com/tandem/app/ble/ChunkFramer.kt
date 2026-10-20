package com.tandem.app.ble

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap

object ChunkFramer {

    private const val MAX_PENDING_STREAMS = 2
    private const val MAX_GLOBAL_BUFFER_BYTES = 8 * 1024 * 1024 // 8 MB global reassembly ceiling

    private val incomingBuffers = ConcurrentHashMap<Long, MutableMap<Int, ByteArray>>()
    private val bufferDeadlines = ConcurrentHashMap<Long, Long>()
    private val bufferTotals = ConcurrentHashMap<Long, Int>()

    private fun getGlobalPendingBytes(): Int {
        var sum = 0
        for (map in incomingBuffers.values) {
            for (arr in map.values) {
                sum += arr.size
            }
        }
        return sum
    }

    /**
     * Splits payload bytes into framed BLE chunks respecting maxChunkSize.
     * Uses classic 11-byte header for <= 64 chunks, or extended 13-byte header for > 64 chunks.
     */
    fun framePayload(payload: ByteArray, messageId: String, maxChunkSize: Int): List<ByteArray> {
        val hashBytes = getHashBytes(messageId)
        val usableClassic = (maxChunkSize - 11).coerceAtLeast(10)

        // Single packet
        if (payload.size <= usableClassic) {
            val packet = ByteArray(11 + payload.size)
            packet[0] = BleProtocol.MAGIC_SINGLE
            packet[1] = 0 // seq
            packet[2] = 1 // total
            System.arraycopy(hashBytes, 0, packet, 3, 8)
            System.arraycopy(payload, 0, packet, 11, payload.size)
            return listOf(packet)
        }

        val classicChunksCount = (payload.size + usableClassic - 1) / usableClassic
        if (classicChunksCount <= 64) {
            // Classic 11-byte framing
            val chunks = ArrayList<ByteArray>(classicChunksCount)
            var offset = 0
            for (i in 0 until classicChunksCount) {
                val length = (payload.size - offset).coerceAtMost(usableClassic)
                val packet = ByteArray(11 + length)
                packet[0] = if (i == classicChunksCount - 1) BleProtocol.MAGIC_FINAL else BleProtocol.MAGIC_MULTI
                packet[1] = i.toByte()
                packet[2] = classicChunksCount.toByte()
                System.arraycopy(hashBytes, 0, packet, 3, 8)
                System.arraycopy(payload, offset, packet, 11, length)
                chunks.add(packet)
                offset += length
            }
            return chunks
        }

        // Extended 13-byte framing for large files (up to 65,535 chunks)
        val usableExtended = (maxChunkSize - 13).coerceAtLeast(10)
        val totalChunks = (payload.size + usableExtended - 1) / usableExtended
        val chunks = ArrayList<ByteArray>(totalChunks)
        var offset = 0

        for (i in 0 until totalChunks) {
            val length = (payload.size - offset).coerceAtMost(usableExtended)
            val packet = ByteArray(13 + length)
            packet[0] = if (i == totalChunks - 1) BleProtocol.MAGIC_EXT_FINAL else BleProtocol.MAGIC_EXT_MULTI
            
            // 16-bit seq (Big Endian)
            packet[1] = ((i shr 8) and 0xFF).toByte()
            packet[2] = (i and 0xFF).toByte()

            // 16-bit total (Big Endian)
            packet[3] = ((totalChunks shr 8) and 0xFF).toByte()
            packet[4] = (totalChunks and 0xFF).toByte()

            System.arraycopy(hashBytes, 0, packet, 5, 8)
            System.arraycopy(payload, offset, packet, 13, length)
            chunks.add(packet)
            offset += length
        }

        return chunks
    }

    /**
     * Reassembles incoming notifications from Mac into a complete payload.
     * Supports classic 11-byte and extended 13-byte framing.
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

        val isClassic = (firstByte == BleProtocol.MAGIC_MULTI || firstByte == BleProtocol.MAGIC_FINAL)
        val isExtended = (firstByte == BleProtocol.MAGIC_EXT_MULTI || firstByte == BleProtocol.MAGIC_EXT_FINAL)

        if (isClassic || isExtended) {
            val seqIndex: Int
            val totalChunks: Int
            val hashValue: Long
            val chunkLen: Int
            val chunkOffset: Int

            if (isClassic) {
                if (packet.size < 11) return null
                seqIndex = packet[1].toInt() and 0xFF
                totalChunks = packet[2].toInt() and 0xFF
                val buffer = ByteBuffer.wrap(packet, 3, 8).order(ByteOrder.LITTLE_ENDIAN)
                hashValue = buffer.long
                chunkOffset = 11
                chunkLen = packet.size - 11
            } else {
                if (packet.size < 13) return null
                seqIndex = ((packet[1].toInt() and 0xFF) shl 8) or (packet[2].toInt() and 0xFF)
                totalChunks = ((packet[3].toInt() and 0xFF) shl 8) or (packet[4].toInt() and 0xFF)
                val buffer = ByteBuffer.wrap(packet, 5, 8).order(ByteOrder.LITTLE_ENDIAN)
                hashValue = buffer.long
                chunkOffset = 13
                chunkLen = packet.size - 13
            }

            if (totalChunks <= 0 || totalChunks > 65535 || seqIndex < 0 || seqIndex >= totalChunks || chunkLen <= 0) {
                return null
            }

            val chunkData = ByteArray(chunkLen)
            System.arraycopy(packet, chunkOffset, chunkData, 0, chunkLen)

            // Purge expired buffers (15 second timeout per active transfer)
            val now = System.currentTimeMillis()
            bufferDeadlines.entries.removeIf { it.value < now }
            incomingBuffers.keys.retainAll(bufferDeadlines.keys)
            bufferTotals.keys.retainAll(bufferDeadlines.keys)

            val existingTotal = bufferTotals[hashValue]
            if (existingTotal != null && existingTotal != totalChunks) {
                // Reject mid-stream chunk total mutation
                return null
            }

            if (!incomingBuffers.containsKey(hashValue) && incomingBuffers.size >= MAX_PENDING_STREAMS) {
                // Buffer stream ceiling reached
                return null
            }

            if (getGlobalPendingBytes() + chunkLen > MAX_GLOBAL_BUFFER_BYTES) {
                // Global reassembly heap ceiling exceeded; drop chunk to prevent OOM
                return null
            }

            bufferTotals.putIfAbsent(hashValue, totalChunks)
            val chunkMap = incomingBuffers.computeIfAbsent(hashValue) {
                ConcurrentHashMap()
            }
            // Refresh deadline on each chunk received
            bufferDeadlines[hashValue] = now + 15000L
            chunkMap[seqIndex] = chunkData

            if (chunkMap.size == totalChunks) {
                var totalBytes = 0
                for (i in 0 until totalChunks) {
                    totalBytes += chunkMap[i]?.size ?: 0
                }
                if (totalBytes > BleProtocol.MAX_PAYLOAD_BYTES) {
                    incomingBuffers.remove(hashValue)
                    bufferDeadlines.remove(hashValue)
                    bufferTotals.remove(hashValue)
                    return null
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
                bufferTotals.remove(hashValue)
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
