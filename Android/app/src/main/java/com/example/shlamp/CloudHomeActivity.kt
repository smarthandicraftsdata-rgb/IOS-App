@file:Suppress("SpellCheckingInspection")

package com.example.shlamp

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import com.example.shlamp.ui.theme.SHLampDesign
import com.example.shlamp.ui.theme.SHLAMPTheme
import org.json.JSONObject
import java.util.Locale
import java.util.concurrent.Executors
import kotlin.math.abs
import kotlin.math.roundToInt
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items as gridItems
import androidx.compose.foundation.lazy.items as listItems
import androidx.compose.foundation.rememberScrollState
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.style.TextAlign
import java.util.Calendar
import androidx.compose.ui.platform.LocalContext

private enum class LampControlPath {
    WIFI,
    BLUETOOTH,
    REMOTE,
    OFFLINE
}

private data class UnifiedLampItem(
    val lampId: String,
    val name: String,
    val room: String,
    val cloud: CloudLamp?,
    val local: LampDevice?,
    val remoteLampId: String? = cloud?.id ?: local?.remoteLampId
) {
    val claimed: Boolean get() = !remoteLampId.isNullOrBlank()
    val nearby: Boolean get() = local?.route != null && local.route != LampConnectionRoute.OFFLINE
    val cloudOnline: Boolean get() = cloud?.online == true
    val routePreference: LampRoutePreference get() = local?.routePreference ?: LampRoutePreference.AUTO
    val powerMode: LampPowerMode get() = local?.powerMode ?: cloud?.state?.powerMode ?: LampPowerMode.BALANCED
    val runtimeState: LampRuntimeState get() = local?.runtimeState ?: cloud?.state?.runtimeState ?: LampRuntimeState.UNKNOWN
    val controlPath: LampControlPath
        get() {
            val localRoute = local?.route
            return when (routePreference) {
                LampRoutePreference.REMOTE -> if (claimed) LampControlPath.REMOTE else when (localRoute) {
                    LampConnectionRoute.WIFI -> LampControlPath.WIFI
                    LampConnectionRoute.BLUETOOTH -> LampControlPath.BLUETOOTH
                    else -> LampControlPath.OFFLINE
                }
                LampRoutePreference.BLUETOOTH -> when (localRoute) {
                    LampConnectionRoute.BLUETOOTH -> LampControlPath.BLUETOOTH
                    LampConnectionRoute.WIFI -> LampControlPath.WIFI
                    else -> if (claimed) LampControlPath.REMOTE else LampControlPath.OFFLINE
                }
                LampRoutePreference.WIFI, LampRoutePreference.AUTO -> when (localRoute) {
                    LampConnectionRoute.WIFI -> LampControlPath.WIFI
                    LampConnectionRoute.BLUETOOTH -> LampControlPath.BLUETOOTH
                    LampConnectionRoute.OFFLINE, null -> if (claimed) LampControlPath.REMOTE else LampControlPath.OFFLINE
                }
            }
        }

    // A claimed lamp can always be attempted through the cloud. The backend will
    // return a clear error if the device is genuinely offline. Do not disable
    // remote controls merely because the realtime online flag is temporarily
    // stale while the phone changes Wi-Fi or mobile networks.
    val cloudCommandAvailable: Boolean get() = claimed
    val reachable: Boolean get() = nearby || cloudCommandAvailable
    val power: Boolean
        get() = when (controlPath) {
            LampControlPath.WIFI, LampControlPath.BLUETOOTH -> local?.isOn == true
            LampControlPath.REMOTE -> cloud?.state?.power ?: local?.isOn ?: false
            LampControlPath.OFFLINE -> local?.isOn ?: cloud?.state?.power ?: false
        }
    val brightness: Int
        get() = when (controlPath) {
            LampControlPath.WIFI, LampControlPath.BLUETOOTH -> local?.brightness ?: 0
            LampControlPath.REMOTE -> cloud?.state?.brightness ?: local?.brightness ?: 0
            LampControlPath.OFFLINE -> local?.brightness ?: cloud?.state?.brightness ?: 0
        }
    val batteryPercent: Int?
        get() = if (nearby) {
            local?.batteryPercent ?: cloud?.state?.batteryPercent
        } else {
            cloud?.state?.batteryPercent ?: local?.batteryPercent
        }
    val batteryVoltageMv: Int?
        get() = if (nearby) {
            local?.batteryVoltageMv ?: cloud?.state?.batteryVoltageMv
        } else {
            cloud?.state?.batteryVoltageMv ?: local?.batteryVoltageMv
        }
    val batteryCharging: Boolean
        get() = if (nearby) {
            local?.batteryCharging ?: cloud?.state?.batteryCharging ?: false
        } else {
            cloud?.state?.batteryCharging ?: local?.batteryCharging ?: false
        }
}

private data class DuplicateLampCandidate(
    val local: LampDevice,
    val cloud: CloudLamp
) {
    val key: String get() = "${local.lampId.uppercase(Locale.US)}|${cloud.id.uppercase(Locale.US)}"
}

class CloudHomeActivity : ComponentActivity(), CloudRealtimeClient.Listener {
    private val handler = Handler(Looper.getMainLooper())
    private val worker = Executors.newFixedThreadPool(3)
    private lateinit var lampManager: LampConnectionManager

    private val bluetoothManager by lazy {
        getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    }
    private val connectivityManager by lazy {
        getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    }
    private val api by lazy { CloudApiClient() }
    private val vault by lazy { CloudTokenVault(this) }
    private val sessions by lazy { CloudSessionManager(vault, api) }
    private val realtime by lazy { CloudRealtimeClient(listener = this) }

    private val dashboardState = mutableStateOf(
        CloudDashboard(listOf(CloudHome("default", "My Home")), emptyList())
    )
    private val loadingState = mutableStateOf(true)
    private val connectedState = mutableStateOf(false)
    private val connectionLabelState = mutableStateOf("Connecting…")
    private val noticeState = mutableStateOf("")
    private val currentCloudUserIdState = mutableStateOf<String?>(null)
    private val pendingCountsState = mutableStateOf<Map<String, Int>>(emptyMap())

    @Volatile
    private var dashboardLoadInFlight = false
    private var lastBluetoothDiscoveryAt = 0L
    private var localDiscoverySeeded = false
    private var networkCallbackRegistered = false
    private var radioReceiverRegistered = false

    private val networkChangedRunnable = Runnable {
        if (!isFinishing) {
            lastBluetoothDiscoveryAt = 0L
            lampManager.onPhoneNetworkChanged()
            connectRealtime(force = true)
            loadDashboard(silent = true)
            startNearbyDiscoveryIfAvailable()
        }
    }

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = scheduleNetworkContextRefresh()

        override fun onLost(network: Network) = scheduleNetworkContextRefresh()

