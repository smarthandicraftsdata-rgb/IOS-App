@file:Suppress("SpellCheckingInspection")

package com.example.shlamp

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.time.Instant
import java.util.Locale
import java.util.UUID
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal const val CLOUD_BASE_URL = "https://sh-lamp-cloud-render.onrender.com"

internal data class CloudUser(
    val id: String,
    val name: String,
    val email: String
)

internal data class CloudSession(
    val accessToken: String,
    val refreshToken: String
)

internal data class AuthResult(
    val user: CloudUser,
    val session: CloudSession
)

internal data class PasswordResetRequestResult(
    val message: String,
    val debugResetToken: String?
)

internal data class CloudRoom(
    val id: String,
    val homeId: String,
    val name: String
)

internal data class CloudHome(
    val id: String,
    val name: String,
    val rooms: List<CloudRoom> = emptyList()
)

internal data class CloudLampState(
    val power: Boolean,
    val brightness: Int,
    val fadeMode: Int,
    val timerRemainingSeconds: Long,
    val batteryValid: Boolean = false,
    val batteryPercent: Int? = null,
    val batteryVoltageMv: Int? = null,
    val batteryCharging: Boolean? = null,
    val powerMode: LampPowerMode? = null,
    val runtimeState: LampRuntimeState? = null
)

internal data class CloudLamp(
    val id: String,
    val homeId: String,
    val roomId: String?,
    val roomName: String? = null,
    val name: String,
    val model: String,
    val online: Boolean,
    val lastSeen: String?,
    val state: CloudLampState
)

internal data class CloudDashboard(
    val homes: List<CloudHome>,
    val lamps: List<CloudLamp>
)

internal data class CloudCommandReceipt(
    val commandId: String,
    val accepted: Boolean,
    val status: String,
    val message: String
)

internal data class ReleasedCloudLamp(
    val lampId: String,
    val newClaimCode: String
)

internal data class CloudRealtimeUpdate(
    val eventType: String,
    val authenticated: Boolean = false,
    val userId: String? = null,
    val lamps: List<CloudLamp> = emptyList(),
    val lamp: CloudLamp? = null,
    val lampId: String? = null,
    val online: Boolean? = null,
    val errorMessage: String? = null
)

internal sealed interface SessionCheck {
    data class SignedIn(val user: CloudUser) : SessionCheck
    data object SignedOut : SessionCheck
    data class Failed(val message: String) : SessionCheck
}

internal class CloudTokenVault(context: Context) {
    private val preferences = context.getSharedPreferences(
        "shlamp_cloud_session",
        Context.MODE_PRIVATE
    )

    fun saveSession(session: CloudSession) {
        preferences.edit()
            .putString("access", encrypt(session.accessToken))
            .putString("refresh", encrypt(session.refreshToken))
            .apply()
    }

    fun readSession(): CloudSession? {
        val encryptedAccess = preferences.getString("access", null) ?: return null
        val encryptedRefresh = preferences.getString("refresh", null) ?: return null
        return try {
            CloudSession(decrypt(encryptedAccess), decrypt(encryptedRefresh))
        } catch (_: Exception) {
            clear()
            null
        }
    }

    fun clear() {
        preferences.edit().clear().apply()
    }

    private fun encrypt(value: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        val encrypted = cipher.doFinal(value.toByteArray(StandardCharsets.UTF_8))
        return Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" +
            Base64.encodeToString(encrypted, Base64.NO_WRAP)
    }

    private fun decrypt(value: String): String {
        val parts = value.split(':', limit = 2)
        require(parts.size == 2) { "Invalid encrypted value" }
        val iv = Base64.decode(parts[0], Base64.NO_WRAP)
        val encrypted = Base64.decode(parts[1], Base64.NO_WRAP)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), GCMParameterSpec(128, iv))
        return String(cipher.doFinal(encrypted), StandardCharsets.UTF_8)
    }

    private fun getOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = keyStore.getKey(KEY_ALIAS, null) as? SecretKey
        if (existing != null) return existing

        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            "AndroidKeyStore"
        )
        val spec = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build()
        generator.init(spec)
        return generator.generateKey()
    }

    companion object {
        private const val KEY_ALIAS = "shlamp_cloud_tokens_v1"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
    }
}

internal class CloudApiClient(private val baseUrl: String = CLOUD_BASE_URL) {
    data class MeResult(
        val user: CloudUser?,
        val unauthorized: Boolean,
        val message: String
    )

    private data class HttpResult(
        val code: Int,
        val body: String,
        val path: String
    )

    fun signIn(email: String, password: String): AuthResult {
        val body = JSONObject()
            .put("email", email)
            .put("password", password)
        val response = request("POST", "/api/auth/login", body)
        return parseAuth(response.body)
    }

    fun register(name: String, email: String, password: String): AuthResult {
        val body = JSONObject()
            .put("displayName", name)
            .put("name", name)
            .put("fullName", name)
            .put("email", email)
            .put("password", password)
        val response = request("POST", "/api/auth/register", body)
        return parseAuth(response.body)
    }

