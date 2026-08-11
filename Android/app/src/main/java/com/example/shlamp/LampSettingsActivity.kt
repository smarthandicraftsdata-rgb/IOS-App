@file:Suppress("SpellCheckingInspection")

package com.example.shlamp

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.shlamp.ui.theme.SHLampDesign
import com.example.shlamp.ui.theme.SHLAMPTheme
import java.util.concurrent.Executors

class LampSettingsActivity : ComponentActivity() {
    private val handler = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private lateinit var manager: LampConnectionManager

    private val api by lazy { CloudApiClient() }
    private val vault by lazy { CloudTokenVault(this) }
    private val sessions by lazy { CloudSessionManager(vault, api) }
    private val transferStore by lazy { LampTransferCodeStore(this) }

    private val lampId by lazy { intent.getStringExtra(EXTRA_LAMP_ID).orEmpty() }
    private var remoteLampId: String = ""
    private val claimedState = mutableStateOf(false)
    private val cloudOnlineState = mutableStateOf(false)
    private val pendingTransferState = mutableStateOf<PendingLampTransfer?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        manager = LampConnectionManager(this, handler)
        remoteLampId = intent.getStringExtra(EXTRA_REMOTE_LAMP_ID)
            ?.trim()
            ?.uppercase()
            ?.takeIf { it.startsWith("SH-") }
            ?: manager.remoteLampIdFor(lampId).orEmpty()
        claimedState.value = remoteLampId.isNotBlank() || intent.getBooleanExtra(EXTRA_CLAIMED, false)
        cloudOnlineState.value = intent.getBooleanExtra(EXTRA_CLOUD_ONLINE, false)
        pendingTransferState.value = transferStore.read()?.takeIf { pending ->
            pending.lampId.equals(remoteLampId, ignoreCase = true) ||
                pending.lampId.equals(lampId, ignoreCase = true)
        }