        override fun onCapabilitiesChanged(
            network: Network,
            networkCapabilities: NetworkCapabilities
        ) = scheduleNetworkContextRefresh()
    }

    private val radioStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                BluetoothAdapter.ACTION_STATE_CHANGED -> {
                    when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                        BluetoothAdapter.STATE_ON -> {
                            lastBluetoothDiscoveryAt = 0L
                            handler.postDelayed({ startNearbyDiscoveryIfAvailable(force = true) }, 250L)
                        }
                        BluetoothAdapter.STATE_OFF -> {
                            lampManager.onPhoneBluetoothDisabled()
                        }
                    }
                }
                WifiManager.WIFI_STATE_CHANGED_ACTION,
                WifiManager.NETWORK_STATE_CHANGED_ACTION -> scheduleNetworkContextRefresh()
            }
        }
    }

    private val refreshRunnable = object : Runnable {
        override fun run() {
            if (!isFinishing) {
                loadDashboard(silent = true)
                startNearbyDiscoveryIfAvailable()
                handler.postDelayed(this, 8_000L)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        lampManager = LampConnectionManager(this, handler)
        setContent {
            SHLAMPTheme {
                UnifiedHomeScreen(
                    dashboard = dashboardState.value,
                    localLamps = lampManager.lamps.value,
                    activeCloudUserId = currentCloudUserIdState.value,
                    confirmedCloudLampIds = lampManager.confirmedCloudLampIds(),
                    cloudIdentityByLocalId = lampManager.confirmedCloudIdentityByLocalId(),
                    loading = loadingState.value,
                    connected = connectedState.value,
                    connectionLabel = connectionLabelState.value,
                    notice = noticeState.value,
                    pendingLampIds = pendingCountsState.value.filterValues { it > 0 }.keys,
                    onRefresh = { loadDashboard(silent = false) },
                    onAddLamp = ::openAddLamp,
                    onPower = ::setLampPower,
                    onBrightness = ::setLampBrightness,
                    onPowerMode = ::setLampPowerMode,
                    onRoutePreference = ::setLampRoutePreference,
                    onLocalFade = ::setLocalFade,
                    onLocalTimer = ::setLocalTimer,
                    onIdentify = ::identifyLamp,
                    onIdentifyDuplicate = ::identifyDuplicateLamp,
                    onLinkDuplicate = ::linkDuplicateLamp,
                    onOpenLamp = { item ->
                        lampManager.selectLamp(item.lampId, connectBle = true)
                    },
                    onOpenSettings = ::openLampSettings,
                    onSignOut = ::signOut
                )
            }
        }
    }

    override fun onStart() {
        super.onStart()
        if (vault.readSession() == null) {
            returnToAccount("Please sign in to continue.")
            return
        }
        lampManager.reloadSavedLamps()
        lampManager.start()
        lampManager.refreshNetworkContext()
        registerNetworkWatcher()
        registerRadioWatcher()
        loadDashboard(silent = false)
        startNearbyDiscoveryIfAvailable()
        handler.removeCallbacks(refreshRunnable)
        handler.postDelayed(refreshRunnable, 8_000L)
    }

    override fun onStop() {
        handler.removeCallbacks(refreshRunnable)
        handler.removeCallbacks(networkChangedRunnable)
        unregisterNetworkWatcher()
        unregisterRadioWatcher()
        realtime.stop()
        lampManager.stop()
        localDiscoverySeeded = false
        super.onStop()
    }

    override fun onDestroy() {
        handler.removeCallbacks(networkChangedRunnable)
        lampManager.close()
        worker.shutdownNow()
        super.onDestroy()
    }

    private fun scheduleNetworkContextRefresh() {
        handler.removeCallbacks(networkChangedRunnable)
        handler.postDelayed(networkChangedRunnable, 350L)
    }

    private fun registerNetworkWatcher() {
        if (networkCallbackRegistered) return
        runCatching {
            connectivityManager.registerDefaultNetworkCallback(networkCallback)
            networkCallbackRegistered = true
        }
    }

    private fun unregisterNetworkWatcher() {
        if (!networkCallbackRegistered) return
        runCatching { connectivityManager.unregisterNetworkCallback(networkCallback) }
        networkCallbackRegistered = false
    }

    private fun registerRadioWatcher() {
        if (radioReceiverRegistered) return
        val filter = IntentFilter().apply {
            addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
            addAction(WifiManager.WIFI_STATE_CHANGED_ACTION)
            addAction(WifiManager.NETWORK_STATE_CHANGED_ACTION)
        }
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(radioStateReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                registerReceiver(radioStateReceiver, filter)
            }
            radioReceiverRegistered = true
        }
    }

    private fun unregisterRadioWatcher() {
        if (!radioReceiverRegistered) return
        runCatching { unregisterReceiver(radioStateReceiver) }
        radioReceiverRegistered = false
    }

    private fun loadDashboard(silent: Boolean) {
        if (dashboardLoadInFlight) return
        dashboardLoadInFlight = true
        if (!silent) {
            loadingState.value = true
            connectionLabelState.value = "Updating…"
        }

        // Snapshot confirmed remote IDs before leaving the main thread. The
        // exact-device fallback below is intentionally independent of the list
        // endpoint and realtime socket, so a temporary dashboard parsing or
        // reconnect problem cannot erase remote capability.
        val confirmedRemoteIds = lampManager.confirmedCloudLampIds().toList()

        worker.execute {
            val result = runCatching {
                sessions.execute { token ->
                    val me = api.readMe(token)
                    if (me.unauthorized) throw UnauthorizedException()
                    val listed = api.loadDashboard(token)
                    val listedIds = listed.lamps
                        .map { it.id.uppercase(Locale.US) }
                        .toSet()
                    val recovered = confirmedRemoteIds
                        .filterNot { it.uppercase(Locale.US) in listedIds }
                        .mapNotNull { remoteId ->
                            runCatching { api.readDevice(token, remoteId) }.getOrNull()
                        }
                    val dashboard = listed.copy(
                        lamps = mergeCloudLampSnapshots(listed.lamps, recovered)
                    )
                    me.user to dashboard
                }
            }
            runOnUiThread {
                dashboardLoadInFlight = false
                loadingState.value = false
                result.onSuccess { (user, dashboard) ->
                    currentCloudUserIdState.value = user?.id
                    dashboardState.value = dashboard
                    lampManager.refreshNetworkContext()
                    lampManager.syncCloudLamps(dashboard.lamps, user?.id)
                    if (!localDiscoverySeeded && dashboard.lamps.isNotEmpty()) {
                        lampManager.stop()
                        lampManager.start()
                        localDiscoverySeeded = true
                    }
                    startNearbyDiscoveryIfAvailable()
                    noticeState.value = ""
                    if (!connectedState.value) connectionLabelState.value = "Ready"
                    connectRealtime()
                }.onFailure { error ->
                    if (error is UnauthorizedException) {
                        returnToAccount("Your sign-in expired. Please sign in again.")
                    } else {
                        connectionLabelState.value = "Connection issue"
                        noticeState.value = friendlyHomeError(error)
                    }
                }
            }
        }
    }

    private fun connectRealtime(force: Boolean = false) {
        val token = sessions.accessToken() ?: return
        val homeId = dashboardState.value.homes.firstOrNull()?.id ?: "default"
        realtime.start(token, homeId, force)
    }

    /**
     * One command entry point for every lamp. Local Wi-Fi is attempted first,
     * then an already-connected BLE route, and finally the permanent cloud ID.
     * Remote control therefore does not depend on a transient CloudLamp UI
     * object being present after a phone network change.
     */
    private fun setLampPower(item: UnifiedLampItem, power: Boolean) {
        val commandLampId = item.remoteLampId
        val localLampId = item.local?.lampId ?: item.lampId
        val payload = JSONObject()
            .put("power", power)
            .put("on", power)
            .put("value", power)

        item.cloud?.let { cloud ->
            optimisticCloudUpdate(
                cloud.id,
                cloud.copy(
                    state = cloud.state.copy(
                        power = power,
                        brightness = if (power && cloud.state.brightness == 0) 20 else cloud.state.brightness
                    )
                )
            )
        }
        beginPending(item.lampId)
        lampManager.powerLamp(
            lampId = localLampId,
            on = power,
            onHandled = {
                endPending(item.lampId)
                scheduleStateRefresh()
            },
            onUnavailable = {
                if (commandLampId.isNullOrBlank()) {
                    endPending(item.lampId)
                    noticeState.value = "Move closer to ${item.name} or connect it to your account."
                } else {
                    sendCommand(
                        lampId = commandLampId,
                        action = "setPower",
                        payload = payload,
                        pendingAlreadyStarted = true,
                        pendingUiLampId = item.lampId
                    )
                }
            }
        )
    }

    private fun setLampBrightness(item: UnifiedLampItem, brightness: Int) {
        val requested = brightness.coerceIn(0, 100)
        val value = if (item.powerMode == LampPowerMode.MAX_BACKUP) requested.coerceAtMost(70) else requested
        if (requested != value) {
            noticeState.value = "Maximum Backup limits brightness to 70%."
        }
        val commandLampId = item.remoteLampId
        val localLampId = item.local?.lampId ?: item.lampId
        val payload = JSONObject()
            .put("brightness", value)
            .put("value", value)
            .put("power", value > 0)

        item.cloud?.let { cloud ->
            optimisticCloudUpdate(
                cloud.id,
                cloud.copy(state = cloud.state.copy(power = value > 0, brightness = value))
            )
        }
        beginPending(item.lampId)
        lampManager.brightnessLamp(
            lampId = localLampId,
            percent = value,
            onHandled = {
                endPending(item.lampId)
                scheduleStateRefresh()
            },
            onUnavailable = {
                if (commandLampId.isNullOrBlank()) {
                    endPending(item.lampId)
                    noticeState.value = "Move closer to ${item.name} or connect it to your account."
                } else {
                    sendCommand(
                        lampId = commandLampId,
                        action = "setBrightness",
                        payload = payload,
                        pendingAlreadyStarted = true,
                        pendingUiLampId = item.lampId
                    )
                }
            }
        )
    }

    private fun setLampPowerMode(item: UnifiedLampItem, mode: LampPowerMode) {
        val local = item.local
        if (local == null) {
            noticeState.value = "Connect to the lamp through local Wi-Fi or Bluetooth to change battery mode."
            return
        }
        beginPending(item.lampId)
        lampManager.powerModeLamp(
            lampId = local.lampId,
            mode = mode,
            onHandled = {
                endPending(item.lampId)
                noticeState.value = when (mode) {
                    LampPowerMode.MAX_BACKUP -> "Maximum Backup enabled. Brightness is limited to 70%."
                    LampPowerMode.BLE_ONLY -> "BLE Only enabled. Wi-Fi and remote control are now unavailable."
                    LampPowerMode.TOUCH_ONLY -> "Touch Only enabled. Restart the lamp to restore wireless control."
                    LampPowerMode.BALANCED -> "Balanced mode enabled."
                }
                scheduleStateRefresh(1_200L)
            },
            onUnavailable = {
                endPending(item.lampId)
                noticeState.value = "Battery mode changes require a nearby Wi-Fi or Bluetooth connection."
            }
        )
    }

    private fun setLampRoutePreference(item: UnifiedLampItem, preference: LampRoutePreference) {
        val localId = item.local?.lampId ?: item.lampId
        lampManager.setRoutePreference(localId, preference)
        noticeState.value = when (preference) {
            LampRoutePreference.AUTO -> "Connection set to Automatic."
            LampRoutePreference.WIFI -> "Local Wi-Fi is preferred when available."
            LampRoutePreference.BLUETOOTH -> "Connecting through Bluetooth when the lamp is nearby."
            LampRoutePreference.REMOTE -> "Remote cloud control is preferred."
        }
        if (preference == LampRoutePreference.BLUETOOTH) startNearbyDiscoveryIfAvailable(force = true)
    }

    private fun setLocalFade(item: UnifiedLampItem, mode: Int) {
        val local = item.local ?: return
        beginPending(item.lampId)
        lampManager.fadeLamp(
            lampId = local.lampId,
            mode = mode,
            onHandled = { endPending(item.lampId) },
            onUnavailable = {
                endPending(item.lampId)
                noticeState.value = "Fade speed is available when ${item.name} is nearby."
            }
        )
    }

    private fun setLocalTimer(item: UnifiedLampItem, minutes: Int) {
        val local = item.local ?: return
        beginPending(item.lampId)
        lampManager.timerLamp(
            lampId = local.lampId,
            minutes = minutes,
            onHandled = { endPending(item.lampId) },
            onUnavailable = {
                endPending(item.lampId)
                noticeState.value = "The auto-off timer is available when ${item.name} is nearby."
            }
        )
    }

    private fun identifyLamp(item: UnifiedLampItem) {
        beginPending(item.lampId)
        lampManager.identifyLamp(
            lampId = item.lampId,
            onHandled = { endPending(item.lampId) },
            onUnavailable = {
                val remoteId = item.remoteLampId
                if (remoteId.isNullOrBlank()) {
                    endPending(item.lampId)
                    noticeState.value = "The lamp is not nearby and is not linked for remote control."
                } else {
                    sendCommand(
                        lampId = remoteId,
                        action = "identify",
                        payload = JSONObject().put("value", true),
                        pendingAlreadyStarted = true,
                        pendingUiLampId = item.lampId
                    )
                }
            }
        )
    }

    private fun identifyDuplicateLamp(lamp: LampDevice) {
        beginPending(lamp.lampId)
        lampManager.identifyLamp(
            lampId = lamp.lampId,
            onHandled = { endPending(lamp.lampId) },
            onUnavailable = {
                endPending(lamp.lampId)
                noticeState.value = "Move closer to ${lamp.name} and try again."
            }
        )
    }

    private fun linkDuplicateLamp(local: LampDevice, cloud: CloudLamp) {
        lampManager.linkLampIdentity(local.lampId, cloud.id, currentCloudUserIdState.value)
        noticeState.value = "${cloud.name} is now shown as one lamp."
        loadDashboard(silent = true)
    }

    private fun sendCommand(
        lampId: String,
        action: String,
        payload: JSONObject,
        pendingAlreadyStarted: Boolean = false,
        pendingUiLampId: String = lampId
    ) {
        if (!pendingAlreadyStarted) beginPending(pendingUiLampId)
        noticeState.value = ""
        worker.execute {
            val result = runCatching {
                sessions.execute { token -> api.sendCommand(token, lampId, action, payload) }
            }
            runOnUiThread {
                endPending(pendingUiLampId)
                result.onSuccess { scheduleStateRefresh() }
                    .onFailure { error ->
                        if (error is UnauthorizedException) {
                            returnToAccount("Your sign-in expired. Please sign in again.")
                        } else {
                            noticeState.value = friendlyHomeError(error)
                            scheduleStateRefresh(1_200L)
                        }
                    }
            }
        }
    }

    private fun beginPending(lampId: String) {
        val current = pendingCountsState.value.toMutableMap()
        current[lampId] = (current[lampId] ?: 0) + 1
        pendingCountsState.value = current
    }

    private fun endPending(lampId: String) {
        val current = pendingCountsState.value.toMutableMap()
        val next = (current[lampId] ?: 1) - 1
        if (next <= 0) current.remove(lampId) else current[lampId] = next
        pendingCountsState.value = current
    }

    private fun scheduleStateRefresh(delayMs: Long = 900L) {
        handler.postDelayed({ loadDashboard(silent = true) }, delayMs)
    }

    private fun startNearbyDiscoveryIfAvailable(force: Boolean = false) {
        if (!hasBluetoothPermissions()) return
        val adapter = bluetoothManager.adapter ?: return
        if (!adapter.isEnabled) return

        val known = lampManager.lamps.value
        val now = System.currentTimeMillis()
        if (known.isNotEmpty() && (force || now - lastBluetoothDiscoveryAt >= 60_000L)) {
            lastBluetoothDiscoveryAt = now
            lampManager.discoverKnownBluetoothLamps()
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

    private fun optimisticCloudUpdate(lampId: String, replacement: CloudLamp) {
        dashboardState.value = dashboardState.value.copy(
            lamps = dashboardState.value.lamps.map { if (it.id == lampId) replacement else it }
        )
    }

    private fun openAddLamp() {
        startActivity(Intent(this, AddLampActivity::class.java))
    }

    private fun openLampSettings(item: UnifiedLampItem) {
        startActivity(
            Intent(this, LampSettingsActivity::class.java)
                .putExtra(LampSettingsActivity.EXTRA_LAMP_ID, item.lampId)
                .putExtra(LampSettingsActivity.EXTRA_REMOTE_LAMP_ID, item.remoteLampId)
                .putExtra(LampSettingsActivity.EXTRA_CLAIMED, item.claimed)
                .putExtra(LampSettingsActivity.EXTRA_CLOUD_ONLINE, item.cloudOnline)
        )
    }

    private fun signOut() {
        realtime.stop()
        vault.clear()
        returnToAccount("You have been signed out.")
    }

    private fun returnToAccount(message: String) {
        val intent = Intent(this, CloudAccountActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra("cloud_message", message)
        startActivity(intent)
        finish()
    }

    override fun onStatus(status: String, connected: Boolean) {
        runOnUiThread {
            connectedState.value = connected
            connectionLabelState.value = status.ifBlank {
                if (connected) "Account connected" else "Connecting…"
            }
        }
    }

    override fun onMessage(text: String) {
        val update = api.parseRealtimeUpdate(text) ?: return
        runOnUiThread {
            update.userId?.let { currentCloudUserIdState.value = it }
            if (update.authenticated) {
                connectedState.value = true
                connectionLabelState.value = "Online"
            }

            if (update.lamps.isNotEmpty()) {
                val merged = mergeCloudLampSnapshots(dashboardState.value.lamps, update.lamps)
                dashboardState.value = dashboardState.value.copy(lamps = merged)
                lampManager.syncCloudLamps(merged, update.userId ?: currentCloudUserIdState.value)
            }

            val changedLamp = update.lamp
            val changedLampId = (changedLamp?.id ?: update.lampId).orEmpty()
            if (changedLampId.isNotBlank()) {
                val existing = dashboardState.value.lamps
                val old = existing.firstOrNull { it.id.equals(changedLampId, ignoreCase = true) }
                val replacement = when {
                    changedLamp != null && old != null -> changedLamp.copy(
                        homeId = changedLamp.homeId.ifBlank { old.homeId },
                        roomId = changedLamp.roomId ?: old.roomId,
                        roomName = changedLamp.roomName ?: old.roomName,
                        name = changedLamp.name.takeUnless { it == "SH Lamp" } ?: old.name,
                        model = changedLamp.model.ifBlank { old.model },
                        online = update.online ?: changedLamp.online,
                        lastSeen = changedLamp.lastSeen ?: old.lastSeen
                    )
                    changedLamp != null -> changedLamp
                    old != null && update.online != null -> old.copy(online = update.online)
                    else -> null
                }
                if (replacement != null) {
                    val merged = mergeCloudLampSnapshots(existing, listOf(replacement))
                    dashboardState.value = dashboardState.value.copy(lamps = merged)
                    lampManager.syncCloudLamps(merged, currentCloudUserIdState.value)
                } else {
                    loadDashboard(silent = true)
                }
            }

            update.errorMessage?.takeIf(String::isNotBlank)?.let { message ->
                noticeState.value = message
            }
        }
    }

    private fun mergeCloudLampSnapshots(
        existing: List<CloudLamp>,
        incoming: List<CloudLamp>
    ): List<CloudLamp> {
        val map = linkedMapOf<String, CloudLamp>()
        existing.forEach { map[it.id.uppercase(Locale.US)] = it }
        incoming.forEach { fresh ->
            val key = fresh.id.uppercase(Locale.US)
            val old = map[key]
            map[key] = if (old == null) fresh else fresh.copy(
                homeId = fresh.homeId.ifBlank { old.homeId },
                roomId = fresh.roomId ?: old.roomId,
                roomName = fresh.roomName ?: old.roomName,
                name = fresh.name.takeUnless { it == "SH Lamp" || it.isBlank() } ?: old.name,
                model = fresh.model.ifBlank { old.model },
                lastSeen = fresh.lastSeen ?: old.lastSeen
            )
        }
        return map.values.toList()
    }

}

@Composable
private fun UnifiedHomeScreen(
    dashboard: CloudDashboard,
    localLamps: List<LampDevice>,
    activeCloudUserId: String?,
    confirmedCloudLampIds: Set<String>,
    cloudIdentityByLocalId: Map<String, String>,
    loading: Boolean,
    connected: Boolean,
    connectionLabel: String,
    notice: String,
    pendingLampIds: Set<String>,
    onRefresh: () -> Unit,
    onAddLamp: () -> Unit,
    onPower: (UnifiedLampItem, Boolean) -> Unit,
    onBrightness: (UnifiedLampItem, Int) -> Unit,
    onPowerMode: (UnifiedLampItem, LampPowerMode) -> Unit,
    onRoutePreference: (UnifiedLampItem, LampRoutePreference) -> Unit,
    onLocalFade: (UnifiedLampItem, Int) -> Unit,
    onLocalTimer: (UnifiedLampItem, Int) -> Unit,
    onIdentify: (UnifiedLampItem) -> Unit,
    onIdentifyDuplicate: (LampDevice) -> Unit,
    onLinkDuplicate: (LampDevice, CloudLamp) -> Unit,
    onOpenLamp: (UnifiedLampItem) -> Unit,
    onOpenSettings: (UnifiedLampItem) -> Unit,
    onSignOut: () -> Unit
) {
    val context = LocalContext.current
    ModernLampApp(
        dashboard = dashboard,
        localLamps = localLamps,
        activeCloudUserId = activeCloudUserId,
        confirmedCloudLampIds = confirmedCloudLampIds,
        cloudIdentityByLocalId = cloudIdentityByLocalId,
        loading = loading,
        connected = connected,
        connectionLabel = connectionLabel,
        notice = notice,
        pendingLampIds = pendingLampIds,
        onRefresh = onRefresh,
        onAddLamp = onAddLamp,
        onPower = onPower,
        onBrightness = onBrightness,
        onPowerMode = onPowerMode,
        onRoutePreference = onRoutePreference,
        onLocalFade = onLocalFade,
        onLocalTimer = onLocalTimer,
        onIdentify = onIdentify,
        onIdentifyDuplicate = onIdentifyDuplicate,
        onLinkDuplicate = onLinkDuplicate,
        onOpenLamp = onOpenLamp,
        onOpenSettings = onOpenSettings,
        onOpenDiagnostics = { item ->
            val diagnosticsIntent = Intent(context, ConnectionDiagnosticsActivity::class.java)
            if (item != null) {
                diagnosticsIntent
                    .putExtra(ConnectionDiagnosticsActivity.EXTRA_LAMP_ID, item.lampId)
                    .putExtra(
                        ConnectionDiagnosticsActivity.EXTRA_REMOTE_LAMP_ID,
                        item.remoteLampId.orEmpty()
                    )
                    .putExtra(ConnectionDiagnosticsActivity.EXTRA_CLAIMED, item.claimed)
                    .putExtra(
                        ConnectionDiagnosticsActivity.EXTRA_CLOUD_ONLINE,
                        item.cloudOnline
                    )
            }
            context.startActivity(diagnosticsIntent)
        },
        onSignOut = onSignOut
    )
}

private fun findDuplicateCandidate(
    cloudLamps: List<CloudLamp>,
    localLamps: List<LampDevice>
): DuplicateLampCandidate? {
    val cloudIds = cloudLamps.map { it.id.uppercase(Locale.US) }.toSet()
    val nearbyUnlinked = localLamps.filter { local ->
        local.route != LampConnectionRoute.OFFLINE &&
            !local.isCloudLinked &&
            local.lampId.uppercase(Locale.US) !in cloudIds
    }
    val cloudWithoutNearbyMatch = cloudLamps.filter { cloud ->
        localLamps.none { local ->
            local.route != LampConnectionRoute.OFFLINE &&
                local.lampId.equals(cloud.id, ignoreCase = true)
        }
    }
    return if (nearbyUnlinked.size == 1 && cloudWithoutNearbyMatch.size == 1) {
        DuplicateLampCandidate(nearbyUnlinked.single(), cloudWithoutNearbyMatch.single())
    } else {
        null
    }
}

@Composable
private fun DuplicateLampCard(
    candidate: DuplicateLampCandidate,
    onBlink: () -> Unit,
    onLink: () -> Unit,
    onKeepSeparate: () -> Unit
) {
    Card(
        shape = RoundedCornerShape(22.dp),
        colors = CardDefaults.cardColors(containerColor = SHLampDesign.WarmSoft),
        border = BorderStroke(1.dp, SHLampDesign.PrimarySoft)
    ) {
        Column(Modifier.padding(18.dp)) {
            Text("Possible duplicate lamp", fontSize = 20.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(6.dp))
            Text(
                "The nearby lamp “${candidate.local.name}” may be the same physical lamp as “${candidate.cloud.name}” in your account.",
                color = SHLampDesign.TextSecondary
            )
            Spacer(Modifier.height(12.dp))
            OutlinedButton(
                onClick = onBlink,
                modifier = Modifier.fillMaxWidth(),
                border = BorderStroke(1.dp, SHLampDesign.Border)
            ) { Text("Blink nearby lamp") }
            Spacer(Modifier.height(8.dp))
            Button(
                onClick = onLink,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(
                    containerColor = SHLampDesign.Primary,
                    contentColor = SHLampDesign.OnPrimary
                )
            ) { Text("Yes, show as one lamp", fontWeight = FontWeight.Bold) }
            TextButton(onClick = onKeepSeparate, modifier = Modifier.fillMaxWidth()) {
                Text("No, keep them separate", color = SHLampDesign.TextSecondary)
            }
        }
    }
}

private fun mergeLampItems(
    cloudLamps: List<CloudLamp>,
    localLamps: List<LampDevice>,
    activeCloudUserId: String?,
    confirmedCloudLampIds: Set<String>,
    cloudIdentityByLocalId: Map<String, String>
): List<UnifiedLampItem> {
    fun normalizeId(value: String): String = value.trim().uppercase(Locale.US)

    fun accountAllowsLocalCloudLink(local: LampDevice): Boolean {
        val storedOwner = local.cloudOwnerUserId?.trim().orEmpty()
        val activeOwner = activeCloudUserId?.trim().orEmpty()
        return storedOwner.isBlank() || activeOwner.isBlank() || storedOwner == activeOwner
    }

    val normalizedIdentityLinks = cloudIdentityByLocalId
        .mapKeys { (localId, _) -> normalizeId(localId) }
        .mapValues { (_, cloudId) -> normalizeId(cloudId) }

    fun canonicalLocalId(local: LampDevice): String {
        val localId = normalizeId(local.lampId)
        return local.remoteLampId
            ?.takeIf { accountAllowsLocalCloudLink(local) }
            ?.let(::normalizeId)
            ?: normalizedIdentityLinks[localId]
            ?: localId
    }

    val cloudById = cloudLamps
        .associateBy { normalizeId(it.id) }
        .toMutableMap()

    // A successful cloud sync or an explicit duplicate-link confirmation is
    // sufficient proof that a permanent lamp ID belongs to this account.
    // Create a temporary cloud view while the dashboard refresh reconnects so
    // changing the phone network cannot disable remote power/brightness.
    val permittedPersistedCloudIds = localLamps
        .filter(::accountAllowsLocalCloudLink)
        .mapNotNull { it.remoteLampId }
    (confirmedCloudLampIds + permittedPersistedCloudIds)
        .map(::normalizeId)
        .forEach { cloudId ->
            if (cloudById.containsKey(cloudId)) return@forEach
            val local = localLamps.firstOrNull {
                accountAllowsLocalCloudLink(it) && canonicalLocalId(it) == cloudId
            } ?: return@forEach
            cloudById[cloudId] = CloudLamp(
                id = cloudId,
                homeId = "default",
                roomId = null,
                roomName = local.room.takeUnless { it.isBlank() || it == "Unassigned" },
                name = local.name.ifBlank { "SH Lamp" },
                model = "SH Lamp",
                online = false,
                lastSeen = null,
                state = CloudLampState(
                    power = local.isOn,
                    brightness = local.brightness.coerceIn(0, 100),
                    fadeMode = local.fadeMode.coerceIn(0, 3),
                    timerRemainingSeconds = local.timerRemainingSeconds.coerceAtLeast(0L),
                    batteryValid = local.batteryPercent != null || local.batteryVoltageMv != null,
                    batteryPercent = local.batteryPercent,
                    batteryVoltageMv = local.batteryVoltageMv,
                    batteryCharging = local.batteryCharging
                )
            )
        }

    val localById = linkedMapOf<String, LampDevice>()
    localLamps.forEach { local ->
        val linkedId = canonicalLocalId(local)
        val suffix = linkedId.removePrefix("SH-")
        val matchingCloudIds = if (
            linkedId.startsWith("SH-") &&
            suffix.length == 6 &&
            linkedId !in cloudById
        ) {
            cloudById.keys.filter { cloudId ->
                cloudId.length > linkedId.length &&
                    cloudId.removePrefix("SH-").endsWith(suffix)
            }
        } else {
            emptyList()
        }
        val key = when {
            linkedId in cloudById -> linkedId
            matchingCloudIds.size == 1 -> matchingCloudIds.single()
            else -> linkedId
        }
        val normalizedLocal = if (normalizeId(local.lampId) == key) {
            local
        } else {
            local.copy(lampId = key)
        }
        val previous = localById[key]
        if (previous == null ||
            (previous.route == LampConnectionRoute.OFFLINE &&
                normalizedLocal.route != LampConnectionRoute.OFFLINE) ||
            normalizedLocal.lastSeenAt > previous.lastSeenAt
        ) {
            localById[key] = normalizedLocal
        }
    }

    return (cloudById.keys + localById.keys)
        .distinct()
        .map { id ->
            val cloud = cloudById[id]
            val local = localById[id]
            UnifiedLampItem(
                lampId = cloud?.id ?: local?.lampId ?: id,
                name = cloud?.name?.takeIf(String::isNotBlank)
                    ?: local?.name?.takeIf(String::isNotBlank)
                    ?: "SH Lamp",
                room = cloud?.roomName?.takeIf(String::isNotBlank)
                    ?: local?.room?.takeUnless { it.isBlank() || it == "Unassigned" }
                    ?: "",
                cloud = cloud,
                local = local,
                remoteLampId = cloud?.id ?: local?.remoteLampId
                    ?.takeIf { accountAllowsLocalCloudLink(local) }
            )
        }
        .sortedWith(
            compareBy<UnifiedLampItem> { it.room.ifBlank { "zzzz" }.lowercase() }
                .thenBy { it.name.lowercase() }
        )
}

@Composable
private fun UnifiedHeader(
    lampCount: Int,
    connected: Boolean,
    connectionLabel: String,
    loading: Boolean,
    onRefresh: () -> Unit,
    onAddLamp: () -> Unit
) {
    Column {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text("My Lamps", fontSize = 30.sp, fontWeight = FontWeight.Bold)
                Text(
                    when (lampCount) {
                        0 -> "Add your first lamp"
                        1 -> "1 lamp"
                        else -> "$lampCount lamps"
                    },
                    color = SHLampDesign.TextSecondary
                )
            }
            TextButton(onClick = onRefresh, enabled = !loading) {
                if (loading) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(18.dp),
                        strokeWidth = 2.dp,
                        color = SHLampDesign.Primary
                    )
                } else {
                    Text("Refresh", color = SHLampDesign.Primary)
                }
            }
            Button(
                onClick = onAddLamp,
                modifier = Modifier.size(48.dp),
                shape = CircleShape,
                contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = SHLampDesign.Primary,
                    contentColor = SHLampDesign.OnPrimary
                )
            ) { Text("+", fontSize = 26.sp, fontWeight = FontWeight.Bold) }
        }
        Spacer(Modifier.height(12.dp))
        Card(
            shape = RoundedCornerShape(50),
            colors = CardDefaults.cardColors(
                containerColor = if (connected) SHLampDesign.SuccessSoft else SHLampDesign.WarmSoft
            )
        ) {
            Row(
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 7.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    Modifier
                        .size(8.dp)
                        .background(if (connected) SHLampDesign.Success else SHLampDesign.Warm, CircleShape)
                )
                Spacer(Modifier.size(7.dp))
                Text(connectionLabel, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

@Composable
private fun CompactLampCard(
    item: UnifiedLampItem,
    pending: Boolean,
    onOpen: () -> Unit,
    onPower: (Boolean) -> Unit
) {
    val brightnessFraction = item.brightness.coerceIn(0, 100) / 100f
    val cardSurface = if (item.power) SHLampDesign.SurfaceRaised else SHLampDesign.Surface
    val cardBorder = if (item.power) {
        SHLampDesign.Primary.copy(alpha = 0.42f)
    } else {
        SHLampDesign.Border.copy(alpha = 0.72f)
    }

    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onOpen),
        shape = RoundedCornerShape(22.dp),
        colors = CardDefaults.cardColors(containerColor = cardSurface),
        border = BorderStroke(1.dp, cardBorder),
        elevation = CardDefaults.cardElevation(
            defaultElevation = if (item.power) 5.dp else 1.dp
        )
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            LampCardGlyph(isOn = item.power)
            Spacer(Modifier.size(13.dp))

            Column(modifier = Modifier.weight(1f)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        item.name,
                        modifier = Modifier.weight(1f),
                        fontSize = 17.sp,
                        fontWeight = FontWeight.Bold,
                        color = SHLampDesign.TextPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    item.batteryPercent?.let { percent ->
                        Spacer(Modifier.size(8.dp))
                        PhoneBatteryIndicator(
                            percent = percent,
                            charging = item.batteryCharging,
                            showPercent = true
                        )
                    }
                    Spacer(Modifier.size(8.dp))
                    LampConnectionChip(item)
                }

                Spacer(Modifier.height(4.dp))
                Text(
                    listOfNotNull(
                        item.room.takeIf { it.isNotBlank() && it != "Unassigned" },
                        lampConnectionDetail(item)
                    ).joinToString(" • "),
                    color = SHLampDesign.TextSecondary,
                    style = MaterialTheme.typography.bodySmall,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )

                Spacer(Modifier.height(10.dp))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .height(5.dp)
                            .background(SHLampDesign.SurfaceSoft, RoundedCornerShape(50))
                    ) {
                        if (brightnessFraction > 0f) {
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth(brightnessFraction)
                                    .height(5.dp)
                                    .background(
                                        if (item.power) SHLampDesign.Warm else SHLampDesign.Offline,
                                        RoundedCornerShape(50)
                                    )
                            )
                        }
                    }
                    Spacer(Modifier.size(9.dp))
                    Text(
                        "${item.brightness.coerceIn(0, 100)}%",
                        color = if (item.power) SHLampDesign.Warm else SHLampDesign.TextSecondary,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold
                    )
                    Spacer(Modifier.size(8.dp))
                    Text("›", fontSize = 24.sp, color = SHLampDesign.TextDisabled)
                }
            }

            Spacer(Modifier.size(12.dp))
            Box(contentAlignment = Alignment.Center) {
                Button(
                    onClick = { onPower(!item.power) },
                    enabled = item.reachable && !pending,
                    modifier = Modifier.size(48.dp),
                    shape = CircleShape,
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = if (item.power) SHLampDesign.Primary else SHLampDesign.SurfaceSoft,
                        contentColor = if (item.power) SHLampDesign.OnPrimary else SHLampDesign.TextPrimary,
                        disabledContainerColor = SHLampDesign.SurfaceSoft,
                        disabledContentColor = SHLampDesign.TextDisabled
                    )
                ) {
                    Text("⏻", fontSize = 22.sp, fontWeight = FontWeight.Bold)
                }
                if (pending) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(48.dp),
                        strokeWidth = 2.dp,
                        color = SHLampDesign.Primary
                    )
                }
            }
        }
    }
}

