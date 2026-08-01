package com.example.shlamp

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale
import java.util.UUID

/**
 * Small local repository for lamps paired with this phone.
 *
 * A lamp can expose a temporary/local identifier over BLE while its permanent
 * cloud identifier comes from the manufacturing QR code. Explicit ID links are
 * stored only after the user confirms or completes setup, so unrelated nearby
 * lamps are never merged by guesswork.
 */
internal class LampRepository(context: Context) {
    companion object {
        private const val PREFS_NAME = "shlamp_phase1_multilamp"
        private const val KEY_LAMPS = "lamps_json"
        private const val KEY_SELECTED_LAMP_ID = "selected_lamp_id"
        private const val KEY_CONTROLLER_ID = "controller_id"
        private const val KEY_CONTROLLER_LABEL = "controller_label"
        private const val KEY_LAMP_ID_LINKS = "lamp_id_links_json"
        private const val KEY_REPORTED_IDENTITY_LINKS = "reported_lamp_id_links_json"
    }

    private val prefs: SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    val controllerId: String by lazy {
        prefs.getString(KEY_CONTROLLER_ID, null)
            ?.takeIf { it.length == 8 }
            ?: UUID.randomUUID().toString()
                .replace("-", "")
                .take(8)
                .uppercase()
                .also { value -> prefs.edit { putString(KEY_CONTROLLER_ID, value) } }
    }

    var controllerLabel: String
        get() = prefs.getString(KEY_CONTROLLER_LABEL, "This phone") ?: "This phone"
        set(value) {
            val clean = value.trim().take(24).ifBlank { "This phone" }
            prefs.edit { putString(KEY_CONTROLLER_LABEL, clean) }
        }

    var selectedLampId: String?
        get() = prefs.getString(KEY_SELECTED_LAMP_ID, null)
        set(value) = prefs.edit {
            if (value.isNullOrBlank()) remove(KEY_SELECTED_LAMP_ID)
            else putString(KEY_SELECTED_LAMP_ID, normalizeId(value))
        }

    fun loadLamps(): List<LampDevice> {
        val raw = prefs.getString(KEY_LAMPS, null) ?: return emptyList()
        return runCatching {
            val array = JSONArray(raw)
            buildList {
                for (index in 0 until array.length()) {
                    val json = array.optJSONObject(index) ?: continue
                    val lampId = normalizeId(json.optString("lampId"))
                    if (lampId.isBlank()) continue
                    add(
                        LampDevice(
                            lampId = lampId,
                            cloudLampId = json.optNullableString("cloudLampId"),
                            cloudOwnerUserId = json.optNullableString("cloudOwnerUserId"),
                            cloudVerifiedAt = json.optLong("cloudVerifiedAt", 0L),
                            name = json.optString("name", lampId),
                            room = json.optString("room", "Unassigned"),
                            bleAddress = json.optNullableString("bleAddress"),
                            bleName = json.optNullableString("bleName"),
                            hostname = json.optNullableString("hostname"),
                            ipAddress = json.optNullableString("ipAddress"),
                            isOn = json.optBoolean("isOn", false),
                            brightness = json.optInt("brightness", 0).coerceIn(0, 100),
                            lastNonZeroBrightness = json.optInt("lastNonZeroBrightness", 70)
                                .coerceIn(1, 100),
                            fadeMode = json.optInt("fadeMode", 2).coerceIn(0, 3),
                            timerRemainingSeconds = json.optLong("timerRemainingSeconds", 0L)
                                .coerceAtLeast(0L),
                            wifiSsid = json.optNullableString("wifiSsid"),
                            firmware = json.optNullableString("firmware"),
                            batteryPercent = json.optNullableInt("batteryPercent")
                                ?.coerceIn(0, 100),
                            batteryVoltageMv = json.optNullableInt("batteryVoltageMv")
                                ?.takeIf { it in 2_000..5_000 },
                            batteryCharging = json.optNullableBoolean("batteryCharging"),
                            batteryUpdatedAt = json.optLong("batteryUpdatedAt", 0L),
                            lastSeenAt = json.optLong("lastSeenAt", 0L)
                        )
                    )
                }
            }
        }.getOrDefault(emptyList())
    }

