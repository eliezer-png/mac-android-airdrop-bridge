package com.airbridge.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.provider.MediaStore
import android.util.Log
import javax.net.ssl.SSLSocket
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

private const val TAG = "BridgeConnectionService"
private const val CHANNEL_ID = "airbridge_connection"
private const val NOTIFICATION_ID = 1

/**
 * Holds the paired connection to the Mac agent open for as long as the app should be able to
 * receive pushed files - see ../../../../docs/PROTOCOL.md. v1 scope: this direction only
 * (Mac -> Android); it never writes to the socket itself except the `ack` reply.
 *
 * v1 limitation, stated plainly: if this connection drops (Mac restart, Wi-Fi blip, the
 * phone's own background/Doze policies), it stops and does not auto-reconnect - the user
 * re-opens the app to reconnect. Acceptable for a first working version, not for a polished one.
 */
class BridgeConnectionService : Service() {
    private val scope = CoroutineScope(Dispatchers.IO + Job())
    /// Guards against the real bug this was fixed for: MainActivity calls
    /// BridgeConnectionService.start() both after a fresh pairing and unconditionally in
    /// onCreate whenever already paired, so onStartCommand can fire more than once while a
    /// connection loop is still running (e.g. reopening the app). Without this guard, each
    /// call opened a second concurrent socket, and its `reconnect` handshake would make the
    /// Mac adopt it as the paired connection - cancelling the still-live first one mid-push,
    /// which surfaced as "Push failed... Operation canceled" on the Mac for every other send.
    private var connectionJob: Job? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, buildNotification("Connecting to Mac…"))
        if (connectionJob?.isActive != true) {
            connectionJob = scope.launch { runConnectionLoop() }
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        scope.cancel()
    }

    private fun runConnectionLoop() {
        val store = PairingStore(applicationContext)
        val host = store.host
        val port = store.port
        val token = store.token
        val pinnedFingerprint = store.pinnedFingerprint
        if (host == null || token == null || pinnedFingerprint == null) {
            Log.e(TAG, "Not paired - stopping")
            stopSelf()
            return
        }

        val socketFactory = buildTofuSocketFactory(pinnedFingerprint) {
            // Already paired - checkServerTrusted will reject a mismatch itself; this
            // callback only fires on a genuinely first-ever connection, which shouldn't
            // happen here since pinnedFingerprint is non-null.
        }

        try {
            (socketFactory.createSocket(host, port) as SSLSocket).use { socket ->
                socket.startHandshake()
                writeMessage(socket.outputStream, WireMessage(type = "reconnect", token = token))
                val reader = FramedReader(socket.inputStream)
                val handshakeReply = reader.readMessage()
                if (handshakeReply.type != "reconnect_ack" || handshakeReply.ok != true) {
                    Log.e(TAG, "Reconnect rejected: ${handshakeReply.message}")
                    stopSelf()
                    return
                }
                updateNotification("Connected to Mac")
                while (true) {
                    val header = reader.readMessage()
                    if (header.type != "file_push") continue
                    if (header.token != token) {
                        Log.e(TAG, "Rejected file_push with wrong token")
                        continue
                    }
                    val length = header.bodyLength ?: 0
                    val body = reader.readExactly(length)
                    val filename = header.filename ?: "received_file"
                    saveToDownloads(filename, body)
                    notifyFileReceived(filename)
                    writeMessage(socket.outputStream, WireMessage(type = "ack", ok = true))
                }
            }
        } catch (error: Exception) {
            Log.e(TAG, "Connection ended: ${error.message}", error)
        }
        stopSelf()
    }

    private fun saveToDownloads(filename: String, body: ByteArray) {
        val resolver = applicationContext.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, filename)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: run {
            Log.e(TAG, "Failed to create MediaStore entry for $filename")
            return
        }
        resolver.openOutputStream(uri)?.use { it.write(body) }
        values.clear()
        values.put(MediaStore.Downloads.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "AirBridge connection",
            NotificationManager.IMPORTANCE_LOW,
        )
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(text: String): Notification {
        val openAppIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("AirBridge")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentIntent(openAppIntent)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification(text: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(text))
    }

    private fun notifyFileReceived(filename: String) {
        val manager = getSystemService(NotificationManager::class.java)
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Received from Mac")
            .setContentText(filename)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .build()
        manager.notify(filename.hashCode(), notification)
    }

    companion object {
        fun start(context: Context) {
            val intent = Intent(context, BridgeConnectionService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }
}