@Composable
private fun LampCardGlyph(isOn: Boolean) {
    val glow = if (isOn) SHLampDesign.WarmSoft else SHLampDesign.SurfaceSoft
    val bulb = if (isOn) SHLampDesign.Warm else SHLampDesign.TextDisabled
    Box(
        modifier = Modifier
            .size(52.dp)
            .background(glow, CircleShape),
        contentAlignment = Alignment.Center
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Box(
                modifier = Modifier
                    .size(width = 22.dp, height = 24.dp)
                    .background(
                        bulb,
                        RoundedCornerShape(
                            topStart = 12.dp,
                            topEnd = 12.dp,
                            bottomStart = 7.dp,
                            bottomEnd = 7.dp
                        )
                    )
            )
            Spacer(Modifier.height(2.dp))
            Box(
                modifier = Modifier
                    .size(width = 13.dp, height = 3.dp)
                    .background(bulb, RoundedCornerShape(50))
            )
            Spacer(Modifier.height(2.dp))
            Box(
                modifier = Modifier
                    .size(width = 9.dp, height = 3.dp)
                    .background(bulb, RoundedCornerShape(50))
            )
        }
    }
}

@Composable
private fun LampConnectionChip(item: UnifiedLampItem) {
    val label = lampConnectionLabel(item)
    val (background, foreground) = when (item.controlPath) {
        LampControlPath.WIFI -> SHLampDesign.SuccessSoft to SHLampDesign.Success
        LampControlPath.BLUETOOTH -> SHLampDesign.PrimarySoft to SHLampDesign.Primary
        LampControlPath.REMOTE -> {
            if (item.cloudOnline) {
                SHLampDesign.SecondarySoft to SHLampDesign.Secondary
            } else {
                SHLampDesign.WarmSoft to SHLampDesign.Warm
            }
        }
        LampControlPath.OFFLINE -> SHLampDesign.SurfaceSoft to SHLampDesign.Offline
    }
    Box(
        modifier = Modifier
            .background(background, RoundedCornerShape(50))
            .padding(horizontal = 9.dp, vertical = 4.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier = Modifier
                    .size(6.dp)
                    .background(foreground, CircleShape)
            )
            Spacer(Modifier.size(5.dp))
            Text(
                label,
                color = foreground,
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold
            )
        }
    }
}

@Composable
private fun LampControlPage(
    item: UnifiedLampItem,
    pending: Boolean,
    notice: String,
    onBack: () -> Unit,
    onPower: (Boolean) -> Unit,
    onBrightness: (Int) -> Unit,
    onFade: (Int) -> Unit,
    onTimer: (Int) -> Unit,
    onIdentify: () -> Unit,
    onSettings: () -> Unit
) {
    var sliderValue by remember(item.lampId) { mutableStateOf(item.brightness.toFloat()) }
    var dragging by remember(item.lampId) { mutableStateOf(false) }
    val fadeMode = item.local?.fadeMode ?: item.cloud?.state?.fadeMode ?: 2
    val timerRemaining = item.local?.timerRemainingSeconds
        ?: item.cloud?.state?.timerRemainingSeconds
        ?: 0L
    var selectedTimerMinutes by remember(item.lampId) {
        mutableStateOf(timerPresetFromRemaining(timerRemaining))
    }

    LaunchedEffect(item.brightness, dragging) {
        if (!dragging) sliderValue = item.brightness.toFloat()
    }

    LaunchedEffect(timerRemaining) {
        if (timerRemaining <= 0L) {
            selectedTimerMinutes = 0
        } else if (selectedTimerMinutes == 0) {
            selectedTimerMinutes = timerPresetFromRemaining(timerRemaining)
        }
    }

    Scaffold(containerColor = SHLampDesign.Background) { innerPadding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .statusBarsPadding()
                .navigationBarsPadding(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(18.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            item {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OutlinedButton(
                        onClick = onBack,
                        modifier = Modifier.size(46.dp),
                        shape = CircleShape,
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp),
                        border = BorderStroke(1.dp, SHLampDesign.Border)
                    ) { Text("‹", fontSize = 28.sp, color = SHLampDesign.TextPrimary) }
                    Spacer(Modifier.size(12.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            item.name,
                            fontSize = 24.sp,
                            fontWeight = FontWeight.Bold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                        Text(
                            listOfNotNull(
                                item.room.takeIf { it.isNotBlank() && it != "Unassigned" },
                                lampConnectionLabel(item)
                            ).joinToString(" • "),
                            color = SHLampDesign.TextSecondary
                        )
                    }
                    TextButton(onClick = onSettings) {
                        Text("Settings", color = SHLampDesign.Primary)
                    }
                }
            }

            if (notice.isNotBlank()) item { HomeNotice(notice) }

            item {
                Card(
                    shape = RoundedCornerShape(24.dp),
                    colors = CardDefaults.cardColors(containerColor = SHLampDesign.Surface)
                ) {
                    Column(
                        modifier = Modifier.padding(20.dp),
                        horizontalAlignment = Alignment.CenterHorizontally
                    ) {
                        Button(
                            onClick = { onPower(!item.power) },
                            enabled = item.reachable && !pending,
                            modifier = Modifier.size(112.dp),
                            shape = CircleShape,
                            colors = ButtonDefaults.buttonColors(
                                containerColor = if (item.power) SHLampDesign.Primary else SHLampDesign.SurfaceSoft,
                                contentColor = if (item.power) SHLampDesign.OnPrimary else SHLampDesign.TextPrimary,
                                disabledContainerColor = SHLampDesign.SurfaceSoft,
                                disabledContentColor = SHLampDesign.TextSecondary
                            )
                        ) {
                            Text(if (item.power) "ON" else "OFF", fontSize = 20.sp, fontWeight = FontWeight.Bold)
                        }
                        Spacer(Modifier.height(10.dp))
                        Text(
                            when {
                                pending -> "Updating…"
                                item.power -> "Lamp is on"
                                else -> "Lamp is off"
                            },
                            color = SHLampDesign.TextSecondary
                        )
                    }
                }
            }

            item {
                Card(
                    shape = RoundedCornerShape(24.dp),
                    colors = CardDefaults.cardColors(containerColor = SHLampDesign.Surface)
                ) {
                    Column(Modifier.padding(18.dp)) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            Text("Brightness", fontWeight = FontWeight.Bold, fontSize = 18.sp)
                            Text(
                                "${sliderValue.roundToInt()}%",
                                color = SHLampDesign.Primary,
                                fontWeight = FontWeight.Bold
                            )
                        }
                        Slider(
                            value = sliderValue,
                            onValueChange = {
                                dragging = true
                                sliderValue = it.coerceIn(0f, 100f)
                            },
                            onValueChangeFinished = {
                                dragging = false
                                onBrightness(sliderValue.roundToInt())
                            },
                            valueRange = 0f..100f,
                            enabled = item.reachable && !pending,
                            colors = SliderDefaults.colors(
                                thumbColor = SHLampDesign.Primary,
                                activeTrackColor = SHLampDesign.Primary,
                                inactiveTrackColor = SHLampDesign.PrimarySoft
                            )
                        )
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            listOf(20, 60, 100).forEach { value ->
                                val selected = abs(sliderValue - value) < 1f
                                OutlinedButton(
                                    onClick = {
                                        sliderValue = value.toFloat()
                                        onBrightness(value)
                                    },
                                    enabled = item.reachable && !pending,
                                    modifier = Modifier.weight(1f),
                                    border = BorderStroke(
                                        1.dp,
                                        if (selected) SHLampDesign.Primary else SHLampDesign.Border
                                    ),
                                    shape = RoundedCornerShape(13.dp)
                                ) { Text("$value%", fontWeight = FontWeight.SemiBold) }
                            }
                        }
                    }
                }
            }

            item {
                Card(
                    shape = RoundedCornerShape(24.dp),
                    colors = CardDefaults.cardColors(containerColor = SHLampDesign.Surface)
                ) {
                    Column(Modifier.padding(18.dp)) {
                        Text("Fade speed", fontWeight = FontWeight.Bold, fontSize = 18.sp)
                        Text(
                            "How quickly brightness changes",
                            color = SHLampDesign.TextSecondary,
                            style = MaterialTheme.typography.bodySmall
                        )
                        Spacer(Modifier.height(12.dp))
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(7.dp)
                        ) {
                            listOf("Instant", "Fast", "Normal", "Slow").forEachIndexed { index, label ->
                                SelectOptionButton(
                                    label = label,
                                    selected = fadeMode == index,
                                    enabled = item.nearby && !pending,
                                    modifier = Modifier.weight(1f),
                                    onClick = { onFade(index) }
                                )
                            }
                        }
                        Spacer(Modifier.height(18.dp))
                        Text("Auto-off timer", fontWeight = FontWeight.Bold, fontSize = 18.sp)
                        Text(
                            "Stored in the lamp, so it works without internet",
                            color = SHLampDesign.TextSecondary,
                            style = MaterialTheme.typography.bodySmall
                        )
                        Spacer(Modifier.height(12.dp))
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(7.dp)
                        ) {
                            listOf("Off" to 0, "15m" to 15, "30m" to 30, "60m" to 60).forEach { (label, minutes) ->
                                SelectOptionButton(
                                    label = label,
                                    selected = selectedTimerMinutes == minutes,
                                    enabled = item.nearby && !pending,
                                    modifier = Modifier.weight(1f),
                                    onClick = {
                                        selectedTimerMinutes = minutes
                                        onTimer(minutes)
                                    }
                                )
                            }
                        }
                        if (timerRemaining > 0L) {
                            Spacer(Modifier.height(10.dp))
                            Text(
                                "Remaining: ${formatTimerRemaining(timerRemaining)}",
                                color = SHLampDesign.Primary,
                                fontWeight = FontWeight.SemiBold
                            )
                        }
                        if (!item.nearby) {
                            Spacer(Modifier.height(12.dp))
                            Text(
                                "Fade speed and timer can be changed when the lamp is nearby.",
                                color = SHLampDesign.TextSecondary,
                                style = MaterialTheme.typography.bodySmall
                            )
                        }
                    }
                }
            }

            item {
                OutlinedButton(
                    onClick = onIdentify,
                    enabled = item.reachable && !pending,
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(16.dp),
                    border = BorderStroke(1.dp, SHLampDesign.Border)
                ) { Text("Blink lamp", color = SHLampDesign.TextPrimary) }
                OutlinedButton(
                    onClick = onSettings,
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(16.dp),
                    border = BorderStroke(1.dp, SHLampDesign.Border)
                ) { Text("Lamp settings", color = SHLampDesign.TextPrimary) }
            }
        }
    }
}

@Composable
private fun SelectOptionButton(
    label: String,
    selected: Boolean,
    enabled: Boolean,
    modifier: Modifier,
    onClick: () -> Unit
) {
    if (selected) {
        Button(
            onClick = onClick,
            enabled = enabled,
            modifier = modifier.height(44.dp),
            shape = RoundedCornerShape(13.dp),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 4.dp),
            colors = ButtonDefaults.buttonColors(
                containerColor = SHLampDesign.Primary,
                contentColor = SHLampDesign.OnPrimary
            )
        ) { Text(label, fontSize = 11.sp, maxLines = 1) }
    } else {
        OutlinedButton(
            onClick = onClick,
            enabled = enabled,
            modifier = modifier.height(44.dp),
            shape = RoundedCornerShape(13.dp),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 4.dp),
            border = BorderStroke(1.dp, SHLampDesign.Border)
        ) { Text(label, fontSize = 11.sp, maxLines = 1) }
    }
}

private fun lampConnectionLabel(item: UnifiedLampItem): String = when (item.controlPath) {
    LampControlPath.WIFI -> "Wi-Fi"
    LampControlPath.BLUETOOTH -> "Bluetooth"
    LampControlPath.REMOTE -> "Remote"
    LampControlPath.OFFLINE -> "Offline"
}