    fun requestPasswordReset(email: String): PasswordResetRequestResult {
        val body = JSONObject().put("email", email)
        val response = request(
            method = "POST",
            path = "/api/auth/password-reset/request",
            jsonBody = body
        )
        val root = JSONObject(response.body)
        return PasswordResetRequestResult(
            message = firstNonBlank(
                root.optString("message"),
                "If an account exists for this email, a reset code has been sent."
            ),
            debugResetToken = root.optString("debugResetToken")
                .trim()
                .takeIf(String::isNotBlank)
        )
    }

    fun confirmPasswordReset(token: String, newPassword: String): String {
        val body = JSONObject()
            .put("token", token)
            .put("newPassword", newPassword)
        val response = request(
            method = "POST",
            path = "/api/auth/password-reset/confirm",
            jsonBody = body
        )
        val root = JSONObject(response.body)
        return firstNonBlank(
            root.optString("message"),
            "Password reset completed. Sign in with your new password."
        )
    }

    fun refresh(refreshToken: String): CloudSession? {
        return try {
            val body = JSONObject().put("refreshToken", refreshToken)
            val response = request("POST", "/api/auth/refresh", body)
            parseSession(JSONObject(response.body))
        } catch (_: Exception) {
            null
        }
    }

    fun readMe(accessToken: String): MeResult {
        return try {
            val response = request(
                method = "GET",
                path = "/api/me",
                bearerToken = accessToken,
                acceptErrors = true
            )
            when {
                response.code == 401 || response.code == 403 -> {
                    MeResult(null, unauthorized = true, message = extractError(response.body))
                }
                response.code !in 200..299 -> {
                    MeResult(null, unauthorized = false, message = extractError(response.body))
                }
                else -> {
                    val root = JSONObject(response.body)
                    val userObject = root.optJSONObject("user")
                        ?: root.optJSONObject("data")?.optJSONObject("user")
                        ?: root
                    MeResult(parseUser(userObject), unauthorized = false, message = "")
                }
            }
        } catch (error: Exception) {
            MeResult(null, unauthorized = false, message = error.message ?: "Network error")
        }
    }

    fun loadDashboard(accessToken: String): CloudDashboard {
        var homes = emptyList<CloudHome>()
        var lamps = emptyList<CloudLamp>()
        val errors = mutableListOf<String>()

        fun fetchFirst(paths: List<String>): CloudDashboard? {
            for (path in paths) {
                val response = request(
                    method = "GET",
                    path = path,
                    bearerToken = accessToken,
                    acceptErrors = true
                )
                if (response.code == 401 || response.code == 403) throw UnauthorizedException()
                if (response.code in 200..299) return parseDashboardPayload(response.body)
                if (response.code != 404) errors += "$path: ${extractError(response.body)}"
            }
            return null
        }

        // These are the production backend routes. Older candidates remain only
        // as compatibility fallbacks and are never tried before the real route.
        fetchFirst(listOf("/api/homes", "/api/me/homes", "/api/home"))?.let { parsed ->
            homes = mergeHomes(homes, parsed.homes)
            lamps = mergeLamps(lamps, parsed.lamps)
        }
        fetchFirst(listOf("/api/devices", "/api/lamps", "/api/me/devices", "/api/me/lamps"))?.let { parsed ->
            homes = mergeHomes(homes, parsed.homes)
            lamps = mergeLamps(lamps, parsed.lamps)
        }

        if (homes.isEmpty() && lamps.isNotEmpty()) {
            val inferredHomeId = lamps.firstNotNullOfOrNull { it.homeId.takeIf(String::isNotBlank) }
                ?: "default"
            homes = listOf(CloudHome(inferredHomeId, "My Home"))
        }
        if (homes.isEmpty() && lamps.isEmpty() && errors.isNotEmpty()) {
            throw IOException(errors.first())
        }
        return CloudDashboard(
            homes = homes.ifEmpty { listOf(CloudHome("default", "My Home")) },
            lamps = lamps
        )
    }

    /** Reads one exact account-owned lamp instead of relying on a list refresh. */
    fun readDevice(accessToken: String, lampId: String): CloudLamp {
        val normalizedId = lampId.trim().uppercase(Locale.US)
        val response = request(
            method = "GET",
            path = "/api/devices/${encodePath(normalizedId)}/state",
            bearerToken = accessToken,
            acceptErrors = true
        )
        if (response.code == 401 || response.code == 403) throw UnauthorizedException()
        if (response.code !in 200..299) throw IOException(extractError(response.body))
        val root = JSONObject(response.body)
        val device = root.optJSONObject("device")
            ?: root.optJSONObject("data")?.optJSONObject("device")
            ?: root
        return parseLamp(device)
            ?: throw IOException("The cloud did not return a valid lamp state.")
    }

    fun createRoom(accessToken: String, homeId: String, name: String): CloudRoom {
        val cleanName = name.trim().take(80)
        require(cleanName.isNotBlank()) { "Room name is required." }
        val response = request(
            method = "POST",
            path = "/api/homes/${encodePath(homeId)}/rooms",
            jsonBody = JSONObject().put("name", cleanName),
            bearerToken = accessToken,
            acceptErrors = true
        )
        if (response.code == 401 || response.code == 403) throw UnauthorizedException()
        if (response.code !in 200..299) throw IOException(extractError(response.body))
        val root = JSONObject(response.body)
        val room = root.optJSONObject("room")
            ?: root.optJSONObject("data")?.optJSONObject("room")
            ?: root
        return CloudRoom(
            id = room.optStringAny("id", "roomId", "uuid"),
            homeId = firstNonBlank(room.optString("homeId"), homeId),
            name = firstNonBlank(room.optString("name"), cleanName)
        )
    }

