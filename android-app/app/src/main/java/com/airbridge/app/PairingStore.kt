package com.airbridge.app

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * Stores the paired Mac agent's address, the pinned TLS certificate fingerprint (set on first
 * connect - trust-on-first-use, like an SSH host key), and the token issued at pairing. Backed
 * by EncryptedSharedPreferences since the token is a real credential.
 */
class PairingStore(context: Context) {
    private val prefs = run {
        val masterKey = MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
        EncryptedSharedPreferences.create(
            context,
            "airbridge_pairing",
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    var host: String?
        get() = prefs.getString("host", null)
        set(value) = prefs.edit().putString("host", value).apply()

    var port: Int
        get() = prefs.getInt("port", 47835)
        set(value) = prefs.edit().putInt("port", value).apply()

    var pinnedFingerprint: String?
        get() = prefs.getString("pinned_fingerprint", null)
        set(value) = prefs.edit().putString("pinned_fingerprint", value).apply()

    var token: String?
        get() = prefs.getString("token", null)
        set(value) = prefs.edit().putString("token", value).apply()

    val isPaired: Boolean
        get() = host != null && pinnedFingerprint != null && token != null

    fun clear() {
        prefs.edit().clear().apply()
    }
}