private fun lampConnectionDetail(item: UnifiedLampItem): String = when (item.controlPath) {
    LampControlPath.WIFI -> "Local Wi-Fi control"
    LampControlPath.BLUETOOTH -> "Nearby Bluetooth control"
    LampControlPath.REMOTE -> {
        if (item.cloudOnline) "Internet control" else "Remote connection checking"
    }
    LampControlPath.OFFLINE -> "Not currently connected"
}

private fun timerPresetFromRemaining(remainingSeconds: Long): Int {
    val remaining = remainingSeconds.coerceAtLeast(0L)
    return when {
        remaining <= 0L -> 0
        remaining <= 15L * 60L -> 15
        remaining <= 30L * 60L -> 30
        else -> 60
    }
}

private fun formatTimerRemaining(seconds: Long): String {
    val safe = seconds.coerceAtLeast(0L)
    val minutes = safe / 60L
    val remainder = safe % 60L
    return "%02d:%02d".format(Locale.US, minutes, remainder)
}

@Composable
private fun EmptyLampsCard(onAddLamp: () -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(24.dp),
        colors = CardDefaults.cardColors(containerColor = SHLampDesign.Surface)
    ) {
        Column(
            modifier = Modifier.padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Box(
                modifier = Modifier
                    .size(58.dp)
                    .background(SHLampDesign.PrimarySoft, CircleShape),
                contentAlignment = Alignment.Center
            ) { Text("SH", color = SHLampDesign.Primary, fontWeight = FontWeight.Bold) }
            Spacer(Modifier.height(14.dp))
            Text("Add your first lamp", fontSize = 22.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(6.dp))
            Text(
                "The app will find nearby lamps automatically.",
                color = SHLampDesign.TextSecondary
            )
            Spacer(Modifier.height(16.dp))
            Button(
                onClick = onAddLamp,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(
                    containerColor = SHLampDesign.Primary,
                    contentColor = SHLampDesign.OnPrimary
                )
            ) { Text("+ Add Lamp", fontWeight = FontWeight.Bold) }
        }
    }
}

@Composable
private fun HomeNotice(message: String) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = SHLampDesign.ErrorSoft)
    ) {
        Text(
            message,
            modifier = Modifier.padding(14.dp),
            color = SHLampDesign.Error
        )
    }
}

private fun friendlyHomeError(error: Throwable): String {
    val text = error.message.orEmpty().lowercase()
    return when {
        error is UnauthorizedException -> "Your sign-in expired. Please sign in again."
        "timeout" in text || "unable to resolve" in text || "failed to connect" in text ||
            "network" in text || "connection" in text ->
            "Check your internet connection and try again."
        else -> error.message?.takeIf(String::isNotBlank)
            ?: "We couldn't update your lamp. Please try again."
    }
}


// UI-only ThinQ-inspired presentation layer. Connection and command logic above is unchanged.
private enum class ModernAppTab(val label: String) {
    HOME("Home"),
    DEVICES("Devices"),
    CARE("Care"),
    MENU("Menu")
}

private enum class ModernGlyph {
    HOME,
    DEVICES,
    CARE,
    MENU,
    PLUS,
    SEARCH,
    BELL,
    POWER,
    BACK,
    SETTINGS,
    REFRESH,
    CHEVRON,
    CHECK,
    ALERT
}

@Composable
private fun ModernLampApp(
    dashboard: CloudDashboard,
    localLamps: List<LampDevice>,
    activeCloudUserId: String?,
    confirmedCloudLampIds: Set<String>,
    cloudIdentityByLocalId: Map<String, String>,
    loading: Boolean,
    connected: Boolean,
    connectionLabel: String,
    notice: String,
    pendingLampIds: Set<String>,
    onRefresh: () -> Unit,
    onAddLamp: () -> Unit,
    onPower: (UnifiedLampItem, Boolean) -> Unit,
    onBrightness: (UnifiedLampItem, Int) -> Unit,
    onPowerMode: (UnifiedLampItem, LampPowerMode) -> Unit,
    onRoutePreference: (UnifiedLampItem, LampRoutePreference) -> Unit,
    onLocalFade: (UnifiedLampItem, Int) -> Unit,
    onLocalTimer: (UnifiedLampItem, Int) -> Unit,
    onIdentify: (UnifiedLampItem) -> Unit,
    onIdentifyDuplicate: (LampDevice) -> Unit,
    onLinkDuplicate: (LampDevice, CloudLamp) -> Unit,
    onOpenLamp: (UnifiedLampItem) -> Unit,
    onOpenSettings: (UnifiedLampItem) -> Unit,
    onOpenDiagnostics: (UnifiedLampItem?) -> Unit,
    onSignOut: () -> Unit
) {
    val items = mergeLampItems(
        cloudLamps = dashboard.lamps,
        localLamps = localLamps,
        activeCloudUserId = activeCloudUserId,
        confirmedCloudLampIds = confirmedCloudLampIds,
        cloudIdentityByLocalId = cloudIdentityByLocalId
    )
    var selectedTab by remember { mutableStateOf(ModernAppTab.HOME) }
    var selectedLampId by remember { mutableStateOf<String?>(null) }
    var dismissedDuplicateKey by remember { mutableStateOf<String?>(null) }

    val selectedLamp = selectedLampId?.let { selectedId ->
        items.firstOrNull { it.lampId.equals(selectedId, ignoreCase = true) }
    }
    val duplicateCandidate = findDuplicateCandidate(dashboard.lamps, localLamps)
        ?.takeUnless { it.key == dismissedDuplicateKey }

    if (selectedLamp != null) {
        ModernLampControlPage(
            item = selectedLamp,
            pending = selectedLamp.lampId in pendingLampIds,
            notice = notice,
            onBack = { selectedLampId = null },
            onPower = { onPower(selectedLamp, it) },
            onBrightness = { onBrightness(selectedLamp, it) },
            onPowerMode = { onPowerMode(selectedLamp, it) },
            onRoutePreference = { onRoutePreference(selectedLamp, it) },
            onFade = { onLocalFade(selectedLamp, it) },
            onTimer = { onLocalTimer(selectedLamp, it) },
            onIdentify = { onIdentify(selectedLamp) },
            onSettings = { onOpenSettings(selectedLamp) }
        )
        return
    }

    Scaffold(
        containerColor = SHLampDesign.Background,
        bottomBar = {
            ModernBottomBar(
                selected = selectedTab,
                onSelected = { selectedTab = it }
            )
        }
    ) { innerPadding ->
        when (selectedTab) {
            ModernAppTab.HOME -> ModernHomePage(
                modifier = Modifier.padding(innerPadding),
                homeName = dashboard.homes.firstOrNull()?.name?.takeIf(String::isNotBlank)
                    ?: "My Home",
                items = items,
                loading = loading,
                connected = connected,
                connectionLabel = connectionLabel,
                notice = notice,
                pendingLampIds = pendingLampIds,
                duplicateCandidate = duplicateCandidate,
                onRefresh = onRefresh,
                onAddLamp = onAddLamp,
                onOpenAllDevices = { selectedTab = ModernAppTab.DEVICES },
                onOpenLamp = { item ->
                    onOpenLamp(item)
                    selectedLampId = item.lampId
                },
                onPower = onPower,
                onBrightness = onBrightness,
                onIdentifyDuplicate = onIdentifyDuplicate,
                onLinkDuplicate = onLinkDuplicate,
                onDismissDuplicate = { dismissedDuplicateKey = it }
            )

            ModernAppTab.DEVICES -> ModernDevicesPage(
                modifier = Modifier.padding(innerPadding),
                items = items,
                loading = loading,
                pendingLampIds = pendingLampIds,
                onRefresh = onRefresh,
                onAddLamp = onAddLamp,
                onOpenLamp = { item ->
                    onOpenLamp(item)
                    selectedLampId = item.lampId
                },
                onPower = onPower
            )

            ModernAppTab.CARE -> ModernCarePage(
                modifier = Modifier.padding(innerPadding),
                items = items,
                connected = connected,
                loading = loading,
                onRefresh = onRefresh,
                onOpenDiagnostics = { onOpenDiagnostics(items.firstOrNull()) },
                onOpenLamp = { item ->
                    onOpenLamp(item)
                    selectedLampId = item.lampId
                }
            )

            ModernAppTab.MENU -> ModernMenuPage(
                modifier = Modifier.padding(innerPadding),
                homeName = dashboard.homes.firstOrNull()?.name?.takeIf(String::isNotBlank)
                    ?: "My Home",
                items = items,
                connected = connected,
                onRefresh = onRefresh,
                onAddLamp = onAddLamp,
                onOpenDevices = { selectedTab = ModernAppTab.DEVICES },
                onOpenCare = { selectedTab = ModernAppTab.CARE },
                onOpenDiagnostics = { onOpenDiagnostics(items.firstOrNull()) },
                onSignOut = onSignOut
            )
        }
    }
}

@Composable
private fun ModernHomePage(
    modifier: Modifier,
    homeName: String,
    items: List<UnifiedLampItem>,
    loading: Boolean,
    connected: Boolean,
    connectionLabel: String,
    notice: String,
    pendingLampIds: Set<String>,
    duplicateCandidate: DuplicateLampCandidate?,
    onRefresh: () -> Unit,
    onAddLamp: () -> Unit,
    onOpenAllDevices: () -> Unit,
    onOpenLamp: (UnifiedLampItem) -> Unit,
    onPower: (UnifiedLampItem, Boolean) -> Unit,
    onBrightness: (UnifiedLampItem, Int) -> Unit,
    onIdentifyDuplicate: (LampDevice) -> Unit,
    onLinkDuplicate: (LampDevice, CloudLamp) -> Unit,
    onDismissDuplicate: (String) -> Unit
) {
    val reachableCount = items.count { it.nearby || it.cloudOnline }
    val nearbyUnclaimed = items.firstOrNull { it.nearby && !it.claimed }
    val favoriteItems = items.take(4)

    LazyColumn(
        modifier = modifier
            .fillMaxSize()
            .statusBarsPadding(),
        contentPadding = PaddingValues(start = 18.dp, end = 18.dp, top = 14.dp, bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        item {
            ModernTopHeader(
                title = homeName,
                subtitle = when {
                    items.isEmpty() -> "Set up your first lamp"
                    reachableCount == items.size -> "All lamps are ready"
                    reachableCount > 0 -> "$reachableCount of ${items.size} lamps ready"
                    connected -> "Remote connection is available"
                    else -> connectionLabel
                },
                loading = loading,
                onRefresh = onRefresh,
                onAdd = onAddLamp,
                onSearch = onOpenAllDevices,
                showDropdown = true
            )
        }

        item {
            ModernHomeHero(
                items = items,
                reachableCount = reachableCount,
                connected = connected
            )
        }

        if (notice.isNotBlank()) {
            item { ModernNoticeCard(notice) }
        }

        nearbyUnclaimed?.let { lamp ->
            item {
                ModernFoundLampBanner(
                    lampName = lamp.name,
                    onAdd = onAddLamp
                )
            }
        }

        duplicateCandidate?.let { candidate ->
            item {
                ModernDuplicateBanner(
                    candidate = candidate,
                    onBlink = { onIdentifyDuplicate(candidate.local) },
                    onLink = { onLinkDuplicate(candidate.local, candidate.cloud) },
                    onDismiss = { onDismissDuplicate(candidate.key) }
                )
            }
        }

        item {
            ModernSectionHeader(title = "Quick scenes")
            Spacer(Modifier.height(10.dp))
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                ModernSceneChip(
                    title = "Reading",
                    subtitle = "100%",
                    accent = SHLampDesign.Secondary,
                    enabled = items.any { it.reachable },
                    onClick = { items.filter { it.reachable }.forEach { onBrightness(it, 100) } }
                )
                ModernSceneChip(
                    title = "Relax",
                    subtitle = "60%",
                    accent = SHLampDesign.Primary,
                    enabled = items.any { it.reachable },
                    onClick = { items.filter { it.reachable }.forEach { onBrightness(it, 60) } }
                )
                ModernSceneChip(
                    title = "Night",
                    subtitle = "20%",
                    accent = SHLampDesign.WarmDeep,
                    enabled = items.any { it.reachable },
                    onClick = { items.filter { it.reachable }.forEach { onBrightness(it, 20) } }
                )
                ModernSceneChip(
                    title = "All off",
                    subtitle = "Home",
                    accent = SHLampDesign.TextSecondary,
                    enabled = items.any { it.reachable },
                    onClick = { items.filter { it.reachable }.forEach { onPower(it, false) } }
                )
            }
        }

        item {
            ModernSectionHeader(
                title = "Favorite devices",
                action = if (items.isEmpty()) "Add lamp" else "View all",
                onAction = if (items.isEmpty()) onAddLamp else onOpenAllDevices
            )
        }

        if (!loading && favoriteItems.isEmpty()) {
            item { ModernEmptyLampCard(onAddLamp) }
        } else {
            favoriteItems.chunked(2).forEach { rowItems ->
                item {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        rowItems.forEach { item ->
                            ModernDeviceCard(
                                modifier = Modifier.weight(1f),
                                item = item,
                                pending = item.lampId in pendingLampIds,
                                onOpen = { onOpenLamp(item) },
                                onPower = { onPower(item, !item.power) }
                            )
                        }
                        if (rowItems.size == 1) Spacer(Modifier.weight(1f))
                    }
                }
            }
        }

        if (items.isNotEmpty()) {
            item {
                ModernRoomSummary(items = items, onOpenDevices = onOpenAllDevices)
            }
        }
    }
}