    fun saveLamps(lamps: List<LampDevice>) {
        val array = JSONArray()
        lamps.distinctBy { normalizeId(it.lampId) }.forEach { lamp ->
            array.put(
                JSONObject().apply {
                    put("lampId", normalizeId(lamp.lampId))
                    putNullable("cloudLampId", lamp.remoteLampId)
                    putNullable("cloudOwnerUserId", lamp.cloudOwnerUserId)
                    put("cloudVerifiedAt", lamp.cloudVerifiedAt)
                    put("name", lamp.name)
                    put("room", lamp.room)
                    putNullable("bleAddress", lamp.bleAddress)
                    putNullable("bleName", lamp.bleName)
                    putNullable("hostname", lamp.hostname)
                    putNullable("ipAddress", lamp.ipAddress)
                    put("isOn", lamp.isOn)
                    put("brightness", lamp.brightness.coerceIn(0, 100))
                    put("lastNonZeroBrightness", lamp.lastNonZeroBrightness)
                    put("fadeMode", lamp.fadeMode.coerceIn(0, 3))
                    put("timerRemainingSeconds", lamp.timerRemainingSeconds.coerceAtLeast(0L))
                    putNullable("wifiSsid", lamp.wifiSsid)
                    putNullable("firmware", lamp.firmware)
                    putNullable("batteryPercent", lamp.batteryPercent)
                    putNullable("batteryVoltageMv", lamp.batteryVoltageMv)
                    putNullable("batteryCharging", lamp.batteryCharging)
                    put("batteryUpdatedAt", lamp.batteryUpdatedAt)
                    put("lastSeenAt", lamp.lastSeenAt)
                }
            )
        }
        prefs.edit { putString(KEY_LAMPS, array.toString()) }
    }

    /** Returns the permanent cloud ID for a confirmed local alias, otherwise the input ID. */
    fun resolveLinkedLampId(candidateId: String): String =
        resolveLinkedLampId(candidateId, loadLampIdLinks())

    /** Snapshot of all explicit local-ID to permanent cloud-ID links. */
    fun lampIdLinks(): Map<String, String> = loadLampIdLinks()

    /**
     * Cloud identity reported by the physical lamp over BLE. This is only an
     * identity hint; it does not prove that the signed-in account owns the lamp.
     */
    fun reportedCloudIdFor(localLampId: String): String? =
        loadReportedIdentityLinks()[normalizeId(localLampId)]
            ?.let(::normalizeId)
            ?.takeIf { it.startsWith("SH-") }

    fun reportedIdentityLinks(): Map<String, String> = loadReportedIdentityLinks()

    /**
     * Saves the two identities exposed by one physical lamp without enabling
     * remote control. Ownership is promoted only after a successful claim or
     * after the cloud dashboard proves that this account can access the cloud ID.
     */
    fun recordReportedLampIds(localLampId: String, cloudLampId: String) {
        val local = normalizeId(localLampId)
        val cloud = normalizeId(cloudLampId)
        require(local.startsWith("SH-") && cloud.startsWith("SH-")) {
            "Valid local and cloud lamp IDs are required."
        }
        if (local == cloud) return
        val links = loadReportedIdentityLinks().toMutableMap()
        links[local] = cloud
        saveReportedIdentityLinks(links)
    }

    /**
     * Repairs older installations where both the local alias record and the
     * permanent cloud record were still saved after the user selected
     * “show as one lamp”. The permanent cloud ID becomes the only stored key,
     * while BLE and local-Wi-Fi details are retained on that record.
     */
    fun migrateLinkedLampRecords(): List<LampDevice> {
        val stored = loadLamps()
        val links = loadLampIdLinks()
        if (stored.isEmpty() || links.isEmpty()) return stored

        val flattenedLinks = links.mapValues { (_, cloudId) ->
            resolveLinkedLampId(cloudId, links)
        }
        if (flattenedLinks != links) saveLampIdLinks(flattenedLinks)

        val merged = stored
            .groupBy { lamp -> resolveLinkedLampId(lamp.lampId, flattenedLinks) }
            .map { (canonicalId, records) ->
                mergePersistedRecords(canonicalId, records)
            }
            .sortedBy { it.name.lowercase(Locale.US) }

        saveLamps(merged)
        selectedLampId = selectedLampId?.let { selected ->
            resolveLinkedLampId(selected, flattenedLinks)
        }
        return merged
    }

