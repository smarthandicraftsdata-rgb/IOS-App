@file:Suppress("SpellCheckingInspection")

package com.example.shlamp

import android.Manifest
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.shlamp.ui.theme.SHLampDesign
import com.example.shlamp.ui.theme.SHLAMPTheme
import java.util.concurrent.Executors

internal data class DiagnosticCheck(
    val label: String,
    val passed: Boolean,
    val detail: String,
    val neutralWhenFailed: Boolean = false
)

class ConnectionDiagnosticsActivity : ComponentActivity() {
    private val handler = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private lateinit var manager: LampConnectionManager

    private val api by lazy { CloudApiClient() }
    private val vault by lazy { CloudTokenVault(this) }
    private val sessions by lazy { CloudSessionManager(vault, api) }

    private val lampId by lazy { intent.getStringExtra(EXTRA_LAMP_ID).orEmpty() }
    private val requestedRemoteLampId by lazy {
        intent.getStringExtra(EXTRA_REMOTE_LAMP_ID).orEmpty().trim().uppercase()
    }

    private fun remoteLampId(): String = requestedRemoteLampId
        .ifBlank { manager.remoteLampIdFor(lampId).orEmpty() }
        .trim()
        .uppercase()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        manager = LampConnectionManager(this, handler)
        setContent {
            SHLAMPTheme {
                DiagnosticsScreen(
                    lampId = lampId,
                    remoteLampId = remoteLampId(),
                    onBack = { finish() },
                    onRun = ::runChecks
                )
            }
        }
    }

    override fun onStart() {
        super.onStart()
        manager.start()
        manager.selectLamp(lampId, connectBle = true)
    }

    override fun onStop() {
        manager.stop()
        super.onStop()
    }

    override fun onDestroy() {
        manager.close()
        worker.shutdownNow()
        super.onDestroy()
    }

    private fun runChecks(callback: (List<DiagnosticCheck>) -> Unit) {
        if (lampId.isBlank()) {
            callback(
                listOf(
                    DiagnosticCheck(
                        "Lamp selection",
                        false,
                        "No lamp was selected for this check. Return to Devices or Care and run diagnostics again."
                    )
                )
            )
            return
        }

        val initial = mutableListOf<DiagnosticCheck>()
        val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val bluetoothPermission = hasBluetoothPermissions()
        initial += DiagnosticCheck(
            "Nearby permission",
            bluetoothPermission,
            if (bluetoothPermission) "Allowed" else "Allow Nearby devices to use Bluetooth."
        )
        initial += DiagnosticCheck(
            "Phone Bluetooth",
            bluetoothManager.adapter?.isEnabled == true,
            if (bluetoothManager.adapter?.isEnabled == true) {
                "Bluetooth is on"
            } else {
                "Bluetooth is off. This is acceptable when Wi-Fi or Remote control is available."
            },
            neutralWhenFailed = true
        )

        val connectivity = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = connectivity.activeNetwork
        val capabilities = network?.let { connectivity.getNetworkCapabilities(it) }
        val hasWifi = capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        val hasInternet = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
        initial += DiagnosticCheck(
            "Phone Wi-Fi",
            hasWifi,
            if (hasWifi) "Connected to Wi-Fi" else "The phone is not on Wi-Fi. Bluetooth or Remote control may still work.",
            neutralWhenFailed = true
        )
        initial += DiagnosticCheck(
            "Phone internet",
            hasInternet,
            if (hasInternet) "Internet is available" else "Internet is unavailable. Nearby control can still work.",
            neutralWhenFailed = true
        )

        manager.diagnoseLamp(lampId) { local ->
            val localChecks = initial.toMutableList()
            localChecks += DiagnosticCheck(
                "Saved nearby lamp",
                local.hasSavedBluetooth || local.hasLocalAddress,
                if (local.hasSavedBluetooth || local.hasLocalAddress) "This phone recognizes the lamp" else local.message,
                neutralWhenFailed = true
            )
            localChecks += DiagnosticCheck(
                "Bluetooth link",
                local.bluetoothConnected,
                if (local.bluetoothConnected) "Lamp is connected through Bluetooth" else "Bluetooth is available as a nearby fallback but is not active now.",
                neutralWhenFailed = true
            )
            localChecks += DiagnosticCheck(
                "Local Wi-Fi response",
                local.localWifiReachable,
                if (local.localWifiReachable) "Lamp responded on the phone's current Wi-Fi" else "Local Wi-Fi is not active on this phone network.",
                neutralWhenFailed = true
            )

            val cloudId = remoteLampId()
            if (cloudId.isBlank()) {
                localChecks += DiagnosticCheck(
                    "Remote identity",
                    false,
                    "No permanent cloud Lamp ID is attached to this saved lamp. Nearby control may still work.",
                    neutralWhenFailed = true
                )
                runOnUiThread { callback(localChecks) }
                return@diagnoseLamp
            }

            localChecks += DiagnosticCheck(
                "Remote identity",
                true,
                "$lampId is linked to $cloudId"
            )

            worker.execute {
                var accountAuthenticated = false
                var accountUserId: String? = null
                val exactDeviceResult = runCatching {
                    sessions.execute { token ->
                        val me = api.readMe(token)
                        if (me.unauthorized) throw UnauthorizedException()
                        accountAuthenticated = me.user != null
                        accountUserId = me.user?.id
                        api.readDevice(token, cloudId)
                    }
                }
                val exactDevice = exactDeviceResult.getOrNull()

                localChecks += DiagnosticCheck(
                    "Account authentication",
                    accountAuthenticated,
                    if (accountAuthenticated) {
                        "The signed-in account was authenticated by the cloud."
                    } else {
                        "The cloud could not authenticate the current session."
                    }
                )
                localChecks += DiagnosticCheck(
                    "Lamp ownership",
                    exactDevice != null,
                    when {
                        exactDevice != null -> "The account can access $cloudId."
                        exactDeviceResult.exceptionOrNull() is UnauthorizedException ->
                            "The account session expired. Sign in again."
                        else ->
                            "The account could not read $cloudId. It may be linked to another account or the cloud request failed: ${exactDeviceResult.exceptionOrNull()?.message ?: "unknown error"}"
                    }
                )
                localChecks += DiagnosticCheck(
                    "ESP remote connection",
                    exactDevice?.online == true,
                    when {
                        exactDevice == null -> "Remote status cannot be checked until ownership is confirmed."
                        exactDevice.online -> "ESP32 is connected to the cloud and Remote commands can be delivered now."
                        else -> "The lamp belongs to the account, but the ESP32 cloud socket is offline. Check its serial cloud/WebSocket status."
                    }
                )
                runOnUiThread {
                    if (exactDevice != null) {
                        manager.syncCloudLamps(listOf(exactDevice), accountUserId)
                        manager.markCloudOwnership(exactDevice.id, accountUserId)
                    }
                    callback(localChecks)
                }
            }
        }
    }

    private fun hasBluetoothPermissions(): Boolean {
        val permissions = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }
        return permissions.all { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
    }

    companion object {
        const val EXTRA_LAMP_ID = "lamp_id"
        const val EXTRA_REMOTE_LAMP_ID = "remote_lamp_id"
        const val EXTRA_CLAIMED = "claimed"
        const val EXTRA_CLOUD_ONLINE = "cloud_online"
    }
}

