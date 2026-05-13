package com.rokidapks.glasses.spp

import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest

data class TransferStatistics(
    val totalBytes: Long,
    val totalChunks: Int,
    val elapsedTimeMs: Long,
    val retryCount: Int,
)

object SppPacketUtils {
    fun calculateMd5(file: File): ByteArray {
        val digest = MessageDigest.getInstance("MD5")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(16 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read <= 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest()
    }

    fun getChunkCount(totalBytes: Long): Int =
        ((totalBytes + SppTransferConstants.CHUNK_SIZE - 1) / SppTransferConstants.CHUNK_SIZE).toInt()
}
