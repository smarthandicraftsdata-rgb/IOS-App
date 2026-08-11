package com.example.shlamp

import android.app.Activity
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.URL
import java.net.URLEncoder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

internal data class WifiLampSnapshot(
    val lampId: String,
    val cloudLampId: String?,
    val lampName: String,
    val hostname: String,
    val firmware: String,
    val power: Boolean,
    val currentBrightness: Int,
    val targetBrightness: Int,
    val lastBrightness: Int,
    val fadeMode: Int,
    val timerRemainingSeconds: Long,
    val ssid: String,
    val rssi: Int,
    val ip: String,
    val activeSsid: String,
    val savedNetworkCount: Int,
    val controllerCount: Int,
    val bleName: String,
    val batteryValid: Boolean = false,
    val batteryPercent: Int? = null,
    val batteryVoltageMv: Int? = null,
    val batteryCharging: Boolean? = null,
    val powerMode: LampPowerMode = LampPowerMode.BALANCED,
    val runtimeState: LampRuntimeState = LampRuntimeState.UNKNOWN
)

internal sealed interface WifiCommandResult {
    data class Success(val snapshot: WifiLampSnapshot? = null) : WifiCommandResult
    data class Failed(val message: String) : WifiCommandResult
}

/**
 * Multi-lamp local HTTP client and mDNS discovery service.
 *
 * Each discovered service is verified through /api/status and matched by the
 * permanent lampId. This prevents two lamps on the same router from being
 * merged or controlled through the wrong IP address.
 */
