package com.airbridge.app

import android.content.Context
import android.net.wifi.WifiManager
import android.util.Log
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import javax.jmdns.JmDNS
import javax.jmdns.ServiceEvent
import javax.jmdns.ServiceInfo
import javax.jmdns.ServiceListener
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private const val TAG = "AirBridgeDiscovery"

/** Our own Bonjour service type - nothing to do with Apple's _airdrop._tcp. */
private const val SERVICE_TYPE = "_airbridge._tcp.local."

data class DiscoveredAgent(
    val name: String,
    val address: InetAddress,
    val port: Int,
)

/** First non-loopback IPv4 address of an up network interface, or null if none is found. */
private fun localIPv4Address(): InetAddress? =
    NetworkInterface.getNetworkInterfaces().asSequence()
        .filter { it.isUp && !it.isLoopback }
        .flatMap { it.inetAddresses.asSequence() }
        .filterIsInstance<Inet4Address>()
        .firstOrNull()

/**
 * Finds the macOS bridge agent on the LAN via our own mDNS service type, and holds the
 * MulticastLock required to actually receive mDNS traffic on Android.
 *
 * Phase 2 scope: discovery only. Phase 3 wires this into the paired, authenticated transfer
 * client - see ../../../bridge/docs/ARCHITECTURE.md.
 */
class AirBridgeDiscovery(private val context: Context) {
    private var jmdns: JmDNS? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    /**
     * JmDNS.create() and service registration do blocking network I/O, so this suspends and
     * runs on Dispatchers.IO - callers (e.g. a Composable's LaunchedEffect, which runs on the
     * Main dispatcher by default) do not need to manage that themselves.
     */
    suspend fun startBrowsing(onAgentFound: (DiscoveredAgent) -> Unit) {
        withContext(Dispatchers.IO) {
            val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val lock = wifiManager.createMulticastLock(TAG).apply {
                setReferenceCounted(true)
                acquire()
            }
            multicastLock = lock

            val address = localIPv4Address()
                ?: error("No active non-loopback IPv4 interface found - is Wi-Fi connected?")
            val instance = JmDNS.create(address, TAG)
            jmdns = instance

            instance.addServiceListener(
                SERVICE_TYPE,
                object : ServiceListener {
                    override fun serviceAdded(event: ServiceEvent) {
                        instance.requestServiceInfo(event.type, event.name)
                    }

                    override fun serviceResolved(event: ServiceEvent) {
                        val info: ServiceInfo = event.info
                        val hostAddress = info.inetAddresses.firstOrNull() ?: return
                        Log.i(TAG, "Found agent: ${info.name} at $hostAddress:${info.port}")
                        onAgentFound(DiscoveredAgent(info.name, hostAddress, info.port))
                    }

                    override fun serviceRemoved(event: ServiceEvent) {
                        Log.i(TAG, "Agent disappeared: ${event.name}")
                    }
                }
            )
        }
    }

    suspend fun stop() {
        withContext(Dispatchers.IO) {
            jmdns?.close()
        }
        jmdns = null
        multicastLock?.release()
        multicastLock = null
    }
}
