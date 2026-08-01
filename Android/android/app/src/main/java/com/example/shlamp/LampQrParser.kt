package com.example.shlamp

import android.net.Uri
import org.json.JSONObject
import java.util.Locale

internal data class LampQrPayload(
    val lampId: String,
    val claimCode: String = "",
    val model: String = ""
)

internal object LampQrParser {
    private val lampIdPattern = Regex("SH-[A-Z0-9]{4,16}")

    fun parse(raw: String): LampQrPayload {
        val text = raw.trim()
        require(text.isNotBlank()) { "The scanned code is empty." }

        parseJson(text)?.let { return it }
        parseUri(text)?.let { return it }
        parseSeparated(text)?.let { return it }

        val lampId = lampIdPattern.find(text.uppercase(Locale.US))?.value
            ?: throw IllegalArgumentException("This is not an SH Lamp code.")
        val remainder = text.replace(lampId, "", ignoreCase = true)
            .trim(' ', '|', ':', ';', ',', '-')
        return LampQrPayload(lampId = lampId, claimCode = remainder.take(32))
    }

    private fun parseJson(text: String): LampQrPayload? = runCatching {
        if (!text.startsWith("{")) return null
        val json = JSONObject(text)
        val lampId = firstNonBlank(
            json.optString("lampId"),
            json.optString("deviceId"),
            json.optString("serial")
        ).uppercase(Locale.US)
        require(lampIdPattern.matches(lampId)) { "Invalid lamp ID." }
        LampQrPayload(
            lampId = lampId,
            claimCode = firstNonBlank(
                json.optString("claimCode"),
                json.optString("code"),
                json.optString("setupCode")
            ).trim().take(32),
            model = json.optString("model").trim().take(40)
        )
    }.getOrNull()

    private fun parseUri(text: String): LampQrPayload? = runCatching {
        val uri = Uri.parse(text)
        val supported = uri.scheme.equals("shlamp", true) ||
            uri.host.equals("setup.shlamp", true) ||
            uri.host.equals("smarthandicrafts.com", true)
        if (!supported) return null
        val lampId = firstNonBlank(
            uri.getQueryParameter("lampId").orEmpty(),
            uri.getQueryParameter("deviceId").orEmpty(),
            uri.lastPathSegment.orEmpty()
        ).uppercase(Locale.US)
        require(lampIdPattern.matches(lampId)) { "Invalid lamp ID." }
        LampQrPayload(
            lampId = lampId,
            claimCode = firstNonBlank(
                uri.getQueryParameter("claimCode").orEmpty(),
                uri.getQueryParameter("code").orEmpty()
            ).trim().take(32),
            model = uri.getQueryParameter("model").orEmpty().trim().take(40)
        )
    }.getOrNull()

    private fun parseSeparated(text: String): LampQrPayload? {
        val parts = text.split('|', ';', ',').map(String::trim).filter(String::isNotBlank)
        val lampId = parts.firstOrNull { lampIdPattern.matches(it.uppercase(Locale.US)) }
            ?.uppercase(Locale.US) ?: return null
        val claimCode = parts.firstOrNull {
            !it.equals(lampId, ignoreCase = true) && it.length in 6..32
        }.orEmpty()
        return LampQrPayload(lampId = lampId, claimCode = claimCode)
    }

    private fun firstNonBlank(vararg values: String): String =
        values.firstOrNull { it.isNotBlank() }.orEmpty()
}
