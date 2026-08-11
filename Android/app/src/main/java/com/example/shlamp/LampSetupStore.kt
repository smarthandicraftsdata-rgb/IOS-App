package com.example.shlamp

import android.content.Context
import androidx.core.content.edit
import org.json.JSONObject

internal enum class LampSetupStep {
    DISCOVER,
    CONFIRM,
    CHOOSE_CONNECTION,
    ENTER_CODE,
    WIFI,
    NAME,
    READY
}

internal enum class LampSetupMode {
    WIFI,
    BLUETOOTH_ONLY,
    REMOTE_ONLY
}

internal data class LampSetupDraft(
    val step: LampSetupStep = LampSetupStep.DISCOVER,
    val lampId: String = "",
    val cloudLampId: String = "",
    val claimCode: String = "",
    val bleAddress: String = "",
    val advertisedName: String = "",
    val mode: LampSetupMode? = null,
    val wifiSsid: String = "",
    val lampName: String = "",
    val roomName: String = "",
    val updatedAt: Long = System.currentTimeMillis()
)

/** Stores only interrupted setup progress. Wi-Fi passwords are deliberately never persisted. */
internal class LampSetupStore(context: Context) {
    private val prefs = context.getSharedPreferences("shlamp_setup_progress", Context.MODE_PRIVATE)

    fun load(): LampSetupDraft? {
        val raw = prefs.getString(KEY_DRAFT, null) ?: return null
        return try {
            val json = JSONObject(raw)
            val updatedAt = json.optLong("updatedAt", 0L)
            val expired = updatedAt <= 0L || System.currentTimeMillis() - updatedAt > MAX_AGE_MS
            if (expired) {
                clear()
                null
            } else {
                LampSetupDraft(
                    step = runCatching {
                        LampSetupStep.valueOf(json.optString("step", LampSetupStep.DISCOVER.name))
                    }.getOrDefault(LampSetupStep.DISCOVER),
                    lampId = json.optString("lampId"),
                    cloudLampId = json.optString("cloudLampId"),
                    claimCode = json.optString("claimCode"),
                    bleAddress = json.optString("bleAddress"),
                    advertisedName = json.optString("advertisedName"),
                    mode = json.optString("mode").takeIf(String::isNotBlank)?.let {
                        runCatching { LampSetupMode.valueOf(it) }.getOrNull()
                    },
                    wifiSsid = json.optString("wifiSsid"),
                    lampName = json.optString("lampName"),
                    roomName = json.optString("roomName"),
                    updatedAt = updatedAt
                )
            }
        } catch (_: Exception) {
            clear()
            null
        }
    }

    fun save(draft: LampSetupDraft) {
        val json = JSONObject()
            .put("step", draft.step.name)
            .put("lampId", draft.lampId)
            .put("cloudLampId", draft.cloudLampId)
            .put("claimCode", draft.claimCode)
            .put("bleAddress", draft.bleAddress)
            .put("advertisedName", draft.advertisedName)
            .put("mode", draft.mode?.name ?: "")
            .put("wifiSsid", draft.wifiSsid)
            .put("lampName", draft.lampName)
            .put("roomName", draft.roomName)
            .put("updatedAt", System.currentTimeMillis())
        prefs.edit { putString(KEY_DRAFT, json.toString()) }
    }

    fun clear() = prefs.edit { remove(KEY_DRAFT) }

    private companion object {
        const val KEY_DRAFT = "draft"
        const val MAX_AGE_MS = 24L * 60L * 60L * 1000L
    }
}