@Composable
private fun ModernDevicesPage(
    modifier: Modifier,
    items: List<UnifiedLampItem>,
    loading: Boolean,
    pendingLampIds: Set<String>,
    onRefresh: () -> Unit,
    onAddLamp: () -> Unit,
    onOpenLamp: (UnifiedLampItem) -> Unit,
    onPower: (UnifiedLampItem, Boolean) -> Unit
) {
    var search by remember { mutableStateOf("") }
    var selectedRoom by remember { mutableStateOf("All") }
    val rooms = remember(items) {
        listOf("All") + items.map { it.room.ifBlank { "Unassigned" } }.distinct().sorted()
    }
    val filtered = items.filter { item ->
        val roomMatches = selectedRoom == "All" || item.room.ifBlank { "Unassigned" } == selectedRoom
        val searchMatches = search.isBlank() ||
            item.name.contains(search, ignoreCase = true) ||
            item.room.contains(search, ignoreCase = true) ||
            item.lampId.contains(search, ignoreCase = true)
        roomMatches && searchMatches
    }

    LazyVerticalGrid(
        columns = GridCells.Adaptive(minSize = 145.dp),
        modifier = modifier
            .fillMaxSize()
            .statusBarsPadding(),
        contentPadding = PaddingValues(start = 18.dp, end = 18.dp, top = 14.dp, bottom = 28.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        item(span = { GridItemSpan(maxLineSpan) }) {
            ModernTopHeader(
                title = "Devices",
                subtitle = when (items.size) {
                    0 -> "No lamps added"
                    1 -> "1 lamp in your home"
                    else -> "${items.size} lamps in your home"
                },
                loading = loading,
                onRefresh = onRefresh,
                onAdd = onAddLamp
            )
        }

        item(span = { GridItemSpan(maxLineSpan) }) {
            ModernSearchField(
                value = search,
                onValueChange = { search = it },
                hint = "Search lamps or rooms"
            )
        }

        item(span = { GridItemSpan(maxLineSpan) }) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                rooms.forEach { room ->
                    ModernFilterChip(
                        label = room,
                        selected = selectedRoom == room,
                        onClick = { selectedRoom = room }
                    )
                }
            }
        }

        if (!loading && filtered.isEmpty()) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                if (items.isEmpty()) {
                    ModernEmptyLampCard(onAddLamp)
                } else {
                    ModernEmptySearchCard(onClear = {
                        search = ""
                        selectedRoom = "All"
                    })
                }
            }
        } else {
            gridItems(filtered, key = { it.lampId }) { item ->
                ModernDeviceCard(
                    modifier = Modifier.fillMaxWidth(),
                    item = item,
                    pending = item.lampId in pendingLampIds,
                    onOpen = { onOpenLamp(item) },
                    onPower = { onPower(item, !item.power) }
                )
            }
        }

        item(span = { GridItemSpan(maxLineSpan) }) {
            OutlinedButton(
                onClick = onAddLamp,
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(18.dp),
                border = BorderStroke(1.dp, SHLampDesign.Border),
                colors = ButtonDefaults.outlinedButtonColors(contentColor = SHLampDesign.Primary)
            ) {
                ModernLineIcon(ModernGlyph.PLUS, SHLampDesign.Primary, Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text("Add another lamp", fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

@Composable
private fun ModernCarePage(
    modifier: Modifier,
    items: List<UnifiedLampItem>,
    connected: Boolean,
    loading: Boolean,
    onRefresh: () -> Unit,
    onOpenDiagnostics: () -> Unit,
    onOpenLamp: (UnifiedLampItem) -> Unit
) {
    val online = items.count { it.nearby || it.cloudOnline }
    val offline = items.size - online
    val linked = items.count { it.claimed }
    val attention = offline > 0 || (!connected && linked > 0)

    LazyColumn(
        modifier = modifier
            .fillMaxSize()
            .statusBarsPadding(),
        contentPadding = PaddingValues(start = 18.dp, end = 18.dp, top = 14.dp, bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        item {
            ModernTopHeader(
                title = "Care",
                subtitle = "Lamp health, connectivity and support",
                loading = loading,
                onRefresh = onRefresh,
                onAdd = null
            )
        }

        item {
            ModernCareHero(
                attention = attention,
                total = items.size,
                offline = offline,
                onDiagnostics = onOpenDiagnostics
            )
        }

        item {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                ModernMetricCard(
                    modifier = Modifier.weight(1f),
                    value = online.toString(),
                    label = "Ready",
                    accent = SHLampDesign.Success,
                    surface = SHLampDesign.SuccessSoft
                )
                ModernMetricCard(
                    modifier = Modifier.weight(1f),
                    value = linked.toString(),
                    label = "Cloud linked",
                    accent = SHLampDesign.Info,
                    surface = SHLampDesign.InfoSoft
                )
                ModernMetricCard(
                    modifier = Modifier.weight(1f),
                    value = offline.toString(),
                    label = "Offline",
                    accent = if (offline > 0) SHLampDesign.Error else SHLampDesign.TextSecondary,
                    surface = if (offline > 0) SHLampDesign.ErrorSoft else SHLampDesign.SurfaceSoft
                )
            }
        }

        item { ModernSectionHeader(title = "Device health") }

        if (items.isEmpty()) {
            item {
                ModernInfoPanel(
                    title = "No lamps to check",
                    text = "Add a lamp and its health information will appear here.",
                    accent = SHLampDesign.Info,
                    surface = SHLampDesign.InfoSoft
                )
            }
        } else {
            listItems(items, key = { it.lampId }) { item ->
                ModernHealthRow(item = item, onClick = { onOpenLamp(item) })
            }
        }

        item { ModernSectionHeader(title = "Battery") }

        val batteryItems = items.filter { it.batteryPercent != null }
        if (batteryItems.isEmpty()) {
            item {
                ModernInfoPanel(
                    title = "Battery status unavailable",
                    text = "Connect to the lamp to refresh its battery status.",
                    accent = SHLampDesign.WarmDeep,
                    surface = SHLampDesign.WarmSoft
                )
            }
        } else {
            listItems(batteryItems, key = { "battery-${it.lampId}" }) { item ->
                ModernBatteryHealthRow(item = item, onClick = { onOpenLamp(item) })
            }
        }

        item {
            ModernActionCard(
                title = "Connection diagnostics",
                subtitle = "Check Bluetooth, local Wi-Fi and cloud status",
                accent = SHLampDesign.Primary,
                onClick = onOpenDiagnostics
            )
        }
    }
}

@Composable
private fun ModernMenuPage(
    modifier: Modifier,
    homeName: String,
    items: List<UnifiedLampItem>,
    connected: Boolean,
    onRefresh: () -> Unit,
    onAddLamp: () -> Unit,
    onOpenDevices: () -> Unit,
    onOpenCare: () -> Unit,
    onOpenDiagnostics: () -> Unit,
    onSignOut: () -> Unit
) {
    LazyColumn(
        modifier = modifier
            .fillMaxSize()
            .statusBarsPadding(),
        contentPadding = PaddingValues(start = 18.dp, end = 18.dp, top = 14.dp, bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        item {
            Text("Smart Handicrafts®", style = MaterialTheme.typography.headlineSmall)
            Text("Account and product management", color = SHLampDesign.TextSecondary)
        }

        item {
            Card(
                shape = RoundedCornerShape(24.dp),
                colors = CardDefaults.cardColors(containerColor = SHLampDesign.Surface),
                border = BorderStroke(1.dp, SHLampDesign.Border)
            ) {
                Row(
                    modifier = Modifier.padding(18.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Box(
                        modifier = Modifier
                            .size(54.dp)
                            .background(SHLampDesign.PrimarySoft, CircleShape),
                        contentAlignment = Alignment.Center
                    ) {
                        Text("SH", color = SHLampDesign.PrimaryDeep, fontWeight = FontWeight.Bold)
                    }
                    Spacer(Modifier.width(14.dp))
                    Column(Modifier.weight(1f)) {
                        Text(homeName, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                        Text(
                            if (connected) "Account connected" else "Reconnecting to account",
                            color = if (connected) SHLampDesign.Success else SHLampDesign.Warning,
                            fontSize = 13.sp
                        )
                    }
                    ModernLineIcon(ModernGlyph.CHEVRON, SHLampDesign.TextDisabled, Modifier.size(18.dp))
                }
            }
        }

        item {
            ModernMenuSection(
                title = "Product management",
                rows = listOf(
                    ModernMenuRowData(
                        title = "Devices",
                        subtitle = "${items.size} lamp${if (items.size == 1) "" else "s"}, rooms and access",
                        accent = SHLampDesign.Primary,
                        action = onOpenDevices
                    ),
                    ModernMenuRowData(
                        title = "Care and diagnostics",
                        subtitle = "Health, connection checks and support",
                        accent = SHLampDesign.Success,
                        action = onOpenCare
                    ),
                    ModernMenuRowData(
                        title = "Connection diagnostics",
                        subtitle = "Detailed Bluetooth, Wi-Fi and cloud status",
                        accent = SHLampDesign.Info,
                        action = onOpenDiagnostics
                    ),
                    ModernMenuRowData(
                        title = "Add a lamp",
                        subtitle = "Find a nearby SH Lamp and connect it",
                        accent = SHLampDesign.Secondary,
                        action = onAddLamp
                    )
                )
            )
        }

        item {
            ModernMenuSection(
                title = "App",
                rows = listOf(
                    ModernMenuRowData(
                        title = "Refresh home",
                        subtitle = "Update device state and cloud connection",
                        accent = SHLampDesign.Primary,
                        action = onRefresh
                    )
                )
            )
        }

        item {
            OutlinedButton(
                onClick = onSignOut,
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(18.dp),
                border = BorderStroke(1.dp, SHLampDesign.Error.copy(alpha = 0.45f)),
                colors = ButtonDefaults.outlinedButtonColors(contentColor = SHLampDesign.Error)
            ) {
                Text("Sign out", fontWeight = FontWeight.SemiBold)
            }
        }

        item {
            Text(
                "SH Lamp · Smart Handicrafts®",
                modifier = Modifier.fillMaxWidth(),
                textAlign = TextAlign.Center,
                color = SHLampDesign.TextDisabled,
                fontSize = 12.sp
            )
        }
    }
}

@Composable
private fun ModernLampControlPage(
    item: UnifiedLampItem,
    pending: Boolean,
    notice: String,
    onBack: () -> Unit,
    onPower: (Boolean) -> Unit,
    onBrightness: (Int) -> Unit,
    onPowerMode: (LampPowerMode) -> Unit,
    onRoutePreference: (LampRoutePreference) -> Unit,
    onFade: (Int) -> Unit,
    onTimer: (Int) -> Unit,
    onIdentify: () -> Unit,
    onSettings: () -> Unit
) {
    val listState = rememberLazyListState()
    val collapsed by remember {
        derivedStateOf {
            listState.firstVisibleItemIndex > 0 || listState.firstVisibleItemScrollOffset > 80
        }
    }
    var sliderValue by remember(item.lampId) { mutableStateOf(item.brightness.toFloat()) }
    var dragging by remember { mutableStateOf(false) }
    var selectedSection by remember { mutableIntStateOf(0) }
    var selectedTimerMinutes by remember(item.lampId) {
        mutableIntStateOf(modernTimerPresetFromRemaining(item.local?.timerRemainingSeconds ?: 0L))
    }
    var showRouteDialog by remember { mutableStateOf(false) }
    var pendingModeConfirmation by remember { mutableStateOf<LampPowerMode?>(null) }
    val fadeMode = item.local?.fadeMode ?: 2
    val timerRemaining = item.local?.timerRemainingSeconds ?: 0L
    val maxBrightness = if (item.powerMode == LampPowerMode.MAX_BACKUP) 70 else 100

    BackHandler(onBack = onBack)

    LaunchedEffect(item.brightness, maxBrightness) {
        if (!dragging) sliderValue = item.brightness.coerceAtMost(maxBrightness).toFloat()
    }
    LaunchedEffect(timerRemaining) {
        selectedTimerMinutes = modernTimerPresetFromRemaining(timerRemaining)
    }

    pendingModeConfirmation?.let { mode ->
        val touchOnly = mode == LampPowerMode.TOUCH_ONLY
        AlertDialog(
            onDismissRequest = { if (!pending) pendingModeConfirmation = null },
            title = { Text(if (touchOnly) "Switch to Touch Only?" else "Switch to BLE Only?") },
            text = {
                Text(
                    if (touchOnly) {
                        "All wireless connections will stop. The lamp can then be controlled only by physical touch. Restart the lamp to restore wireless control."
                    } else {
                        "Wi-Fi and remote access will become unavailable. Nearby Bluetooth control will remain available."
                    }
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        pendingModeConfirmation = null
                        onPowerMode(mode)
                    },
                    enabled = !pending
                ) { Text("Switch mode") }
            },
            dismissButton = {
                TextButton(onClick = { pendingModeConfirmation = null }) { Text("Cancel") }
            }
        )
    }

    if (showRouteDialog) {
        AlertDialog(
            onDismissRequest = { showRouteDialog = false },
            title = { Text("Connection route") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    LampRoutePreference.values().forEach { preference ->
                        val selected = item.routePreference == preference
                        Card(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable {
                                    onRoutePreference(preference)
                                    showRouteDialog = false
                                },
                            shape = RoundedCornerShape(16.dp),
                            colors = CardDefaults.cardColors(
                                containerColor = if (selected) SHLampDesign.PrimarySoft else SHLampDesign.Surface
                            ),
                            border = BorderStroke(
                                1.dp,
                                if (selected) SHLampDesign.Primary else SHLampDesign.Border
                            )
                        ) {
                            Column(Modifier.padding(13.dp)) {
                                Text(modernRoutePreferenceTitle(preference), fontWeight = FontWeight.Bold)
                                Text(
                                    modernRoutePreferenceSubtitle(preference),
                                    color = SHLampDesign.TextSecondary,
                                    fontSize = 12.sp
                                )
                            }
                        }
                    }
                }
            },
            confirmButton = { TextButton(onClick = { showRouteDialog = false }) { Text("Done") } }
        )
    }

    Scaffold(containerColor = SHLampDesign.Background) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .statusBarsPadding()
                .navigationBarsPadding()
        ) {
            ModernAdaptiveLampHeader(
                item = item,
                collapsed = collapsed,
                pending = pending,
                onBack = onBack,
                onPower = { onPower(!item.power) },
                onSettings = onSettings,
                onRoute = { showRouteDialog = true }
            )

            LazyColumn(
                state = listState,
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
                contentPadding = PaddingValues(start = 18.dp, end = 18.dp, top = 14.dp, bottom = 28.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                if (notice.isNotBlank()) item { ModernNoticeCard(notice) }

                item {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        ModernControlMetric(
                            modifier = Modifier.weight(1f),
                            title = "Brightness",
                            value = "${item.brightness}%",
                            accent = SHLampDesign.WarmDeep,
                            surface = SHLampDesign.WarmSoft
                        )
                        ModernControlMetric(
                            modifier = Modifier
                                .weight(1f)
                                .clickable { showRouteDialog = true },
                            title = "Connection",
                            value = modernConnectionLabel(item),
                            accent = if (item.reachable) SHLampDesign.Success else SHLampDesign.Warning,
                            surface = if (item.reachable) SHLampDesign.SuccessSoft else SHLampDesign.WarningSoft
                        )
                        ModernControlMetric(
                            modifier = Modifier.weight(1f),
                            title = "Activity",
                            value = modernRuntimeStateTitle(item.runtimeState),
                            accent = SHLampDesign.Secondary,
                            surface = SHLampDesign.SecondarySoft
                        )
                    }
                }

                item {
                    ModernSegmentedControl(
                        labels = listOf("Control", "Useful features"),
                        selectedIndex = selectedSection,
                        onSelected = { selectedSection = it }
                    )
                }

                if (selectedSection == 0) {
                    item {
                        Card(
                            shape = RoundedCornerShape(24.dp),
                            colors = CardDefaults.cardColors(containerColor = SHLampDesign.Surface),
                            border = BorderStroke(1.dp, SHLampDesign.Border)
                        ) {
                            Column(Modifier.padding(18.dp)) {
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Column {
                                        Text("Brightness", fontSize = 18.sp, fontWeight = FontWeight.Bold)
                                        Text(
                                            if (maxBrightness == 70) "Maximum Backup limit: 70%" else "Drag to adjust the lamp",
                                            color = SHLampDesign.TextSecondary,
                                            fontSize = 13.sp
                                        )
                                    }
                                    Text(
                                        "${sliderValue.roundToInt()}%",
                                        color = SHLampDesign.Primary,
                                        fontSize = 20.sp,
                                        fontWeight = FontWeight.Bold
                                    )
                                }
                                Spacer(Modifier.height(8.dp))
                                Slider(
                                    value = sliderValue.coerceIn(0f, maxBrightness.toFloat()),
                                    onValueChange = {
                                        dragging = true
                                        sliderValue = it.coerceIn(0f, maxBrightness.toFloat())
                                    },
                                    onValueChangeFinished = {
                                        dragging = false
                                        onBrightness(sliderValue.roundToInt().coerceAtMost(maxBrightness))
                                    },
                                    valueRange = 0f..maxBrightness.toFloat(),
                                    enabled = item.reachable && !pending,
                                    colors = SliderDefaults.colors(
                                        thumbColor = SHLampDesign.Primary,
                                        activeTrackColor = SHLampDesign.Primary,
                                        inactiveTrackColor = SHLampDesign.PrimarySoft
                                    )
                                )
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                                ) {
                                    listOf(20, 60, maxBrightness).distinct().forEach { value ->
                                        ModernPresetButton(
                                            modifier = Modifier.weight(1f),
                                            label = "$value%",
                                            selected = abs(sliderValue - value) < 1f,
                                            enabled = item.reachable && !pending,
                                            onClick = {
                                                sliderValue = value.toFloat()
                                                onBrightness(value)
                                            }
                                        )
                                    }
                                }
                                if (maxBrightness == 70) {
                                    Spacer(Modifier.height(10.dp))
                                    Text(
                                        "Requests above 70% are limited by Maximum Backup.",
                                        color = SHLampDesign.Primary,
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.SemiBold
                                    )
                                }
                            }
                        }
                    }

                    item {
                        ModernPowerModeCard(
                            selectedMode = item.powerMode,
                            runtimeState = item.runtimeState,
                            enabled = item.nearby && !pending,
                            onMode = { mode ->
                                if (mode == LampPowerMode.BLE_ONLY || mode == LampPowerMode.TOUCH_ONLY) {
                                    pendingModeConfirmation = mode
                                } else {
                                    onPowerMode(mode)
                                }
                            }
                        )
                    }

                    item {
                        ModernActionCard(
                            title = "Set auto-off timer",
                            subtitle = if (timerRemaining > 0L) {
                                "${modernFormatTimer(timerRemaining)} remaining"
                            } else {
                                "Turn the lamp off automatically"
                            },
                            accent = SHLampDesign.Secondary,
                            onClick = { selectedSection = 1 }
                        )
                    }
                } else {
                    item {
                        Card(
                            shape = RoundedCornerShape(24.dp),
                            colors = CardDefaults.cardColors(containerColor = SHLampDesign.Surface),
                            border = BorderStroke(1.dp, SHLampDesign.Border)
                        ) {
                            Column(Modifier.padding(18.dp)) {
                                Text("Fade speed", fontSize = 18.sp, fontWeight = FontWeight.Bold)
                                Text(
                                    "Choose how quickly brightness changes",
                                    color = SHLampDesign.TextSecondary,
                                    fontSize = 13.sp
                                )
                                Spacer(Modifier.height(12.dp))
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.spacedBy(7.dp)
                                ) {
                                    listOf("Instant", "Fast", "Normal", "Slow").forEachIndexed { index, label ->
                                        ModernPresetButton(
                                            modifier = Modifier.weight(1f),
                                            label = label,
                                            selected = fadeMode == index,
                                            enabled = item.nearby && !pending,
                                            onClick = { onFade(index) },
                                            compact = true
                                        )
                                    }
                                }
                                if (!item.nearby) {
                                    Spacer(Modifier.height(10.dp))
                                    Text(
                                        "Fade speed is available when the lamp is nearby.",
                                        color = SHLampDesign.TextSecondary,
                                        fontSize = 12.sp
                                    )
                                }
                            }
                        }
                    }

                    item {
                        Card(
                            shape = RoundedCornerShape(24.dp),
                            colors = CardDefaults.cardColors(containerColor = SHLampDesign.Surface),
                            border = BorderStroke(1.dp, SHLampDesign.Border)
                        ) {
                            Column(Modifier.padding(18.dp)) {
                                Text("Auto-off timer", fontSize = 18.sp, fontWeight = FontWeight.Bold)
                                Text(
                                    "Stored in the lamp, so it works without internet",
                                    color = SHLampDesign.TextSecondary,
                                    fontSize = 13.sp
                                )
                                Spacer(Modifier.height(12.dp))
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.spacedBy(7.dp)
                                ) {
                                    listOf("Off" to 0, "15m" to 15, "30m" to 30, "60m" to 60).forEach { (label, minutes) ->
                                        ModernPresetButton(
                                            modifier = Modifier.weight(1f),
                                            label = label,
                                            selected = selectedTimerMinutes == minutes,
                                            enabled = item.nearby && !pending,
                                            onClick = {
                                                selectedTimerMinutes = minutes
                                                onTimer(minutes)
                                            },
                                            compact = true
                                        )
                                    }
                                }
                                if (timerRemaining > 0L) {
                                    Spacer(Modifier.height(10.dp))
                                    Text(
                                        "Remaining: ${modernFormatTimer(timerRemaining)}",
                                        color = SHLampDesign.Secondary,
                                        fontWeight = FontWeight.SemiBold
                                    )
                                }
                                if (!item.nearby) {
                                    Spacer(Modifier.height(10.dp))
                                    Text(
                                        "Timer changes are available when the lamp is nearby.",
                                        color = SHLampDesign.TextSecondary,
                                        fontSize = 12.sp
                                    )
                                }
                            }
                        }
                    }

                    item {
                        ModernActionCard(
                            title = "Blink lamp",
                            subtitle = "Identify this lamp in the room",
                            accent = SHLampDesign.WarmDeep,
                            enabled = item.reachable && !pending,
                            onClick = onIdentify
                        )
                    }

                    item {
                        ModernActionCard(
                            title = "Lamp settings",
                            subtitle = "Name, room, Wi-Fi, remote access and device information",
                            accent = SHLampDesign.Primary,
                            onClick = onSettings
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun ModernAdaptiveLampHeader(
    item: UnifiedLampItem,
    collapsed: Boolean,
    pending: Boolean,
    onBack: () -> Unit,
    onPower: () -> Unit,
    onSettings: () -> Unit,
    onRoute: () -> Unit
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 8.dp)
            .animateContentSize(),
        shape = RoundedCornerShape(if (collapsed) 20.dp else 28.dp),
        colors = CardDefaults.cardColors(containerColor = SHLampDesign.Surface),
        border = BorderStroke(1.dp, SHLampDesign.Border),
        elevation = CardDefaults.cardElevation(defaultElevation = if (collapsed) 6.dp else 2.dp)
    ) {
        if (collapsed) {
            Row(
                modifier = Modifier.padding(horizontal = 10.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                ModernCircleIconButton(
                    icon = ModernGlyph.BACK,
                    contentDescription = "Back",
                    onClick = onBack
                )
                Spacer(Modifier.width(8.dp))
                Column(Modifier.weight(1f)) {
                    Text(item.name, maxLines = 1, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.Bold)
                    Text(
                        "${if (item.power) "${item.brightness}%" else "Off"} · ${modernConnectionLabel(item)}",
                        color = SHLampDesign.TextSecondary,
                        fontSize = 11.sp,
                        maxLines = 1
                    )
                }
                Box(Modifier.clickable(onClick = onRoute)) {
                    ModernStatusPill(modernConnectionLabel(item), item.reachable)
                }
                item.batteryPercent?.let { percent ->
                    Spacer(Modifier.width(8.dp))
                    PhoneBatteryIndicator(percent, item.batteryCharging, showPercent = true)
                }
                Spacer(Modifier.width(7.dp))
                Button(
                    onClick = onPower,
                    enabled = item.reachable && !pending,
                    modifier = Modifier.size(46.dp),
                    shape = CircleShape,
                    contentPadding = PaddingValues(0.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = if (item.power) SHLampDesign.Primary else SHLampDesign.PrimarySoft,
                        contentColor = if (item.power) SHLampDesign.OnPrimary else SHLampDesign.Primary
                    )
                ) {
                    ModernLineIcon(ModernGlyph.POWER, if (item.power) SHLampDesign.OnPrimary else SHLampDesign.Primary, Modifier.size(21.dp))
                }
            }
        } else {
            Column(Modifier.padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    ModernCircleIconButton(ModernGlyph.BACK, "Back", onClick = onBack)
                    Spacer(Modifier.width(10.dp))
                    Column(Modifier.weight(1f)) {
                        Text(item.name, fontSize = 22.sp, fontWeight = FontWeight.Bold)
                        Text(
                            item.room.takeIf { it.isNotBlank() } ?: "SH Lamp",
                            color = SHLampDesign.TextSecondary,
                            fontSize = 13.sp
                        )
                    }
                    ModernCircleIconButton(ModernGlyph.SETTINGS, "Lamp settings", onClick = onSettings)
                }
                Spacer(Modifier.height(10.dp))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Box(Modifier.clickable(onClick = onRoute)) {
                        ModernStatusPill(modernConnectionLabel(item), item.reachable)
                    }
                    item.batteryPercent?.let { percent ->
                        PhoneBatteryIndicator(
                            percent = percent,
                            charging = item.batteryCharging,
                            showPercent = true,
                            modifier = Modifier.size(width = 43.dp, height = 22.dp)
                        )
                    }
                }
                ModernLampIllustration(
                    isOn = item.power,
                    brightness = item.brightness,
                    modifier = Modifier.fillMaxWidth().height(122.dp)
                )
                Text(modernModeName(item.brightness, item.power), fontSize = 19.sp, fontWeight = FontWeight.Bold)
                Text(
                    "${modernPowerModeTitle(item.powerMode)} · ${modernRuntimeStateTitle(item.runtimeState)}",
                    color = SHLampDesign.TextSecondary,
                    fontSize = 12.sp
                )
                Spacer(Modifier.height(10.dp))
                Box(contentAlignment = Alignment.Center) {
                    Button(
                        onClick = onPower,
                        enabled = item.reachable && !pending,
                        modifier = Modifier.size(60.dp),
                        shape = CircleShape,
                        contentPadding = PaddingValues(0.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = if (item.power) SHLampDesign.Primary else SHLampDesign.PrimarySoft,
                            contentColor = if (item.power) SHLampDesign.OnPrimary else SHLampDesign.Primary
                        )
                    ) {
                        ModernLineIcon(
                            ModernGlyph.POWER,
                            if (item.power) SHLampDesign.OnPrimary else SHLampDesign.Primary,
                            Modifier.size(27.dp)
                        )
                    }
                    if (pending) {
                        CircularProgressIndicator(Modifier.size(66.dp), strokeWidth = 2.dp, color = SHLampDesign.Primary)
                    }
                }
            }
        }
    }
}

@Composable
private fun ModernPowerModeCard(
    selectedMode: LampPowerMode,
    runtimeState: LampRuntimeState,
    enabled: Boolean,
    onMode: (LampPowerMode) -> Unit
) {
    Card(
        shape = RoundedCornerShape(24.dp),
        colors = CardDefaults.cardColors(containerColor = SHLampDesign.Surface),
        border = BorderStroke(1.dp, SHLampDesign.Border)
    ) {
        Column(Modifier.padding(18.dp)) {
            Text("Battery mode", fontSize = 18.sp, fontWeight = FontWeight.Bold)
            Text(
                "${modernPowerModeTitle(selectedMode)} · ${modernRuntimeStateTitle(runtimeState)}",
                color = SHLampDesign.TextSecondary,
                fontSize = 13.sp
            )
            Spacer(Modifier.height(12.dp))
            LampPowerMode.values().forEach { mode ->
                val selected = mode == selectedMode
                Card(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 4.dp)
                        .clickable(enabled = enabled) { onMode(mode) },
                    shape = RoundedCornerShape(16.dp),
                    colors = CardDefaults.cardColors(
                        containerColor = if (selected) SHLampDesign.PrimarySoft else SHLampDesign.SurfaceSoft
                    ),
                    border = BorderStroke(1.dp, if (selected) SHLampDesign.Primary else SHLampDesign.Border)
                ) {
                    Row(Modifier.padding(13.dp), verticalAlignment = Alignment.CenterVertically) {
                        Box(
                            Modifier
                                .size(10.dp)
                                .background(if (selected) SHLampDesign.Primary else SHLampDesign.TextDisabled, CircleShape)
                        )
                        Spacer(Modifier.width(11.dp))
                        Column(Modifier.weight(1f)) {
                            Text(modernPowerModeTitle(mode), fontWeight = FontWeight.Bold)
                            Text(modernPowerModeSubtitle(mode), color = SHLampDesign.TextSecondary, fontSize = 11.sp)
                        }
                        if (selected) Text("Active", color = SHLampDesign.Primary, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                    }
                }
            }
            if (!enabled) {
                Spacer(Modifier.height(8.dp))
                Text("Power modes are available through local Wi-Fi or Bluetooth.", color = SHLampDesign.TextSecondary, fontSize = 12.sp)
            }
        }
    }
}

private fun modernPowerModeTitle(mode: LampPowerMode): String = when (mode) {
    LampPowerMode.BALANCED -> "Balanced"
    LampPowerMode.MAX_BACKUP -> "Maximum Backup"
    LampPowerMode.BLE_ONLY -> "BLE Only"
    LampPowerMode.TOUCH_ONLY -> "Touch Only"
}

private fun modernPowerModeSubtitle(mode: LampPowerMode): String = when (mode) {
    LampPowerMode.BALANCED -> "Wi-Fi, Bluetooth and remote · up to 100%"
    LampPowerMode.MAX_BACKUP -> "Stronger saving · brightness limited to 70%"
    LampPowerMode.BLE_ONLY -> "Wi-Fi and cloud off · nearby Bluetooth remains"
    LampPowerMode.TOUCH_ONLY -> "All wireless off · physical touch remains"
}

private fun modernRuntimeStateTitle(state: LampRuntimeState): String = when (state) {
    LampRuntimeState.ACTIVE -> "Active"
    LampRuntimeState.LAMP_ON_IDLE -> "Lamp on idle"
    LampRuntimeState.OFF_RECENT -> "Off recently"
    LampRuntimeState.OFF_LONG -> "Long idle"
    LampRuntimeState.TOUCH_ONLY -> "Touch only"
    LampRuntimeState.UNKNOWN -> "Status unavailable"
}

private fun modernRoutePreferenceTitle(preference: LampRoutePreference): String = when (preference) {
    LampRoutePreference.AUTO -> "Automatic"
    LampRoutePreference.WIFI -> "Local Wi-Fi"
    LampRoutePreference.BLUETOOTH -> "Bluetooth"
    LampRoutePreference.REMOTE -> "Remote"
}

private fun modernRoutePreferenceSubtitle(preference: LampRoutePreference): String = when (preference) {
    LampRoutePreference.AUTO -> "Local Wi-Fi, then Bluetooth, then Remote"
    LampRoutePreference.WIFI -> "Prefer the lamp on the current local network"
    LampRoutePreference.BLUETOOTH -> "Stay nearby over Bluetooth when available"
    LampRoutePreference.REMOTE -> "Use cloud control through the internet"
}

@Composable
private fun ModernTopHeader(
    title: String,
    subtitle: String,
    loading: Boolean,
    onRefresh: () -> Unit,
    onAdd: (() -> Unit)?,
    onSearch: (() -> Unit)? = null,
    showDropdown: Boolean = false
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(title, fontSize = 26.sp, fontWeight = FontWeight.Bold)
                if (showDropdown) {
                    Spacer(Modifier.width(5.dp))
                    ModernLineIcon(ModernGlyph.CHEVRON, SHLampDesign.TextSecondary, Modifier.size(14.dp))
                }
            }
            Text(subtitle, color = SHLampDesign.TextSecondary, fontSize = 13.sp)
        }
        ModernCircleIconButton(
            icon = ModernGlyph.REFRESH,
            contentDescription = "Refresh",
            enabled = !loading,
            loading = loading,
            onClick = onRefresh
        )
        if (onSearch != null) {
            Spacer(Modifier.width(8.dp))
            ModernCircleIconButton(
                icon = ModernGlyph.SEARCH,
                contentDescription = "Search",
                onClick = onSearch
            )
        }
        if (onAdd != null) {
            Spacer(Modifier.width(8.dp))
            ModernCircleIconButton(
                icon = ModernGlyph.PLUS,
                contentDescription = "Add lamp",
                filled = true,
                onClick = onAdd
            )
        }
    }
}