        setContent {
            SHLAMPTheme {
                LampSettingsScreen(
                    manager = manager,
                    lampId = lampId,
                    claimed = claimedState.value,
                    cloudOnline = cloudOnlineState.value,
                    initialTransferCode = pendingTransferState.value?.claimCode.orEmpty(),
                    onBack = {
                        if (pendingTransferState.value != null) {
                            Toast.makeText(
                                this,
                                "Save the claim code before leaving this screen.",
                                Toast.LENGTH_LONG
                            ).show()
                        } else {
                            finish()
                        }
                    },
                    onSaveIdentity = ::saveIdentity,
                    onRelease = ::releaseLamp,
                    onCopyTransferCode = ::copyTransferCode,
                    onConfirmTransferSaved = ::confirmTransferCodeSaved,
                    onAddRemoteAccess = {
                        startActivity(
                            Intent(this, AddLampActivity::class.java)
                                .putExtra(AddLampActivity.EXTRA_EXISTING_LAMP_ID, lampId)
                                .putExtra(AddLampActivity.EXTRA_START_REMOTE_ACCESS, true)
                        )
                    },
                    onRemoveLocal = {
                        manager.removeLamp(lampId)
                        setResult(RESULT_OK)
                        finish()
                    },
                    onDiagnostics = {
                        startActivity(
                            Intent(this, ConnectionDiagnosticsActivity::class.java)
                                .putExtra(ConnectionDiagnosticsActivity.EXTRA_LAMP_ID, lampId)
                                .putExtra(ConnectionDiagnosticsActivity.EXTRA_REMOTE_LAMP_ID, remoteLampId)
                                .putExtra(ConnectionDiagnosticsActivity.EXTRA_CLAIMED, claimedState.value)
                                .putExtra(
                                    ConnectionDiagnosticsActivity.EXTRA_CLOUD_ONLINE,
                                    cloudOnlineState.value
                                )
                        )
                    }
                )
            }
        }
    }

    override fun onStart() {
        super.onStart()
        manager.start()
        manager.selectLamp(lampId, connectBle = true)
        manager.refreshNetworkContext()
        refreshCloudStatus()
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

    private fun refreshCloudStatus() {
        val cloudId = remoteLampId.ifBlank { manager.remoteLampIdFor(lampId).orEmpty() }
        if (cloudId.isBlank()) {
            cloudOnlineState.value = false
            return
        }
        remoteLampId = cloudId
        claimedState.value = true
        worker.execute {
            val result = runCatching {
                sessions.execute { token ->
                    val me = api.readMe(token)
                    if (me.unauthorized) throw UnauthorizedException()
                    api.readDevice(token, cloudId) to me.user?.id
                }
            }
            runOnUiThread {
                result.onSuccess { (lamp, ownerUserId) ->
                    cloudOnlineState.value = lamp.online
                    manager.syncCloudLamps(listOf(lamp), ownerUserId)
                    manager.markCloudOwnership(lamp.id, ownerUserId)
                }.onFailure {
                    cloudOnlineState.value = false
                }
            }
        }
    }

    private fun saveIdentity(
        name: String,
        roomName: String,
        callback: (Result<String>) -> Unit
    ) {
        val cleanName = name.trim().take(32)
        val cleanRoomName = roomName.trim().take(24)
        manager.selectLamp(lampId, connectBle = false)
        manager.renameSelectedLamp(cleanName, cleanRoomName)
        if (!claimedState.value) {
            callback(Result.success("Lamp details saved on this phone."))
            return
        }

        worker.execute {
            val result = runCatching {
                sessions.execute { token ->
                    val dashboard = api.loadDashboard(token)
                    val cloudId = remoteLampId.ifBlank { lampId }
                    val lamp = runCatching { api.readDevice(token, cloudId) }.getOrElse {
                        dashboard.lamps.firstOrNull { it.id.equals(cloudId, ignoreCase = true) }
                            ?: throw IllegalStateException("The lamp is no longer linked to this account.")
                    }
                    val home = dashboard.homes.firstOrNull { it.id == lamp.homeId }
                        ?: dashboard.homes.firstOrNull { it.id != "default" }
                        ?: throw IllegalStateException("The lamp home could not be loaded.")
                    val roomId = cleanRoomName.takeIf(String::isNotBlank)?.let { cleanRoom ->
                        home.rooms.firstOrNull { it.name.equals(cleanRoom, ignoreCase = true) }?.id
                            ?: api.createRoom(token, home.id, cleanRoom).id
                    }
                    api.updateDevice(
                        accessToken = token,
                        lampId = remoteLampId.ifBlank { lampId },
                        displayName = cleanName,
                        roomId = roomId,
                        updateRoom = true
                    )
                }
                "Lamp details saved."
            }
            runOnUiThread { callback(result) }
        }
    }

    private fun releaseLamp(callback: (Result<ReleasedCloudLamp>) -> Unit) {
        worker.execute {
            var pendingTransfer: PendingLampTransfer? = null
            var persistenceWarning: Throwable? = null
            val result = runCatching {
                val released = sessions.execute { token ->
                    api.releaseDevice(token, remoteLampId.ifBlank { lampId })
                }
                require(released.newClaimCode.isNotBlank()) {
                    "The server did not return a new claim code."
                }

                // Set the in-memory value before encrypted persistence. Even if
                // Android Keystore is temporarily unavailable, the only readable
                // claim code is still shown and the local lamp is not removed.
                pendingTransfer = PendingLampTransfer(
                    lampId = released.lampId,
                    claimCode = released.newClaimCode,
                    releasedAt = System.currentTimeMillis()
                )
                runCatching { transferStore.save(pendingTransfer!!) }
                    .onFailure { persistenceWarning = it }
                released
            }
            runOnUiThread {
                pendingTransfer?.let { pendingTransferState.value = it }
                if (persistenceWarning != null) {
                    Toast.makeText(
                        this,
                        "Keep this screen open and copy the claim code now.",
                        Toast.LENGTH_LONG
                    ).show()
                }
                callback(result)
            }
        }
    }

    private fun copyTransferCode(code: String) {
        val cleanCode = code.trim().uppercase()
        if (cleanCode.isBlank()) return
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText("SH Lamp claim code", cleanCode))
        Toast.makeText(this, "Claim code copied", Toast.LENGTH_SHORT).show()
    }

    private fun confirmTransferCodeSaved() {
        val pending = pendingTransferState.value ?: return
        transferStore.clear(pending.lampId)
        pendingTransferState.value = null
        manager.removeLamp(lampId)
        setResult(RESULT_OK)
        finish()
    }

    companion object {
        const val EXTRA_LAMP_ID = "lamp_id"
        const val EXTRA_REMOTE_LAMP_ID = "remote_lamp_id"
        const val EXTRA_CLAIMED = "claimed"
        const val EXTRA_CLOUD_ONLINE = "cloud_online"
    }
}

