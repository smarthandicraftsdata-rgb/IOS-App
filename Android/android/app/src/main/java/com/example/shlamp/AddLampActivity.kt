@file:Suppress("SpellCheckingInspection")

package com.example.shlamp

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.shlamp.ui.theme.SHLampDesign
import com.example.shlamp.ui.theme.SHLAMPTheme
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import java.util.Locale
import java.util.concurrent.Executors

class AddLampActivity : ComponentActivity() {
    private val handler = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private lateinit var manager: LampConnectionManager
    private lateinit var setupStore: LampSetupStore

    private val api by lazy { CloudApiClient() }
    private val vault by lazy { CloudTokenVault(this) }
    private val sessions by lazy { CloudSessionManager(vault, api) }

    private var permissionResult: ((Boolean) -> Unit)? = null
    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { result ->
        permissionResult?.invoke(result.values.all { it })
        permissionResult = null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        manager = LampConnectionManager(this, handler)
        setupStore = LampSetupStore(this)

        setContent {
            SHLAMPTheme {
                AddLampWizard(
                    manager = manager,
                    savedDraft = setupStore.load(),
                    defaultSsid = currentWifiSsid(),
                    onBack = { finish() },
                    onStartDiscovery = ::startDiscovery,
                    onScanQr = ::scanQr,
                    onPersist = setupStore::save,
                    onClearDraft = setupStore::clear,
                    onComplete = ::completeSetup
                )
            }
        }
    }

