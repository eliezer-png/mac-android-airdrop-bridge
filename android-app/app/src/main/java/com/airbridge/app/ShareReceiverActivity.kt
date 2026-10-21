package com.airbridge.app

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch

/**
 * Entry point for "Send via Mac" in Android's share sheet (android.intent.action.SEND) - the
 * Android -> Mac direction. Reads the shared file fully into memory (acceptable for v1 - see
 * ../../../../docs/PROTOCOL.md's "Deliberately out of scope" list for why there's no
 * chunked/streaming transfer yet), uploads it to the paired Mac agent, which then opens the
 * native AirDrop picker for it via NSSharingService.
 */
class ShareReceiverActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val uri = sharedUri()
        if (uri == null) {
            toastAndFinish("AirBridge: no file in this share")
            return
        }

        val filename = queryDisplayName(uri) ?: "shared_file"
        val body = try {
            contentResolver.openInputStream(uri)?.use { it.readBytes() }
        } catch (error: Exception) {
            // The shared content can vanish between the share sheet handing us the URI and this
            // read (deleted file, revoked permission, stale URI from another app) - a normal,
            // user-reachable condition, not a reason to crash.
            null
        }
        if (body == null) {
            toastAndFinish("AirBridge: couldn't read the shared file")
            return
        }

        Toast.makeText(this, "AirBridge: sending to Mac…", Toast.LENGTH_SHORT).show()
        lifecycleScope.launch {
            val result = FileSendClient(PairingStore(applicationContext)).send(filename, body)
            when (result) {
                is SendResult.Success -> toastAndFinish("AirBridge: sent - saved to your Mac's Downloads")
                is SendResult.Failure -> toastAndFinish("AirBridge: send failed - ${result.reason}")
            }
        }
    }

    private fun sharedUri(): Uri? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }

    private fun queryDisplayName(uri: Uri): String? {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (index >= 0 && cursor.moveToFirst()) return cursor.getString(index)
        }
        return null
    }

    private fun toastAndFinish(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_LONG).show()
        finish()
    }
}