@Composable
private fun LampSettingsScreen(
    manager: LampConnectionManager,
    lampId: String,
    claimed: Boolean,
    cloudOnline: Boolean,
    initialTransferCode: String,
    onBack: () -> Unit,
    onSaveIdentity: (String, String, (Result<String>) -> Unit) -> Unit,
    onRelease: ((Result<ReleasedCloudLamp>) -> Unit) -> Unit,
    onCopyTransferCode: (String) -> Unit,
    onConfirmTransferSaved: () -> Unit,
    onAddRemoteAccess: () -> Unit,
    onRemoveLocal: () -> Unit,
    onDiagnostics: () -> Unit
) {
    val lamp = manager.localLamp(lampId)
    var name by remember(lampId) { mutableStateOf(lamp?.name ?: "SH Lamp") }
    var room by remember(lampId) { mutableStateOf(lamp?.room?.takeUnless { it == "Unassigned" }.orEmpty()) }
    var ssid by remember(lampId) { mutableStateOf(lamp?.wifiSsid.orEmpty()) }
    var password by remember { mutableStateOf("") }
    var message by remember { mutableStateOf("") }
    var error by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var confirmRemoval by remember { mutableStateOf(false) }
    var transferCode by remember(lampId, initialTransferCode) {
        mutableStateOf(initialTransferCode.trim().uppercase())
    }

    BackHandler(enabled = transferCode.isNotBlank()) {
        onBack()
    }

    LaunchedEffect(initialTransferCode) {
        if (initialTransferCode.isNotBlank()) {
            transferCode = initialTransferCode.trim().uppercase()
        }
    }

    LaunchedEffect(lamp?.name, lamp?.room) {
        if (lamp != null) {
            name = lamp.name
            room = lamp.room.takeUnless { it == "Unassigned" }.orEmpty()
            if (ssid.isBlank()) ssid = lamp.wifiSsid.orEmpty()
        }
    }

    if (transferCode.isNotBlank()) {
        AlertDialog(
            onDismissRequest = { },
            title = { Text("Save the new claim code") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(
                        "This is the only readable copy of the new claim code. " +
                            "The lamp will stay saved on this phone until you confirm that the code is safe."
                    )
                    Card(
                        colors = CardDefaults.cardColors(containerColor = SHLampDesign.WarmSoft),
                        shape = RoundedCornerShape(14.dp)
                    ) {
                        Text(
                            transferCode,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(16.dp),
                            fontSize = 24.sp,
                            fontWeight = FontWeight.Bold
                        )
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = onConfirmTransferSaved) {
                    Text("I saved it")
                }
            },
            dismissButton = {
                TextButton(onClick = { onCopyTransferCode(transferCode) }) {
                    Text("Copy code")
                }
            }
        )
    }

    if (confirmRemoval && transferCode.isBlank()) {
        AlertDialog(
            onDismissRequest = { if (!busy) confirmRemoval = false },
            title = { Text(if (claimed) "Remove or transfer lamp?" else "Remove lamp from this phone?") },
            text = {
                Text(
                    if (claimed) {
                        "This removes the lamp from your account and creates a new claim code for transfer. The physical lamp should also be reset before another owner adds it."
                    } else {
                        "The lamp will be removed from this phone. You can add it again later."
                    }
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        if (!claimed) {
                            confirmRemoval = false
                            onRemoveLocal()
                        } else {
                            busy = true
                            onRelease { result ->
                                busy = false
                                result.onSuccess {
                                    transferCode = it.newClaimCode
                                    message = "Lamp released. Save the transfer code below."
                                    confirmRemoval = false
                                }.onFailure {
                                    error = it.message ?: "The lamp could not be removed."
                                }
                            }
                        }
                    }
                ) { Text(if (claimed) "Release lamp" else "Remove") }
            },
            dismissButton = { TextButton(onClick = { confirmRemoval = false }) { Text("Cancel") } }
        )
    }

    Scaffold(containerColor = SHLampDesign.Background) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .statusBarsPadding()
                .navigationBarsPadding()
                .imePadding()
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
                Text("Lamp Settings", fontSize = 24.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(1.dp))
            }

            SettingsSection("Lamp details") {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it.take(32) },
                    label = { Text("Lamp name") },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true
                )
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = room,
                    onValueChange = { room = it.take(24) },
                    label = { Text("Room (optional)") },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true
                )
                Spacer(Modifier.height(12.dp))
                Button(
                    onClick = {
                        if (name.trim().length < 2) {
                            error = "Enter a lamp name."
                        } else {
                            busy = true
                            error = ""
                            onSaveIdentity(name.trim(), room.trim()) { result ->
                                busy = false
                                result.onSuccess { message = it }
                                    .onFailure { error = it.message ?: "The details could not be saved." }
                            }
                        }
                    },
                    enabled = !busy,
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = SHLampDesign.Primary,
                        contentColor = SHLampDesign.OnPrimary
                    )
                ) { Text("Save details", fontWeight = FontWeight.Bold) }
            }

            SettingsSection("Connection") {
                Text(
                    when {
                        lamp?.route == LampConnectionRoute.WIFI -> "Wi-Fi • local control"
                        lamp?.route == LampConnectionRoute.BLUETOOTH -> "Bluetooth • nearby control"
                        claimed && cloudOnline -> "Remote • internet control"
                        claimed -> "Remote • connection checking"
                        else -> "Offline • move closer to the lamp"
                    },
                    color = SHLampDesign.TextPrimary,
                    fontWeight = FontWeight.SemiBold
                )
                Spacer(Modifier.height(6.dp))
                Text(
                    "Change Wi-Fi without removing or reclaiming the lamp.",
                    color = SHLampDesign.TextSecondary,
                    style = MaterialTheme.typography.bodySmall
                )
                Spacer(Modifier.height(12.dp))
                OutlinedTextField(
                    value = ssid,
                    onValueChange = { ssid = it.take(32) },
                    label = { Text("Wi-Fi network") },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true
                )
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = password,
                    onValueChange = { password = it.take(64) },
                    label = { Text("Wi-Fi password") },
                    visualTransformation = PasswordVisualTransformation(),
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true
                )
                Spacer(Modifier.height(10.dp))
                Text(manager.wifiSetupStatus.value, color = SHLampDesign.TextSecondary)
                Spacer(Modifier.height(10.dp))
                Button(
                    onClick = {
                        message = ""
                        error = ""
                        manager.selectLamp(lampId, connectBle = true)
                        manager.provisionSelectedWifi(ssid.trim(), password)
                    },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = ssid.isNotBlank(),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = SHLampDesign.Primary,
                        contentColor = SHLampDesign.OnPrimary
                    )
                ) { Text("Change Wi-Fi", fontWeight = FontWeight.Bold) }
                Spacer(Modifier.height(8.dp))
                OutlinedButton(
                    onClick = {
                        manager.identifyLamp(
                            lampId = lampId,
                            onHandled = { _ -> },
                            onUnavailable = { message = "Move closer to the lamp and try again." }
                        )
                    },
                    modifier = Modifier.fillMaxWidth(),
                    border = BorderStroke(1.dp, SHLampDesign.Border)
                ) { Text("Blink lamp") }
            }

            SettingsSection("Remote access") {
                if (claimed) {
                    Text("Connected", color = SHLampDesign.Success, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.height(5.dp))
                    Text(
                        "Cloud ID: ${lamp?.remoteLampId ?: lampId}",
                        color = SHLampDesign.TextSecondary,
                        style = MaterialTheme.typography.bodySmall
                    )
                    Spacer(Modifier.height(5.dp))
                    Text(
                        if (cloudOnline) "Remote control is currently online." else "Remote access is linked; the lamp is currently reconnecting.",
                        color = SHLampDesign.TextSecondary,
                        style = MaterialTheme.typography.bodySmall
                    )
                } else {
                    Text("Not connected", fontWeight = FontWeight.Bold)
                    Spacer(Modifier.height(5.dp))
                    Text(
                        "Enable control while away from home. This updates the same lamp and will not create another device.",
                        color = SHLampDesign.TextSecondary,
                        style = MaterialTheme.typography.bodySmall
                    )
                    Spacer(Modifier.height(12.dp))
                    Button(
                        onClick = onAddRemoteAccess,
                        modifier = Modifier.fillMaxWidth(),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = SHLampDesign.Primary,
                            contentColor = SHLampDesign.OnPrimary
                        )
                    ) { Text("Add remote access", fontWeight = FontWeight.Bold) }
                }
            }

            SettingsSection("Help") {
                OutlinedButton(
                    onClick = onDiagnostics,
                    modifier = Modifier.fillMaxWidth(),
                    border = BorderStroke(1.dp, SHLampDesign.Border)
                ) { Text("Run connection check") }
            }

            SettingsSection(if (claimed) "Ownership" else "This phone") {
                Text(
                    if (claimed) {
                        "Remove the lamp from your account when selling, gifting or transferring it."
                    } else {
                        "This lamp is saved only on this phone and has no remote internet control."
                    },
                    color = SHLampDesign.TextSecondary,
                    style = MaterialTheme.typography.bodySmall
                )
                Spacer(Modifier.height(10.dp))
                OutlinedButton(
                    onClick = { confirmRemoval = true },
                    modifier = Modifier.fillMaxWidth(),
                    border = BorderStroke(1.dp, SHLampDesign.Error),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = SHLampDesign.Error)
                ) { Text(if (claimed) "Remove or transfer lamp" else "Remove from this phone") }
            }

            if (busy) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(18.dp),
                        strokeWidth = 2.dp,
                        color = SHLampDesign.Primary
                    )
                    Spacer(Modifier.size(8.dp))
                    Text("Please wait…", color = SHLampDesign.TextSecondary)
                }
            }
            if (transferCode.isNotBlank()) {
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    colors = CardDefaults.cardColors(containerColor = SHLampDesign.WarmSoft),
                    shape = RoundedCornerShape(16.dp)
                ) {
                    Column(Modifier.padding(14.dp)) {
                        Text("Transfer code", fontWeight = FontWeight.Bold)
                        Text(transferCode, fontSize = 23.sp, fontWeight = FontWeight.Bold)
                        Text(
                            "Give this code only to the new owner after physically resetting the lamp.",
                            color = SHLampDesign.TextSecondary,
                            style = MaterialTheme.typography.bodySmall
                        )
                    }
                }
            }
            if (message.isNotBlank()) SettingsMessage(message, false)
            if (error.isNotBlank()) SettingsMessage(error, true)
        }
    }
}

@Composable
private fun SettingsSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(22.dp),
        colors = CardDefaults.cardColors(containerColor = SHLampDesign.Surface)
    ) {
        Column(Modifier.padding(18.dp)) {
            Text(title, fontSize = 19.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(12.dp))
            content.invoke(this)
        }
    }
}

@Composable
private fun SettingsMessage(message: String, isError: Boolean) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = if (isError) SHLampDesign.ErrorSoft else SHLampDesign.SuccessSoft
        ),
        shape = RoundedCornerShape(15.dp)
    ) {
        Text(
            message,
            modifier = Modifier.padding(13.dp),
            color = if (isError) SHLampDesign.Error else SHLampDesign.TextPrimary
        )
    }
}