    override fun onStart() {
        super.onStart()
        manager.start()
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

    private fun startDiscovery(onResult: (Boolean) -> Unit = {}) {
        if (hasBluetoothPermissions()) {
            manager.startNearbyScan()
            onResult(true)
            return
        }
        permissionResult = { granted ->
            if (granted) manager.startNearbyScan()
            onResult(granted)
        }
        permissionLauncher.launch(requiredBluetoothPermissions())
    }

    private fun hasBluetoothPermissions(): Boolean =
        requiredBluetoothPermissions().all { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }

    private fun requiredBluetoothPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private fun scanQr(callback: (Result<LampQrPayload>) -> Unit) {
        val options = GmsBarcodeScannerOptions.Builder()
            .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
            .enableAutoZoom()
            .build()
        GmsBarcodeScanning.getClient(this, options)
            .startScan()
            .addOnSuccessListener { barcode ->
                callback(runCatching { LampQrParser.parse(barcode.rawValue.orEmpty()) })
            }
            .addOnCanceledListener {
                callback(Result.failure(IllegalStateException("Scanning was cancelled.")))
            }
            .addOnFailureListener { callback(Result.failure(it)) }
    }

    @Suppress("DEPRECATION")
    private fun currentWifiSsid(): String {
        return runCatching {
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            wifiManager.connectionInfo?.ssid
                ?.trim('"')
                ?.takeUnless { it.equals("<unknown ssid>", ignoreCase = true) }
                .orEmpty()
        }.getOrDefault("")
    }

    private fun completeSetup(draft: LampSetupDraft, callback: (Result<String>) -> Unit) {
        val localLampId = draft.lampId.trim().uppercase(Locale.US)
        val cleanLampName = draft.lampName.trim().take(32)
            .ifBlank { draft.advertisedName.trim().take(32).ifBlank { "SH Lamp" } }
        val cleanRoomName = draft.roomName.trim().take(24)
        manager.selectLamp(localLampId, connectBle = false)
        manager.renameSelectedLamp(cleanLampName, cleanRoomName)

        if (draft.mode == LampSetupMode.BLUETOOTH_ONLY) {
            val reportedCloudId = draft.cloudLampId
                .ifBlank { manager.reportedCloudLampIdFor(localLampId).orEmpty() }
                .trim()
                .uppercase(Locale.US)
            if (Regex("SH-[A-Z0-9]{4,16}").matches(reportedCloudId) &&
                !reportedCloudId.equals(localLampId, ignoreCase = true)
            ) {
                // Save only the physical identity hint. Bluetooth-only setup does
                // not prove account ownership and therefore must not enable remote.
                manager.recordReportedIdentity(localLampId, reportedCloudId)
            }
            setupStore.clear()
            callback(Result.success("Your lamp is ready for nearby Bluetooth control."))
            return
        }

        worker.execute {
            val result = runCatching {
                val cloudLampId = draft.cloudLampId
                    .ifBlank { manager.reportedCloudLampIdFor(localLampId).orEmpty() }
                    .trim()
                    .uppercase(Locale.US)
                require(Regex("SH-[A-Z0-9]{4,16}").matches(cloudLampId)) {
                    "Scan the lamp QR code or enter its Lamp ID."
                }

                val ownerUserId = sessions.execute { token ->
                    val me = api.readMe(token)
                    if (me.unauthorized) throw UnauthorizedException()
                    val dashboard = api.loadDashboard(token)
                    val home = dashboard.homes.firstOrNull { it.id != "default" }
                        ?: throw IllegalStateException("Your account home could not be loaded.")
                    val roomId = cleanRoomName.takeIf(String::isNotBlank)?.let { roomName ->
                        home.rooms.firstOrNull { it.name.equals(roomName, ignoreCase = true) }?.id
                            ?: api.createRoom(token, home.id, roomName).id
                    }
                    val alreadyOwned = runCatching {
                        api.readDevice(token, cloudLampId)
                    }.isSuccess
                    if (alreadyOwned) {
                        api.updateDevice(
                            accessToken = token,
                            lampId = cloudLampId,
                            displayName = cleanLampName,
                            roomId = roomId,
                            updateRoom = true
                        )
                    } else {
                        require(draft.claimCode.isNotBlank()) {
                            "Enter the claim code printed with the lamp."
                        }
                        api.claimDevice(
                            accessToken = token,
                            lampId = cloudLampId,
                            claimCode = draft.claimCode,
                            homeId = home.id,
                            roomId = roomId,
                            displayName = cleanLampName
                        )
                    }
                    me.user?.id
                }
                setupStore.clear()
                cloudLampId to ownerUserId
            }
            runOnUiThread {
                result.onSuccess { (cloudLampId, ownerUserId) ->
                    manager.linkLampIdentity(localLampId, cloudLampId, ownerUserId)
                    callback(Result.success("Your lamp is connected and added to My Lamps."))
                }.onFailure { error ->
                    callback(Result.failure(error))
                }
            }
        }
    }
}

@Composable
private fun AddLampWizard(
    manager: LampConnectionManager,
    savedDraft: LampSetupDraft?,
    defaultSsid: String,
    onBack: () -> Unit,
    onStartDiscovery: ((Boolean) -> Unit) -> Unit,
    onScanQr: ((Result<LampQrPayload>) -> Unit) -> Unit,
    onPersist: (LampSetupDraft) -> Unit,
    onClearDraft: () -> Unit,
    onComplete: (LampSetupDraft, (Result<String>) -> Unit) -> Unit
) {
    val context = LocalContext.current
    var showResume by remember { mutableStateOf(savedDraft != null) }
    var draft by remember { mutableStateOf(savedDraft ?: LampSetupDraft(wifiSsid = defaultSsid)) }
    var message by remember { mutableStateOf("") }
    var error by remember { mutableStateOf("") }
    var wifiPassword by remember { mutableStateOf("") }
    var wifiSubmitted by remember { mutableStateOf(false) }
    var finishing by remember { mutableStateOf(false) }
    var manualLampId by remember { mutableStateOf(draft.cloudLampId) }
    var manualClaimCode by remember { mutableStateOf(draft.claimCode) }

    val nearbyLamps = manager.nearbyLamps.value
    val selectedLamp = manager.selectedLamp()
    val status = manager.status.value
    val wifiStatus = manager.wifiSetupStatus.value
    val scanning = manager.scanning.value
    val connecting = manager.connecting.value

    fun save(next: LampSetupDraft) {
        draft = next.copy(updatedAt = System.currentTimeMillis())
        onPersist(draft)
    }

    fun chooseNearby(nearby: NearbyLamp) {
        error = ""
        message = "Connecting to ${nearby.advertisedName}…"
        manager.addLamp(nearby)
        save(
            draft.copy(
                step = LampSetupStep.CONFIRM,
                lampId = nearby.lampId.uppercase(Locale.US),
                bleAddress = nearby.bleAddress,
                advertisedName = nearby.advertisedName,
                lampName = draft.lampName.ifBlank { nearby.advertisedName }
            )
        )
    }

    LaunchedEffect(Unit) {
        if (!showResume) onStartDiscovery { granted ->
            if (!granted) error = "Nearby device permission is needed to find your lamp."
        }
    }

    LaunchedEffect(selectedLamp?.lampId, draft.step) {
        val lamp = selectedLamp ?: return@LaunchedEffect
        if (draft.step == LampSetupStep.CONFIRM && lamp.lampId.isNotBlank() &&
            !lamp.lampId.startsWith("BLE-")
        ) {
            val reportedCloudId = manager.reportedCloudLampIdFor(lamp.lampId).orEmpty()
            save(
                draft.copy(
                    lampId = lamp.lampId,
                    cloudLampId = draft.cloudLampId.ifBlank { reportedCloudId },
                    advertisedName = draft.advertisedName.ifBlank { lamp.name },
                    lampName = draft.lampName.ifBlank { lamp.name }
                )
            )
        }
    }

    LaunchedEffect(nearbyLamps, draft.step, draft.cloudLampId) {
        if (draft.step != LampSetupStep.DISCOVER || draft.cloudLampId.isBlank()) return@LaunchedEffect
        val match = nearbyLamps.firstOrNull {
            it.lampId.equals(draft.cloudLampId, ignoreCase = true)
        }
        if (match != null) chooseNearby(match)
    }

    LaunchedEffect(wifiStatus) {
        if (draft.step == LampSetupStep.WIFI &&
            (wifiStatus.startsWith("Connected to Wi-Fi") || selectedLamp?.route == LampConnectionRoute.WIFI)
        ) {
            wifiSubmitted = true
        }
    }

    Scaffold(containerColor = SHLampDesign.Background) { innerPadding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .statusBarsPadding()
                .navigationBarsPadding()
                .imePadding(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(18.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            item {
                WizardHeader(
                    step = draft.step,
                    onBack = {
                        when (draft.step) {
                            LampSetupStep.DISCOVER -> onBack()
                            LampSetupStep.CONFIRM -> save(draft.copy(step = LampSetupStep.DISCOVER))
                            LampSetupStep.CHOOSE_CONNECTION -> save(draft.copy(step = LampSetupStep.CONFIRM))
                            LampSetupStep.ENTER_CODE -> save(
                                draft.copy(
                                    step = if (draft.mode == null) {
                                        LampSetupStep.DISCOVER
                                    } else {
                                        LampSetupStep.CHOOSE_CONNECTION
                                    }
                                )
                            )
                            LampSetupStep.WIFI -> save(draft.copy(step = LampSetupStep.CHOOSE_CONNECTION))
                            LampSetupStep.NAME -> save(
                                draft.copy(
                                    step = if (draft.mode == LampSetupMode.WIFI) LampSetupStep.WIFI
                                    else LampSetupStep.CHOOSE_CONNECTION
                                )
                            )
                            LampSetupStep.READY -> onBack()
                        }
                    }
                )
            }

            if (showResume && savedDraft != null) {
                item {
                    SetupCard {
                        Text("Continue lamp setup?", fontSize = 22.sp, fontWeight = FontWeight.Bold)
                        Spacer(Modifier.height(8.dp))
                        Text(
                            savedDraft.lampName.ifBlank {
                                savedDraft.advertisedName.ifBlank { savedDraft.lampId.ifBlank { "SH Lamp" } }
                            },
                            color = SHLampDesign.TextSecondary
                        )
                        Spacer(Modifier.height(16.dp))
                        Button(
                            onClick = {
                                showResume = false
                                draft = savedDraft
                                savedDraft.lampId.takeIf(String::isNotBlank)?.let {
                                    manager.selectLamp(it, connectBle = true)
                                }
                                if (savedDraft.step == LampSetupStep.DISCOVER) {
                                    onStartDiscovery { }
                                }
                            },
                            modifier = Modifier.fillMaxWidth(),
                            colors = ButtonDefaults.buttonColors(
                                containerColor = SHLampDesign.Primary,
                                contentColor = SHLampDesign.OnPrimary
                            )
                        ) { Text("Continue setup", fontWeight = FontWeight.Bold) }
                        Spacer(Modifier.height(8.dp))
                        OutlinedButton(
                            onClick = {
                                onClearDraft()
                                showResume = false
                                draft = LampSetupDraft(wifiSsid = defaultSsid)
                                onStartDiscovery { }
                            },
                            modifier = Modifier.fillMaxWidth(),
                            border = BorderStroke(1.dp, SHLampDesign.Border)
                        ) { Text("Start again") }
                    }
                }
            } else {
                when (draft.step) {
                    LampSetupStep.DISCOVER -> {
                        item {
                            SetupCard {
                                SetupHeroCard(
                                    title = if (scanning) "Searching nearby" else "Find your lamp",
                                    subtitle = if (scanning) {
                                        "Keep your phone close while we look for an SH Lamp."
                                    } else {
                                        "Switch on the lamp and keep it near your phone."
                                    },
                                    badge = if (scanning) "Searching" else "Step 1",
                                    active = scanning
                                )
                                Spacer(Modifier.height(18.dp))
                                Text("Add a lamp", fontSize = 24.sp, fontWeight = FontWeight.Bold)
                                Spacer(Modifier.height(6.dp))
                                Text(
                                    "Keep the lamp switched on and close to your phone. SH Lamp searches automatically.",
                                    color = SHLampDesign.TextSecondary
                                )
                                Spacer(Modifier.height(16.dp))
                                Button(
                                    onClick = { onStartDiscovery { } },
                                    modifier = Modifier.fillMaxWidth(),
                                    enabled = !scanning,
                                    colors = ButtonDefaults.buttonColors(
                                        containerColor = SHLampDesign.Primary,
                                        contentColor = SHLampDesign.OnPrimary
                                    )
                                ) {
                                    if (scanning) {
                                        CircularProgressIndicator(
                                            modifier = Modifier.size(18.dp),
                                            strokeWidth = 2.dp,
                                            color = SHLampDesign.OnPrimary
                                        )
                                        Spacer(Modifier.size(8.dp))
                                        Text("Searching…")
                                    } else {
                                        Text("Search again", fontWeight = FontWeight.Bold)
                                    }
                                }
                                Spacer(Modifier.height(8.dp))
                                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    OutlinedButton(
                                        onClick = {
                                            onScanQr { result ->
                                                result.onSuccess { payload ->
                                                    manualLampId = payload.lampId
                                                    manualClaimCode = payload.claimCode
                                                    save(
                                                        draft.copy(
                                                            cloudLampId = payload.lampId,
                                                            claimCode = payload.claimCode,
                                                            step = LampSetupStep.DISCOVER
                                                        )
                                                    )
                                                    message = "Code accepted. Looking for ${payload.lampId} nearby…"
                                                    onStartDiscovery { }
                                                }.onFailure {
                                                    error = it.message ?: "The code could not be read."
                                                }
                                            }
                                        },
                                        modifier = Modifier.weight(1f),
                                        border = BorderStroke(1.dp, SHLampDesign.Border)
                                    ) { Text("Scan QR") }
                                    OutlinedButton(
                                        onClick = { save(draft.copy(step = LampSetupStep.ENTER_CODE)) },
                                        modifier = Modifier.weight(1f),
                                        border = BorderStroke(1.dp, SHLampDesign.Border)
                                    ) { Text("Enter code") }
                                }
                            }
                        }
                        if (nearbyLamps.isEmpty() && !scanning) {
                            item {
                                SetupNotice("No lamp found yet. Move closer, check that the lamp is on, then search again.")
                            }
                        }
                        items(nearbyLamps, key = { it.bleAddress }) { nearby ->
                            NearbyLampResult(nearby = nearby, onAdd = { chooseNearby(nearby) })
                        }
                    }

                    LampSetupStep.CONFIRM -> item {
                        SetupCard {
                            SetupHeroCard(
                                title = selectedLamp?.name ?: draft.advertisedName.ifBlank { "SH Lamp" },
                                subtitle = if (connecting) "Connecting to the nearby lamp…" else status,
                                badge = "Found",
                                active = selectedLamp?.isReachable == true
                            )
                            Spacer(Modifier.height(18.dp))
                            Text("Confirm your lamp", fontSize = 24.sp, fontWeight = FontWeight.Bold)
                            Spacer(Modifier.height(8.dp))
                            Text(
                                selectedLamp?.name ?: draft.advertisedName.ifBlank { draft.lampId },
                                color = SHLampDesign.TextPrimary,
                                fontWeight = FontWeight.SemiBold
                            )
                            Text(
                                if (connecting) "Connecting…" else status,
                                color = SHLampDesign.TextSecondary
                            )
                            Spacer(Modifier.height(18.dp))
                            OutlinedButton(
                                onClick = { manager.identifySelectedLamp() },
                                modifier = Modifier.fillMaxWidth(),
                                enabled = selectedLamp?.isReachable == true,
                                border = BorderStroke(1.dp, SHLampDesign.Border)
                            ) { Text("Blink lamp") }
                            Spacer(Modifier.height(8.dp))
                            Text(
                                "The selected lamp should blink. This helps confirm that you chose the correct lamp.",
                                color = SHLampDesign.TextSecondary,
                                style = MaterialTheme.typography.bodySmall
                            )
                            Spacer(Modifier.height(16.dp))
                            Button(
                                onClick = { save(draft.copy(step = LampSetupStep.CHOOSE_CONNECTION)) },
                                modifier = Modifier.fillMaxWidth(),
                                enabled = selectedLamp != null && !connecting,
                                colors = ButtonDefaults.buttonColors(
                                    containerColor = SHLampDesign.Primary,
                                    contentColor = SHLampDesign.OnPrimary
                                )
                            ) { Text("This is my lamp", fontWeight = FontWeight.Bold) }
                        }
                    }

                    LampSetupStep.CHOOSE_CONNECTION -> item {
                        SetupCard {
                            SetupHeroCard(
                                title = "Choose how to control it",
                                subtitle = "Wi-Fi gives local and remote control. Bluetooth works when you are nearby.",
                                badge = "Step 2",
                                active = true
                            )
                            Spacer(Modifier.height(18.dp))
                            Text("Choose connection", fontSize = 24.sp, fontWeight = FontWeight.Bold)
                            Spacer(Modifier.height(6.dp))
                            Text("You can change this later in Lamp Settings.", color = SHLampDesign.TextSecondary)
                            Spacer(Modifier.height(18.dp))
                            ChoiceCard(
                                title = "Connect to Wi-Fi",
                                subtitle = "Recommended • control nearby and while away",
                                primary = true,
                                onClick = {
                                    save(
                                        draft.copy(
                                            mode = LampSetupMode.WIFI,
                                            step = if (draft.cloudLampId.isBlank()) {
                                                LampSetupStep.ENTER_CODE
                                            } else {
                                                LampSetupStep.WIFI
                                            }
                                        )
                                    )
                                }
                            )
                            Spacer(Modifier.height(10.dp))
                            ChoiceCard(
                                title = "Use Bluetooth only",
                                subtitle = "Control when you are close to the lamp",
                                primary = false,
                                onClick = {
                                    save(
                                        draft.copy(
                                            mode = LampSetupMode.BLUETOOTH_ONLY,
                                            step = LampSetupStep.NAME
                                        )
                                    )
                                }
                            )
                        }
                    }

                    LampSetupStep.ENTER_CODE -> item {
                        SetupCard {
                            SetupHeroCard(
                                title = "Identify your lamp",
                                subtitle = "Scan the QR code for the quickest and safest setup.",
                                badge = "QR or code",
                                active = true
                            )
                            Spacer(Modifier.height(18.dp))
                            Text("Lamp code", fontSize = 24.sp, fontWeight = FontWeight.Bold)
                            Spacer(Modifier.height(6.dp))
                            Text(
                                if (draft.mode == LampSetupMode.WIFI) {
                                    "Scan the code on the lamp or packaging to add it to your account."
                                } else {
                                    "Use this when automatic discovery does not identify the lamp."
                                },
                                color = SHLampDesign.TextSecondary
                            )
                            Spacer(Modifier.height(16.dp))
                            OutlinedButton(
                                onClick = {
                                    onScanQr { result ->
                                        result.onSuccess { payload ->
                                            manualLampId = payload.lampId
                                            manualClaimCode = payload.claimCode
                                            save(
                                                draft.copy(
                                                    cloudLampId = payload.lampId,
                                                    claimCode = payload.claimCode,
                                                    step = if (draft.mode == LampSetupMode.WIFI) {
                                                        LampSetupStep.WIFI
                                                    } else {
                                                        LampSetupStep.DISCOVER
                                                    }
                                                )
                                            )
                                            if (draft.mode != LampSetupMode.WIFI) onStartDiscovery { }
                                        }.onFailure {
                                            error = it.message ?: "The code could not be read."
                                        }
                                    }
                                },
                                modifier = Modifier.fillMaxWidth(),
                                border = BorderStroke(1.dp, SHLampDesign.Border)
                            ) { Text("Scan QR code") }
                            Spacer(Modifier.height(14.dp))
                            Text("Or enter manually", fontWeight = FontWeight.SemiBold)
                            Spacer(Modifier.height(8.dp))
                            OutlinedTextField(
                                value = manualLampId,
                                onValueChange = { manualLampId = it.uppercase(Locale.US).take(20) },
                                label = { Text("Lamp ID") },
                                placeholder = { Text("SH-0727182134") },
                                modifier = Modifier.fillMaxWidth(),
                                singleLine = true
                            )
                            Spacer(Modifier.height(8.dp))
                            OutlinedTextField(
                                value = manualClaimCode,
                                onValueChange = { manualClaimCode = it.trim().uppercase(Locale.US).take(32) },
                                label = { Text("Claim code") },
                                modifier = Modifier.fillMaxWidth(),
                                singleLine = true
                            )
                            Text(
                                "Required for a new lamp. An already-owned lamp can be linked using its Lamp ID.",
                                color = SHLampDesign.TextSecondary,
                                style = MaterialTheme.typography.bodySmall
                            )
                            Spacer(Modifier.height(14.dp))
                            Button(
                                onClick = {
                                    val lampId = manualLampId.trim().uppercase(Locale.US)
                                    if (!Regex("SH-[A-Z0-9]{4,16}").matches(lampId)) {
                                        error = "Enter a valid SH Lamp ID."
                                    } else {
                                        error = ""
                                        save(
                                            draft.copy(
                                                cloudLampId = lampId,
                                                claimCode = manualClaimCode.trim(),
                                                step = if (draft.mode == LampSetupMode.WIFI) {
                                                    LampSetupStep.WIFI
                                                } else {
                                                    LampSetupStep.DISCOVER
                                                }
                                            )
                                        )
                                        if (draft.mode != LampSetupMode.WIFI) onStartDiscovery { }
                                    }
                                },
                                modifier = Modifier.fillMaxWidth(),
                                colors = ButtonDefaults.buttonColors(
                                    containerColor = SHLampDesign.Primary,
                                    contentColor = SHLampDesign.OnPrimary
                                )
                            ) { Text("Continue", fontWeight = FontWeight.Bold) }
                        }
                    }

                    LampSetupStep.WIFI -> item {
                        SetupCard {
                            SetupHeroCard(
                                title = "Connect to home Wi-Fi",
                                subtitle = draft.wifiSsid.ifBlank { "Select the same 2.4 GHz network used by your phone." },
                                badge = "Step 3",
                                active = wifiSubmitted || connecting
                            )
                            Spacer(Modifier.height(18.dp))
                            Text("Connect to Wi-Fi", fontSize = 24.sp, fontWeight = FontWeight.Bold)
                            Spacer(Modifier.height(6.dp))
                            Text(
                                "The app sends these details directly to the nearby lamp through Bluetooth.",
                                color = SHLampDesign.TextSecondary
                            )
                            Spacer(Modifier.height(16.dp))
                            OutlinedTextField(
                                value = draft.wifiSsid,
                                onValueChange = { save(draft.copy(wifiSsid = it.take(32))) },
                                label = { Text("Wi-Fi network") },
                                modifier = Modifier.fillMaxWidth(),
                                singleLine = true
                            )
                            Spacer(Modifier.height(8.dp))
                            OutlinedTextField(
                                value = wifiPassword,
                                onValueChange = { wifiPassword = it.take(64) },
                                label = { Text("Wi-Fi password") },
                                modifier = Modifier.fillMaxWidth(),
                                visualTransformation = PasswordVisualTransformation(),
                                singleLine = true
                            )
                            Spacer(Modifier.height(10.dp))
                            SetupNotice(wifiStatus)
                            Spacer(Modifier.height(12.dp))
                            Button(
                                onClick = {
                                    if (draft.wifiSsid.isBlank()) {
                                        error = "Enter the Wi-Fi network name."
                                    } else {
                                        error = ""
                                        wifiSubmitted = false
                                        manager.provisionSelectedWifi(draft.wifiSsid, wifiPassword)
                                        onPersist(draft)
                                    }
                                },
                                modifier = Modifier.fillMaxWidth(),
                                enabled = !connecting,
                                colors = ButtonDefaults.buttonColors(
                                    containerColor = SHLampDesign.Primary,
                                    contentColor = SHLampDesign.OnPrimary
                                )
                            ) { Text("Connect lamp", fontWeight = FontWeight.Bold) }
                            if (wifiSubmitted) {
                                Spacer(Modifier.height(8.dp))
                                OutlinedButton(
                                    onClick = { save(draft.copy(step = LampSetupStep.NAME)) },
                                    modifier = Modifier.fillMaxWidth(),
                                    border = BorderStroke(1.dp, SHLampDesign.Border)
                                ) { Text("Continue") }
                            } else {
                                Spacer(Modifier.height(8.dp))
                                Text(
                                    "Continue appears after the lamp confirms its Wi-Fi connection.",
                                    color = SHLampDesign.TextSecondary,
                                    style = MaterialTheme.typography.bodySmall
                                )
                            }
                        }
                    }

                    LampSetupStep.NAME -> item {
                        SetupCard {
                            SetupHeroCard(
                                title = "Make the lamp yours",
                                subtitle = "Give it a clear name and place it in a room.",
                                badge = "Final step",
                                active = true
                            )
                            Spacer(Modifier.height(18.dp))
                            Text("Name your lamp", fontSize = 24.sp, fontWeight = FontWeight.Bold)
                            Spacer(Modifier.height(6.dp))
                            Text("Room is optional and can be changed later.", color = SHLampDesign.TextSecondary)
                            Spacer(Modifier.height(16.dp))
                            OutlinedTextField(
                                value = draft.lampName,
                                onValueChange = { save(draft.copy(lampName = it.take(32))) },
                                label = { Text("Lamp name") },
                                placeholder = { Text("Living Room Lamp") },
                                modifier = Modifier.fillMaxWidth(),
                                singleLine = true
                            )
                            Spacer(Modifier.height(8.dp))
                            OutlinedTextField(
                                value = draft.roomName,
                                onValueChange = { save(draft.copy(roomName = it.take(24))) },
                                label = { Text("Room (optional)") },
                                placeholder = { Text("Living Room") },
                                modifier = Modifier.fillMaxWidth(),
                                singleLine = true
                            )
                            Spacer(Modifier.height(10.dp))
                            RoomSuggestionRow(
                                selected = draft.roomName,
                                onSelect = { room -> save(draft.copy(roomName = room)) }
                            )
                            Spacer(Modifier.height(16.dp))
                            Button(
                                onClick = {
                                    if (draft.lampName.trim().length < 2) {
                                        error = "Enter a lamp name."
                                    } else {
                                        finishing = true
                                        error = ""
                                        onComplete(draft) { result ->
                                            finishing = false
                                            result.onSuccess { success ->
                                                message = success
                                                save(draft.copy(step = LampSetupStep.READY))
                                                onClearDraft()
                                            }.onFailure {
                                                error = it.message ?: "Setup could not be completed."
                                            }
                                        }
                                    }
                                },
                                modifier = Modifier.fillMaxWidth(),
                                enabled = !finishing,
                                colors = ButtonDefaults.buttonColors(
                                    containerColor = SHLampDesign.Primary,
                                    contentColor = SHLampDesign.OnPrimary
                                )
                            ) {
                                if (finishing) {
                                    CircularProgressIndicator(
                                        modifier = Modifier.size(18.dp),
                                        strokeWidth = 2.dp,
                                        color = SHLampDesign.OnPrimary
                                    )
                                    Spacer(Modifier.size(8.dp))
                                }
                                Text(if (finishing) "Finishing…" else "Finish setup", fontWeight = FontWeight.Bold)
                            }
                        }
                    }

                    LampSetupStep.READY -> item {
                        SetupCard {
                            Box(
                                modifier = Modifier
                                    .size(62.dp)
                                    .background(SHLampDesign.SuccessSoft, CircleShape),
                                contentAlignment = Alignment.Center
                            ) {
                                Text("✓", color = SHLampDesign.Success, fontSize = 30.sp, fontWeight = FontWeight.Bold)
                            }
                            Spacer(Modifier.height(14.dp))
                            Text("Your lamp is ready", fontSize = 25.sp, fontWeight = FontWeight.Bold)
                            Spacer(Modifier.height(6.dp))
                            Text(message, color = SHLampDesign.TextSecondary)
                            Spacer(Modifier.height(18.dp))
                            Button(
                                onClick = {
                                    val intent = Intent(context, CloudHomeActivity::class.java)
                                    intent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
                                    context.startActivity(intent)
                                    (context as? Activity)?.finish()
                                },
                                modifier = Modifier.fillMaxWidth(),
                                colors = ButtonDefaults.buttonColors(
                                    containerColor = SHLampDesign.Primary,
                                    contentColor = SHLampDesign.OnPrimary
                                )
                            ) { Text("Start using lamp", fontWeight = FontWeight.Bold) }
                        }
                    }
                }
            }

            if (message.isNotBlank() && draft.step != LampSetupStep.READY) {
                item { SetupNotice(message) }
            }
            if (error.isNotBlank()) {
                item { SetupError(error) }
            }
        }
    }
}

@Composable
private fun WizardHeader(step: LampSetupStep, onBack: () -> Unit) {
    val stage = when (step) {
        LampSetupStep.DISCOVER, LampSetupStep.CONFIRM -> 1
        LampSetupStep.CHOOSE_CONNECTION, LampSetupStep.ENTER_CODE -> 2
        LampSetupStep.WIFI -> 3
        LampSetupStep.NAME -> 4
        LampSetupStep.READY -> 4
    }
    Column(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            TextButton(
                onClick = onBack,
                modifier = Modifier.size(48.dp),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp)
            ) {
                Text("‹", color = SHLampDesign.TextPrimary, fontSize = 32.sp, fontWeight = FontWeight.Light)
            }
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    if (step == LampSetupStep.READY) "Setup complete" else "Add lamp",
                    color = SHLampDesign.TextPrimary,
                    fontSize = 23.sp,
                    fontWeight = FontWeight.Bold
                )
                Text(
                    when (step) {
                        LampSetupStep.DISCOVER, LampSetupStep.CONFIRM -> "Find and confirm your lamp"
                        LampSetupStep.CHOOSE_CONNECTION, LampSetupStep.ENTER_CODE -> "Choose connection and identify it"
                        LampSetupStep.WIFI -> "Connect it to home Wi-Fi"
                        LampSetupStep.NAME -> "Name it and choose a room"
                        LampSetupStep.READY -> "Your lamp has been added"
                    },
                    color = SHLampDesign.TextSecondary,
                    style = MaterialTheme.typography.bodySmall
                )
            }
            Text(
                if (step == LampSetupStep.READY) "Done" else "$stage/4",
                modifier = Modifier
                    .clip(RoundedCornerShape(12.dp))
                    .background(if (step == LampSetupStep.READY) SHLampDesign.SuccessSoft else SHLampDesign.PrimarySoft)
                    .padding(horizontal = 11.dp, vertical = 7.dp),
                color = if (step == LampSetupStep.READY) SHLampDesign.Success else SHLampDesign.PrimaryDeep,
                fontWeight = FontWeight.Bold,
                style = MaterialTheme.typography.labelMedium
            )
        }
        Spacer(Modifier.height(12.dp))
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(7.dp)
        ) {
            repeat(4) { index ->
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .height(5.dp)
                        .clip(CircleShape)
                        .background(
                            when {
                                step == LampSetupStep.READY -> SHLampDesign.Success
                                index < stage -> SHLampDesign.Primary
                                else -> SHLampDesign.Border
                            }
                        )
                )
            }
        }
    }
}

