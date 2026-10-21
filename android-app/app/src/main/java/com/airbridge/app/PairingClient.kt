package com.airbridge.app

import javax.net.ssl.SSLSocket
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

sealed interface PairingResult {
    data object Success : PairingResult
    data class Failure(val reason: String) : PairingResult
}

/**
 * One-shot pairing handshake: connect, send `pair_request` with the code shown on the Mac's
 * status-bar menu, store the issued token and the TLS certificate's pinned fingerprint on
 * success. See ../../../../docs/PROTOCOL.md.
 */
class PairingClient(private val store: PairingStore) {
    suspend fun pair(host: String, port: Int, code: String): PairingResult = withContext(Dispatchers.IO) {
        var capturedFingerprint: String? = null
        val socketFactory = buildTofuSocketFactory(pinnedFingerprint = null) { fingerprint ->
            capturedFingerprint = fingerprint
        }
        try {
            (socketFactory.createSocket(host, port) as SSLSocket).use { socket ->
                socket.startHandshake()
                writeMessage(socket.outputStream, WireMessage(type = "pair_request", code = code))
                val reply = FramedReader(socket.inputStream).readMessage()
                if (reply.type == "pair_response" && reply.ok == true && reply.token != null) {
                    store.host = host
                    store.port = port
                    store.token = reply.token
                    store.pinnedFingerprint = capturedFingerprint
                    PairingResult.Success
                } else {
                    PairingResult.Failure(reply.message ?: "Pairing rejected")
                }
            }
        } catch (error: Exception) {
            PairingResult.Failure(error.message ?: error.javaClass.simpleName)
        }
    }
}