    /**
     * Permanently links a BLE/local ID to a manufacturing/cloud ID on this phone.
     * This method is called only after explicit user confirmation or successful setup.
     */
    fun linkLampIds(localLampId: String, cloudLampId: String) {
        val local = normalizeId(localLampId)
        val cloud = normalizeId(cloudLampId)
        require(local.isNotBlank() && cloud.startsWith("SH-")) {
            "A local lamp identity and valid SH Lamp cloud ID are required."
        }
        if (local == cloud) return
        val links = loadLampIdLinks().toMutableMap()
        links[local] = cloud
        // Flatten any older aliases that pointed at the local ID.
        links.entries.forEach { entry ->
            if (entry.value == local) entry.setValue(cloud)
        }
        saveLampIdLinks(links)
    }

    fun removeLampIdentity(lampId: String) {
        val normalized = normalizeId(lampId)
        val links = loadLampIdLinks().filterNot { (local, cloud) ->
            local == normalized || cloud == normalized
        }
        saveLampIdLinks(links)
        val reported = loadReportedIdentityLinks().filterNot { (local, cloud) ->
            local == normalized || cloud == normalized
        }
        saveReportedIdentityLinks(reported)
    }

    fun linkedAliasesFor(cloudLampId: String): Set<String> {
        val cloud = normalizeId(cloudLampId)
        return loadLampIdLinks()
            .filterValues { it == cloud }
            .keys
    }

    private fun loadLampIdLinks(): Map<String, String> {
        val raw = prefs.getString(KEY_LAMP_ID_LINKS, null) ?: return emptyMap()
        return runCatching {
            val json = JSONObject(raw)
            buildMap {
                json.keys().forEach { key ->
                    val local = normalizeId(key)
                    val cloud = normalizeId(json.optString(key))
                    if (local.isNotBlank() && cloud.isNotBlank()) put(local, cloud)
                }
            }
        }.getOrDefault(emptyMap())
    }

    private fun saveLampIdLinks(links: Map<String, String>) {
        val json = JSONObject()
        links.forEach { (local, cloud) -> json.put(normalizeId(local), normalizeId(cloud)) }
        prefs.edit { putString(KEY_LAMP_ID_LINKS, json.toString()) }
    }

    private fun loadReportedIdentityLinks(): Map<String, String> {
        val raw = prefs.getString(KEY_REPORTED_IDENTITY_LINKS, null) ?: return emptyMap()
        return runCatching {
            val json = JSONObject(raw)
            buildMap {
                json.keys().forEach { key ->
                    val local = normalizeId(key)
                    val cloud = normalizeId(json.optString(key))
                    if (local.startsWith("SH-") && cloud.startsWith("SH-")) put(local, cloud)
                }
            }
        }.getOrDefault(emptyMap())
    }

    private fun saveReportedIdentityLinks(links: Map<String, String>) {
        val json = JSONObject()
        links.forEach { (local, cloud) -> json.put(normalizeId(local), normalizeId(cloud)) }
        prefs.edit { putString(KEY_REPORTED_IDENTITY_LINKS, json.toString()) }
    }

    private fun resolveLinkedLampId(
        candidateId: String,
        links: Map<String, String>
    ): String {
        var current = normalizeId(candidateId)
        val visited = mutableSetOf<String>()
        while (current.isNotBlank() && visited.add(current)) {
            val next = links[current]?.let(::normalizeId) ?: break
            if (next == current) break
            current = next
        }
        return current
    }

