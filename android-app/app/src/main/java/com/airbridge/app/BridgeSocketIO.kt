package com.airbridge.app

import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream
import java.security.SecureRandom
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

/** Builds an SSLSocketFactory that trusts only the pinned (or first-seen) certificate. */
fun buildTofuSocketFactory(pinnedFingerprint: String?, onFirstUse: (String) -> Unit): SSLSocketFactory {
    val trustManager = TofuTrustManager(pinnedFingerprint, onFirstUse)
    val context = SSLContext.getInstance("TLS")
    context.init(null, arrayOf(trustManager), SecureRandom())
    return context.socketFactory
}

/**
 * Reads the line-delimited JSON header + raw body framing described in
 * ../../../../docs/PROTOCOL.md, buffering only as much as needed (not the whole stream) so
 * this works for large file bodies too.
 */
class FramedReader(private val input: InputStream) {
    private var pending = ByteArray(0)

    fun readMessage(): WireMessage {
        val line = readLine()
        return WireMessage.fromJson(line)
    }

    fun readExactly(count: Int): ByteArray {
        val result = ByteArray(count)
        var filled = 0
        if (pending.isNotEmpty()) {
            val fromPending = minOf(pending.size, count)
            pending.copyInto(result, 0, 0, fromPending)
            filled = fromPending
            pending = pending.copyOfRange(fromPending, pending.size)
        }
        while (filled < count) {
            val chunk = ByteArray(minOf(65536, count - filled))
            val read = input.read(chunk)
            if (read < 0) throw EOFException("Connection closed mid-body")
            chunk.copyInto(result, filled, 0, read)
            filled += read
        }
        return result
    }

    private fun readLine(): String {
        val buffer = StringBuilder()
        while (true) {
            if (pending.isNotEmpty()) {
                val newlineIndex = pending.indexOf(0x0A.toByte())
                if (newlineIndex >= 0) {
                    buffer.append(String(pending, 0, newlineIndex, Charsets.UTF_8))
                    pending = pending.copyOfRange(newlineIndex + 1, pending.size)
                    return buffer.toString()
                }
                buffer.append(String(pending, Charsets.UTF_8))
                pending = ByteArray(0)
            }
            val chunk = ByteArray(4096)
            val read = input.read(chunk)
            if (read < 0) throw EOFException("Connection closed mid-header")
            pending = chunk.copyOfRange(0, read)
        }
    }
}

fun writeMessage(output: OutputStream, message: WireMessage) {
    output.write(message.toJsonLine().toByteArray(Charsets.UTF_8))
    output.flush()
}

private fun ByteArray.indexOf(byte: Byte): Int {
    for (index in indices) if (this[index] == byte) return index
    return -1
}
