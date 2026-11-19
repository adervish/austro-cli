package com.austro.reader.can

import android.content.Context
import android.content.SharedPreferences
import com.austro.reader.BuildConfig

/**
 * The two user-supplied keys (the .ae3 passphrase and the ECU security key mask).
 *
 * They are entered at runtime on the Keys tab and kept in app-private preferences on the
 * device. A value compiled in through local.properties (BuildConfig) is used only as a
 * fallback when nothing has been entered. Values are never logged or shown back in the UI.
 */
object Keys {
    private const val PREFS = "austro_keys"
    private const val K_PASS = "ae3_passphrase"
    private const val K_MASK = "ae3_ukey"

    private var prefs: SharedPreferences? = null

    fun init(context: Context) {
        if (prefs == null) prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    }

    /** The .ae3 passphrase, or "" when none is available. */
    fun passphrase(): String =
        prefs?.getString(K_PASS, null)?.takeIf { it.isNotEmpty() } ?: BuildConfig.AE3_PASSPHRASE

    /** The 8x4 security key mask, or null when none is available. */
    fun mask(): Array<IntArray>? =
        parseMask(prefs?.getString(K_MASK, null).orEmpty()) ?: parseMask(BuildConfig.AE3_UKEY)

    fun hasStoredPassphrase(): Boolean = !prefs?.getString(K_PASS, null).isNullOrEmpty()
    fun hasStoredMask(): Boolean = parseMask(prefs?.getString(K_MASK, null).orEmpty()) != null
    fun hasBuiltInPassphrase(): Boolean = BuildConfig.AE3_PASSPHRASE.isNotEmpty()
    fun hasBuiltInMask(): Boolean = parseMask(BuildConfig.AE3_UKEY) != null

    /** Saves the passphrase. Returns an error message, or null on success. */
    fun savePassphrase(text: String): String? {
        val value = normalizePassphrase(text) ?: return "The passphrase is empty."
        val p = prefs ?: return "Key storage is not ready."
        p.edit().putString(K_PASS, value).apply()
        return null
    }

    /** Saves the key mask. Returns an error message, or null on success. */
    fun saveMask(text: String): String? {
        val rows = parseMask(text)
            ?: return "The key mask must be exactly 32 whole numbers (8 rows of 4), each 0 to 255."
        val p = prefs ?: return "Key storage is not ready."
        p.edit().putString(K_MASK, maskToJson(rows)).apply()
        return null
    }

    fun clear() { prefs?.edit()?.clear()?.apply() }

    // ---- pure helpers (unit-tested; no Android or JSON dependency) ----

    /** Trims whitespace and one pair of surrounding quotes left over from copying. */
    fun normalizePassphrase(text: String): String? {
        var s = text.trim()
        if (s.length >= 2 && (s.first() == '"' || s.first() == '\'') && s.last() == s.first()) {
            s = s.substring(1, s.length - 1)
        }
        return s.takeIf { it.isNotEmpty() }
    }

    /**
     * Accepts the mask however it was copied: JSON (`[[1,2,3,4], ...]`), C# braces
     * (`{ {1,2,3,4}, ... }`), or just 32 numbers, decimal or 0x hex. Anything other than
     * exactly 32 byte values is rejected.
     */
    fun parseMask(text: String): Array<IntArray>? {
        if (text.isBlank()) return null
        // Only digits, hex, separators and brackets may appear; reject anything else so a
        // pasted paragraph that happens to contain 32 numbers is not accepted.
        if (!Regex("""^[\s\[\]{}(),;0-9a-fA-FxX]*$""").matches(text)) return null
        val tokens = Regex("""0[xX][0-9a-fA-F]+|[0-9a-fA-F]+""").findAll(text).map { it.value }.toList()
        if (tokens.size != 32) return null
        val values = IntArray(32)
        for ((i, t) in tokens.withIndex()) {
            val v = if (t.startsWith("0x") || t.startsWith("0X")) t.substring(2).toIntOrNull(16)
                    else t.toIntOrNull()
            if (v == null || v !in 0..255) return null
            values[i] = v
        }
        return Array(8) { r -> IntArray(4) { c -> values[r * 4 + c] } }
    }

    fun maskToJson(rows: Array<IntArray>): String =
        rows.joinToString(",", "[", "]") { it.joinToString(",", "[", "]") }
}
