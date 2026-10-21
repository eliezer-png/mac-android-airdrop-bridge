package com.airbridge.app

import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.X509TrustManager

/**
 * Trust-on-first-use, like an SSH host key: the first connection accepts whatever certificate
 * the Mac agent presents and pins its fingerprint via [onFirstUse]; every connection after that
 * must present the exact same fingerprint or the handshake is rejected.
 *
 * No mDNS-distributed fingerprint is needed in advance - this pins directly off the TLS
 * handshake itself, which is why pairing works over a manually-entered IP with no mDNS
 * dependency on the critical path (see ../../../../docs/PROTOCOL.md and
 * ../../../../docs/ARCHITECTURE.md's note on this network's multicast behavior).
 */
class TofuTrustManager(
    private val pinnedFingerprint: String?,
    private val onFirstUse: (String) -> Unit,
) : X509TrustManager {
    override fun checkClientTrusted(chain: Array<out X509Certificate>, authType: String) {
        throw CertificateException("Client certificates are not used by this protocol")
    }

    override fun checkServerTrusted(chain: Array<out X509Certificate>, authType: String) {
        val presented = fingerprint(chain[0])
        if (pinnedFingerprint == null) {
            onFirstUse(presented)
            return
        }
        if (!presented.equals(pinnedFingerprint, ignoreCase = true)) {
            throw CertificateException(
                "Mac agent's certificate fingerprint changed (was it re-paired or reinstalled?). " +
                    "Re-pair to trust the new certificate."
            )
        }
    }

    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()

    companion object {
        fun fingerprint(certificate: X509Certificate): String {
            val digest = MessageDigest.getInstance("SHA-256").digest(certificate.encoded)
            return digest.joinToString("") { "%02x".format(it) }
        }
    }
}
