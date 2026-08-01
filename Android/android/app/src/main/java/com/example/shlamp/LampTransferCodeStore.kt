package com.example.shlamp

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal data class PendingLampTransfer(
    val lampId: String,
    val claimCode: String,
    val releasedAt: Long
)

/**
 * Keeps a newly generated transfer/claim code until the user explicitly confirms
 * that it has been copied or saved. The value is encrypted with Android Keystore
 * so an Activity restart cannot silently lose the only recoverable copy.
 */
internal class LampTransferCodeStore(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences(
        PREFS_NAME,
        Context.MODE_PRIVATE
    )

    fun save(transfer: PendingLampTransfer) {
        val lampId = normalizeLampId(transfer.lampId)
        val claimCode = transfer.claimCode.trim().uppercase()
        require(lampId.startsWith("SH-") && claimCode.isNotBlank()) {
            "A valid lamp ID and claim code are required."
        }
        val payload = JSONObject()
            .put("lampId", lampId)
            .put("claimCode", claimCode)
            .put("releasedAt", transfer.releasedAt)
            .toString()
        check(
            preferences.edit()
                .putString(KEY_PENDING_TRANSFER, encrypt(payload))
                .commit()
        ) { "The claim code could not be saved on this phone." }
    }

    fun read(): PendingLampTransfer? {
        val encrypted = preferences.getString(KEY_PENDING_TRANSFER, null) ?: return null
        return try {
            val json = JSONObject(decrypt(encrypted))
            val lampId = normalizeLampId(json.optString("lampId"))
            val claimCode = json.optString("claimCode").trim().uppercase()
            val releasedAt = json.optLong("releasedAt", 0L)
            if (!lampId.startsWith("SH-") || claimCode.isBlank()) {
                clear()
                null
            } else {
                PendingLampTransfer(lampId, claimCode, releasedAt)
            }
        } catch (_: Exception) {
            clear()
            null
        }
    }

    fun clear(expectedLampId: String? = null) {
        if (expectedLampId != null) {
            val current = read()
            if (current != null && !current.lampId.equals(expectedLampId, ignoreCase = true)) return
        }
        preferences.edit().remove(KEY_PENDING_TRANSFER).commit()
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
        require(parts.size == 2) { "Invalid encrypted transfer value" }
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
        val builder = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)

        // AES-256 is available on supported Android versions, but keeping the
        // branch explicit makes the intent clear for older API levels.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) builder.setKeySize(256)
        generator.init(builder.build())
        return generator.generateKey()
    }

    private fun normalizeLampId(value: String): String = value.trim().uppercase()

    private companion object {
        const val PREFS_NAME = "shlamp_pending_transfer"
        const val KEY_PENDING_TRANSFER = "pending_transfer"
        const val KEY_ALIAS = "shlamp_pending_transfer_v1"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
    }
}