    fun claimDevice(
        accessToken: String,
        lampId: String,
        claimCode: String,
        homeId: String,
        roomId: String?,
        displayName: String
    ): CloudLamp {
        val body = JSONObject()
            .put("lampId", lampId.trim().uppercase(Locale.US))
            .put("claimCode", claimCode.trim())
            .put("homeId", homeId)
            .put("displayName", displayName.trim().take(80))
        if (roomId.isNullOrBlank()) body.put("roomId", JSONObject.NULL) else body.put("roomId", roomId)

        val response = request(
            method = "POST",
            path = "/api/devices/claim",
            jsonBody = body,
            bearerToken = accessToken,
            acceptErrors = true
        )
        if (response.code == 401 || response.code == 403) throw UnauthorizedException()
        if (response.code !in 200..299) throw IOException(extractError(response.body))
        val root = JSONObject(response.body)
        val device = root.optJSONObject("device")
            ?: root.optJSONObject("data")?.optJSONObject("device")
            ?: throw IOException("The server did not return the claimed lamp.")
        return parseLamp(device, homeId)
            ?: throw IOException("The claimed lamp response was incomplete.")
    }

    fun updateDevice(
        accessToken: String,
        lampId: String,
        displayName: String? = null,
        roomId: String? = null,
        updateRoom: Boolean = false
    ): CloudLamp {
        val body = JSONObject()
        displayName?.trim()?.takeIf { it.isNotBlank() }?.let { body.put("displayName", it.take(80)) }
        if (updateRoom) {
            if (roomId.isNullOrBlank()) body.put("roomId", JSONObject.NULL) else body.put("roomId", roomId)
        }
        require(body.length() > 0) { "No lamp changes were provided." }

        val response = request(
            method = "PATCH",
            path = "/api/devices/${encodePath(lampId)}",
            jsonBody = body,
            bearerToken = accessToken,
            acceptErrors = true
        )
        if (response.code == 401 || response.code == 403) throw UnauthorizedException()
        if (response.code !in 200..299) throw IOException(extractError(response.body))
        val root = JSONObject(response.body)
        val device = root.optJSONObject("device")
            ?: root.optJSONObject("data")?.optJSONObject("device")
            ?: throw IOException("The server did not return the updated lamp.")
        return parseLamp(device) ?: throw IOException("The updated lamp response was incomplete.")
    }

    fun releaseDevice(accessToken: String, lampId: String): ReleasedCloudLamp {
        val response = request(
            method = "DELETE",
            path = "/api/devices/${encodePath(lampId)}",
            bearerToken = accessToken,
            acceptErrors = true
        )
        if (response.code == 401 || response.code == 403) throw UnauthorizedException()
        if (response.code !in 200..299) throw IOException(extractError(response.body))
        val root = JSONObject(response.body)
        val data = root.optJSONObject("data")
        val credentials = root.optJSONObject("credentials")
            ?: data?.optJSONObject("credentials")
        val releasedLampId = firstNonBlank(
            root.optString("lampId"),
            data?.optString("lampId").orEmpty(),
            lampId
        )
        val newClaimCode = firstNonBlank(
            root.optString("newClaimCode"),
            data?.optString("newClaimCode").orEmpty(),
            credentials?.optString("claimCode").orEmpty()
        ).trim().uppercase(Locale.US)
        if (!Regex("[A-Z0-9]{6,32}").matches(newClaimCode)) {
            throw IOException(
                "The lamp was released, but the server did not return a valid new claim code. " +
                    "Do not remove the local lamp record."
            )
        }
        return ReleasedCloudLamp(
            lampId = releasedLampId,
            newClaimCode = newClaimCode
        )
    }

    fun sendCommand(
        accessToken: String,
        lampId: String,
        action: String,
        payload: JSONObject = JSONObject()
    ): CloudCommandReceipt {
        val commandId = UUID.randomUUID().toString()
        val body = JSONObject()
            .put("commandId", commandId)
            .put("idempotencyKey", commandId)
            .put("action", action)
            .put("type", action)
            .put("payload", payload)
            .put("value", payload.opt("value"))

        payload.keys().forEach { key ->
            if (!body.has(key)) body.put(key, payload.opt(key))
        }

        val encodedId = encodePath(lampId)
        val candidates = listOf(
            "/api/devices/$encodedId/commands",
            "/api/lamps/$encodedId/commands",
            "/api/devices/$encodedId/command",
            "/api/lamps/$encodedId/command"
        )

        var lastError = "Cloud command endpoint was not found."
        for (path in candidates) {
            val response = request(
                method = "POST",
                path = path,
                jsonBody = body,
                bearerToken = accessToken,
                acceptErrors = true
            )
            if (response.code == 401 || response.code == 403) {
                throw UnauthorizedException()
            }
            if (response.code in 200..299) {
                return parseCommandReceipt(response.body, commandId)
            }
            if (response.code != 404) {
                lastError = extractError(response.body).ifBlank {
                    "Cloud command failed with HTTP ${response.code}."
                }
            }
        }
        throw IOException(lastError)
    }

