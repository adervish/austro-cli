package com.austro.reader.can

import java.io.ByteArrayInputStream
import java.security.MessageDigest
import java.util.zip.GZIPInputStream
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Decrypts AE300 Wizard `.ae3` files: AES-192-CBC (fixed IV, PKCS7) then GZip,
 * reproducing Wizard's CryptedCompression + PasswordDeriveBytes (PBKDF1/SHA1).
 * Validated byte-for-byte against the .NET implementation (same derived key).
 * The passphrase is supplied by the caller — never embedded here.
 */
object Ae3Crypto {
    private val IV = byteArrayOf(16,17,18,19,20,21,22,23,24,25,10,11,12,13,14,15)
    private val SALT = byteArrayOf(16,17,18,19,20,21,22,23,24,25,10,11,12)
    private const val ITERATIONS = 100

    /** .NET PasswordDeriveBytes(passphrase, salt).GetBytes(24): PBKDF1/SHA1 with the
     *  Microsoft extension (ASCII decimal counter "1","2",… prepended per 20-byte block). */
    fun deriveKey(passphrase: String, length: Int = 24): ByteArray {
        fun sha1(b: ByteArray) = MessageDigest.getInstance("SHA-1").digest(b)
        var base = sha1(passphrase.toByteArray(Charsets.UTF_8) + SALT)
        repeat(ITERATIONS - 2) { base = sha1(base) }
        val out = ArrayList<Byte>(length + 20)
        var prefix = 0
        while (out.size < length) {
            val block = if (prefix == 0) sha1(base) else sha1(prefix.toString().toByteArray(Charsets.US_ASCII) + base)
            out.addAll(block.toList())
            prefix++
        }
        return out.toByteArray().copyOf(length)
    }

    /** Decrypted XML bytes -> full .ae3 bytes (GZip then AES-192-CBC), for ECU flash dumps. */
    fun encryptAe3(xml: ByteArray, passphrase: String): ByteArray {
        val gz = java.io.ByteArrayOutputStream().also { bos ->
            java.util.zip.GZIPOutputStream(bos).use { it.write(xml) }
        }.toByteArray()
        val key = deriveKey(passphrase)
        val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(IV))
        return cipher.doFinal(gz)
    }

    /** Full .ae3 bytes -> decrypted XML bytes. */
    fun decryptAe3(data: ByteArray, passphrase: String): ByteArray {
        val key = deriveKey(passphrase)
        val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(IV))
        val gz = cipher.doFinal(data)
        return GZIPInputStream(ByteArrayInputStream(gz)).use { it.readBytes() }
    }
}