@Composable
private fun DiagnosticsScreen(
    lampId: String,
    remoteLampId: String,
    onBack: () -> Unit,
    onRun: ((List<DiagnosticCheck>) -> Unit) -> Unit
) {
    var checks by remember { mutableStateOf<List<DiagnosticCheck>>(emptyList()) }
    var running by remember { mutableStateOf(false) }

    fun run() {
        running = true
        checks = emptyList()
        onRun {
            checks = it
            running = false
        }
    }

    LaunchedEffect(Unit) { run() }

    Scaffold(containerColor = SHLampDesign.Background) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .statusBarsPadding()
                .navigationBarsPadding()
                .verticalScroll(rememberScrollState())
                .padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                TextButton(onClick = onBack) { Text("Back", color = SHLampDesign.Primary) }
                Text("Connection Check", fontSize = 23.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.size(48.dp))
            }

            Card(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(22.dp),
                colors = CardDefaults.cardColors(containerColor = SHLampDesign.Surface)
            ) {
                Column(Modifier.padding(18.dp)) {
                    Text("Lamp", color = SHLampDesign.TextSecondary)
                    Text(lampId, fontWeight = FontWeight.Bold, fontSize = 18.sp)
                    if (remoteLampId.isNotBlank() && !remoteLampId.equals(lampId, ignoreCase = true)) {
                        Text(
                            "Remote ID: $remoteLampId",
                            color = SHLampDesign.TextSecondary,
                            style = MaterialTheme.typography.bodySmall
                        )
                    }
                    Text(
                        "This check tests the phone, nearby routes and account connection without showing technical error codes.",
                        color = SHLampDesign.TextSecondary,
                        style = MaterialTheme.typography.bodySmall
                    )
                }
            }

            if (running) {
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(18.dp),
                    colors = CardDefaults.cardColors(containerColor = SHLampDesign.PrimarySoft)
                ) {
                    Row(
                        modifier = Modifier.padding(16.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(20.dp),
                            strokeWidth = 2.dp,
                            color = SHLampDesign.Primary
                        )
                        Spacer(Modifier.size(10.dp))
                        Text("Checking connections…", fontWeight = FontWeight.SemiBold)
                    }
                }
            }

            checks.forEach { check ->
                DiagnosticCheckCard(check)
            }

            if (!running && checks.isNotEmpty()) {
                val controlRouteLabels = setOf(
                    "Bluetooth link",
                    "Local Wi-Fi response",
                    "ESP remote connection"
                )
                val routeWorking = checks.any { it.passed && it.label in controlRouteLabels }
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(18.dp),
                    colors = CardDefaults.cardColors(
                        containerColor = if (routeWorking) {
                            SHLampDesign.SuccessSoft
                        } else {
                            SHLampDesign.WarmSoft
                        }
                    )
                ) {
                    Text(
                        if (routeWorking) {
                            "Lamp control is available. Backup routes shown as inactive are normal."
                        } else {
                            "No lamp-control route responded. Check Bluetooth, local Wi-Fi and remote status."
                        },
                        modifier = Modifier.padding(16.dp),
                        color = SHLampDesign.TextPrimary,
                        fontWeight = FontWeight.SemiBold
                    )
                }
                Button(
                    onClick = { run() },
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = SHLampDesign.Primary,
                        contentColor = SHLampDesign.OnPrimary
                    )
                ) { Text("Run again", fontWeight = FontWeight.Bold) }
            }
        }
    }
}