    fun parseRealtimeUpdate(text: String): CloudRealtimeUpdate? {
        return try {
            val root = JSONObject(text)
            val eventType = firstNonBlank(
                root.optString("type"),
                root.optString("event"),
                root.optString("eventType")
            ).lowercase(Locale.US)

            if (eventType == "authok" &&
                root.optString("connection").equals("app", ignoreCase = true)
            ) {
                val devices = root.optJSONArray("devices") ?: JSONArray()
                val lamps = buildList {
                    for (index in 0 until devices.length()) {
                        devices.optJSONObject(index)?.let { parseLamp(it) }?.let(::add)
                    }
                }
                return CloudRealtimeUpdate(
                    eventType = eventType,
                    authenticated = true,
                    userId = root.optString("userId").trim().takeIf(String::isNotBlank),
                    lamps = mergeLamps(emptyList(), lamps)
                )
            }

            if (eventType == "error") {
                return CloudRealtimeUpdate(
                    eventType = eventType,
                    errorMessage = firstNonBlank(
                        root.optString("message"),
                        root.optString("code"),
                        "Cloud realtime error"
                    )
                )
            }

            val lampId = root.optStringAny("lampId", "deviceId")
                .trim()
                .uppercase(Locale.US)
                .takeIf(String::isNotBlank)
            val online = root.optBooleanOrNull("online")
            val stateObject = root.optJSONObject("state")
            val embeddedLamp = root.optJSONObject("lamp")
                ?: root.optJSONObject("device")
                ?: root.optJSONObject("data")?.optJSONObject("lamp")
                ?: root.optJSONObject("data")?.optJSONObject("device")

            val lamp = when {
                embeddedLamp != null -> parseLamp(embeddedLamp)
                lampId != null && stateObject != null -> parseLamp(
                    JSONObject()
                        .put("lampId", lampId)
                        .put("online", online ?: true)
                        .put("state", stateObject)
                        .also { json ->
                            root.optString("firmwareVersion")
                                .takeIf(String::isNotBlank)
                                ?.let { json.put("firmwareVersion", it) }
                        }
                )
                else -> null
            }
            if (lamp != null || lampId != null || online != null) {
                CloudRealtimeUpdate(
                    eventType = eventType,
                    lamp = lamp,
                    lampId = lamp?.id ?: lampId,
                    online = online ?: lamp?.online
                )
            } else {
                CloudRealtimeUpdate(eventType = eventType)
            }
        } catch (_: Exception) {
            null
        }
    }

    fun parseRealtimeLamp(text: String): CloudLamp? = parseRealtimeUpdate(text)?.lamp

    private fun parseDashboardPayload(text: String, defaultHomeId: String = ""): CloudDashboard {
        if (text.isBlank()) return CloudDashboard(emptyList(), emptyList())
        val homes = mutableListOf<CloudHome>()
        val lamps = mutableListOf<CloudLamp>()
        val trimmed = text.trim()

        if (trimmed.startsWith("[")) {
            val array = JSONArray(trimmed)
            for (index in 0 until array.length()) {
                val item = array.optJSONObject(index) ?: continue
                val looksLikeLamp = item.has("lampId") || item.has("deviceId") ||
                    item.has("state") || item.has("online") || item.has("isOnline")
                if (looksLikeLamp) {
                    parseLamp(item, defaultHomeId)?.let(lamps::add)
                } else {
                    parseHome(item)?.let(homes::add)
                }
            }
            return CloudDashboard(
                homes = mergeHomes(emptyList(), homes),
                lamps = mergeLamps(emptyList(), lamps)
            )
        }

        val root = JSONObject(trimmed)

        val homeArrays = collectArrays(root, listOf("homes", "homeList"))
        for (array in homeArrays) {
            for (index in 0 until array.length()) {
                val homeObject = array.optJSONObject(index) ?: continue
                parseHome(homeObject)?.let(homes::add)
                collectLampObjects(homeObject).forEach { lampObject ->
                    parseLamp(lampObject, homeObject.optStringAny("id", "homeId"))?.let(lamps::add)
                }
            }
        }

        val singleHome = root.optJSONObject("home")
            ?: root.optJSONObject("data")?.optJSONObject("home")
        if (singleHome != null) {
            parseHome(singleHome)?.let(homes::add)
            collectLampObjects(singleHome).forEach { lampObject ->
                parseLamp(lampObject, singleHome.optStringAny("id", "homeId"))?.let(lamps::add)
            }
        }

        collectLampObjects(root).forEach { lampObject ->
            parseLamp(lampObject, defaultHomeId)?.let(lamps::add)
        }

        if (root.has("lampId") || root.has("deviceId")) {
            parseLamp(root, defaultHomeId)?.let(lamps::add)
        }

        return CloudDashboard(
            homes = mergeHomes(emptyList(), homes),
            lamps = mergeLamps(emptyList(), lamps)
        )
    }