@Composable
private fun SetupHeroCard(
    title: String,
    subtitle: String,
    badge: String,
    active: Boolean
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(22.dp),
        colors = CardDefaults.cardColors(
            containerColor = if (active) SHLampDesign.SurfaceTint else SHLampDesign.SurfaceSoft
        ),
        border = BorderStroke(
            1.dp,
            if (active) SHLampDesign.Primary.copy(alpha = 0.22f) else SHLampDesign.Border
        )
    ) {
        Row(
            modifier = Modifier.padding(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            SetupLampGlyph(active = active, modifier = Modifier.size(82.dp))
            Spacer(Modifier.width(15.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    badge,
                    modifier = Modifier
                        .clip(RoundedCornerShape(10.dp))
                        .background(if (active) SHLampDesign.PrimarySoft else SHLampDesign.Surface)
                        .padding(horizontal = 9.dp, vertical = 5.dp),
                    color = if (active) SHLampDesign.PrimaryDeep else SHLampDesign.TextSecondary,
                    fontWeight = FontWeight.Bold,
                    style = MaterialTheme.typography.labelSmall
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    title,
                    color = SHLampDesign.TextPrimary,
                    fontSize = 18.sp,
                    fontWeight = FontWeight.Bold,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
                Spacer(Modifier.height(3.dp))
                Text(
                    subtitle,
                    color = SHLampDesign.TextSecondary,
                    style = MaterialTheme.typography.bodySmall,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }
    }
}

@Composable
private fun SetupLampGlyph(active: Boolean, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(24.dp))
            .background(if (active) SHLampDesign.WarmSoft else SHLampDesign.Surface),
        contentAlignment = Alignment.Center
    ) {
        Canvas(modifier = Modifier.size(58.dp)) {
            val w = size.width
            val h = size.height
            val line = if (active) SHLampDesign.WarmDeep else SHLampDesign.TextDisabled
            val shadeFill = if (active) Color(0xFFFFD98F) else SHLampDesign.SurfaceSoft
            val shade = Path().apply {
                moveTo(w * 0.24f, h * 0.38f)
                lineTo(w * 0.76f, h * 0.38f)
                lineTo(w * 0.64f, h * 0.66f)
                quadraticTo(w * 0.50f, h * 0.72f, w * 0.36f, h * 0.66f)
                close()
            }
            drawPath(shade, color = shadeFill)
            drawPath(shade, color = line, style = Stroke(width = w * 0.045f))
            drawLine(
                color = line,
                start = androidx.compose.ui.geometry.Offset(w * 0.50f, h * 0.66f),
                end = androidx.compose.ui.geometry.Offset(w * 0.50f, h * 0.84f),
                strokeWidth = w * 0.05f
            )
            drawLine(
                color = line,
                start = androidx.compose.ui.geometry.Offset(w * 0.33f, h * 0.85f),
                end = androidx.compose.ui.geometry.Offset(w * 0.67f, h * 0.85f),
                strokeWidth = w * 0.055f
            )
            if (active) {
                drawCircle(SHLampDesign.Warm, radius = w * 0.045f, center = androidx.compose.ui.geometry.Offset(w * 0.16f, h * 0.25f))
                drawCircle(SHLampDesign.Primary, radius = w * 0.035f, center = androidx.compose.ui.geometry.Offset(w * 0.82f, h * 0.24f))
                drawCircle(SHLampDesign.Warm, radius = w * 0.025f, center = androidx.compose.ui.geometry.Offset(w * 0.86f, h * 0.46f))
            }
        }
    }
}

@Composable
private fun RoomSuggestionRow(selected: String, onSelect: (String) -> Unit) {
    Column {
        Text(
            "Quick room choices",
            color = SHLampDesign.TextSecondary,
            style = MaterialTheme.typography.labelMedium
        )
        Spacer(Modifier.height(7.dp))
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            listOf("Living Room", "Bedroom", "Office").forEach { room ->
                val chosen = selected.equals(room, ignoreCase = true)
                OutlinedButton(
                    onClick = { onSelect(room) },
                    shape = RoundedCornerShape(14.dp),
                    border = BorderStroke(
                        1.dp,
                        if (chosen) SHLampDesign.Primary else SHLampDesign.Border
                    ),
                    colors = ButtonDefaults.outlinedButtonColors(
                        containerColor = if (chosen) SHLampDesign.PrimarySoft else SHLampDesign.Surface,
                        contentColor = if (chosen) SHLampDesign.PrimaryDeep else SHLampDesign.TextSecondary
                    ),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(
                        horizontal = 13.dp,
                        vertical = 8.dp
                    )
                ) {
                    Text(room, fontWeight = if (chosen) FontWeight.Bold else FontWeight.Medium)
                }
            }
        }
    }
}

