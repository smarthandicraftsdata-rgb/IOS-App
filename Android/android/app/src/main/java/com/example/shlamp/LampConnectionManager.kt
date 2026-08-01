package com.example.shlamp

import android.app.Activity
import android.content.Context
import android.os.Handler
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf

/**
 * One source of truth for all lamps known to this phone.
 *
 * Wi-Fi and BLE observations are merged by permanent lampId. Only the selected
 * lamp receives commands, so selecting Lamp 2 cannot control Lamp 1.
 */
internal class LampConnectionManager(
    activity: Activity,
    private val handler: Handler
) : BleLampListener {
    private val repository = LampRepository(activity)
    private val wifiController = WifiLampController(activity, handler)
    private val bleManager = BleLampManager(activity, handler, this)
    private val accessManager = LampAccessManager(repository, bleManager)
    private val discoveryManager = LampDiscoveryManager(wifiController, ::applyWifiSnapshot)

    // A local Wi-Fi route is valid only on the same Android Network on which
    // the lamp was last discovered. This prevents a stale local IP attempt
    // from delaying remote commands after the phone changes Wi-Fi networks.
    private val wifiNetworkKeyByLampId = mutableMapOf<String, Long>()

    // Cloud ownership is remembered locally after a successful account sync or
    // an explicit alias-to-cloud link. This keeps remote control available when
    // a phone network change briefly interrupts the dashboard REST refresh.
    private val cloudOwnershipPrefs = activity.getSharedPreferences(
        "shlamp_cloud_ownership",
        Context.MODE_PRIVATE
    )
    private val knownCloudLampIds = cloudOwnershipPrefs
        .getStringSet("known_cloud_lamp_ids", emptySet())
        .orEmpty()
        .map(::normalizedLampId)
        .filter { it.startsWith("SH-") }
        .toMutableSet()

    private val migratedStoredLamps = repository.migrateLinkedLampRecords()

    private val _lamps = mutableStateOf(
        migratedStoredLamps
            .map { stored ->
                val canonicalId = normalizedLampId(repository.resolveLinkedLampId(stored.lampId))
                val linkedCloudId = stored.remoteLampId
                    ?: canonicalId.takeIf {
                        repository.linkedAliasesFor(canonicalId).isNotEmpty() ||
                            canonicalId in knownCloudLampIds
                    }
                stored.copy(
                    lampId = canonicalId,
                    cloudLampId = linkedCloudId,
                    route = LampConnectionRoute.OFFLINE
                )
            }
            .distinctBy { it.lampId.uppercase() }
    )
    val lamps: State<List<LampDevice>> = _lamps

    private val _nearbyLamps = mutableStateOf<List<NearbyLamp>>(emptyList())
    val nearbyLamps: State<List<NearbyLamp>> = _nearbyLamps

    private val initialSelected = repository.selectedLampId
        ?.takeIf { id -> _lamps.value.any { it.lampId == id } }
        ?: _lamps.value.firstOrNull()?.lampId

    private val _selectedLampId = mutableStateOf(initialSelected)
    val selectedLampId: State<String?> = _selectedLampId

    private val _status = mutableStateOf(
        if (_lamps.value.isEmpty()) "Add your first lamp" else "Looking for your lamps…"
    )
    val status: State<String> = _status

    private val _scanning = mutableStateOf(false)
    val scanning: State<Boolean> = _scanning

    private val _connecting = mutableStateOf(false)
    val connecting: State<Boolean> = _connecting

    private val _savedWifiNetworks = mutableStateOf<List<SavedWifiNetwork>>(emptyList())
    val savedWifiNetworks: State<List<SavedWifiNetwork>> = _savedWifiNetworks

    private val _controllers = mutableStateOf<List<LampControllerAccess>>(emptyList())
    val controllers: State<List<LampControllerAccess>> = _controllers

    private val _wifiSetupStatus = mutableStateOf("Wi-Fi details are stored separately in each lamp.")
    val wifiSetupStatus: State<String> = _wifiSetupStatus

    private var closed = false

    private val selectedRefresh = object : Runnable {
        override fun run() {
            if (closed) return
            refreshSelectedLamp()
            handler.postDelayed(this, 7_000L)
        }
    }

    fun start() {
        closed = false
        discoveryManager.start()
        handler.removeCallbacks(selectedRefresh)
        handler.postDelayed(selectedRefresh, 900L)
    }

    fun stop() {
        discoveryManager.stop()
        handler.removeCallbacks(selectedRefresh)
    }

    /**
     * Called when Android changes Wi-Fi, mobile data or the default network.
     * Any local Wi-Fi route discovered on the previous network is invalidated
     * immediately so the UI and command router can fall back to Bluetooth or cloud.
     */
    fun onPhoneNetworkChanged() {
        refreshNetworkContext()
        discoveryManager.stop()
        discoveryManager.start()
    }

    fun refreshNetworkContext() {
        val currentNetworkKey = wifiController.currentWifiNetworkKey()
        var changed = false
        val refreshed = _lamps.value.map { lamp ->
            if (lamp.route != LampConnectionRoute.WIFI) {
                lamp
            } else {
                val confirmedNetworkKey =
                    wifiNetworkKeyByLampId[normalizedLampId(lamp.lampId)]
                if (currentNetworkKey != null && confirmedNetworkKey == currentNetworkKey) {
                    lamp
                } else {
                    changed = true
                    wifiNetworkKeyByLampId.remove(normalizedLampId(lamp.lampId))
                    lamp.copy(
                        route = if (bleManager.isConnectedTo(lamp.bleAddress)) {
                            LampConnectionRoute.BLUETOOTH
                        } else {
                            LampConnectionRoute.OFFLINE
                        }
                    )
                }
            }
        }
        if (changed) {
            _lamps.value = refreshed.sortedBy { it.name.lowercase() }
        }
    }

    fun close() {
        closed = true
        handler.removeCallbacks(selectedRefresh)
        discoveryManager.stop()
        bleManager.close()
        wifiController.close()
    }

    fun selectedLamp(): LampDevice? =
        _selectedLampId.value?.let(::localLamp)

    /** Reloads lamps saved by Add Lamp or Lamp Settings while this activity was paused. */
    fun reloadSavedLamps() {
        val saved = repository.migrateLinkedLampRecords()
            .map { stored ->
                val canonicalId = repository.resolveLinkedLampId(stored.lampId)
                val linkedCloudId = stored.remoteLampId
                    ?: normalizedLampId(canonicalId).takeIf {
                        repository.linkedAliasesFor(it).isNotEmpty() || it in knownCloudLampIds
                    }
                stored.copy(lampId = canonicalId, cloudLampId = linkedCloudId)
            }
            .distinctBy { it.lampId.uppercase() }
        val liveById = _lamps.value.associateBy { it.lampId.uppercase() }
        _lamps.value = saved.map { stored ->
            val live = liveById[stored.lampId.uppercase()]
            if (live == null) {
                stored.copy(route = LampConnectionRoute.OFFLINE)
            } else {
                live.copy(
                    cloudLampId = stored.remoteLampId ?: live.remoteLampId,
                    cloudOwnerUserId = stored.cloudOwnerUserId ?: live.cloudOwnerUserId,
                    cloudVerifiedAt = maxOf(stored.cloudVerifiedAt, live.cloudVerifiedAt),
                    name = stored.name,
                    room = stored.room,
                    bleAddress = stored.bleAddress ?: live.bleAddress,
                    bleName = stored.bleName ?: live.bleName,
                    hostname = stored.hostname ?: live.hostname,
                    ipAddress = stored.ipAddress ?: live.ipAddress,
                    lastNonZeroBrightness = stored.lastNonZeroBrightness,
                    lastSeenAt = maxOf(stored.lastSeenAt, live.lastSeenAt)
                )
            }
        }.sortedBy { it.name.lowercase() }

        val selected = repository.selectedLampId
            ?.takeIf { id -> _lamps.value.any { it.lampId.equals(id, ignoreCase = true) } }
            ?: _lamps.value.firstOrNull()?.lampId
        _selectedLampId.value = selected
        repository.selectedLampId = selected
    }

    fun localLamp(lampId: String): LampDevice? {
        val requested = normalizedLampId(lampId)
        val canonical = repository.resolveLinkedLampId(requested)
        return _lamps.value.firstOrNull { known ->
            known.lampId.equals(requested, ignoreCase = true) ||
                repository.resolveLinkedLampId(known.lampId).equals(canonical, ignoreCase = true)
        }
    }

    /**
     * Registers the lamps owned by the signed-in account as trusted local candidates.
     * Discovery still has to prove that a matching lampId is reachable before any
     * local command is sent. Unknown nearby lamps are never added automatically.
     */
    fun reportedCloudLampIdFor(localLampId: String): String? =
        repository.reportedCloudIdFor(localLampId)

    /**
     * Records the two IDs reported by one physical lamp without granting cloud
     * ownership. Remote control is enabled only after claim success or after the
     * signed-in account dashboard contains the reported cloud ID.
     */
    fun recordReportedIdentity(localLampId: String, cloudLampId: String) {
        val local = normalizedLampId(localLampId)
        val cloud = normalizedLampId(cloudLampId)
        if (!local.startsWith("SH-") || !cloud.startsWith("SH-") || local == cloud) return
        repository.recordReportedLampIds(local, cloud)
    }

    private fun normalizedLampId(value: String): String = value.trim().uppercase()

    /**
     * Older BLE advertising uses only the final six characters of the cloud lamp ID.
     * Example: SH-182134 is the nearby alias of SH-0727182134.
     */
    private fun isShortBleAlias(aliasId: String, fullId: String): Boolean {
        val alias = normalizedLampId(aliasId)
        val full = normalizedLampId(fullId)
        if (!alias.startsWith("SH-") || !full.startsWith("SH-")) return false
        val suffix = alias.removePrefix("SH-")
        return suffix.length == 6 && full.length > alias.length &&
            full.removePrefix("SH-").endsWith(suffix)
    }

    private fun resolveKnownLampId(candidateId: String): String {
        val candidate = normalizedLampId(candidateId)
        if (!candidate.startsWith("SH-")) return candidate
        val explicitlyLinked = repository.resolveLinkedLampId(candidate)
        if (!explicitlyLinked.equals(candidate, ignoreCase = true)) return explicitlyLinked
        val matches = _lamps.value
            .map { normalizedLampId(it.lampId) }
            .filter { fullId -> isShortBleAlias(candidate, fullId) }
            .distinct()
        return if (matches.size == 1) matches.single() else candidate
    }

    private fun mergeAliasIntoFull(
        exact: LampDevice?,
        alias: LampDevice,
        fullId: String
    ): LampDevice {
        val aliasIsNearby = alias.route != LampConnectionRoute.OFFLINE
        return (exact ?: alias).copy(
            lampId = fullId,
            name = exact?.name?.takeIf { it.isNotBlank() } ?: alias.name,
            room = exact?.room?.takeUnless { it.isBlank() || it == "Unassigned" }
                ?: alias.room,
            bleAddress = alias.bleAddress ?: exact?.bleAddress,
            bleName = alias.bleName ?: exact?.bleName,
            hostname = alias.hostname ?: exact?.hostname,
            ipAddress = alias.ipAddress ?: exact?.ipAddress,
            route = if (aliasIsNearby) alias.route else exact?.route ?: alias.route,
            isOn = if (aliasIsNearby) alias.isOn else exact?.isOn ?: alias.isOn,
            brightness = if (aliasIsNearby) alias.brightness else exact?.brightness ?: alias.brightness,
            lastNonZeroBrightness = if (alias.lastNonZeroBrightness > 0) {
                alias.lastNonZeroBrightness
            } else {
                exact?.lastNonZeroBrightness ?: 70
            },
            fadeMode = if (aliasIsNearby) alias.fadeMode else exact?.fadeMode ?: alias.fadeMode,
            timerRemainingSeconds = if (aliasIsNearby) {
                alias.timerRemainingSeconds
            } else {
                exact?.timerRemainingSeconds ?: alias.timerRemainingSeconds
            },
            wifiSsid = alias.wifiSsid ?: exact?.wifiSsid,
            wifiRssi = if (alias.wifiRssi != -127) alias.wifiRssi else exact?.wifiRssi ?: -127,
            bleRssi = if (alias.bleRssi != -127) alias.bleRssi else exact?.bleRssi ?: -127,
            firmware = alias.firmware ?: exact?.firmware,
            batteryPercent = if (aliasIsNearby) {
                alias.batteryPercent ?: exact?.batteryPercent
            } else {
                exact?.batteryPercent ?: alias.batteryPercent
            },
            batteryVoltageMv = if (aliasIsNearby) {
                alias.batteryVoltageMv ?: exact?.batteryVoltageMv
            } else {
                exact?.batteryVoltageMv ?: alias.batteryVoltageMv
            },
            batteryCharging = if (aliasIsNearby) {
                alias.batteryCharging ?: exact?.batteryCharging
            } else {
                exact?.batteryCharging ?: alias.batteryCharging
            },
            batteryUpdatedAt = maxOf(alias.batteryUpdatedAt, exact?.batteryUpdatedAt ?: 0L),
            controllerCount = maxOf(alias.controllerCount, exact?.controllerCount ?: 0),
            lastSeenAt = maxOf(alias.lastSeenAt, exact?.lastSeenAt ?: 0L)
        )
    }

    private fun saveKnownCloudLampIds() {
        cloudOwnershipPrefs.edit()
            .putStringSet("known_cloud_lamp_ids", knownCloudLampIds.toSet())
            .apply()
    }

    private fun rememberCloudLampIds(lampIds: Collection<String>) {
        val before = knownCloudLampIds.size
        lampIds
            .map(::normalizedLampId)
            .filterTo(knownCloudLampIds) { it.startsWith("SH-") }
        if (knownCloudLampIds.size != before) saveKnownCloudLampIds()
    }

    /**
     * Permanent cloud identities previously confirmed for this phone.
     * Explicit ID links are included so an existing installation can recover
     * remote control even before the next successful cloud dashboard refresh.
     */
    fun confirmedCloudLampIds(): Set<String> {
        val linkedCloudIds = repository.lampIdLinks()
            .values
            .map(::normalizedLampId)
            .filter { it.startsWith("SH-") }
        val persistedCloudIds = _lamps.value.mapNotNull { it.remoteLampId }
        val canonicalLocalIds = _lamps.value.mapNotNull { lamp ->
            val canonical = normalizedLampId(repository.resolveLinkedLampId(lamp.lampId))
            canonical.takeIf {
                repository.linkedAliasesFor(canonical).isNotEmpty() ||
                    canonical in knownCloudLampIds
            }
        }
        rememberCloudLampIds(linkedCloudIds + persistedCloudIds + canonicalLocalIds)
        return knownCloudLampIds.toSet()
    }

    /**
     * Explicit local alias -> permanent cloud identity map used by the unified
     * UI. This remains available even when a temporary dashboard refresh fails.
     */
    fun confirmedCloudIdentityByLocalId(): Map<String, String> {
        val result = linkedMapOf<String, String>()
        val confirmedCloudIds = confirmedCloudLampIds()
        repository.lampIdLinks().forEach { (localId, cloudId) ->
            val local = normalizedLampId(localId)
            val cloud = normalizedLampId(repository.resolveLinkedLampId(cloudId))
            if (local.isNotBlank() && cloud.startsWith("SH-")) result[local] = cloud
        }
        _lamps.value.forEach { lamp ->
            val local = normalizedLampId(lamp.lampId)
            val cloud = lamp.remoteLampId
                ?: normalizedLampId(repository.resolveLinkedLampId(local))
            if (cloud in confirmedCloudIds) result[local] = cloud
        }
        return result
    }

    fun syncCloudLamps(cloudLamps: List<CloudLamp>, ownerUserId: String? = null) {
        if (cloudLamps.isEmpty()) return
        rememberCloudLampIds(cloudLamps.map { it.id })

        val list = _lamps.value.toMutableList()
        var changed = false
        cloudLamps.forEach { cloud ->
            val lampId = normalizedLampId(cloud.id)
            if (!lampId.startsWith("SH-")) return@forEach

            // Prefer an explicit user-confirmed link. Legacy shortened IDs remain
            // supported only as a migration fallback.
            val linkedAliasIndexes = list.indices.filter { index ->
                val localId = list[index].lampId
                !localId.equals(lampId, ignoreCase = true) &&
                    repository.resolveLinkedLampId(localId).equals(lampId, ignoreCase = true)
            }
            val reportedAliasIndexes = list.indices.filter { index ->
                val localId = list[index].lampId
                !localId.equals(lampId, ignoreCase = true) &&
                    repository.reportedCloudIdFor(localId)
                        ?.equals(lampId, ignoreCase = true) == true
            }
            val shortAliasIndexes = list.indices.filter { index ->
                isShortBleAlias(list[index].lampId, lampId)
            }
            val aliasIndexes = when {
                linkedAliasIndexes.size == 1 -> linkedAliasIndexes
                reportedAliasIndexes.size == 1 -> reportedAliasIndexes
                shortAliasIndexes.size == 1 -> shortAliasIndexes
                else -> emptyList()
            }
            if (aliasIndexes.size == 1) {
                val alias = list[aliasIndexes.single()]
                if (repository.reportedCloudIdFor(alias.lampId)
                        ?.equals(lampId, ignoreCase = true) == true
                ) {
                    // The cloud dashboard proves this signed-in account can access
                    // the firmware-reported cloud ID, so the physical identity hint
                    // can now be promoted to a confirmed local -> cloud link.
                    repository.linkLampIds(alias.lampId, lampId)
                }
                val exact = list.firstOrNull { it.lampId.equals(lampId, ignoreCase = true) }
                val merged = mergeAliasIntoFull(exact, alias, lampId)
                wifiNetworkKeyByLampId
                    .remove(normalizedLampId(alias.lampId))
                    ?.let { networkKey -> wifiNetworkKeyByLampId[lampId] = networkKey }
                list.removeAll { item ->
                    item.lampId.equals(alias.lampId, ignoreCase = true) ||
                        item.lampId.equals(lampId, ignoreCase = true)
                }
                list.add(merged)
                if (_selectedLampId.value.equals(alias.lampId, ignoreCase = true)) {
                    _selectedLampId.value = lampId
                    repository.selectedLampId = lampId
                }
                changed = true
            }

            val index = list.indexOfFirst { it.lampId.equals(lampId, ignoreCase = true) }
            val existing = list.getOrNull(index)
            val nearby = existing?.route != null && existing.route != LampConnectionRoute.OFFLINE
            val cloudBrightness = cloud.state.brightness.coerceIn(0, 100)
            val cloudBatteryPercent = cloud.state.batteryPercent
                ?.takeIf { cloud.state.batteryValid }
                ?.coerceIn(0, 100)
            val cloudBatteryVoltageMv = cloud.state.batteryVoltageMv
                ?.takeIf { cloud.state.batteryValid && it in 2_000..5_000 }
            val cloudBatteryCharging = cloud.state.batteryCharging
                ?.takeIf { cloud.state.batteryValid }
            val replacement = if (existing == null) {
                LampDevice(
                    lampId = lampId,
                    cloudLampId = lampId,
                    cloudOwnerUserId = ownerUserId,
                    cloudVerifiedAt = System.currentTimeMillis(),
                    name = cloud.name.ifBlank { "SH Lamp" },
                    isOn = cloud.state.power,
                    brightness = cloudBrightness,
                    lastNonZeroBrightness = cloudBrightness.takeIf { it > 0 } ?: 70,
                    fadeMode = cloud.state.fadeMode.coerceIn(0, 3),
                    timerRemainingSeconds = cloud.state.timerRemainingSeconds.coerceAtLeast(0L),
                    batteryPercent = cloudBatteryPercent,
                    batteryVoltageMv = cloudBatteryVoltageMv,
                    batteryCharging = cloudBatteryCharging,
                    batteryUpdatedAt = if (cloudBatteryPercent != null || cloudBatteryVoltageMv != null) {
                        System.currentTimeMillis()
                    } else {
                        0L
                    }
                )
            } else {
                existing.copy(
                    lampId = lampId,
                    cloudLampId = lampId,
                    cloudOwnerUserId = ownerUserId ?: existing.cloudOwnerUserId,
                    cloudVerifiedAt = System.currentTimeMillis(),
                    name = cloud.name.ifBlank { existing.name },
                    isOn = if (nearby) existing.isOn else cloud.state.power,
                    brightness = if (nearby) existing.brightness else cloudBrightness,
                    lastNonZeroBrightness = when {
                        nearby -> existing.lastNonZeroBrightness
                        cloudBrightness > 0 -> cloudBrightness
                        else -> existing.lastNonZeroBrightness
                    },
                    fadeMode = if (nearby) existing.fadeMode else cloud.state.fadeMode.coerceIn(0, 3),
                    timerRemainingSeconds = if (nearby) {
                        existing.timerRemainingSeconds
                    } else {
                        cloud.state.timerRemainingSeconds.coerceAtLeast(0L)
                    },
                    batteryPercent = if (nearby) {
                        existing.batteryPercent ?: cloudBatteryPercent
                    } else {
                        cloudBatteryPercent ?: existing.batteryPercent
                    },
                    batteryVoltageMv = if (nearby) {
                        existing.batteryVoltageMv ?: cloudBatteryVoltageMv
                    } else {
                        cloudBatteryVoltageMv ?: existing.batteryVoltageMv
                    },
                    batteryCharging = if (nearby) {
                        existing.batteryCharging ?: cloudBatteryCharging
                    } else {
                        cloudBatteryCharging ?: existing.batteryCharging
                    },
                    batteryUpdatedAt = if (cloudBatteryPercent != null || cloudBatteryVoltageMv != null) {
                        System.currentTimeMillis()
                    } else {
                        existing.batteryUpdatedAt
                    }
                )
            }

            if (index >= 0) {
                if (list[index] != replacement) {
                    list[index] = replacement
                    changed = true
                }
            } else {
                list.add(replacement)
                changed = true
            }
        }

        if (changed) {
            _lamps.value = list
                .distinctBy { normalizedLampId(it.lampId) }
                .sortedBy { it.name.lowercase() }
            persist()
        }

        val selectedStillExists = _selectedLampId.value?.let(::localLamp) != null
        if (!selectedStillExists) {
            val firstAvailable = _lamps.value.firstOrNull()?.lampId
            _selectedLampId.value = firstAvailable
            repository.selectedLampId = firstAvailable
        }
    }


    /**
     * Links a local BLE/Wi-Fi identity to the permanent manufacturing/cloud ID.
     * The link is saved only after explicit confirmation or successful QR setup.
     */
    fun linkLampIdentity(
        localLampId: String,
        cloudLampId: String,
        ownerUserId: String? = null
    ) {
        val localId = normalizedLampId(localLampId)
        val cloudId = normalizedLampId(cloudLampId)
        require(cloudId.startsWith("SH-")) { "A valid SH Lamp cloud ID is required." }

        if (localId != cloudId) repository.linkLampIds(localId, cloudId)
        rememberCloudLampIds(listOf(cloudId))
        wifiNetworkKeyByLampId.remove(localId)?.let { networkKey ->
            wifiNetworkKeyByLampId[cloudId] = networkKey
        }

        val alias = _lamps.value.firstOrNull {
            it.lampId.equals(localId, ignoreCase = true) ||
                it.remoteLampId.equals(cloudId, ignoreCase = true)
        }
        val exact = _lamps.value.firstOrNull {
            it.lampId.equals(cloudId, ignoreCase = true)
        }
        val base = when {
            alias != null && alias !== exact -> mergeAliasIntoFull(exact, alias, cloudId)
            exact != null -> exact.copy(lampId = cloudId)
            alias != null -> alias.copy(lampId = cloudId)
            else -> LampDevice(lampId = cloudId, name = "SH Lamp")
        }
        val merged = base.copy(
            cloudLampId = cloudId,
            cloudOwnerUserId = ownerUserId ?: base.cloudOwnerUserId,
            cloudVerifiedAt = System.currentTimeMillis()
        )

        _lamps.value = _lamps.value
            .filterNot { item ->
                item.lampId.equals(localId, ignoreCase = true) ||
                    item.lampId.equals(cloudId, ignoreCase = true) ||
                    item.remoteLampId.equals(cloudId, ignoreCase = true)
            }
            .plus(merged)
            .distinctBy { normalizedLampId(it.lampId) }
            .sortedBy { it.name.lowercase() }

        if (_selectedLampId.value.equals(localId, ignoreCase = true) ||
            _selectedLampId.value.equals(cloudId, ignoreCase = true)
        ) {
            _selectedLampId.value = cloudId
        }
        repository.selectedLampId = _selectedLampId.value ?: cloudId
        persist()
        _status.value = "${merged.name} linked to your account"
    }

    fun markCloudOwnership(lampId: String, ownerUserId: String? = null) {
        val cloudId = normalizedLampId(lampId)
        if (!cloudId.startsWith("SH-")) return
        rememberCloudLampIds(listOf(cloudId))
        val existing = localLamp(cloudId)
        val updated = (existing ?: LampDevice(lampId = cloudId, name = "SH Lamp")).copy(
            lampId = cloudId,
            cloudLampId = cloudId,
            cloudOwnerUserId = ownerUserId ?: existing?.cloudOwnerUserId,
            cloudVerifiedAt = System.currentTimeMillis()
        )
        upsertLamp(updated)
    }

    fun remoteLampIdFor(lampId: String): String? {
        val local = localLamp(lampId)
        return local?.remoteLampId
            ?: normalizedLampId(repository.resolveLinkedLampId(lampId))
                .takeIf { it in confirmedCloudLampIds() }
    }

    fun discoverKnownBluetoothLamps() {
        if (_lamps.value.isEmpty()) return
        _nearbyLamps.value = emptyList()
        _scanning.value = true
        bleManager.startScan()
    }

    fun reconnectLamp(lampId: String, makeSelected: Boolean = false) {
        val lamp = localLamp(lampId) ?: return
        if (makeSelected) {
            _selectedLampId.value = lamp.lampId
            repository.selectedLampId = lamp.lampId
        }
        val address = lamp.bleAddress ?: return
        if (!bleManager.isConnectedTo(address)) {
            _connecting.value = true
            bleManager.connect(address, lamp.bleName ?: lamp.name)
        }
    }

    fun lampsOnSelectedNetwork(): List<LampDevice> {
        val ssid = selectedLamp()?.wifiSsid?.takeIf { it.isNotBlank() } ?: return emptyList()
        return _lamps.value.filter { it.wifiSsid == ssid }
    }

    fun startNearbyScan() {
        _nearbyLamps.value = emptyList()
        _scanning.value = true
        _status.value = "Scanning for nearby SH Lamps…"
        bleManager.startScan()
    }

    fun addLamp(nearby: NearbyLamp) {
        val existing = localLamp(nearby.lampId)
            ?: _lamps.value.firstOrNull {
                it.bleAddress.equals(nearby.bleAddress, ignoreCase = true)
            }
        val lamp = if (existing == null) {
            LampDevice(
                lampId = nearby.lampId,
                name = nearby.advertisedName,
                bleAddress = nearby.bleAddress,
                bleName = nearby.advertisedName,
                bleRssi = nearby.rssi,
                route = LampConnectionRoute.OFFLINE,
                lastSeenAt = System.currentTimeMillis()
            )
        } else {
            existing.copy(
                bleAddress = nearby.bleAddress,
                bleName = nearby.advertisedName,
                bleRssi = nearby.rssi,
                lastSeenAt = System.currentTimeMillis()
            )
        }
        upsertLamp(lamp)
        selectLamp(lamp.lampId, connectBle = false)
        _connecting.value = true
        _status.value = "Connecting to ${lamp.name}…"
        bleManager.connect(nearby.bleAddress, nearby.advertisedName)
    }

    fun selectLamp(lampId: String, connectBle: Boolean = true) {
        val lamp = localLamp(lampId) ?: return
        _selectedLampId.value = lamp.lampId
        repository.selectedLampId = lamp.lampId
        _controllers.value = emptyList()
        _savedWifiNetworks.value = emptyList()
        _status.value = when (lamp.route) {
            LampConnectionRoute.WIFI -> "${lamp.name} connected locally"
            LampConnectionRoute.BLUETOOTH -> "${lamp.name} connected through Bluetooth"
            LampConnectionRoute.OFFLINE -> "Checking ${lamp.name}…"
        }
        if (connectBle && lamp.bleAddress != null && !bleManager.isConnectedTo(lamp.bleAddress)) {
            _connecting.value = true
            bleManager.connect(lamp.bleAddress, lamp.bleName ?: lamp.name)
        }
        refreshSelectedLamp()
    }

    fun reconnectSelectedBle() {
        val lamp = selectedLamp() ?: return
        val address = lamp.bleAddress ?: return
        _connecting.value = true
        bleManager.connect(address, lamp.bleName ?: lamp.name)
    }

    fun removeSelectedLamp() {
        val selected = selectedLamp() ?: return
        if (bleManager.isConnectedTo(selected.bleAddress)) bleManager.disconnect()

        val canonicalId =
            normalizedLampId(repository.resolveLinkedLampId(selected.lampId))
        val linkedAliases = repository.linkedAliasesFor(canonicalId)
            .map(::normalizedLampId)
            .toSet()
        _lamps.value = _lamps.value.filterNot { known ->
            val knownId = normalizedLampId(known.lampId)
            val knownCanonical =
                normalizedLampId(repository.resolveLinkedLampId(known.lampId))
            knownId == canonicalId ||
                knownCanonical == canonicalId ||
                knownId in linkedAliases ||
                (
                    selected.bleAddress != null &&
                        known.bleAddress.equals(selected.bleAddress, ignoreCase = true)
                    )
        }
        wifiNetworkKeyByLampId.remove(canonicalId)
        linkedAliases.forEach(wifiNetworkKeyByLampId::remove)
        if (knownCloudLampIds.remove(canonicalId)) saveKnownCloudLampIds()
        repository.removeLampIdentity(canonicalId)

        val next = _lamps.value.firstOrNull()?.lampId
        _selectedLampId.value = next
        repository.selectedLampId = next
        persist()
        _controllers.value = emptyList()
        _savedWifiNetworks.value = emptyList()
        _status.value = if (next == null) "Add your first lamp" else "Lamp removed"
    }

    fun renameSelectedLamp(name: String, room: String) {
        val lamp = selectedLamp() ?: return
        val cleanName = name.trim().take(32)
        val cleanRoom = room.trim().take(24).ifBlank { "Unassigned" }
        if (cleanName.isBlank()) {
            _status.value = "Enter a lamp name"
            return
        }
        upsertLamp(lamp.copy(name = cleanName, room = cleanRoom))

        val host = bestHost(lamp)
        if (lamp.route == LampConnectionRoute.WIFI && host != null) {
            wifiController.rename(host, cleanName) { result ->
                _status.value = if (result is WifiCommandResult.Success) {
                    "Lamp renamed"
                } else {
                    bleManager.renameLamp(cleanName)
                    "Name saved locally; syncing through Bluetooth"
                }
            }
        } else {
            bleManager.renameLamp(cleanName)
            _status.value = "Lamp name saved"
        }
    }

    fun identifySelectedLamp() {
        val lamp = selectedLamp() ?: return
        val host = bestHost(lamp)
        if (lamp.route == LampConnectionRoute.WIFI && host != null) {
            wifiController.identify(host) { result ->
                if (result is WifiCommandResult.Failed && bleManager.isConnectedTo(lamp.bleAddress)) {
                    bleManager.identify()
                }
            }
        } else {
            bleManager.identify()
        }
        _status.value = "${lamp.name} will blink three times"
    }

    /**
     * Sends through local Wi-Fi first, then an already-connected Bluetooth link.
     * The caller may fall back to internet control only when onUnavailable runs.
     */
    fun powerLamp(
        lampId: String,
        on: Boolean,
        onHandled: (LampConnectionRoute) -> Unit,
        onUnavailable: () -> Unit
    ) {
        val lamp = localLamp(lampId)
        if (lamp == null) {
            onUnavailable()
            return
        }
        upsertLamp(
            lamp.copy(
                isOn = on,
                brightness = if (on) lamp.lastNonZeroBrightness else 0
            ),
            persist = false
        )
        routeLampWifiThenBle(
            lampId = lamp.lampId,
            wifiAction = { host, callback -> wifiController.sendPower(host, on, callback) },
            bleAction = { bleManager.power(on) },
            onHandled = onHandled,
            onUnavailable = onUnavailable
        )
    }

    fun brightnessLamp(
        lampId: String,
        percent: Int,
        onHandled: (LampConnectionRoute) -> Unit,
        onUnavailable: () -> Unit
    ) {
        val lamp = localLamp(lampId)
        if (lamp == null) {
            onUnavailable()
            return
        }
        val value = percent.coerceIn(0, 100)
        upsertLamp(
            lamp.copy(
                brightness = value,
                isOn = value > 0,
                lastNonZeroBrightness = if (value > 0) value else lamp.lastNonZeroBrightness
            ),
            persist = true
        )
        routeLampWifiThenBle(
            lampId = lamp.lampId,
            wifiAction = { host, callback -> wifiController.sendBrightness(host, value, callback) },
            bleAction = { bleManager.brightness(value) },
            onHandled = onHandled,
            onUnavailable = onUnavailable
        )
    }

    fun fadeLamp(
        lampId: String,
        mode: Int,
        onHandled: (LampConnectionRoute) -> Unit,
        onUnavailable: () -> Unit
    ) {
        val lamp = localLamp(lampId)
        if (lamp == null) {
            onUnavailable()
            return
        }
        val value = mode.coerceIn(0, 3)
        upsertLamp(lamp.copy(fadeMode = value), persist = false)
        routeLampWifiThenBle(
            lampId = lamp.lampId,
            wifiAction = { host, callback -> wifiController.sendFade(host, value, callback) },
            bleAction = { bleManager.fade(value) },
            onHandled = onHandled,
            onUnavailable = onUnavailable
        )
    }

    fun timerLamp(
        lampId: String,
        minutes: Int,
        onHandled: (LampConnectionRoute) -> Unit,
        onUnavailable: () -> Unit
    ) {
        val lamp = localLamp(lampId)
        if (lamp == null) {
            onUnavailable()
            return
        }
        val value = when (minutes) {
            0, 15, 30, 60 -> minutes
            else -> 0
        }
        upsertLamp(lamp.copy(timerRemainingSeconds = value * 60L), persist = false)
        routeLampWifiThenBle(
            lampId = lamp.lampId,
            wifiAction = { host, callback -> wifiController.sendTimer(host, value, callback) },
            bleAction = { bleManager.timer(value) },
            onHandled = onHandled,
            onUnavailable = onUnavailable
        )
    }

    fun identifyLamp(
        lampId: String,
        onHandled: (LampConnectionRoute) -> Unit,
        onUnavailable: () -> Unit
    ) {
        val lamp = localLamp(lampId)
        if (lamp == null) {
            onUnavailable()
            return
        }
        routeLampWifiThenBle(
            lampId = lamp.lampId,
            wifiAction = { host, callback -> wifiController.identify(host, callback) },
            bleAction = { bleManager.identify() },
            onHandled = onHandled,
            onUnavailable = onUnavailable
        )
    }

    fun refreshLamp(
        lampId: String,
        onHandled: (LampConnectionRoute) -> Unit,
        onUnavailable: () -> Unit
    ) {
        val lamp = localLamp(lampId)
        if (lamp == null) {
            onUnavailable()
            return
        }
        val host = bestHost(lamp)
        when {
            lamp.route == LampConnectionRoute.WIFI && host != null -> {
                wifiController.readStatus(host) { result ->
                    result.onSuccess { snapshot ->
                        applyWifiSnapshot(snapshot)
                        onHandled(LampConnectionRoute.WIFI)
                    }.onFailure {
                        if (bleManager.isConnectedTo(lamp.bleAddress)) {
                            bleManager.requestStatus()
                            onHandled(LampConnectionRoute.BLUETOOTH)
                        } else {
                            onUnavailable()
                        }
                    }
                }
            }
            bleManager.isConnectedTo(lamp.bleAddress) -> {
                bleManager.requestStatus()
                onHandled(LampConnectionRoute.BLUETOOTH)
            }
            else -> onUnavailable()
        }
    }

    fun powerSelected(on: Boolean) {
        val lamp = selectedLamp() ?: return
        upsertLamp(
            lamp.copy(
                isOn = on,
                brightness = if (on) lamp.lastNonZeroBrightness else 0
            ),
            persist = false
        )
        routeWifiThenBle(
            wifiAction = { host, callback -> wifiController.sendPower(host, on, callback) },
            bleAction = { bleManager.power(on) }
        )
    }

    fun setSelectedBrightness(percent: Int, finished: Boolean) {
        val lamp = selectedLamp() ?: return
        val value = percent.coerceIn(0, 100)
        upsertLamp(
            lamp.copy(
                brightness = value,
                isOn = value > 0,
                lastNonZeroBrightness = if (value > 0) value else lamp.lastNonZeroBrightness
            ),
            persist = finished
        )
        if (!finished) return
        routeWifiThenBle(
            wifiAction = { host, callback -> wifiController.sendBrightness(host, value, callback) },
            bleAction = { bleManager.brightness(value) }
        )
    }

    fun setSelectedFade(mode: Int) {
        val lamp = selectedLamp() ?: return
        val value = mode.coerceIn(0, 3)
        upsertLamp(lamp.copy(fadeMode = value), persist = false)
        routeWifiThenBle(
            wifiAction = { host, callback -> wifiController.sendFade(host, value, callback) },
            bleAction = { bleManager.fade(value) }
        )
    }

    fun setSelectedTimer(minutes: Int) {
        val lamp = selectedLamp() ?: return
        val value = when (minutes) {
            0, 15, 30, 60 -> minutes
            else -> 0
        }
        upsertLamp(
            lamp.copy(timerRemainingSeconds = value * 60L),
            persist = false
        )
        routeWifiThenBle(
            wifiAction = { host, callback -> wifiController.sendTimer(host, value, callback) },
            bleAction = { bleManager.timer(value) }
        )
    }

    fun provisionSelectedWifi(ssid: String, password: String) {
        val lamp = selectedLamp() ?: return
        if (!bleManager.isConnectedTo(lamp.bleAddress)) {
            _wifiSetupStatus.value = "Connect to this lamp through Bluetooth before changing Wi-Fi."
            reconnectSelectedBle()
            return
        }
        _wifiSetupStatus.value = "Sending Wi-Fi details to ${lamp.name}…"
        bleManager.provisionWifi(ssid, password)
    }

    fun retrySelectedWifi() {
        bleManager.retryWifi()
        _wifiSetupStatus.value = "The selected lamp is retrying its saved Wi-Fi networks."
    }

    fun refreshSavedWifiNetworks() = bleManager.requestSavedWifiNetworks()

    fun selectSavedWifi(ssid: String) {
        bleManager.selectSavedWifi(ssid)
        _wifiSetupStatus.value = "Switching the selected lamp to $ssid…"
    }

    fun deleteSavedWifi(ssid: String) {
        bleManager.deleteSavedWifi(ssid)
        _wifiSetupStatus.value = "Removing $ssid from the selected lamp…"
    }

    fun refreshControllers() {
        val lamp = selectedLamp() ?: return
        if (bleManager.isConnectedTo(lamp.bleAddress)) {
            accessManager.refresh()
        } else {
            bestHost(lamp)?.let { host ->
                wifiController.readControllers(host) { result ->
                    result.getOrNull()?.let { _controllers.value = it }
                }
            }
        }
    }

    fun removeController(controllerId: String) {
        accessManager.remove(controllerId)
        _status.value = "Controller removed from the selected lamp"
    }

    fun removeLamp(lampId: String) {
        selectLamp(lampId, connectBle = false)
        removeSelectedLamp()
    }

    fun diagnoseLamp(lampId: String, callback: (LocalLampDiagnostics) -> Unit) {
        val lamp = localLamp(lampId)
        if (lamp == null) {
            callback(
                LocalLampDiagnostics(
                    lampId = lampId,
                    hasSavedBluetooth = false,
                    bluetoothConnected = false,
                    hasLocalAddress = false,
                    localWifiReachable = false,
                    route = LampConnectionRoute.OFFLINE,
                    message = "This phone has not connected to the lamp nearby yet."
                )
            )
            return
        }

        val bluetoothConnected = bleManager.isConnectedTo(lamp.bleAddress)
        val host = bestHost(lamp)
        if (host == null) {
            callback(
                LocalLampDiagnostics(
                    lampId = lamp.lampId,
                    hasSavedBluetooth = !lamp.bleAddress.isNullOrBlank(),
                    bluetoothConnected = bluetoothConnected,
                    hasLocalAddress = false,
                    localWifiReachable = false,
                    route = lamp.route,
                    message = if (bluetoothConnected) {
                        "Bluetooth is connected. Local Wi-Fi has not been discovered."
                    } else {
                        "The lamp is not currently reachable nearby."
                    }
                )
            )
            return
        }

        wifiController.readStatus(host) { result ->
            val reachable = result.isSuccess
            result.getOrNull()?.let(::applyWifiSnapshot)
            callback(
                LocalLampDiagnostics(
                    lampId = lamp.lampId,
                    hasSavedBluetooth = !lamp.bleAddress.isNullOrBlank(),
                    bluetoothConnected = bluetoothConnected,
                    hasLocalAddress = true,
                    localWifiReachable = reachable,
                    route = if (reachable) LampConnectionRoute.WIFI else lamp.route,
                    message = when {
                        reachable -> "The lamp responded on the local Wi-Fi network."
                        bluetoothConnected -> "Local Wi-Fi did not respond, but Bluetooth is connected."
                        else -> "The lamp did not respond through local Wi-Fi or Bluetooth."
                    }
                )
            )
        }
    }

    fun thisControllerId(): String = accessManager.thisControllerId

    fun thisControllerLabel(): String = accessManager.thisControllerLabel

    fun renameThisController(label: String) {
        accessManager.renameThisPhone(label)
        _status.value = "Controller name updated"
    }

    private fun refreshSelectedLamp() {
        val lamp = selectedLamp() ?: return
        val host = bestHost(lamp) ?: return
        val currentNetworkKey = wifiController.currentWifiNetworkKey()
        val confirmedNetworkKey = wifiNetworkKeyByLampId[normalizedLampId(lamp.lampId)]
        if (lamp.route != LampConnectionRoute.WIFI ||
            currentNetworkKey == null ||
            confirmedNetworkKey != currentNetworkKey
        ) {
            if (lamp.route == LampConnectionRoute.WIFI) {
                upsertLamp(lamp.copy(route = LampConnectionRoute.OFFLINE), persist = false)
            }
            return
        }
        wifiController.readStatus(host) { result ->
            result.onSuccess(::applyWifiSnapshot)
            result.onFailure {
                wifiNetworkKeyByLampId.remove(normalizedLampId(lamp.lampId))
                upsertLamp(lamp.copy(route = LampConnectionRoute.OFFLINE), persist = false)
            }
        }
    }

    private fun routeLampWifiThenBle(
        lampId: String,
        wifiAction: (String, (WifiCommandResult) -> Unit) -> Unit,
        bleAction: () -> Unit,
        onHandled: (LampConnectionRoute) -> Unit,
        onUnavailable: () -> Unit
    ) {
        val lamp = localLamp(lampId)
        if (lamp == null) {
            onUnavailable()
            return
        }

        val host = bestHost(lamp)
        val currentNetworkKey = wifiController.currentWifiNetworkKey()
        val confirmedNetworkKey = wifiNetworkKeyByLampId[normalizedLampId(lamp.lampId)]
        val canTryConfirmedLocalWifi =
            lamp.route == LampConnectionRoute.WIFI &&
                host != null &&
                currentNetworkKey != null &&
                confirmedNetworkKey == currentNetworkKey

        if (canTryConfirmedLocalWifi) {
            wifiAction(host!!) { result ->
                when (result) {
                    is WifiCommandResult.Success -> {
                        result.snapshot?.let(::applyWifiSnapshot)
                        _status.value = "${lamp.name} controlled nearby"
                        onHandled(LampConnectionRoute.WIFI)
                    }
                    is WifiCommandResult.Failed -> {
                        // Invalidate the stale Wi-Fi route immediately. The first
                        // failed attempt may time out, but later commands will not.
                        wifiNetworkKeyByLampId.remove(normalizedLampId(lamp.lampId))
                        if (bleManager.isConnectedTo(lamp.bleAddress)) {
                            bleAction()
                            _status.value = "${lamp.name} controlled nearby"
                            upsertLamp(
                                lamp.copy(route = LampConnectionRoute.BLUETOOTH),
                                persist = false
                            )
                            onHandled(LampConnectionRoute.BLUETOOTH)
                        } else {
                            upsertLamp(lamp.copy(route = LampConnectionRoute.OFFLINE), persist = false)
                            _status.value = result.message
                            onUnavailable()
                        }
                    }
                }
            }
        } else if (bleManager.isConnectedTo(lamp.bleAddress)) {
            bleAction()
            _status.value = "${lamp.name} controlled nearby"
            onHandled(LampConnectionRoute.BLUETOOTH)
        } else {
            // The phone is no longer on the Wi-Fi network where this lamp was
            // discovered. Go directly to cloud control instead of waiting for
            // the saved local IP to time out.
            if (lamp.route == LampConnectionRoute.WIFI) {
                upsertLamp(lamp.copy(route = LampConnectionRoute.OFFLINE), persist = false)
            }
            if (lamp.bleAddress != null) reconnectLamp(lamp.lampId)
            onUnavailable()
        }
    }

    private fun routeWifiThenBle(
        wifiAction: (String, (WifiCommandResult) -> Unit) -> Unit,
        bleAction: () -> Unit
    ) {
        val lamp = selectedLamp() ?: return
        val host = bestHost(lamp)
        val currentNetworkKey = wifiController.currentWifiNetworkKey()
        val confirmedNetworkKey = wifiNetworkKeyByLampId[normalizedLampId(lamp.lampId)]
        val canTryConfirmedLocalWifi =
            lamp.route == LampConnectionRoute.WIFI &&
                host != null &&
                currentNetworkKey != null &&
                confirmedNetworkKey == currentNetworkKey

        if (canTryConfirmedLocalWifi) {
            wifiAction(host!!) { result ->
                when (result) {
                    is WifiCommandResult.Success -> {
                        result.snapshot?.let(::applyWifiSnapshot)
                        _status.value = "${lamp.name} controlled locally"
                    }
                    is WifiCommandResult.Failed -> {
                        wifiNetworkKeyByLampId.remove(normalizedLampId(lamp.lampId))
                        if (bleManager.isConnectedTo(lamp.bleAddress)) {
                            bleAction()
                            _status.value = "Local Wi-Fi delayed; command sent through Bluetooth"
                            upsertLamp(lamp.copy(route = LampConnectionRoute.BLUETOOTH), persist = false)
                        } else {
                            upsertLamp(lamp.copy(route = LampConnectionRoute.OFFLINE), persist = false)
                            _status.value = result.message
                        }
                    }
                }
            }
        } else if (bleManager.isConnectedTo(lamp.bleAddress)) {
            bleAction()
            _status.value = "${lamp.name} controlled through Bluetooth"
        } else {
            if (lamp.route == LampConnectionRoute.WIFI) {
                upsertLamp(lamp.copy(route = LampConnectionRoute.OFFLINE), persist = false)
            }
            _status.value = "${lamp.name} is not nearby"
            reconnectSelectedBle()
        }
    }

    private fun applyWifiSnapshot(snapshot: WifiLampSnapshot) {
        snapshot.cloudLampId
            ?.takeIf { !it.equals(snapshot.lampId, ignoreCase = true) }
            ?.let { cloudId -> recordReportedIdentity(snapshot.lampId, cloudId) }
        val resolvedLampId = resolveKnownLampId(snapshot.lampId)
        wifiController.currentWifiNetworkKey()?.let { networkKey ->
            wifiNetworkKeyByLampId[normalizedLampId(resolvedLampId)] = networkKey
        }
        val existing = _lamps.value.firstOrNull {
            it.lampId.equals(resolvedLampId, ignoreCase = true) ||
                it.lampId.equals(snapshot.lampId, ignoreCase = true)
        }
        if (existing == null) return // Discovery does not auto-add an unowned lamp.

        val updated = existing.copy(
            lampId = resolvedLampId,
            name = snapshot.lampName.ifBlank { existing.name },
            hostname = snapshot.hostname.takeIf { it.isNotBlank() } ?: existing.hostname,
            ipAddress = snapshot.ip.takeIf { it.isNotBlank() } ?: existing.ipAddress,
            route = LampConnectionRoute.WIFI,
            isOn = snapshot.power,
            brightness = snapshot.targetBrightness,
            lastNonZeroBrightness = snapshot.lastBrightness,
            fadeMode = snapshot.fadeMode,
            timerRemainingSeconds = snapshot.timerRemainingSeconds,
            wifiSsid = snapshot.ssid.takeIf { it.isNotBlank() }
                ?: snapshot.activeSsid.takeIf { it.isNotBlank() }
                ?: existing.wifiSsid,
            wifiRssi = snapshot.rssi,
            firmware = snapshot.firmware,
            batteryPercent = snapshot.batteryPercent.takeIf { snapshot.batteryValid },
            batteryVoltageMv = snapshot.batteryVoltageMv.takeIf { snapshot.batteryValid },
            batteryCharging = snapshot.batteryCharging.takeIf { snapshot.batteryValid },
            batteryUpdatedAt = if (snapshot.batteryValid) System.currentTimeMillis() else 0L,
            controllerCount = snapshot.controllerCount,
            bleName = snapshot.bleName.takeIf { it.isNotBlank() } ?: existing.bleName,
            lastSeenAt = System.currentTimeMillis()
        )
        upsertLamp(updated)
        if (_selectedLampId.value.equals(resolvedLampId, ignoreCase = true)) {
            _status.value = "${updated.name} connected locally"
        }
    }

    override fun onScanUpdated(lamps: List<NearbyLamp>) {
        _nearbyLamps.value = lamps

        lamps.forEach { nearby ->
            val resolvedNearbyId = resolveKnownLampId(nearby.lampId)
            val existing = _lamps.value.firstOrNull { known ->
                known.lampId.equals(resolvedNearbyId, ignoreCase = true) ||
                    known.lampId.equals(nearby.lampId, ignoreCase = true) ||
                    known.bleAddress == nearby.bleAddress
            } ?: return@forEach

            val verifiedLampId = resolvedNearbyId.takeUnless { it.startsWith("BLE-") }
                ?: existing.lampId
            val updated = existing.copy(
                lampId = verifiedLampId,
                bleAddress = nearby.bleAddress,
                bleName = nearby.advertisedName,
                bleRssi = nearby.rssi,
                lastSeenAt = System.currentTimeMillis()
            )
            upsertLamp(updated)

            if (_selectedLampId.value.equals(updated.lampId, ignoreCase = true) &&
                !bleManager.isConnectedTo(updated.bleAddress) &&
                !_connecting.value
            ) {
                _connecting.value = true
                bleManager.connect(nearby.bleAddress, updated.bleName ?: updated.name)
            }
        }
    }

    override fun onScanFinished() {
        _scanning.value = false
        _status.value = if (_nearbyLamps.value.isEmpty()) {
            "No nearby SH Lamps found"
        } else {
            "${_nearbyLamps.value.size} nearby lamp${if (_nearbyLamps.value.size == 1) "" else "s"} found"
        }
    }

    override fun onBleIdentity(identity: BleLampIdentity) {
        val localId = normalizedLampId(identity.localLampId)
        val cloudId = identity.cloudLampId?.let(::normalizedLampId)
        if (cloudId != null && cloudId.startsWith("SH-") && cloudId != localId) {
            recordReportedIdentity(localId, cloudId)
            _status.value = "Lamp identity verified"
        }
    }

    override fun onBleReady(lampId: String, address: String, advertisedName: String) {
        _connecting.value = false
        val resolvedLampId = resolveKnownLampId(lampId)
        val old = _lamps.value.firstOrNull {
            it.lampId.equals(resolvedLampId, ignoreCase = true) ||
                it.lampId.equals(lampId, ignoreCase = true) ||
                it.bleAddress == address
        }
        val merged = (old ?: LampDevice(lampId = resolvedLampId, name = advertisedName)).copy(
            lampId = resolvedLampId,
            bleAddress = address,
            bleName = advertisedName,
            route = if (old?.route == LampConnectionRoute.WIFI) {
                LampConnectionRoute.WIFI
            } else {
                LampConnectionRoute.BLUETOOTH
            },
            lastSeenAt = System.currentTimeMillis()
        )

        val connectedLampWasSelected = _selectedLampId.value?.let { selectedId ->
            selectedId.equals(resolvedLampId, ignoreCase = true) ||
                old?.lampId?.let { selectedId.equals(it, ignoreCase = true) } == true
        } == true

        if (old != null && !old.lampId.equals(resolvedLampId, ignoreCase = true)) {
            _lamps.value = _lamps.value.filterNot { it.lampId.equals(old.lampId, ignoreCase = true) }
        }
        upsertLamp(merged)
        if (_selectedLampId.value == null || connectedLampWasSelected) {
            _selectedLampId.value = resolvedLampId
            repository.selectedLampId = resolvedLampId
        }
        _status.value = "${merged.name} connected through Bluetooth"
        accessManager.registerThisPhone()
        handler.postDelayed({
            accessManager.refresh()
            bleManager.requestSavedWifiNetworks()
        }, 300L)
    }

    override fun onBleDisconnected(address: String?) {
        _connecting.value = false
        val existing = _lamps.value.firstOrNull { it.bleAddress == address } ?: return
        if (existing.route != LampConnectionRoute.WIFI) {
            upsertLamp(existing.copy(route = LampConnectionRoute.OFFLINE), persist = false)
        }
        if (_selectedLampId.value == existing.lampId) {
            _status.value = if (existing.route == LampConnectionRoute.WIFI) {
                "${existing.name} remains connected locally"
            } else {
                "${existing.name} Bluetooth disconnected"
            }
        }
    }

    override fun onBleLampStatus(status: BleLampStatus) {
        val resolvedLampId = resolveKnownLampId(status.lampId)
        val existing = _lamps.value.firstOrNull {
            it.lampId.equals(resolvedLampId, ignoreCase = true) ||
                it.lampId.equals(status.lampId, ignoreCase = true)
        }
            ?: selectedLamp()
            ?: return
        val updated = existing.copy(
            lampId = resolvedLampId,
            route = if (existing.route == LampConnectionRoute.WIFI) {
                LampConnectionRoute.WIFI
            } else {
                LampConnectionRoute.BLUETOOTH
            },
            isOn = status.power,
            brightness = status.targetBrightness,
            lastNonZeroBrightness = if (status.targetBrightness > 0) {
                status.targetBrightness
            } else {
                existing.lastNonZeroBrightness
            },
            fadeMode = status.fadeMode,
            timerRemainingSeconds = status.timerRemainingSeconds,
            bleRssi = status.rssi,
            lastSeenAt = System.currentTimeMillis()
        )
        upsertLamp(updated, persist = false)
    }

    override fun onBleBatteryLevel(lampId: String, percent: Int) {
        val resolvedLampId = resolveKnownLampId(lampId)
        val existing = _lamps.value.firstOrNull {
            it.lampId.equals(resolvedLampId, ignoreCase = true) ||
                it.lampId.equals(lampId, ignoreCase = true)
        } ?: selectedLamp() ?: return
        upsertLamp(
            existing.copy(
                lampId = resolvedLampId,
                batteryPercent = percent.coerceIn(0, 100),
                batteryUpdatedAt = System.currentTimeMillis(),
                lastSeenAt = System.currentTimeMillis()
            ),
            persist = false
        )
    }

    override fun onBleWifiStatus(message: String) {
        _wifiSetupStatus.value = when {
            message.startsWith("W:IP:") -> "Connected to Wi-Fi • ${message.removePrefix("W:IP:")}"
            message == "W:SAVED" -> "Wi-Fi saved. The lamp is connecting automatically."
            message == "W:NAME_SAVED" -> "Lamp name saved."
            message == "W:CTRL_SAVED" -> "This phone is registered with the lamp."
            message == "W:CTRL_REMOVED" -> "Controller removed."
            message == "W:NEED_SETUP" -> "This lamp has no saved Wi-Fi network."
            message == "W:CONNECTING" -> "Connecting to Wi-Fi…"
            message.startsWith("W:RETRY:") -> "Wi-Fi retry in ${message.substringAfterLast(':')} seconds."
            message.startsWith("W:FAIL:") -> "Wi-Fi connection delayed. Bluetooth remains available."
            message.startsWith("W:ERR:") -> "Lamp setup error: ${message.removePrefix("W:ERR:")}"
            else -> message
        }

        if (message.startsWith("W:IP:")) {
            val lamp = selectedLamp() ?: return
            val ip = message.removePrefix("W:IP:").trim()
            if (ip.isNotBlank() && ip != "0.0.0.0") {
                upsertLamp(lamp.copy(ipAddress = ip), persist = true)
                wifiController.readStatus(ip) { result -> result.onSuccess(::applyWifiSnapshot) }
            }
        }
    }

    override fun onSavedWifiNetworks(networks: List<SavedWifiNetwork>) {
        _savedWifiNetworks.value = networks
    }

    override fun onLampControllers(controllers: List<LampControllerAccess>) {
        _controllers.value = controllers
        val lamp = selectedLamp() ?: return
        upsertLamp(lamp.copy(controllerCount = controllers.size), persist = false)
    }

    override fun onBleError(message: String) {
        _connecting.value = false
        _scanning.value = false
        _status.value = message
    }

    private fun bestHost(lamp: LampDevice): String? =
        lamp.ipAddress?.takeIf { it.isNotBlank() && it != "0.0.0.0" }
            ?: lamp.hostname?.takeIf { it.isNotBlank() }

    private fun upsertLamp(lamp: LampDevice, persist: Boolean = true) {
        val sourceId = normalizedLampId(lamp.lampId)
        val canonicalId = normalizedLampId(repository.resolveLinkedLampId(sourceId))
        if (sourceId != canonicalId) {
            wifiNetworkKeyByLampId.remove(sourceId)?.let { networkKey ->
                wifiNetworkKeyByLampId[canonicalId] = networkKey
            }
        }
        val linkedAliases = repository.linkedAliasesFor(canonicalId)
            .map(::normalizedLampId)
            .toSet()
        val list = _lamps.value.toMutableList()

        fun isSamePhysicalLamp(known: LampDevice): Boolean {
            val knownId = normalizedLampId(known.lampId)
            val knownCanonical = normalizedLampId(repository.resolveLinkedLampId(known.lampId))
            return knownId == canonicalId ||
                knownCanonical == canonicalId ||
                knownId in linkedAliases ||
                (
                    lamp.bleAddress != null &&
                        known.bleAddress.equals(lamp.bleAddress, ignoreCase = true)
                    )
        }

        val replacedRecords = list.filter(::isSamePhysicalLamp)
        // Nearby status packets do not contain account ownership. Never let a
        // BLE/Wi-Fi refresh erase the already-verified permanent cloud route.
        val preservedCloudId = lamp.remoteLampId
            ?: replacedRecords.firstNotNullOfOrNull { it.remoteLampId }
            ?: canonicalId.takeIf { it in knownCloudLampIds }
        val preservedOwner = lamp.cloudOwnerUserId
            ?: replacedRecords.firstNotNullOfOrNull { it.cloudOwnerUserId }
        val preservedVerifiedAt = maxOf(
            lamp.cloudVerifiedAt,
            replacedRecords.maxOfOrNull { it.cloudVerifiedAt } ?: 0L
        )
        val normalizedLamp = lamp.copy(
            lampId = canonicalId,
            cloudLampId = preservedCloudId,
            cloudOwnerUserId = preservedOwner,
            cloudVerifiedAt = preservedVerifiedAt
        )
        val removedIds = replacedRecords
            .map { normalizedLampId(it.lampId) }
            .toSet()

        list.removeAll(::isSamePhysicalLamp)
        list.add(normalizedLamp)

        _lamps.value = list
            .distinctBy { normalizedLampId(it.lampId) }
            .sortedBy { it.name.lowercase() }

        val selected = _selectedLampId.value
        if (selected != null && normalizedLampId(selected) in removedIds) {
            _selectedLampId.value = canonicalId
            repository.selectedLampId = canonicalId
        }
        if (persist) persist()
    }

    private fun persist() {
        repository.saveLamps(_lamps.value)
    }
}