    private fun parseHome(json: JSONObject): CloudHome? {
        val id = json.optStringAny("id", "homeId", "uuid")
        if (id.isBlank()) return null
        val rooms = mutableListOf<CloudRoom>()
        json.optJSONArray("rooms")?.let { array ->
            for (index in 0 until array.length()) {
                val room = array.optJSONObject(index) ?: continue
                val roomId = room.optStringAny("id", "roomId", "uuid")
                val roomName = firstNonBlank(room.optString("name"), room.optString("displayName"))
                if (roomId.isNotBlank() && roomName.isNotBlank()) {
                    rooms += CloudRoom(roomId, id, roomName)
                }
            }
        }
        return CloudHome(
            id = id,
            name = firstNonBlank(
                json.optString("name"),
                json.optString("displayName"),
                "My Home"
            ),
            rooms = rooms.distinctBy { it.id }
        )
    }

    private fun parseLamp(json: JSONObject, fallbackHomeId: String = ""): CloudLamp? {
        // lampId is the canonical public device identity used by every command route and
        // WebSocket event. The backend also returns an internal database UUID as `id`;
        // choosing that UUID first creates a duplicate card and sends commands to the
        // wrong URL. Always prefer lampId/deviceId and use id only as a final fallback.
        val id = json.optStringAny("lampId", "deviceId", "id", "uuid")
            .trim()
            .uppercase(Locale.US)
        if (id.isBlank()) return null

        val stateJson = json.optJSONObject("state")
            ?: json.optJSONObject("currentState")
            ?: json.optJSONObject("reportedState")
            ?: json.optJSONObject("lastState")
            ?: JSONObject()

        val brightness = firstInt(
            stateJson.optIntOrNull("brightness"),
            stateJson.optIntOrNull("currentBrightness"),
            stateJson.optIntOrNull("targetBrightness"),
            json.optIntOrNull("brightness"),
            0
        ).coerceIn(0, 100)

        val power = firstBoolean(
            stateJson.optBooleanOrNull("power"),
            stateJson.optBooleanOrNull("on"),
            json.optBooleanOrNull("power"),
            brightness > 0
        )

        val online = firstBoolean(
            json.optBooleanOrNull("online"),
            json.optBooleanOrNull("isOnline"),
            json.optString("status").equals("online", ignoreCase = true),
            false
        )

        val rawJson = stateJson.optJSONObject("raw")
            ?: json.optJSONObject("raw")
            ?: JSONObject()
        val batteryPercentValue = sequenceOf(
            stateJson.optIntOrNull("batteryPercent"),
            stateJson.optIntOrNull("battery"),
            stateJson.optIntOrNull("batteryLevel"),
            rawJson.optIntOrNull("batteryPercent"),
            rawJson.optIntOrNull("battery"),
            json.optIntOrNull("batteryPercent"),
            json.optIntOrNull("battery"),
            json.optIntOrNull("batteryLevel")
        ).firstOrNull { it != null }?.coerceIn(0, 100)
        val batteryVoltageValue = sequenceOf(
            stateJson.optIntOrNull("batteryVoltageMv"),
            stateJson.optIntOrNull("batteryMv"),
            rawJson.optIntOrNull("batteryVoltageMv"),
            rawJson.optIntOrNull("batteryMv"),
            json.optIntOrNull("batteryVoltageMv"),
            json.optIntOrNull("batteryMv")
        ).firstOrNull { it != null }?.takeIf { it in 2_000..5_000 }
        val explicitBatteryValid = sequenceOf(
            stateJson.optBooleanOrNull("batteryValid"),
            rawJson.optBooleanOrNull("batteryValid"),
            json.optBooleanOrNull("batteryValid")
        ).firstOrNull { it != null }
        val batteryValid = explicitBatteryValid
            ?: (batteryPercentValue != null || batteryVoltageValue != null)
        val batteryChargingValue = sequenceOf(
            stateJson.optBooleanOrNull("batteryCharging"),
            stateJson.optBooleanOrNull("isCharging"),
            stateJson.optBooleanOrNull("charging"),
            rawJson.optBooleanOrNull("batteryCharging"),
            rawJson.optBooleanOrNull("isCharging"),
            rawJson.optBooleanOrNull("charging"),
            json.optBooleanOrNull("batteryCharging"),
            json.optBooleanOrNull("isCharging"),
            json.optBooleanOrNull("charging")
        ).firstOrNull { it != null }
        val powerModeValue = sequenceOf(
            stateJson.optString("powerMode"),
            rawJson.optString("powerMode"),
            json.optString("powerMode")
        ).firstOrNull { it.isNotBlank() }?.let { raw ->
            LampPowerMode.values().firstOrNull { mode ->
                mode.name.equals(raw, ignoreCase = true) ||
                    mode.firmwareValue.equals(raw, ignoreCase = true)
            }
        }
        val runtimeStateValue = sequenceOf(
            stateJson.optString("runtimeState"),
            rawJson.optString("runtimeState"),
            json.optString("runtimeState")
        ).firstOrNull { it.isNotBlank() }?.let { raw ->
            LampRuntimeState.values().firstOrNull { state ->
                state.name.equals(raw, ignoreCase = true)
            }
        }


        return CloudLamp(
            id = id,
            homeId = firstNonBlank(
                json.optString("homeId"),
                json.optJSONObject("home")?.optStringAny("id", "homeId").orEmpty(),
                fallbackHomeId
            ),
            roomId = firstNonBlank(
                json.optString("roomId"),
                json.optJSONObject("room")?.optStringAny("id", "roomId").orEmpty()
            ).ifBlank { null },
            roomName = firstNonBlank(
                json.optJSONObject("room")?.optString("name").orEmpty(),
                json.optString("roomName")
            ).ifBlank { null },
            name = firstNonBlank(
                json.optString("name"),
                json.optString("displayName"),
                json.optString("label"),
                "SH Lamp"
            ),
            model = firstNonBlank(
                json.optString("model"),
                json.optString("productModel"),
                json.optString("firmwareVersion")
            ),
            online = online,
            lastSeen = firstNonBlank(
                json.optString("lastSeen"),
                json.optString("lastSeenAt"),
                json.optString("updatedAt")
            ).ifBlank { null },
            state = CloudLampState(
                power = power,
                brightness = brightness,
                fadeMode = firstInt(
                    stateJson.optIntOrNull("fadeMode"),
                    stateJson.optIntOrNull("fade"),
                    json.optIntOrNull("fadeMode"),
                    2
                ).coerceIn(0, 3),
                timerRemainingSeconds = firstLong(
                    stateJson.optLongOrNull("timerRemainingSeconds"),
                    stateJson.optLongOrNull("timerRemaining"),
                    json.optLongOrNull("timerRemainingSeconds"),
                    0L
                ).coerceAtLeast(0L),
                batteryValid = batteryValid,
                batteryPercent = batteryPercentValue.takeIf { batteryValid },
                batteryVoltageMv = batteryVoltageValue.takeIf { batteryValid },
                batteryCharging = batteryChargingValue.takeIf { batteryValid },
                powerMode = powerModeValue,
                runtimeState = runtimeStateValue
            )
        )
    }