internal class WifiLampController(
    private val activity: Activity,
    private val handler: Handler
) {
    companion object {
        private const val SERVICE_TYPE = "_http._tcp."
        private const val CONNECT_TIMEOUT_MS = 2_500
        private const val READ_TIMEOUT_MS = 3_500
    }

    private val executor: ExecutorService = Executors.newFixedThreadPool(3)
    private val nsdManager = activity.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val connectivityManager =
        activity.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val wifiManager =
        activity.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager

    private val resolvingServices = ConcurrentHashMap.newKeySet<String>()
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private var onLampFound: ((WifiLampSnapshot) -> Unit)? = null

    /**
     * Identifies the phone's current Wi-Fi network. Android assigns a new
     * Network handle when the phone changes routers/hotspots, even when both
     * networks use similar private IP ranges.
     */
    fun currentWifiNetworkKey(): Long? {
        val network = findWifiNetwork() ?: return null
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            network.networkHandle
        } else {
            network.hashCode().toLong()
        }
    }

    fun startDiscovery(onFound: (WifiLampSnapshot) -> Unit) {
        onLampFound = onFound
        if (discoveryListener != null) return

        acquireMulticastLock()

        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                val serviceName = serviceInfo.serviceName.orEmpty()
                val serviceType = serviceInfo.serviceType.orEmpty()
                if (!serviceType.startsWith("_http._tcp", ignoreCase = true)) return
                if (!serviceName.contains("sh-lamp", ignoreCase = true) &&
                    !serviceName.contains("sh lamp", ignoreCase = true)
                ) return
                resolveService(serviceInfo)
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit

            override fun onDiscoveryStopped(serviceType: String) {
                if (discoveryListener === this) discoveryListener = null
                releaseMulticastLock()
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                if (discoveryListener === this) discoveryListener = null
                releaseMulticastLock()
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                if (discoveryListener === this) discoveryListener = null
                releaseMulticastLock()
            }
        }

        discoveryListener = listener
        runCatching {
            nsdManager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
        }.onFailure {
            discoveryListener = null
            releaseMulticastLock()
        }
    }

    fun stopDiscovery() {
        val listener = discoveryListener
        discoveryListener = null
        if (listener != null) {
            runCatching { nsdManager.stopServiceDiscovery(listener) }
        }
        resolvingServices.clear()
        releaseMulticastLock()
    }

    fun readStatus(host: String, callback: (Result<WifiLampSnapshot>) -> Unit) {
        val cleanHost = normalizeHost(host)
        if (cleanHost.isBlank()) {
            handler.post { callback(Result.failure(IOException("Lamp address is empty"))) }
            return
        }

        executor.execute {
            val result = runCatching {
                parseSnapshot(request(cleanHost, "/api/status"))
            }
            handler.post { callback(result) }
        }
    }

    fun sendPower(
        host: String,
        on: Boolean,
        callback: (WifiCommandResult) -> Unit
    ) = sendVerifiedCommand(
        host = host,
        path = "/api/power?state=${if (on) "on" else "off"}",
        verify = { it.power == on },
        callback = callback
    )

    fun sendBrightness(
        host: String,
        percent: Int,
        callback: (WifiCommandResult) -> Unit
    ) {
        val value = percent.coerceIn(0, 100)
        sendVerifiedCommand(
            host = host,
            path = "/api/brightness?value=$value",
            verify = { snapshot ->
                val expected = if (snapshot.powerMode == LampPowerMode.MAX_BACKUP) {
                    value.coerceAtMost(70)
                } else {
                    value
                }
                snapshot.targetBrightness == expected
            },
            callback = callback
        )
    }

    fun sendPowerMode(
        host: String,
        mode: LampPowerMode,
        callback: (WifiCommandResult) -> Unit
    ) {
        val path = "/api/power-mode?mode=${mode.firmwareValue}"
        if (mode == LampPowerMode.BLE_ONLY || mode == LampPowerMode.TOUCH_ONLY) {
            // These modes intentionally stop local Wi-Fi immediately, so a second
            // /api/status verification would incorrectly report a failure.
            sendSimpleCommand(host, path, callback)
        } else {
            sendVerifiedCommand(
                host = host,
                path = path,
                verify = { it.powerMode == mode },
                callback = callback
            )
        }
    }

    fun sendFade(
        host: String,
        mode: Int,
        callback: (WifiCommandResult) -> Unit
    ) {
        val value = mode.coerceIn(0, 3)
        sendVerifiedCommand(
            host = host,
            path = "/api/fade?mode=$value",
            verify = { it.fadeMode == value },
            callback = callback
        )
    }

    fun sendTimer(
        host: String,
        minutes: Int,
        callback: (WifiCommandResult) -> Unit
    ) {
        val value = when (minutes) {
            0, 15, 30, 60 -> minutes
            else -> 0
        }
        sendVerifiedCommand(
            host = host,
            path = "/api/timer?minutes=$value",
            verify = {
                if (value == 0) it.timerRemainingSeconds == 0L
                else it.timerRemainingSeconds in 1L..(value * 60L)
            },
            callback = callback
        )
    }

    fun identify(host: String, callback: (WifiCommandResult) -> Unit) =
        sendSimpleCommand(host, "/api/identify", callback)

    fun rename(host: String, name: String, callback: (WifiCommandResult) -> Unit) {
        val encoded = URLEncoder.encode(name.trim(), Charsets.UTF_8.name())
        sendVerifiedCommand(
            host = host,
            path = "/api/name?value=$encoded",
            verify = { it.lampName == name.trim() },
            callback = callback
        )
    }

    fun readControllers(
        host: String,
        callback: (Result<List<LampControllerAccess>>) -> Unit
    ) {
        val cleanHost = normalizeHost(host)
        executor.execute {
            val result = runCatching {
                val array = JSONArray(request(cleanHost, "/api/controllers"))
                buildList {
                    for (index in 0 until array.length()) {
                        val item = array.optJSONObject(index) ?: continue
                        val id = item.optString("controllerId").trim()
                        if (id.isBlank()) continue
                        add(
                            LampControllerAccess(
                                controllerId = id,
                                label = item.optString("label", "Controller"),
                                role = if (item.optString("role") == "OWNER") {
                                    LampAccessRole.OWNER
                                } else {
                                    LampAccessRole.MEMBER
                                }
                            )
                        )
                    }
                }
            }
            handler.post { callback(result) }
        }
    }

    fun close() {
        stopDiscovery()
        executor.shutdownNow()
    }

    private fun sendSimpleCommand(
        host: String,
        path: String,
        callback: (WifiCommandResult) -> Unit
    ) {
        val cleanHost = normalizeHost(host)
        executor.execute {
            val result = runCatching { request(cleanHost, path) }
                .fold(
                    onSuccess = { WifiCommandResult.Success() },
                    onFailure = { WifiCommandResult.Failed(it.message ?: "Local Wi-Fi command failed") }
                )
            handler.post { callback(result) }
        }
    }

    private fun sendVerifiedCommand(
        host: String,
        path: String,
        verify: (WifiLampSnapshot) -> Boolean,
        callback: (WifiCommandResult) -> Unit
    ) {
        val cleanHost = normalizeHost(host)
        executor.execute {
            val result = try {
                request(cleanHost, path)
                val snapshot = parseSnapshot(request(cleanHost, "/api/status"))
                if (verify(snapshot)) {
                    WifiCommandResult.Success(snapshot)
                } else {
                    WifiCommandResult.Failed("Lamp replied but the requested state was not confirmed")
                }
            } catch (firstError: Exception) {
                // A command may execute even when Android times out waiting for
                // the response. Verify once before allowing BLE fallback.
                try {
                    val snapshot = parseSnapshot(request(cleanHost, "/api/status"))
                    if (verify(snapshot)) {
                        WifiCommandResult.Success(snapshot)
                    } else {
                        WifiCommandResult.Failed(
                            firstError.message ?: "Local Wi-Fi command was not confirmed"
                        )
                    }
                } catch (_: Exception) {
                    WifiCommandResult.Failed(
                        firstError.message ?: "Lamp is unreachable on local Wi-Fi"
                    )
                }
            }
            handler.post { callback(result) }
        }
    }

    @Suppress("DEPRECATION")
    private fun resolveService(serviceInfo: NsdServiceInfo) {
        val key = "${serviceInfo.serviceName}|${serviceInfo.serviceType}"
        if (!resolvingServices.add(key)) return

        runCatching {
            nsdManager.resolveService(
                serviceInfo,
                object : NsdManager.ResolveListener {
                    override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                        resolvingServices.remove(key)
                    }

                    override fun onServiceResolved(resolvedInfo: NsdServiceInfo) {
                        resolvingServices.remove(key)
                        val addresses = if (Build.VERSION.SDK_INT >= 34) {
                            resolvedInfo.hostAddresses
                        } else {
                            listOfNotNull(resolvedInfo.host)
                        }
                        val address = addresses.firstOrNull { it is Inet4Address }
                            ?: addresses.firstOrNull()
                            ?: return
                        val host = formatResolvedHost(address.hostAddress, resolvedInfo.port)
                        readStatus(host) { result ->
                            result.getOrNull()?.let { snapshot -> onLampFound?.invoke(snapshot) }
                        }
                    }
                }
            )
        }.onFailure { resolvingServices.remove(key) }
    }

    private fun parseSnapshot(jsonText: String): WifiLampSnapshot {
        val json = JSONObject(jsonText)
        val lampId = json.optString("lampId", "").trim()
        if (lampId.isBlank()) throw IOException("The lamp firmware did not return lampId")

        val cloudLampId = sequenceOf(
            json.optString("cloudLampId", ""),
            json.optString("cloudId", ""),
            json.optString("renderLampId", "")
        )
            .map { it.trim().uppercase() }
            .firstOrNull { Regex("SH-[A-Z0-9]{4,16}").matches(it) }

        return WifiLampSnapshot(
            lampId = lampId,
            cloudLampId = cloudLampId,
            lampName = json.optString("lampName", lampId),
            hostname = json.optString("hostname", ""),
            firmware = json.optString("firmware", ""),
            power = json.optBoolean("power", false),
            currentBrightness = json.optInt("currentBrightness", 0).coerceIn(0, 100),
            targetBrightness = json.optInt("targetBrightness", 0).coerceIn(0, 100),
            lastBrightness = json.optInt("lastBrightness", 70).coerceIn(1, 100),
            fadeMode = json.optInt("fadeMode", 2).coerceIn(0, 3),
            timerRemainingSeconds = json.optLong("timerRemaining", 0L).coerceAtLeast(0L),
            ssid = json.optString("ssid", ""),
            rssi = json.optInt("rssi", -127),
            ip = json.optString("ip", ""),
            activeSsid = json.optString("activeSsid", ""),
            savedNetworkCount = json.optInt("savedNetworkCount", 0).coerceIn(0, 5),
            controllerCount = json.optInt("controllerCount", 0).coerceIn(0, 8),
            bleName = json.optString("bleName", ""),
            batteryValid = json.optBoolean("batteryValid", false),
            batteryPercent = readNullableInt(json, "batteryPercent")
                ?.coerceIn(0, 100),
            batteryVoltageMv = readNullableInt(json, "batteryVoltageMv")
                ?.takeIf { it in 2_000..5_000 },
            batteryCharging = readNullableBoolean(json, "batteryCharging")
                ?: readNullableBoolean(json, "isCharging")
                ?: readNullableBoolean(json, "charging"),
            powerMode = parsePowerMode(json.optString("powerMode", "BALANCED")),
            runtimeState = parseRuntimeState(json.optString("runtimeState", "UNKNOWN"))
        )
    }


    private fun parsePowerMode(raw: String): LampPowerMode = when (
        raw.trim().uppercase().replace('-', '_').replace(' ', '_')
    ) {
        "MAX_BACKUP", "MAXIMUM_BACKUP" -> LampPowerMode.MAX_BACKUP
        "BLE_ONLY", "BLUETOOTH_ONLY" -> LampPowerMode.BLE_ONLY
        "TOUCH_ONLY" -> LampPowerMode.TOUCH_ONLY
        else -> LampPowerMode.BALANCED
    }

    private fun parseRuntimeState(raw: String): LampRuntimeState = when (
        raw.trim().uppercase().replace('-', '_').replace(' ', '_')
    ) {
        "ACTIVE" -> LampRuntimeState.ACTIVE
        "LAMP_ON_IDLE", "ON_IDLE" -> LampRuntimeState.LAMP_ON_IDLE
        "OFF_RECENT", "RECENT_OFF" -> LampRuntimeState.OFF_RECENT
        "OFF_LONG", "LONG_IDLE" -> LampRuntimeState.OFF_LONG
        "TOUCH_ONLY" -> LampRuntimeState.TOUCH_ONLY
        else -> LampRuntimeState.UNKNOWN
    }

    private fun readNullableInt(json: JSONObject, key: String): Int? {
        if (!json.has(key) || json.isNull(key)) return null
        return when (val value = json.opt(key)) {
            is Number -> value.toInt()
            is String -> value.toDoubleOrNull()?.toInt()
            else -> null
        }
    }

    private fun readNullableBoolean(json: JSONObject, key: String): Boolean? {
        if (!json.has(key) || json.isNull(key)) return null
        return when (val value = json.opt(key)) {
            is Boolean -> value
            is Number -> value.toInt() != 0
            is String -> when (value.trim().lowercase()) {
                "true", "1", "yes", "on", "charging" -> true
                "false", "0", "no", "off", "idle", "not_charging" -> false
                else -> null
            }
            else -> null
        }
    }

    private fun request(host: String, path: String): String {
        val wifiNetwork = findWifiNetwork()
            ?: throw IOException("Phone is not connected to Wi-Fi")
        val url = URL("http://${normalizeHost(host)}$path")
        val connection = wifiNetwork.openConnection(url) as HttpURLConnection

        try {
            connection.requestMethod = "GET"
            connection.connectTimeout = CONNECT_TIMEOUT_MS
            connection.readTimeout = READ_TIMEOUT_MS
            connection.useCaches = false
            connection.instanceFollowRedirects = false
            connection.setRequestProperty("Connection", "close")
            connection.setRequestProperty("Cache-Control", "no-cache")

            val code = connection.responseCode
            val stream = if (code in 200..299) connection.inputStream else connection.errorStream
            val text = stream?.bufferedReader()?.use { it.readText() }.orEmpty()
            if (code !in 200..299) {
                throw IOException(text.ifBlank { "HTTP $code" })
            }
            return text
        } finally {
            connection.disconnect()
        }
    }

    private fun findWifiNetwork(): Network? {
        val activeNetwork = connectivityManager.activeNetwork
        if (activeNetwork != null) {
            val capabilities = connectivityManager.getNetworkCapabilities(activeNetwork)
            if (capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true) {
                return activeNetwork
            }
        }

        return connectivityManager.allNetworks.firstOrNull { network ->
            connectivityManager.getNetworkCapabilities(network)
                ?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        }
    }

    private fun normalizeHost(raw: String): String = raw
        .removePrefix("http://")
        .removePrefix("https://")
        .trim()
        .trimEnd('/')

    private fun formatResolvedHost(rawAddress: String?, port: Int): String {
        val address = rawAddress.orEmpty().substringBefore('%')
        val formatted = if (address.contains(':')) "[$address]" else address
        return if (port > 0 && port != 80) "$formatted:$port" else formatted
    }

    private fun acquireMulticastLock() {
        if (multicastLock?.isHeld == true) return
        multicastLock = wifiManager.createMulticastLock("shlamp-mdns").apply {
            setReferenceCounted(false)
            runCatching { acquire() }
        }
    }

    private fun releaseMulticastLock() {
        multicastLock?.let { lock ->
            if (lock.isHeld) runCatching { lock.release() }
        }
        multicastLock = null
    }
}