@Composable
private fun SetupCard(content: @Composable ColumnScope.() -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(26.dp),
        colors = CardDefaults.cardColors(
            containerColor = SHLampDesign.Surface,
            contentColor = SHLampDesign.TextPrimary
        ),
        border = BorderStroke(1.dp, SHLampDesign.Border),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
    ) {
        Column(modifier = Modifier.padding(19.dp), content = content)
    }
}

@Composable
private fun NearbyLampResult(nearby: NearbyLamp, onAdd: () -> Unit) {
    val proximity = when {
        nearby.rssi > -65 -> "Very close"
        nearby.rssi > -78 -> "Nearby"
        else -> "Move closer"
    }
    val proximityColor = if (nearby.rssi > -78) SHLampDesign.Success else SHLampDesign.Warning
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(22.dp),
        colors = CardDefaults.cardColors(containerColor = SHLampDesign.Surface),
        border = BorderStroke(1.dp, SHLampDesign.Border)
    ) {
        Row(
            modifier = Modifier.padding(15.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            SetupLampGlyph(active = true, modifier = Modifier.size(58.dp))
            Spacer(Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    nearby.advertisedName,
                    color = SHLampDesign.TextPrimary,
                    fontWeight = FontWeight.Bold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Spacer(Modifier.height(4.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(7.dp).background(proximityColor, CircleShape))
                    Spacer(Modifier.width(6.dp))
                    Text(
                        proximity,
                        color = SHLampDesign.TextSecondary,
                        style = MaterialTheme.typography.bodySmall
                    )
                }
            }
            Button(
                onClick = onAdd,
                shape = RoundedCornerShape(15.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = SHLampDesign.Primary,
                    contentColor = SHLampDesign.OnPrimary
                ),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(
                    horizontal = 16.dp,
                    vertical = 10.dp
                )
            ) { Text("Add", fontWeight = FontWeight.Bold) }
        }
    }
}