    private fun parseCommandReceipt(text: String, fallbackCommandId: String): CloudCommandReceipt {
        if (text.isBlank()) {
            return CloudCommandReceipt(fallbackCommandId, true, "queued", "Command queued.")
        }
        val root = JSONObject(text)
        val command = root.optJSONObject("command")
            ?: root.optJSONObject("data")?.optJSONObject("command")
            ?: root
        val status = firstNonBlank(
            command.optString("status"),
            root.optString("status"),
            "queued"
        )
        return CloudCommandReceipt(
            commandId = firstNonBlank(
                command.optString("id"),
                command.optString("commandId"),
                root.optString("commandId"),
                fallbackCommandId
            ),
            accepted = firstBoolean(
                root.optBooleanOrNull("accepted"),
                root.optBooleanOrNull("ok"),
                status.lowercase(Locale.US) !in setOf("failed", "rejected", "expired"),
                true
            ),
            status = status,
            message = firstNonBlank(
                root.optString("message"),
                command.optString("message"),
                "Command $status."
            )
        )
    }

    private fun parseAuth(text: String): AuthResult {
        val root = JSONObject(text)
        val userObject = root.optJSONObject("user")
            ?: root.optJSONObject("data")?.optJSONObject("user")
            ?: throw IOException("The cloud response did not contain a user.")
        return AuthResult(parseUser(userObject), parseSession(root))
    }

    private fun parseUser(json: JSONObject): CloudUser {
        return CloudUser(
            id = json.optStringAny("id", "userId", "uuid"),
            name = firstNonBlank(
                json.optString("displayName"),
                json.optString("name"),
                json.optString("fullName")
            ),
            email = json.optString("email")
        )
    }

    private fun parseSession(root: JSONObject): CloudSession {
        val session = root.optJSONObject("session")
            ?: root.optJSONObject("data")?.optJSONObject("session")
            ?: root

        val access = firstNonBlank(
            session.optString("accessToken"),
            session.optString("access_token"),
            root.optString("accessToken"),
            root.optString("token")
        )
        val refresh = firstNonBlank(
            session.optString("refreshToken"),
            session.optString("refresh_token"),
            root.optString("refreshToken")
        )
        if (access.isBlank() || refresh.isBlank()) {
            throw IOException("The cloud response did not contain both session tokens.")
        }
        return CloudSession(access, refresh)
    }

    private fun collectLampObjects(root: JSONObject): List<JSONObject> {
        val result = mutableListOf<JSONObject>()
        val arrays = collectArrays(root, listOf("lamps", "devices", "items"))
        arrays.forEach { array ->
            for (index in 0 until array.length()) {
                array.optJSONObject(index)?.let(result::add)
            }
        }
        root.optJSONObject("lamp")?.let(result::add)
        root.optJSONObject("device")?.let(result::add)
        return result
    }

    private fun collectArrays(root: JSONObject, keys: List<String>): List<JSONArray> {
        val result = mutableListOf<JSONArray>()
        val containers = listOfNotNull(
            root,
            root.optJSONObject("data"),
            root.optJSONObject("result")
        )
        for (container in containers) {
            for (key in keys) {
                container.optJSONArray(key)?.let(result::add)
            }
        }
        return result
    }

    private fun mergeHomes(existing: List<CloudHome>, incoming: List<CloudHome>): List<CloudHome> {
        val map = LinkedHashMap<String, CloudHome>()
        existing.forEach { home -> if (home.id.isNotBlank()) map[home.id] = home }
        incoming.forEach { home ->
            if (home.id.isBlank()) return@forEach
            val old = map[home.id]
            map[home.id] = if (old == null) home else home.copy(
                name = home.name.ifBlank { old.name },
                rooms = (old.rooms + home.rooms).distinctBy { it.id }.sortedBy { it.name.lowercase() }
            )
        }
        return map.values.toList()
    }