@Composable
private fun DiagnosticCheckCard(check: DiagnosticCheck) {
    val isNeutral = !check.passed && check.neutralWhenFailed
    val accent = when {
        check.passed -> SHLampDesign.Success
        isNeutral -> SHLampDesign.Info
        else -> SHLampDesign.Warning
    }
    val accentSurface = when {
        check.passed -> SHLampDesign.SuccessSoft
        isNeutral -> SHLampDesign.InfoSoft
        else -> SHLampDesign.WarningSoft
    }
    val symbol = when {
        check.passed -> "✓"
        isNeutral -> "–"
        else -> "!"
    }
    val status = when {
        check.passed -> "Working"
        isNeutral -> "Not active"
        else -> "Needs attention"
    }

    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(containerColor = SHLampDesign.Surface),
        border = androidx.compose.foundation.BorderStroke(1.dp, SHLampDesign.Border)
    ) {
        Row(
            modifier = Modifier.padding(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            androidx.compose.foundation.layout.Box(
                modifier = Modifier
                    .size(36.dp)
                    .background(accentSurface, RoundedCornerShape(12.dp)),
                contentAlignment = Alignment.Center
            ) {
                Text(symbol, color = accent, fontSize = 20.sp, fontWeight = FontWeight.Bold)
            }
            Spacer(Modifier.size(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Text(check.label, fontWeight = FontWeight.Bold)
                    Text(
                        status,
                        color = accent,
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.SemiBold
                    )
                }
                Text(
                    check.detail,
                    color = SHLampDesign.TextSecondary,
                    style = MaterialTheme.typography.bodySmall
                )
            }
        }
    }
}