@Composable
private fun ChoiceCard(title: String, subtitle: String, primary: Boolean, onClick: () -> Unit) {
    val iconText = if (primary) "Wi-Fi" else "BLE"
    val container = if (primary) SHLampDesign.Primary else SHLampDesign.Surface
    val content = if (primary) SHLampDesign.OnPrimary else SHLampDesign.TextPrimary
    val secondary = if (primary) SHLampDesign.OnPrimary.copy(alpha = 0.82f) else SHLampDesign.TextSecondary

    if (primary) {
        Button(
            onClick = onClick,
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 94.dp),
            shape = RoundedCornerShape(22.dp),
            colors = ButtonDefaults.buttonColors(
                containerColor = container,
                contentColor = content
            ),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(15.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    modifier = Modifier
                        .size(50.dp)
                        .background(Color.White.copy(alpha = 0.16f), RoundedCornerShape(16.dp)),
                    contentAlignment = Alignment.Center
                ) {
                    Text(iconText, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                }
                Spacer(Modifier.width(13.dp))
                Column(modifier = Modifier.weight(1f), horizontalAlignment = Alignment.Start) {
                    Text(
                        "Recommended",
                        modifier = Modifier
                            .clip(RoundedCornerShape(8.dp))
                            .background(Color.White.copy(alpha = 0.16f))
                            .padding(horizontal = 7.dp, vertical = 3.dp),
                        fontSize = 9.sp,
                        fontWeight = FontWeight.Bold
                    )
                    Spacer(Modifier.height(3.dp))
                    Text(title, fontWeight = FontWeight.Bold, fontSize = 17.sp)
                    Text(
                        subtitle,
                        color = secondary,
                        style = MaterialTheme.typography.bodySmall,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
                Text("›", fontSize = 28.sp, fontWeight = FontWeight.Light)
            }
        }
    } else {
        OutlinedButton(
            onClick = onClick,
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 90.dp),
            shape = RoundedCornerShape(22.dp),
            border = BorderStroke(1.dp, SHLampDesign.Border),
            colors = ButtonDefaults.outlinedButtonColors(
                containerColor = container,
                contentColor = content
            ),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(15.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    modifier = Modifier
                        .size(50.dp)
                        .background(SHLampDesign.SecondarySoft, RoundedCornerShape(16.dp)),
                    contentAlignment = Alignment.Center
                ) {
                    Text(iconText, color = SHLampDesign.Secondary, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                }
                Spacer(Modifier.width(13.dp))
                Column(modifier = Modifier.weight(1f), horizontalAlignment = Alignment.Start) {
                    Text(title, color = content, fontWeight = FontWeight.Bold, fontSize = 17.sp)
                    Spacer(Modifier.height(3.dp))
                    Text(
                        subtitle,
                        color = secondary,
                        style = MaterialTheme.typography.bodySmall,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
                Text("›", color = SHLampDesign.TextSecondary, fontSize = 28.sp, fontWeight = FontWeight.Light)
            }
        }
    }
}

@Composable
private fun SetupNotice(text: String) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(15.dp),
        colors = CardDefaults.cardColors(containerColor = SHLampDesign.PrimarySoft)
    ) {
        Text(
            text,
            modifier = Modifier.padding(13.dp),
            color = SHLampDesign.TextPrimary,
            style = MaterialTheme.typography.bodySmall
        )
    }
}

@Composable
private fun SetupError(text: String) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(15.dp),
        colors = CardDefaults.cardColors(containerColor = SHLampDesign.ErrorSoft)
    ) {
        Text(
            text,
            modifier = Modifier.padding(13.dp),
            color = SHLampDesign.Error,
            style = MaterialTheme.typography.bodySmall
        )
    }
}
