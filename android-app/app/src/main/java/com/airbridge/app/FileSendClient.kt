package com.airbridge.app

import javax.net.ssl.SSLSocket
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

sealed interface SendResult {
    data object Success : SendResult
    data class Failure(val reason: String) : SendResult
}

/**
 * Android -> Mac direction: opens its own short-lived connection to push one file, per
 * ../../../../docs/PROTOCOL.md. Deliberately a separate connection from the one
 * BridgeConnectionService holds open for receiving - sharing one connection for both
 * directions would reintroduce the read/write race the protocol doc explicitly rejected.
 */
class FileSendClient(private val store: PairingStore) {
    suspend fun send(filename: String, body: ByteArray): SendResult = withContext(Dispatchers.IO) {
        val host = store.host
        val port = store.port
        val token = store.token
        val pinnedFingerprint = store.pinnedFingerprint
        if (host == null || token == null || pinnedFingerprint == null) {
            return@withContext SendResult.Failure("Not paired with a Mac")
        }

        val socketFactory = buildTofuSocketFactory(pinnedFingerprint) { }
        try {
            (socketFactory.createSocket(host, port) as SSLSocket).use { socket ->
                socket.startHandshake()
                writeMessage(
                    socket.outputStream,
                    WireMessage(type = "file_push", token = token, filename = filename, bodyLength = body.size),
                )
                socket.outputStream.write(body)
                socket.outputStream.flush()
                val reply = FramedReader(socket.inputStream).readMessage()
                if (reply.type == "ack" && reply.ok == true) {
                    SendResult.Success
                } else {
                    SendResult.Failure(reply.message ?: "Send rejected")
                }
            }
        } catch (error: Exception) {
            SendResult.Failure(error.message ?: error.javaClass.simpleName)
        }
    }
}