@Composable
private fun ModernHomeHero(
    items: List<UnifiedLampItem>,
    reachableCount: Int,
    connected: Boolean
) {
    val onCount = items.count { it.power }
    val greeting = remember {
        when (Calendar.getInstance().get(Calendar.HOUR_OF_DAY)) {
            in 5..11 -> "Good morning"
            in 12..16 -> "Good afternoon"
            else -> "Good evening"
        }
    }
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .shadow(10.dp, RoundedCornerShape(30.dp), ambientColor = SHLampDesign.Shadow),
        shape = RoundedCornerShape(30.dp),
        colors = CardDefaults.cardColors(containerColor = Color.Transparent)
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .background(
                    Brush.linearGradient(
                        listOf(Color(0xFFDDF7F8), Color(0xFFF2F0FF), Color(0xFFFFF5E4))
                    )
                )
                .padding(20.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(greeting, color = SHLampDesign.TextSecondary, fontWeight = FontWeight.Medium)
                    Spacer(Modifier.height(4.dp))
                    Text(
                        when {
                            items.isEmpty() -> "Let’s add your first lamp"
                            onCount > 0 -> "$onCount lamp${if (onCount == 1) " is" else "s are"} lighting your home"
                            reachableCount > 0 -> "Your lamps are ready"
                            connected -> "Remote control is reconnecting"
                            else -> "Your home needs attention"
                        },
                        fontSize = 22.sp,
                        lineHeight = 28.sp,
                        fontWeight = FontWeight.Bold
                    )
                    Spacer(Modifier.height(12.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        ModernStatusPill(
                            label = if (items.isEmpty()) "No devices" else "$reachableCount ready",
                            good = reachableCount > 0 || items.isEmpty()
                        )
                        if (items.isNotEmpty()) {
                            ModernStatusPill(
                                label = "$onCount on",
                                good = true,
                                neutral = true
                            )
                        }
                    }
                }
                ModernLampIllustration(
                    isOn = onCount > 0,
                    brightness = items.filter { it.power }.maxOfOrNull { it.brightness } ?: 0,
                    modifier = Modifier.size(125.dp)
                )
            }
        }
    }
}

@Composable
private fun ModernFoundLampBanner(lampName: String, onAdd: () -> Unit) {
    Card(
        shape = RoundedCornerShape(24.dp),
        colors = CardDefaults.cardColors(containerColor = SHLampDesign.PrimarySoft),
        border = BorderStroke(1.dp, SHLampDesign.Primary.copy(alpha = 0.18f))
    ) {
        Row(
            modifier = Modifier.padding(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            ModernMiniLampGlyph(isOn = true, modifier = Modifier.size(48.dp))
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text("New lamp found nearby", fontWeight = FontWeight.Bold)
                Text(lampName, color = SHLampDesign.TextSecondary, fontSize = 13.sp)
            }
            Button(
                onClick = onAdd,
                shape = RoundedCornerShape(14.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = SHLampDesign.Primary,
                    contentColor = SHLampDesign.OnPrimary
                ),
                contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp)
            ) { Text("Add", fontWeight = FontWeight.Bold) }
        }
    }
}

@Composable
private fun ModernDuplicateBanner(
    candidate: DuplicateLampCandidate,
    onBlink: () -> Unit,
    onLink: () -> Unit,
    onDismiss: () -> Unit
) {
    var expanded by remember(candidate.key) { mutableStateOf(false) }
    Card(
        modifier = Modifier.animateContentSize(),
        shape = RoundedCornerShape(24.dp),
        colors = CardDefaults.cardColors(containerColor = SHLampDesign.WarningSoft),
        border = BorderStroke(1.dp, SHLampDesign.Warning.copy(alpha = 0.25f))
    ) {
        Column(Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier
                        .size(42.dp)
                        .background(Color.White.copy(alpha = 0.7f), CircleShape),
                    contentAlignment = Alignment.Center
                ) {
                    ModernLineIcon(ModernGlyph.ALERT, SHLampDesign.Warning, Modifier.size(22.dp))
                }
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text("Possible duplicate lamp", fontWeight = FontWeight.Bold)
                    Text(
                        "Confirm whether two records are the same lamp",
                        color = SHLampDesign.TextSecondary,
                        fontSize = 13.sp
                    )
                }
                TextButton(onClick = { expanded = !expanded }) {
                    Text(if (expanded) "Hide" else "Review", color = SHLampDesign.Warning)
                }
            }
            if (expanded) {
                Spacer(Modifier.height(12.dp))
                Text(
                    "“${candidate.local.name}” nearby may be the same physical lamp as “${candidate.cloud.name}” in your account.",
                    color = SHLampDesign.TextSecondary
                )
                Spacer(Modifier.height(12.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(
                        onClick = onBlink,
                        modifier = Modifier.weight(1f),
                        shape = RoundedCornerShape(14.dp),
                        border = BorderStroke(1.dp, SHLampDesign.Warning.copy(alpha = 0.4f))
                    ) { Text("Blink") }
                    Button(
                        onClick = onLink,
                        modifier = Modifier.weight(1.4f),
                        shape = RoundedCornerShape(14.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = SHLampDesign.Warning,
                            contentColor = Color.White
                        )
                    ) { Text("Show as one", fontWeight = FontWeight.Bold) }
                }
                TextButton(onClick = onDismiss, modifier = Modifier.fillMaxWidth()) {
                    Text("Keep separate", color = SHLampDesign.TextSecondary)
                }
            }
        }
    }
}

@Composable
private fun ModernSceneChip(
    title: String,
    subtitle: String,
    accent: Color,
    enabled: Boolean,
    onClick: () -> Unit
) {
    Card(
        modifier = Modifier
            .width(132.dp)
            .clickable(enabled = enabled, onClick = onClick),
        shape = RoundedCornerShape(19.dp),
        colors = CardDefaults.cardColors(containerColor = SHLampDesign.Surface),
        border = BorderStroke(1.dp, SHLampDesign.Border)
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 13.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                Modifier
                    .size(34.dp)
                    .background(accent.copy(alpha = 0.12f), RoundedCornerShape(11.dp)),
                contentAlignment = Alignment.Center
            ) {
                Box(Modifier.size(10.dp).background(accent, CircleShape))
            }
            Spacer(Modifier.width(9.dp))
            Column {
                Text(title, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
                Text(subtitle, color = SHLampDesign.TextSecondary, fontSize = 11.sp)
            }
        }
    }
}