    private fun mergeLamps(existing: List<CloudLamp>, incoming: List<CloudLamp>): List<CloudLamp> {
        val map = LinkedHashMap<String, CloudLamp>()
        existing.forEach { lamp -> map[lamp.id] = lamp }
        incoming.forEach { lamp ->
            val old = map[lamp.id]
            map[lamp.id] = if (old == null) lamp else lamp.copy(
                homeId = lamp.homeId.ifBlank { old.homeId },
                roomId = lamp.roomId ?: old.roomId,
                roomName = lamp.roomName ?: old.roomName,
                name = lamp.name.ifBlank { old.name },
                model = lamp.model.ifBlank { old.model },
                lastSeen = lamp.lastSeen ?: old.lastSeen
            )
        }
        return map.values.toList()
    }

    private fun request(
        method: String,
        path: String,
        jsonBody: JSONObject? = null,
        bearerToken: String? = null,
        acceptErrors: Boolean = false
    ): HttpResult {
        val connection = URL(baseUrl.trimEnd('/') + path).openConnection() as HttpURLConnection
        connection.requestMethod = method
        connection.connectTimeout = 20_000
        connection.readTimeout = 30_000
        connection.setRequestProperty("Accept", "application/json")
        connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
        connection.setRequestProperty("User-Agent", "SHLAMP-Android/1.5.0")
        if (!bearerToken.isNullOrBlank()) {
            connection.setRequestProperty("Authorization", "Bearer $bearerToken")
        }
        if (jsonBody != null) {
            connection.doOutput = true
            connection.outputStream.use {
                it.write(jsonBody.toString().toByteArray(StandardCharsets.UTF_8))
            }
        }

        val code = connection.responseCode
        val stream = if (code in 200..299) connection.inputStream else connection.errorStream
        val text = stream?.bufferedReader(StandardCharsets.UTF_8)?.use { it.readText() }.orEmpty()
        connection.disconnect()

        if (!acceptErrors && code !in 200..299) {
            throw IOException(extractError(text).ifBlank { "Cloud request failed with HTTP $code." })
        }
        return HttpResult(code, text, path)
    }

    private fun extractError(text: String): String {
        return try {
            val json = JSONObject(text)
            firstNonBlank(
                json.optString("message"),
                json.optString("error"),
                json.optJSONObject("error")?.optString("message").orEmpty()
            )
        } catch (_: Exception) {
            text.trim()
        }
    }

    private fun encodePath(value: String): String =
        URLEncoder.encode(value, StandardCharsets.UTF_8.name()).replace("+", "%20")
}

internal class UnauthorizedException : IOException("Cloud session expired.")

internal class CloudSessionManager(
    private val vault: CloudTokenVault,
    private val api: CloudApiClient
) {
    /**
     * REST refresh tokens are rotated by the backend. Dashboard refreshes,
     * commands and diagnostics can run concurrently, so only one thread may
     * exchange a refresh token. Other callers reuse the session saved by the
     * first successful refresh instead of revoking each other and clearing the
     * account unexpectedly.
     */
    private val refreshLock = Any()

    fun <T> execute(block: (String) -> T): T {
        val attemptedSession = vault.readSession() ?: throw UnauthorizedException()
        return try {
            block(attemptedSession.accessToken)
        } catch (_: UnauthorizedException) {
            val usableSession = synchronized(refreshLock) {
                val current = vault.readSession() ?: throw UnauthorizedException()
                if (current.accessToken != attemptedSession.accessToken) {
                    // Another request refreshed the tokens while this request
                    // was waiting for the lock.
                    current
                } else {
                    val refreshed = api.refresh(current.refreshToken) ?: run {
                        vault.clear()
                        throw UnauthorizedException()
                    }
                    vault.saveSession(refreshed)
                    refreshed
                }
            }
            block(usableSession.accessToken)
        }
    }

    fun accessToken(): String? = vault.readSession()?.accessToken
}

