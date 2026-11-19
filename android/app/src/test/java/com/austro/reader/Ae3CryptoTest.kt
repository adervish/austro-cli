package com.austro.reader

import com.austro.reader.can.Ae3Crypto
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/**
 * Verifies the Android AES/PBKDF1/gunzip decrypt against a real .ae3 capture + the local
 * key. Point AE3_SAMPLE at one of your own Wizard exports to run it; it skips automatically
 * when the capture or ~/.config/austro/ae3.pass is missing, so it is harmless elsewhere.
 */
class Ae3CryptoTest {
    @Test
    fun decryptsRealCaptureToXml() {
        val home = System.getProperty("user.home")
        val passFile = File("$home/.config/austro/ae3.pass")
        val sample = System.getenv("AE3_SAMPLE")
        assumeTrue("set AE3_SAMPLE to a .ae3 capture to run this test", sample != null)
        val ae3 = File(sample!!)
        assumeTrue("needs local ~/.config/austro/ae3.pass + the capture", passFile.exists() && ae3.exists())

        val pass = passFile.readText().trim()
        val xml = Ae3Crypto.decryptAe3(ae3.readBytes(), pass)
        val head = String(xml.copyOf(minOf(xml.size, 120)), Charsets.UTF_8)

        assertTrue("decrypted output should be the datalog XML, got: ${head.take(60)}",
            head.contains("RECMAN_HEXDUMP_DATLOG"))
        assertTrue("XML should be non-trivial", xml.size > 1000)
    }
}