@Composable
private fun ModernDeviceCard(
    modifier: Modifier,
    item: UnifiedLampItem,
    pending: Boolean,
    onOpen: () -> Unit,
    onPower: () -> Unit
) {
    val confirmedOnline = item.nearby || item.cloudOnline
    val activeSurface = if (item.power) SHLampDesign.SurfaceTint else SHLampDesign.Surface
    Card(
        modifier = modifier
            .aspectRatio(1f)
            .clickable(onClick = onOpen),
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(containerColor = activeSurface),
        border = BorderStroke(
            1.dp,
            if (item.power) SHLampDesign.Primary.copy(alpha = 0.22f) else SHLampDesign.Border
        ),
        elevation = CardDefaults.cardElevation(defaultElevation = if (item.power) 3.dp else 0.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(12.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                ModernMiniLampGlyph(isOn = item.power, modifier = Modifier.size(38.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    item.batteryPercent?.let { percent ->
                        PhoneBatteryIndicator(
                            percent = percent,
                            charging = item.batteryCharging,
                            showPercent = false
                        )
                        Spacer(Modifier.width(8.dp))
                    }
                    Box(contentAlignment = Alignment.Center) {
                        Button(
                            onClick = onPower,
                            enabled = item.reachable && !pending,
                            modifier = Modifier.size(34.dp),
                            shape = CircleShape,
                            contentPadding = PaddingValues(0.dp),
                            colors = ButtonDefaults.buttonColors(
                                containerColor = if (item.power) SHLampDesign.Primary else SHLampDesign.SurfaceSoft,
                                contentColor = if (item.power) SHLampDesign.OnPrimary else SHLampDesign.TextSecondary,
                                disabledContainerColor = SHLampDesign.SurfaceSoft,
                                disabledContentColor = SHLampDesign.TextDisabled
                            ),
                            elevation = ButtonDefaults.buttonElevation(defaultElevation = 0.dp)
                        ) {
                            ModernLineIcon(
                                ModernGlyph.POWER,
                                if (item.power) Color.White else SHLampDesign.TextSecondary,
                                Modifier.size(19.dp)
                            )
                        }
                        if (pending) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(38.dp),
                                strokeWidth = 1.5.dp,
                                color = SHLampDesign.Primary
                            )
                        }
                    }
                }
            }
            Spacer(Modifier.weight(1f))
            Text(
                item.name,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                fontSize = 15.sp,
                fontWeight = FontWeight.Bold
            )
            Spacer(Modifier.height(3.dp))
            Text(
                when {
                    item.power -> "On · ${item.brightness}%"
                    confirmedOnline -> "Off"
                    item.claimed -> "Remote connection checking"
                    else -> "Offline"
                },
                color = if (item.power) SHLampDesign.PrimaryDeep else SHLampDesign.TextSecondary,
                fontSize = 12.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            Spacer(Modifier.height(8.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier
                        .size(7.dp)
                        .background(
                            if (confirmedOnline) SHLampDesign.Success else SHLampDesign.Offline,
                            CircleShape
                        )
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    item.room.ifBlank { modernConnectionLabel(item) },
                    color = SHLampDesign.TextSecondary,
                    fontSize = 11.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }
    }
}

@Composable
private fun ModernMiniLampGlyph(isOn: Boolean, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .background(
                if (isOn) SHLampDesign.WarmSoft else SHLampDesign.SurfaceSoft,
                RoundedCornerShape(15.dp)
            )
            .padding(7.dp),
        contentAlignment = Alignment.Center
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val w = size.width
            val h = size.height
            val accent = if (isOn) SHLampDesign.WarmDeep else SHLampDesign.TextDisabled
            val shade = Path().apply {
                moveTo(w * 0.28f, h * 0.20f)
                lineTo(w * 0.72f, h * 0.20f)
                lineTo(w * 0.82f, h * 0.47f)
                lineTo(w * 0.18f, h * 0.47f)
                close()
            }
            drawPath(shade, accent)
            drawLine(accent, Offset(w * 0.5f, h * 0.47f), Offset(w * 0.5f, h * 0.78f), strokeWidth = w * 0.08f, cap = StrokeCap.Round)
            drawRoundRect(
                color = accent,
                topLeft = Offset(w * 0.28f, h * 0.77f),
                size = Size(w * 0.44f, h * 0.10f),
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(w * 0.05f, w * 0.05f)
            )
        }
    }
}

@Composable
private fun ModernLampIllustration(
    isOn: Boolean,
    brightness: Int,
    modifier: Modifier = Modifier
) {
    Canvas(modifier) {
        val w = size.width
        val h = size.height
        val center = Offset(w * 0.5f, h * 0.46f)
        val intensity = (brightness.coerceIn(0, 100) / 100f).coerceAtLeast(if (isOn) 0.18f else 0f)
        if (isOn) {
            drawCircle(
                brush = Brush.radialGradient(
                    colors = listOf(
                        SHLampDesign.Warm.copy(alpha = 0.26f + intensity * 0.18f),
                        SHLampDesign.Warm.copy(alpha = 0.06f),
                        Color.Transparent
                    ),
                    center = center,
                    radius = minOf(w, h) * 0.48f
                ),
                radius = minOf(w, h) * 0.48f,
                center = center
            )
        }

        val shadeColor = if (isOn) Color(0xFFFFC866) else Color(0xFFB7C0CB)
        val dark = if (isOn) Color(0xFF9A6A24) else Color(0xFF7B8794)
        val shade = Path().apply {
            moveTo(w * 0.34f, h * 0.23f)
            quadraticTo(w * 0.50f, h * 0.17f, w * 0.66f, h * 0.23f)
            lineTo(w * 0.74f, h * 0.47f)
            quadraticTo(w * 0.50f, h * 0.53f, w * 0.26f, h * 0.47f)
            close()
        }
        drawPath(shade, shadeColor)
        drawLine(
            color = dark,
            start = Offset(w * 0.50f, h * 0.49f),
            end = Offset(w * 0.50f, h * 0.79f),
            strokeWidth = maxOf(6f, w * 0.025f),
            cap = StrokeCap.Round
        )
        drawRoundRect(
            color = dark,
            topLeft = Offset(w * 0.35f, h * 0.78f),
            size = Size(w * 0.30f, h * 0.075f),
            cornerRadius = androidx.compose.ui.geometry.CornerRadius(w * 0.05f, w * 0.05f)
        )
        drawOval(
            color = Color(0x22000000),
            topLeft = Offset(w * 0.30f, h * 0.87f),
            size = Size(w * 0.40f, h * 0.06f)
        )
        if (isOn) {
            repeat(5) { index ->
                val x = w * (0.28f + index * 0.11f)
                drawCircle(
                    color = SHLampDesign.Warm.copy(alpha = 0.15f + index * 0.025f),
                    radius = w * (0.012f + index * 0.002f),
                    center = Offset(x, h * (0.14f + (index % 2) * 0.04f))
                )
            }
        }
    }
}

@Composable
private fun ModernRoomSummary(items: List<UnifiedLampItem>, onOpenDevices: () -> Unit) {
    val groups = items.groupBy { it.room.ifBlank { "Unassigned" } }
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onOpenDevices),
        shape = RoundedCornerShape(24.dp),
        colors = CardDefaults.cardColors(containerColor = SHLampDesign.Surface),
        border = BorderStroke(1.dp, SHLampDesign.Border)
    ) {
        Column(Modifier.padding(17.dp)) {
            ModernSectionHeader(title = "Rooms", action = "Open devices", onAction = onOpenDevices)
            Spacer(Modifier.height(12.dp))
            groups.entries.take(4).forEachIndexed { index, entry ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Box(
                        Modifier
                            .size(36.dp)
                            .background(SHLampDesign.SurfaceSoft, RoundedCornerShape(12.dp)),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(entry.key.take(1).uppercase(), fontWeight = FontWeight.Bold, color = SHLampDesign.Primary)
                    }
                    Spacer(Modifier.width(11.dp))
                    Column(Modifier.weight(1f)) {
                        Text(entry.key, fontWeight = FontWeight.SemiBold)
                        Text(
                            "${entry.value.count { it.power }} on · ${entry.value.size} total",
                            color = SHLampDesign.TextSecondary,
                            fontSize = 12.sp
                        )
                    }
                    ModernLineIcon(ModernGlyph.CHEVRON, SHLampDesign.TextDisabled, Modifier.size(16.dp))
                }
                if (index < groups.entries.take(4).lastIndex) {
                    Box(Modifier.fillMaxWidth().height(1.dp).background(SHLampDesign.Divider))
                }
            }
        }
    }
}

@Composable
private fun ModernCareHero(
    attention: Boolean,
    total: Int,
    offline: Int,
    onDiagnostics: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(28.dp),
        colors = CardDefaults.cardColors(
            containerColor = if (attention) SHLampDesign.WarningSoft else SHLampDesign.SuccessSoft
        ),
        border = BorderStroke(
            1.dp,
            (if (attention) SHLampDesign.Warning else SHLampDesign.Success).copy(alpha = 0.18f)
        )
    ) {
        Column(Modifier.padding(20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier
                        .size(52.dp)
                        .background(Color.White.copy(alpha = 0.78f), CircleShape),
                    contentAlignment = Alignment.Center
                ) {
                    ModernLineIcon(
                        if (attention) ModernGlyph.ALERT else ModernGlyph.CHECK,
                        if (attention) SHLampDesign.Warning else SHLampDesign.Success,
                        Modifier.size(25.dp)
                    )
                }
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        if (attention) "Some lamps need attention" else "Everything looks good",
                        fontSize = 20.sp,
                        fontWeight = FontWeight.Bold
                    )
                    Text(
                        when {
                            total == 0 -> "Add a lamp to begin health monitoring"
                            offline > 0 -> "$offline lamp${if (offline == 1) " is" else "s are"} offline"
                            else -> "All $total lamps are responding normally"
                        },
                        color = SHLampDesign.TextSecondary
                    )
                }
            }
            Spacer(Modifier.height(16.dp))
            Button(
                onClick = onDiagnostics,
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(16.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = if (attention) SHLampDesign.Warning else SHLampDesign.Success,
                    contentColor = Color.White
                )
            ) { Text("Run Smart Check", fontWeight = FontWeight.Bold) }
        }
    }
}

@Composable
private fun ModernMetricCard(
    modifier: Modifier,
    value: String,
    label: String,
    accent: Color,
    surface: Color
) {
    Card(
        modifier = modifier,
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(containerColor = surface)
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 14.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(value, color = accent, fontSize = 23.sp, fontWeight = FontWeight.Bold)
            Text(label, color = SHLampDesign.TextSecondary, fontSize = 11.sp, textAlign = TextAlign.Center)
        }
    }
}

@Composable
private fun ModernHealthRow(item: UnifiedLampItem, onClick: () -> Unit) {
    val healthy = item.nearby || item.cloudOnline
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick),
        shape = RoundedCornerShape(21.dp),
        colors = CardDefaults.cardColors(containerColor = SHLampDesign.Surface),
        border = BorderStroke(1.dp, SHLampDesign.Border)
    ) {
        Row(
            modifier = Modifier.padding(15.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            ModernMiniLampGlyph(isOn = item.power, modifier = Modifier.size(44.dp))
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(item.name, fontWeight = FontWeight.Bold)
                Text(
                    if (healthy) "Working normally" else "Connection needs attention",
                    color = if (healthy) SHLampDesign.Success else SHLampDesign.Error,
                    fontSize = 13.sp
                )
            }
            ModernStatusPill(label = modernConnectionLabel(item), good = healthy)
            Spacer(Modifier.width(8.dp))
            ModernLineIcon(ModernGlyph.CHEVRON, SHLampDesign.TextDisabled, Modifier.size(16.dp))
        }
    }
}

@Composable
private fun ModernBatteryHealthRow(item: UnifiedLampItem, onClick: () -> Unit) {
    val percent = item.batteryPercent ?: return
    val charging = item.batteryCharging
    val low = percent <= 20
    val accent = when {
        charging -> SHLampDesign.Success
        low -> SHLampDesign.Error
        else -> SHLampDesign.TextPrimary
    }
    val surface = when {
        charging -> SHLampDesign.SuccessSoft
        low -> SHLampDesign.ErrorSoft
        else -> SHLampDesign.Surface
    }
    val status = when {
        charging -> "Charging"
        low -> "Low battery"
        else -> "Battery healthy"
    }

    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick),
        shape = RoundedCornerShape(21.dp),
        colors = CardDefaults.cardColors(containerColor = surface),
        border = BorderStroke(1.dp, accent.copy(alpha = 0.22f))
    ) {
        Row(
            modifier = Modifier.padding(15.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            PhoneBatteryIndicator(
                percent = percent,
                charging = charging,
                showPercent = false,
                modifier = Modifier.size(width = 46.dp, height = 23.dp)
            )
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(item.name, fontWeight = FontWeight.Bold)
                Text(status, color = accent, fontSize = 13.sp)
            }
            Text(
                "$percent%",
                color = accent,
                fontSize = 15.sp,
                fontWeight = FontWeight.Bold
            )
            Spacer(Modifier.width(8.dp))
            ModernLineIcon(ModernGlyph.CHEVRON, accent, Modifier.size(16.dp))
        }
    }
}

@Composable
private fun PhoneBatteryIndicator(
    percent: Int,
    charging: Boolean,
    showPercent: Boolean,
    modifier: Modifier = Modifier.size(width = 35.dp, height = 18.dp)
) {
    val safePercent = percent.coerceIn(0, 100)
    val low = safePercent <= 20
    val accent = when {
        charging -> SHLampDesign.Success
        low -> SHLampDesign.Error
        else -> SHLampDesign.TextPrimary
    }
    val transition = rememberInfiniteTransition(label = "batteryCharging")
    val chargingPulse by transition.animateFloat(
        initialValue = 0.45f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 650),
            repeatMode = RepeatMode.Reverse
        ),
        label = "chargingPulse"
    )

    Row(verticalAlignment = Alignment.CenterVertically) {
        Canvas(modifier = modifier) {
            val strokeWidth = 1.5.dp.toPx()
            val terminalGap = 2.dp.toPx()
            val terminalWidth = 3.dp.toPx()
            val bodyWidth = size.width - terminalGap - terminalWidth
            val verticalInset = 1.dp.toPx()
            val bodyHeight = size.height - verticalInset * 2f
            val corner = CornerRadius(bodyHeight * 0.23f, bodyHeight * 0.23f)

            drawRoundRect(
                color = accent.copy(alpha = 0.52f),
                topLeft = Offset(0f, verticalInset),
                size = Size(bodyWidth, bodyHeight),
                cornerRadius = corner,
                style = Stroke(width = strokeWidth)
            )
            drawRoundRect(
                color = accent.copy(alpha = 0.72f),
                topLeft = Offset(bodyWidth + terminalGap, size.height * 0.34f),
                size = Size(terminalWidth, size.height * 0.32f),
                cornerRadius = CornerRadius(terminalWidth * 0.45f, terminalWidth * 0.45f)
            )

            val innerPadding = 2.8.dp.toPx()
            val maxFillWidth = (bodyWidth - innerPadding * 2f).coerceAtLeast(0f)
            val fillWidth = maxFillWidth * (safePercent / 100f)
            if (fillWidth > 0f) {
                drawRoundRect(
                    color = accent.copy(alpha = if (charging) chargingPulse else 1f),
                    topLeft = Offset(innerPadding, verticalInset + innerPadding),
                    size = Size(
                        fillWidth,
                        (bodyHeight - innerPadding * 2f).coerceAtLeast(1f)
                    ),
                    cornerRadius = CornerRadius(bodyHeight * 0.13f, bodyHeight * 0.13f)
                )
            }

            if (charging) {
                val bolt = Path().apply {
                    moveTo(bodyWidth * 0.56f, size.height * 0.18f)
                    lineTo(bodyWidth * 0.36f, size.height * 0.54f)
                    lineTo(bodyWidth * 0.49f, size.height * 0.54f)
                    lineTo(bodyWidth * 0.40f, size.height * 0.84f)
                    lineTo(bodyWidth * 0.68f, size.height * 0.44f)
                    lineTo(bodyWidth * 0.54f, size.height * 0.44f)
                    close()
                }
                drawPath(bolt, Color.White.copy(alpha = chargingPulse))
            }
        }
        if (showPercent) {
            Spacer(Modifier.width(5.dp))
            Text(
                "$safePercent%",
                color = accent,
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1
            )
        }
    }
}

private data class ModernMenuRowData(
    val title: String,
    val subtitle: String,
    val accent: Color,
    val action: () -> Unit
)