    private fun mergePersistedRecords(
        canonicalId: String,
        records: List<LampDevice>
    ): LampDevice {
        val ordered = records.sortedByDescending { it.lastSeenAt }
        val exact = ordered.firstOrNull {
            normalizeId(it.lampId) == normalizeId(canonicalId)
        }
        val newest = ordered.first()

        fun preferredName(): String = exact?.name
            ?.takeIf { it.isNotBlank() && !it.equals(exact.lampId, ignoreCase = true) }
            ?: ordered.firstNotNullOfOrNull { lamp ->
                lamp.name.takeIf {
                    it.isNotBlank() && !it.equals(lamp.lampId, ignoreCase = true)
                }
            }
            ?: exact?.name?.takeIf(String::isNotBlank)
            ?: newest.name.ifBlank { "SH Lamp" }

        fun preferredRoom(): String = exact?.room
            ?.takeUnless { it.isBlank() || it == "Unassigned" }
            ?: ordered.firstNotNullOfOrNull { lamp ->
                lamp.room.takeUnless { it.isBlank() || it == "Unassigned" }
            }
            ?: "Unassigned"

        val normalizedCanonical = normalizeId(canonicalId)
        val linkedCloudId = ordered.firstNotNullOfOrNull { it.remoteLampId }
            ?: normalizedCanonical.takeIf { canonical ->
                loadLampIdLinks().values.any { normalizeId(it) == canonical }
            }
        val freshestState = ordered.first()

        return LampDevice(
            lampId = normalizedCanonical,
            cloudLampId = linkedCloudId,
            cloudOwnerUserId = ordered.firstNotNullOfOrNull { it.cloudOwnerUserId },
            cloudVerifiedAt = ordered.maxOfOrNull { it.cloudVerifiedAt } ?: 0L,
            name = preferredName(),
            room = preferredRoom(),
            bleAddress = ordered.firstNotNullOfOrNull { it.bleAddress },
            bleName = ordered.firstNotNullOfOrNull { it.bleName },
            hostname = ordered.firstNotNullOfOrNull { it.hostname },
            ipAddress = ordered.firstNotNullOfOrNull { it.ipAddress },
            isOn = freshestState.isOn,
            brightness = freshestState.brightness.coerceIn(0, 100),
            lastNonZeroBrightness = ordered.firstOrNull {
                it.lastNonZeroBrightness in 1..100
            }?.lastNonZeroBrightness ?: 70,
            fadeMode = freshestState.fadeMode.coerceIn(0, 3),
            timerRemainingSeconds = freshestState.timerRemainingSeconds.coerceAtLeast(0L),
            wifiSsid = ordered.firstNotNullOfOrNull { it.wifiSsid },
            firmware = ordered.firstNotNullOfOrNull { it.firmware },
            batteryPercent = ordered.firstNotNullOfOrNull { it.batteryPercent },
            batteryVoltageMv = ordered.firstNotNullOfOrNull { it.batteryVoltageMv },
            batteryCharging = ordered.firstNotNullOfOrNull { it.batteryCharging },
            batteryUpdatedAt = ordered.maxOfOrNull { it.batteryUpdatedAt } ?: 0L,
            lastSeenAt = ordered.maxOfOrNull { it.lastSeenAt } ?: 0L
        )
    }

    private fun normalizeId(value: String): String = value.trim().uppercase(Locale.US)

    private fun JSONObject.optNullableString(key: String): String? =
        optString(key, "").trim().takeIf { it.isNotBlank() && it != "null" }

    private fun JSONObject.optNullableInt(key: String): Int? {
        if (!has(key) || isNull(key)) return null
        return when (val value = opt(key)) {
            is Number -> value.toInt()
            is String -> value.toDoubleOrNull()?.toInt()
            else -> null
        }
    }

    private fun JSONObject.optNullableBoolean(key: String): Boolean? {
        if (!has(key) || isNull(key)) return null
        return when (val value = opt(key)) {
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

    private fun JSONObject.putNullable(key: String, value: String?) {
        if (value.isNullOrBlank()) put(key, JSONObject.NULL) else put(key, value)
    }

    private fun JSONObject.putNullable(key: String, value: Int?) {
        if (value == null) put(key, JSONObject.NULL) else put(key, value)
    }

    private fun JSONObject.putNullable(key: String, value: Boolean?) {
        if (value == null) put(key, JSONObject.NULL) else put(key, value)
    }
}
