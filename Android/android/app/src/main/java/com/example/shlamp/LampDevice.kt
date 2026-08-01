package com.example.shlamp

import java.util.Locale

internal enum class LampConnectionRoute {
    OFFLINE,
    BLUETOOTH,
    WIFI
}

internal enum class LampAccessRole {
    OWNER,
    MEMBER
}

internal data class LampControllerAccess(
    val controllerId: String,
    val label: String,
    val role: LampAccessRole
)

internal data class NearbyLamp(
    val lampId: String,
    val advertisedName: String,
    val bleAddress: String,
    val rssi: Int
)

internal data class SavedWifiNetwork(
    val ssid: String,
    val active: Boolean
)

/**
 * One physical lamp known to this phone.
 *
 * [lampId] is the best local/canonical identity currently known. [cloudLampId]
 * is persisted separately because nearby discovery and cloud ownership are two
 * different facts. A lamp remains remote-capable when local Wi-Fi/Bluetooth
 * disappears as long as its cloud identity has been verified for the account.
 */
internal data class LampDevice(
    val lampId: String,
    val cloudLampId: String? = null,
    val cloudOwnerUserId: String? = null,
    val cloudVerifiedAt: Long = 0L,
    val name: String,
    val room: String = "Unassigned",
    val bleAddress: String? = null,
    val bleName: String? = null,
    val hostname: String? = null,
    val ipAddress: String? = null,
    val route: LampConnectionRoute = LampConnectionRoute.OFFLINE,
    val isOn: Boolean = false,
    val brightness: Int = 0,
    val lastNonZeroBrightness: Int = 70,
    val fadeMode: Int = 2,
    val timerRemainingSeconds: Long = 0L,
    val wifiSsid: String? = null,
    val wifiRssi: Int = -127,
    val bleRssi: Int = -127,
    val firmware: String? = null,
    val controllerCount: Int = 0,
    val batteryPercent: Int? = null,
    val batteryVoltageMv: Int? = null,
    val batteryCharging: Boolean? = null,
    val batteryUpdatedAt: Long = 0L,
    val lastSeenAt: Long = 0L
) {
    val isReachable: Boolean
        get() = route != LampConnectionRoute.OFFLINE

    val remoteLampId: String?
        get() = cloudLampId
            ?.trim()
            ?.uppercase(Locale.US)
            ?.takeIf { it.startsWith("SH-") }

    val isCloudLinked: Boolean
        get() = remoteLampId != null

    val displaySuffix: String
        get() = lampId.removePrefix("SH-").takeLast(6)
}

internal data class LocalLampDiagnostics(
    val lampId: String,
    val hasSavedBluetooth: Boolean,
    val bluetoothConnected: Boolean,
    val hasLocalAddress: Boolean,
    val localWifiReachable: Boolean,
    val route: LampConnectionRoute,
    val message: String
)
