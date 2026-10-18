package com.tandem.app.ble

import java.nio.ByteBuffer
import java.nio.ByteOrder

object ChunkFramer {

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

    private fun getHashBytes(messageId: String): ByteArray {
        val hash = messageId.hashCode().toLong()
        val buffer = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN)
        buffer.putLong(hash)
        return buffer.array()
    }
}