@Composable
private fun ModernMenuSection(title: String, rows: List<ModernMenuRowData>) {
    Column {
        Text(
            title,
            modifier = Modifier.padding(start = 4.dp, bottom = 8.dp),
            color = SHLampDesign.TextSecondary,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold
        )
        Card(
            shape = RoundedCornerShape(24.dp),
            colors = CardDefaults.cardColors(containerColor = SHLampDesign.Surface),
            border = BorderStroke(1.dp, SHLampDesign.Border)
        ) {
            Column {
                rows.forEachIndexed { index, row ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable(onClick = row.action)
                            .padding(16.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Box(
                            Modifier
                                .size(40.dp)
                                .background(row.accent.copy(alpha = 0.10f), RoundedCornerShape(13.dp)),
                            contentAlignment = Alignment.Center
                        ) {
                            Box(Modifier.size(10.dp).background(row.accent, CircleShape))
                        }
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(row.title, fontWeight = FontWeight.SemiBold)
                            Text(
                                row.subtitle,
                                color = SHLampDesign.TextSecondary,
                                fontSize = 12.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                        ModernLineIcon(ModernGlyph.CHEVRON, SHLampDesign.TextDisabled, Modifier.size(16.dp))
                    }
                    if (index < rows.lastIndex) {
                        Box(
                            Modifier
                                .fillMaxWidth()
                                .padding(start = 68.dp)
                                .height(1.dp)
                                .background(SHLampDesign.Divider)
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun ModernActionCard(
    title: String,
    subtitle: String,
    accent: Color,
    enabled: Boolean = true,
    onClick: () -> Unit
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, onClick = onClick),
        shape = RoundedCornerShape(22.dp),
        colors = CardDefaults.cardColors(containerColor = SHLampDesign.Surface),
        border = BorderStroke(1.dp, SHLampDesign.Border)
    ) {
        Row(
            modifier = Modifier.padding(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                Modifier
                    .size(42.dp)
                    .background(accent.copy(alpha = 0.11f), RoundedCornerShape(14.dp)),
                contentAlignment = Alignment.Center
            ) {
                Box(Modifier.size(11.dp).background(accent, CircleShape))
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(title, fontWeight = FontWeight.Bold)
                Text(subtitle, color = SHLampDesign.TextSecondary, fontSize = 12.sp)
            }
            ModernLineIcon(ModernGlyph.CHEVRON, SHLampDesign.TextDisabled, Modifier.size(17.dp))
        }
    }
}

@Composable
private fun ModernInfoPanel(title: String, text: String, accent: Color, surface: Color) {
    Card(
        shape = RoundedCornerShape(22.dp),
        colors = CardDefaults.cardColors(containerColor = surface)
    ) {
        Column(Modifier.padding(17.dp)) {
            Box(Modifier.size(10.dp).background(accent, CircleShape))
            Spacer(Modifier.height(10.dp))
            Text(title, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(5.dp))
            Text(text, color = SHLampDesign.TextSecondary, fontSize = 13.sp, lineHeight = 19.sp)
        }
    }
}

@Composable
private fun ModernControlMetric(
    modifier: Modifier,
    title: String,
    value: String,
    accent: Color,
    surface: Color
) {
    Card(
        modifier = modifier,
        shape = RoundedCornerShape(19.dp),
        colors = CardDefaults.cardColors(containerColor = surface)
    ) {
        Column(Modifier.padding(horizontal = 11.dp, vertical = 13.dp)) {
            Box(Modifier.size(8.dp).background(accent, CircleShape))
            Spacer(Modifier.height(10.dp))
            Text(value, fontWeight = FontWeight.Bold, fontSize = 14.sp, maxLines = 1)
            Text(title, color = SHLampDesign.TextSecondary, fontSize = 10.sp, maxLines = 1)
        }
    }
}

@Composable
private fun ModernSectionHeader(
    title: String,
    action: String? = null,
    onAction: (() -> Unit)? = null
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(title, modifier = Modifier.weight(1f), fontSize = 19.sp, fontWeight = FontWeight.Bold)
        if (action != null && onAction != null) {
            TextButton(onClick = onAction, contentPadding = PaddingValues(horizontal = 6.dp, vertical = 2.dp)) {
                Text(action, color = SHLampDesign.Primary, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

@Composable
private fun ModernStatusPill(
    label: String,
    good: Boolean,
    neutral: Boolean = false
) {
    val background = when {
        neutral -> Color.White.copy(alpha = 0.65f)
        good -> SHLampDesign.SuccessSoft
        else -> SHLampDesign.ErrorSoft
    }
    val foreground = when {
        neutral -> SHLampDesign.TextSecondary
        good -> SHLampDesign.Success
        else -> SHLampDesign.Error
    }
    Row(
        modifier = Modifier
            .background(background, RoundedCornerShape(50))
            .padding(horizontal = 9.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(Modifier.size(6.dp).background(foreground, CircleShape))
        Spacer(Modifier.width(5.dp))
        Text(label, color = foreground, fontSize = 10.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
    }
}

@Composable
private fun ModernSearchField(value: String, onValueChange: (String) -> Unit, hint: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(SHLampDesign.Surface, RoundedCornerShape(18.dp))
            .clip(RoundedCornerShape(18.dp))
            .clickable { }
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        ModernLineIcon(ModernGlyph.SEARCH, SHLampDesign.TextSecondary, Modifier.size(19.dp))
        Spacer(Modifier.width(10.dp))
        androidx.compose.material3.OutlinedTextField(
            value = value,
            onValueChange = onValueChange,
            modifier = Modifier.weight(1f),
            placeholder = { Text(hint, color = SHLampDesign.TextDisabled) },
            singleLine = true,
            colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
                focusedBorderColor = Color.Transparent,
                unfocusedBorderColor = Color.Transparent,
                focusedContainerColor = Color.Transparent,
                unfocusedContainerColor = Color.Transparent
            )
        )
        if (value.isNotBlank()) {
            TextButton(onClick = { onValueChange("") }, contentPadding = PaddingValues(4.dp)) {
                Text("Clear", color = SHLampDesign.Primary, fontSize = 12.sp)
            }
        }
    }
}

@Composable
private fun ModernFilterChip(label: String, selected: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .background(
                if (selected) SHLampDesign.Primary else SHLampDesign.Surface,
                RoundedCornerShape(50)
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 15.dp, vertical = 9.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            label,
            color = if (selected) Color.White else SHLampDesign.TextSecondary,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold
        )
    }
}

@Composable
private fun ModernSegmentedControl(
    labels: List<String>,
    selectedIndex: Int,
    onSelected: (Int) -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(SHLampDesign.SurfaceSoft, RoundedCornerShape(18.dp))
            .padding(4.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp)
    ) {
        labels.forEachIndexed { index, label ->
            Box(
                modifier = Modifier
                    .weight(1f)
                    .background(
                        if (selectedIndex == index) SHLampDesign.Surface else Color.Transparent,
                        RoundedCornerShape(14.dp)
                    )
                    .clickable { onSelected(index) }
                    .padding(vertical = 10.dp),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    label,
                    color = if (selectedIndex == index) SHLampDesign.PrimaryDeep else SHLampDesign.TextSecondary,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 13.sp
                )
            }
        }
    }
}

@Composable
private fun ModernPresetButton(
    modifier: Modifier,
    label: String,
    selected: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
    compact: Boolean = false
) {
    if (selected) {
        Button(
            onClick = onClick,
            enabled = enabled,
            modifier = modifier.height(if (compact) 42.dp else 46.dp),
            shape = RoundedCornerShape(14.dp),
            contentPadding = PaddingValues(horizontal = 3.dp),
            colors = ButtonDefaults.buttonColors(
                containerColor = SHLampDesign.Primary,
                contentColor = Color.White,
                disabledContainerColor = SHLampDesign.PrimarySoft,
                disabledContentColor = SHLampDesign.TextDisabled
            )
        ) { Text(label, fontSize = if (compact) 10.sp else 13.sp, maxLines = 1) }
    } else {
        OutlinedButton(
            onClick = onClick,
            enabled = enabled,
            modifier = modifier.height(if (compact) 42.dp else 46.dp),
            shape = RoundedCornerShape(14.dp),
            contentPadding = PaddingValues(horizontal = 3.dp),
            border = BorderStroke(1.dp, SHLampDesign.Border),
            colors = ButtonDefaults.outlinedButtonColors(contentColor = SHLampDesign.TextPrimary)
        ) { Text(label, fontSize = if (compact) 10.sp else 13.sp, maxLines = 1) }
    }
}

@Composable
private fun ModernEmptyLampCard(onAddLamp: () -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(26.dp),
        colors = CardDefaults.cardColors(containerColor = SHLampDesign.Surface),
        border = BorderStroke(1.dp, SHLampDesign.Border)
    ) {
        Column(
            modifier = Modifier.padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            ModernLampIllustration(false, 0, Modifier.size(120.dp))
            Text("Add your first lamp", fontSize = 21.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(6.dp))
            Text(
                "The app will find nearby Smart Handicrafts® lamps and guide you through Wi-Fi setup.",
                color = SHLampDesign.TextSecondary,
                textAlign = TextAlign.Center
            )
            Spacer(Modifier.height(16.dp))
            Button(
                onClick = onAddLamp,
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(16.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = SHLampDesign.Primary,
                    contentColor = Color.White
                )
            ) { Text("Add Lamp", fontWeight = FontWeight.Bold) }
        }
    }
}

@Composable
private fun ModernEmptySearchCard(onClear: () -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(24.dp),
        colors = CardDefaults.cardColors(containerColor = SHLampDesign.Surface)
    ) {
        Column(
            modifier = Modifier.padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text("No matching lamps", fontSize = 18.sp, fontWeight = FontWeight.Bold)
            Text("Try another room or clear the search.", color = SHLampDesign.TextSecondary)
            Spacer(Modifier.height(12.dp))
            TextButton(onClick = onClear) { Text("Clear filters", color = SHLampDesign.Primary) }
        }
    }
}

@Composable
private fun ModernNoticeCard(message: String) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(containerColor = SHLampDesign.ErrorSoft),
        border = BorderStroke(1.dp, SHLampDesign.Error.copy(alpha = 0.16f))
    ) {
        Row(
            modifier = Modifier.padding(14.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            ModernLineIcon(ModernGlyph.ALERT, SHLampDesign.Error, Modifier.size(20.dp))
            Spacer(Modifier.width(10.dp))
            Text(message, color = SHLampDesign.Error, fontSize = 13.sp)
        }
    }
}

@Composable
private fun ModernBottomBar(
    selected: ModernAppTab,
    onSelected: (ModernAppTab) -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(SHLampDesign.Surface)
            .navigationBarsPadding()
            .padding(horizontal = 8.dp, vertical = 7.dp),
        horizontalArrangement = Arrangement.SpaceAround,
        verticalAlignment = Alignment.CenterVertically
    ) {
        ModernAppTab.entries.forEach { tab ->
            val active = tab == selected
            Column(
                modifier = Modifier
                    .weight(1f)
                    .clickable { onSelected(tab) }
                    .padding(vertical = 4.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Box(
                    modifier = Modifier
                        .size(width = 42.dp, height = 30.dp)
                        .background(
                            if (active) SHLampDesign.PrimarySoft else Color.Transparent,
                            RoundedCornerShape(50)
                        ),
                    contentAlignment = Alignment.Center
                ) {
                    ModernLineIcon(
                        icon = when (tab) {
                            ModernAppTab.HOME -> ModernGlyph.HOME
                            ModernAppTab.DEVICES -> ModernGlyph.DEVICES
                            ModernAppTab.CARE -> ModernGlyph.CARE
                            ModernAppTab.MENU -> ModernGlyph.MENU
                        },
                        tint = if (active) SHLampDesign.PrimaryDeep else SHLampDesign.TextSecondary,
                        modifier = Modifier.size(20.dp)
                    )
                }
                Spacer(Modifier.height(3.dp))
                Text(
                    tab.label,
                    color = if (active) SHLampDesign.PrimaryDeep else SHLampDesign.TextSecondary,
                    fontSize = 10.sp,
                    fontWeight = if (active) FontWeight.Bold else FontWeight.Medium
                )
            }
        }
    }
}

@Composable
private fun ModernCircleIconButton(
    icon: ModernGlyph,
    contentDescription: String,
    enabled: Boolean = true,
    loading: Boolean = false,
    filled: Boolean = false,
    onClick: () -> Unit
) {
    Box(contentAlignment = Alignment.Center) {
        Box(
            modifier = Modifier
                .size(42.dp)
                .background(
                    if (filled) SHLampDesign.Primary else SHLampDesign.Surface,
                    CircleShape
                )
                .clickable(enabled = enabled && !loading, onClick = onClick),
            contentAlignment = Alignment.Center
        ) {
            ModernLineIcon(
                icon,
                if (filled) Color.White else SHLampDesign.TextPrimary,
                Modifier.size(20.dp)
            )
        }
        if (loading) {
            CircularProgressIndicator(
                modifier = Modifier.size(42.dp),
                strokeWidth = 1.5.dp,
                color = SHLampDesign.Primary
            )
        }
    }
}

@Composable
private fun ModernLineIcon(icon: ModernGlyph, tint: Color, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val w = size.width
        val h = size.height
        val stroke = maxOf(1.6f, minOf(w, h) * 0.085f)
        val style = Stroke(width = stroke, cap = StrokeCap.Round)
        when (icon) {
            ModernGlyph.HOME -> {
                val p = Path().apply {
                    moveTo(w * 0.16f, h * 0.48f)
                    lineTo(w * 0.50f, h * 0.18f)
                    lineTo(w * 0.84f, h * 0.48f)
                    moveTo(w * 0.24f, h * 0.43f)
                    lineTo(w * 0.24f, h * 0.82f)
                    lineTo(w * 0.76f, h * 0.82f)
                    lineTo(w * 0.76f, h * 0.43f)
                    moveTo(w * 0.43f, h * 0.82f)
                    lineTo(w * 0.43f, h * 0.60f)
                    lineTo(w * 0.57f, h * 0.60f)
                    lineTo(w * 0.57f, h * 0.82f)
                }
                drawPath(p, tint, style = style)
            }

            ModernGlyph.DEVICES -> {
                val gap = w * 0.10f
                val cell = (w - gap * 3) / 2f
                listOf(
                    Offset(gap, gap),
                    Offset(gap * 2 + cell, gap),
                    Offset(gap, gap * 2 + cell),
                    Offset(gap * 2 + cell, gap * 2 + cell)
                ).forEach {
                    drawRoundRect(
                        color = tint,
                        topLeft = it,
                        size = Size(cell, cell),
                        cornerRadius = androidx.compose.ui.geometry.CornerRadius(cell * 0.2f),
                        style = style
                    )
                }
            }

            ModernGlyph.CARE -> {
                val p = Path().apply {
                    moveTo(w * 0.50f, h * 0.84f)
                    cubicTo(w * 0.12f, h * 0.62f, w * 0.13f, h * 0.22f, w * 0.35f, h * 0.20f)
                    cubicTo(w * 0.44f, h * 0.19f, w * 0.49f, h * 0.26f, w * 0.50f, h * 0.33f)
                    cubicTo(w * 0.51f, h * 0.26f, w * 0.57f, h * 0.19f, w * 0.66f, h * 0.20f)
                    cubicTo(w * 0.88f, h * 0.22f, w * 0.89f, h * 0.62f, w * 0.50f, h * 0.84f)
                }
                drawPath(p, tint, style = style)
            }

            ModernGlyph.MENU -> {
                listOf(0.28f, 0.50f, 0.72f).forEach { y ->
                    drawLine(tint, Offset(w * 0.20f, h * y), Offset(w * 0.80f, h * y), stroke, StrokeCap.Round)
                }
            }

            ModernGlyph.PLUS -> {
                drawLine(tint, Offset(w * 0.50f, h * 0.22f), Offset(w * 0.50f, h * 0.78f), stroke, StrokeCap.Round)
                drawLine(tint, Offset(w * 0.22f, h * 0.50f), Offset(w * 0.78f, h * 0.50f), stroke, StrokeCap.Round)
            }

            ModernGlyph.SEARCH -> {
                drawCircle(tint, radius = w * 0.25f, center = Offset(w * 0.43f, h * 0.43f), style = style)
                drawLine(tint, Offset(w * 0.61f, h * 0.61f), Offset(w * 0.82f, h * 0.82f), stroke, StrokeCap.Round)
            }

            ModernGlyph.BELL -> {
                val p = Path().apply {
                    moveTo(w * 0.26f, h * 0.66f)
                    quadraticTo(w * 0.32f, h * 0.58f, w * 0.32f, h * 0.42f)
                    quadraticTo(w * 0.32f, h * 0.20f, w * 0.50f, h * 0.20f)
                    quadraticTo(w * 0.68f, h * 0.20f, w * 0.68f, h * 0.42f)
                    quadraticTo(w * 0.68f, h * 0.58f, w * 0.74f, h * 0.66f)
                    lineTo(w * 0.26f, h * 0.66f)
                    moveTo(w * 0.43f, h * 0.76f)
                    quadraticTo(w * 0.50f, h * 0.84f, w * 0.57f, h * 0.76f)
                }
                drawPath(p, tint, style = style)
            }

            ModernGlyph.POWER -> {
                drawArc(
                    color = tint,
                    startAngle = -48f,
                    sweepAngle = 276f,
                    useCenter = false,
                    topLeft = Offset(w * 0.16f, h * 0.16f),
                    size = Size(w * 0.68f, h * 0.68f),
                    style = style
                )
                drawLine(tint, Offset(w * 0.50f, h * 0.12f), Offset(w * 0.50f, h * 0.50f), stroke, StrokeCap.Round)
            }

            ModernGlyph.BACK -> {
                drawLine(tint, Offset(w * 0.70f, h * 0.20f), Offset(w * 0.30f, h * 0.50f), stroke, StrokeCap.Round)
                drawLine(tint, Offset(w * 0.30f, h * 0.50f), Offset(w * 0.70f, h * 0.80f), stroke, StrokeCap.Round)
            }

            ModernGlyph.SETTINGS -> {
                drawCircle(tint, radius = w * 0.28f, center = Offset(w * 0.50f, h * 0.50f), style = style)
                drawCircle(tint, radius = w * 0.08f, center = Offset(w * 0.50f, h * 0.50f), style = style)
                listOf(0f, 90f, 180f, 270f).forEach { degree ->
                    val rad = Math.toRadians(degree.toDouble())
                    val c = kotlin.math.cos(rad).toFloat()
                    val s = kotlin.math.sin(rad).toFloat()
                    drawLine(
                        tint,
                        Offset(w * 0.50f + c * w * 0.30f, h * 0.50f + s * h * 0.30f),
                        Offset(w * 0.50f + c * w * 0.40f, h * 0.50f + s * h * 0.40f),
                        stroke,
                        StrokeCap.Round
                    )
                }
            }

            ModernGlyph.REFRESH -> {
                drawArc(tint, -55f, 255f, false, Offset(w * 0.16f, h * 0.16f), Size(w * 0.68f, h * 0.68f), style = style)
                val p = Path().apply {
                    moveTo(w * 0.73f, h * 0.13f)
                    lineTo(w * 0.84f, h * 0.18f)
                    lineTo(w * 0.79f, h * 0.30f)
                }
                drawPath(p, tint, style = style)
            }

            ModernGlyph.CHEVRON -> {
                drawLine(tint, Offset(w * 0.35f, h * 0.25f), Offset(w * 0.65f, h * 0.50f), stroke, StrokeCap.Round)
                drawLine(tint, Offset(w * 0.65f, h * 0.50f), Offset(w * 0.35f, h * 0.75f), stroke, StrokeCap.Round)
            }

            ModernGlyph.CHECK -> {
                drawLine(tint, Offset(w * 0.20f, h * 0.53f), Offset(w * 0.42f, h * 0.73f), stroke, StrokeCap.Round)
                drawLine(tint, Offset(w * 0.42f, h * 0.73f), Offset(w * 0.82f, h * 0.28f), stroke, StrokeCap.Round)
            }

            ModernGlyph.ALERT -> {
                val p = Path().apply {
                    moveTo(w * 0.50f, h * 0.14f)
                    lineTo(w * 0.86f, h * 0.80f)
                    lineTo(w * 0.14f, h * 0.80f)
                    close()
                }
                drawPath(p, tint, style = style)
                drawLine(tint, Offset(w * 0.50f, h * 0.36f), Offset(w * 0.50f, h * 0.58f), stroke, StrokeCap.Round)
                drawCircle(tint, radius = stroke * 0.55f, center = Offset(w * 0.50f, h * 0.69f))
            }
        }
    }
}

private fun modernConnectionLabel(item: UnifiedLampItem): String = when (item.controlPath) {
    LampControlPath.WIFI -> "Wi-Fi"
    LampControlPath.BLUETOOTH -> "Bluetooth"
    LampControlPath.REMOTE -> if (item.cloudOnline) "Remote" else "Cloud"
    LampControlPath.OFFLINE -> "Offline"
}

private fun modernModeName(brightness: Int, power: Boolean): String = when {
    !power -> "Lamp off"
    brightness <= 25 -> "Night light"
    brightness <= 70 -> "Relax mode"
    else -> "Reading mode"
}

private fun modernTimerPresetFromRemaining(seconds: Long): Int = when {
    seconds <= 0L -> 0
    seconds <= 15L * 60L -> 15
    seconds <= 30L * 60L -> 30
    else -> 60
}

private fun modernFormatTimer(seconds: Long): String {
    val safe = seconds.coerceAtLeast(0L)
    val minutes = safe / 60L
    val remainder = safe % 60L
    return "%02d:%02d".format(Locale.US, minutes, remainder)
}
