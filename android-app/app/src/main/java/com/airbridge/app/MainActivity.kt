package com.airbridge.app

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * v1 scope: pairing UI and discovery-state display only. See
 * ../../../../docs/PROTOCOL.md and ARCHITECTURE.md for what's implemented vs. deferred.
 */
class MainActivity : ComponentActivity() {
    private val discovery by lazy { AirBridgeDiscovery(applicationContext) }
    private lateinit var pairingStore: PairingStore
    private val requestNotificationPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pairingStore = PairingStore(applicationContext)
        requestNotificationPermissionIfNeeded()

        setContent {
            var foundAgents by remember { mutableStateOf(listOf<DiscoveredAgent>()) }
            var hostInput by remember { mutableStateOf(pairingStore.host ?: "") }
            var codeInput by remember { mutableStateOf("") }
            var statusText by remember { mutableStateOf(if (pairingStore.isPaired) "Paired" else "Not paired") }
            val coroutineScope = rememberCoroutineScope()

            LaunchedEffect(Unit) {
                discovery.startBrowsing { agent ->
                    foundAgents = foundAgents + agent
                    if (hostInput.isEmpty()) hostInput = agent.address.hostAddress ?: ""
                }
            }

            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    Column(
                        modifier = Modifier.fillMaxSize().padding(24.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text("AirBridge", style = MaterialTheme.typography.headlineMedium)
                        Text("Status: $statusText")
                        Text("Looking for Mac agent on the LAN (mDNS, best-effort)…")
                        if (foundAgents.isEmpty()) {
                            Text("(none found via mDNS - enter the Mac's address manually below " +
                                "if your network doesn't relay mDNS between devices)")
                        } else {
                            foundAgents.forEach { agent ->
                                Text("Found: ${agent.name} — ${agent.address.hostAddress}:${agent.port}")
                            }
                        }

                        OutlinedTextField(
                            value = hostInput,
                            onValueChange = { hostInput = it },
                            label = { Text("Mac IP address") },
                            modifier = Modifier.fillMaxWidth(),
                        )
                        OutlinedTextField(
                            value = codeInput,
                            onValueChange = { codeInput = it },
                            label = { Text("Pairing code (shown on the Mac)") },
                            modifier = Modifier.fillMaxWidth(),
                        )
                        Button(onClick = {
                            coroutineScope.launch {
                                statusText = "Pairing…"
                                val result = PairingClient(pairingStore).pair(hostInput, 47835, codeInput)
                                statusText = when (result) {
                                    is PairingResult.Success -> {
                                        BridgeConnectionService.start(applicationContext)
                                        "Paired - connected"
                                    }
                                    is PairingResult.Failure -> "Pairing failed: ${result.reason}"
                                }
                            }
                        }) {
                            Text("Pair")
                        }
                    }
                }
            }
        }

        if (pairingStore.isPaired) {
            BridgeConnectionService.start(applicationContext)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        CoroutineScope(Dispatchers.IO).launch { discovery.stop() }
    }

    /// On API 33+, POST_NOTIFICATIONS is a runtime permission; without requesting it, Android
    /// defaults the app's notification importance to NONE, which on this Samsung device also
    /// silently swallows Toasts (not just notifications) - the actual cause of "it's not
    /// working" reports where the transfer succeeded but nothing visible happened.
    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            requestNotificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }
}