internal class CloudRealtimeClient(
    private val baseUrl: String = CLOUD_BASE_URL,
    private val listener: Listener
) {
    interface Listener {
        fun onStatus(status: String, connected: Boolean)
        fun onMessage(text: String)
    }

    private val client = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .pingInterval(25, TimeUnit.SECONDS)
        .build()
    private val reconnectHandler = Handler(Looper.getMainLooper())

    @Volatile private var socket: WebSocket? = null
    @Volatile private var stopped = true
    @Volatile private var authenticated = false
    private var accessToken = ""
    private var homeId = ""
    private var candidateIndex = 0
    private var reconnectAttempt = 0

    private val reconnectRunnable = Runnable {
        if (stopped) return@Runnable
        candidateIndex = 0
        openNext()
    }

    fun start(token: String, selectedHomeId: String, force: Boolean = false) {
        if (!force && !stopped && accessToken == token && homeId == selectedHomeId && socket != null) {
            return
        }
        closeSocket("Restarting cloud connection")
        reconnectHandler.removeCallbacks(reconnectRunnable)
        stopped = false
        authenticated = false
        accessToken = token
        homeId = selectedHomeId
        candidateIndex = 0
        openNext()
    }

    fun stop() {
        stopped = true
        authenticated = false
        reconnectHandler.removeCallbacks(reconnectRunnable)
        closeSocket("Activity stopped")
    }

    private fun closeSocket(reason: String) {
        val existing = socket
        socket = null
        existing?.close(1000, reason)
    }

    private fun openNext() {
        if (stopped || socket != null) return
        val paths = socketPaths()
        if (candidateIndex >= paths.size) {
            scheduleReconnect("Live cloud reconnecting…")
            return
        }
        val url = paths[candidateIndex++]
        listener.onStatus("Connecting live cloud…", false)
        val request = Request.Builder()
            .url(url)
            .header("Authorization", "Bearer $accessToken")
            .header("User-Agent", "SHLAMP-Android/1.5.0")
            .build()
        socket = client.newWebSocket(request, socketListener)
    }

    private fun scheduleReconnect(label: String) {
        if (stopped) return
        socket = null
        authenticated = false
        listener.onStatus(label, false)
        reconnectHandler.removeCallbacks(reconnectRunnable)
        val delay = (1_500L * (1 shl reconnectAttempt.coerceAtMost(4))).coerceAtMost(20_000L)
        reconnectAttempt++
        reconnectHandler.postDelayed(reconnectRunnable, delay)
    }

    private val socketListener = object : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            if (socket !== webSocket || stopped) return
            listener.onStatus("Authenticating cloud account…", false)
            webSocket.send(
                JSONObject()
                    .put("type", "auth")
                    .put("token", accessToken)
                    .toString()
            )
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            if (socket !== webSocket || stopped) return
            val root = runCatching { JSONObject(text) }.getOrNull()
            val type = root?.optString("type").orEmpty()
            if (type.equals("authOk", ignoreCase = true) &&
                root?.optString("connection").equals("app", ignoreCase = true)
            ) {
                authenticated = true
                reconnectAttempt = 0
                listener.onStatus("Live cloud connected.", true)
            } else if (type.equals("error", ignoreCase = true) && !authenticated) {
                listener.onStatus("Cloud authentication failed.", false)
            }
            listener.onMessage(text)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            // A force-reconnect closes the previous socket and opens a new one.
            // Ignore the delayed callback from that old socket; otherwise it can
            // null out/schedule over the new authenticated connection.
            if (socket !== webSocket) return
            socket = null
            if (!stopped) scheduleReconnect("Live cloud reconnecting…")
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            if (socket !== webSocket) return
            socket = null
            if (stopped) return
            if (candidateIndex < socketPaths().size) openNext()
            else scheduleReconnect("Live cloud reconnecting…")
        }
    }

    private fun socketPaths(): List<String> {
        val schemeBase = baseUrl.trimEnd('/').replaceFirst("https://", "wss://")
            .replaceFirst("http://", "ws://")
        return listOf(
            "$schemeBase/ws/app",
            "$schemeBase/api/ws/app"
        )
    }
}

internal fun formatCloudLastSeen(value: String?): String {
    if (value.isNullOrBlank()) return "Never connected"
    return try {
        val instant = Instant.parse(value)
        val seconds = (Instant.now().epochSecond - instant.epochSecond).coerceAtLeast(0)
        when {
            seconds < 10 -> "Just now"
            seconds < 60 -> "$seconds seconds ago"
            seconds < 3600 -> "${seconds / 60} minutes ago"
            seconds < 86_400 -> "${seconds / 3600} hours ago"
            else -> "${seconds / 86_400} days ago"
        }
    } catch (_: Exception) {
        value
    }
}

private fun JSONObject.optStringAny(vararg keys: String): String {
    for (key in keys) {
        val value = optString(key)
        if (value.isNotBlank() && value != "null") return value
    }
    return ""
}

private fun JSONObject.optIntOrNull(key: String): Int? {
    if (!has(key) || isNull(key)) return null
    return when (val value = opt(key)) {
        is Number -> value.toInt()
        is String -> value.toDoubleOrNull()?.toInt()
        else -> null
    }
}

private fun JSONObject.optLongOrNull(key: String): Long? {
    if (!has(key) || isNull(key)) return null
    return when (val value = opt(key)) {
        is Number -> value.toLong()
        is String -> value.toDoubleOrNull()?.toLong()
        else -> null
    }
}

private fun JSONObject.optBooleanOrNull(key: String): Boolean? {
    if (!has(key) || isNull(key)) return null
    return when (val value = opt(key)) {
        is Boolean -> value
        is Number -> value.toInt() != 0
        is String -> when (value.lowercase(Locale.US)) {
            "true", "1", "on", "online", "yes" -> true
            "false", "0", "off", "offline", "no" -> false
            else -> null
        }
        else -> null
    }
}

private fun firstNonBlank(vararg values: String): String =
    values.firstOrNull { it.isNotBlank() && it != "null" }.orEmpty()

private fun firstInt(vararg values: Int?): Int = values.firstOrNull { it != null } ?: 0
private fun firstLong(vararg values: Long?): Long = values.firstOrNull { it != null } ?: 0L
private fun firstBoolean(vararg values: Boolean?): Boolean = values.firstOrNull { it != null } ?: false
