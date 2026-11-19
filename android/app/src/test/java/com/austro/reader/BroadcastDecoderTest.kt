package com.austro.reader

import com.austro.reader.can.PcanFrameParser
import com.austro.reader.core.BroadcastDecoder
import com.austro.reader.core.BroadcastGroup
import com.austro.reader.core.CanFrame
import com.austro.reader.core.ECUSide
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BroadcastDecoderTest {

    private fun bytes(hex: String): ByteArray =
        ByteArray(hex.length / 2) { ((hex.substring(it * 2, it * 2 + 2)).toInt(16)).toByte() }

    @Test fun eng1EcuADecodesKnownSyntheticValues() {
        val d = BroadcastDecoder(0)
        val b = d.decode(CanFrame(0x300, bytes("FC088403827D7800")))!!
        assertEquals(ECUSide.A, b.ecu)
        assertEquals(BroadcastGroup.ENGINE1, b.group)
        val byName = b.readings.associate { it.name to it }
        assertEquals(2300.0, byName["Propeller speed"]!!.value!!, 0.0001)
        assertEquals(4500.0, byName["Oil pressure"]!!.value!!, 0.0001)   // 900 * 5
        assertEquals(80.0, byName["Oil temperature"]!!.value!!, 0.0001)  // 130 - 50
        assertEquals(75.0, byName["Coolant temperature"]!!.value!!, 0.0001)
        assertEquals(70.0, byName["Gearbox oil temperature"]!!.value!!, 0.0001)
    }

    @Test fun eng2EcuADecodesStatesAndScales() {
        val d = BroadcastDecoder(0)
        val b = d.decode(CanFrame(0x310, bytes("8C00000096FA0000")))!!
        assertEquals(BroadcastGroup.ENGINE2, b.group)
        val byName = b.readings.associate { it.name to it }
        assertEquals(28.0, byName["Battery voltage"]!!.value!!, 0.0001)   // 140 * 0.2
        assertEquals(75.0, byName["Engine performance"]!!.value!!, 0.0001) // 150 * 0.5
        assertEquals(25.0, byName["Fuel flow"]!!.value!!, 0.0001)         // 250 * 0.1
        assertEquals("Off", byName["Caution lamp"]!!.status)
        assertEquals("ECU A", byName["Voter output"]!!.status)
    }

    @Test fun nodeOffsetAndUnrelatedFrames() {
        assertNull(BroadcastDecoder(0).decode(CanFrame(0x301, bytes("0000000000000000"))))
        assertEquals(ECUSide.B, BroadcastDecoder(1).decode(CanFrame(0x401, bytes("0000000000000000")))!!.ecu)
        assertNull(BroadcastDecoder(0).decode(CanFrame(0x123, bytes("0000000000000000"))))
    }

    @Test fun unavailableSentinelBecomesNull() {
        val b = BroadcastDecoder(0).decode(CanFrame(0x300, bytes("FFFF000000000000")))!!
        assertNull(b.readings.first { it.name == "Propeller speed" }.value)
    }

    /** One standard data frame encoded in the PCAN-USB bulk format round-trips through the parser. */
    @Test fun parserDecodesOneStandardDataFrame() {
        // [status][count=1][sl=0x08][id lo][id hi][ts word lo][ts word hi][8 data bytes]
        val idFlags = 0x300 shl 5  // standard id packed into the 16-bit field
        val buf = byteArrayOf(
            0x00, 0x01,
            0x08,
            (idFlags and 0xFF).toByte(), ((idFlags shr 8) and 0xFF).toByte(),
            0x00, 0x00,  // first-record word timestamp (ignored)
        ) + bytes("FC088403827D7800")
        val frames = PcanFrameParser.parse(buf, buf.size)
        assertEquals(1, frames.size)
        val f = frames[0]
        assertEquals(0x300, f.id)
        assertTrue(!f.isExtended && !f.isRemote)
        assertEquals(8, f.data.size)
        // And it decodes to the expected engine values.
        val b = BroadcastDecoder(0).decode(f)!!
        assertEquals(2300.0, b.readings.first { it.name == "Propeller speed" }.value!!, 0.0001)
    }

    @Test fun parserToleratesTruncatedBuffer() {
        // count says 1 record but the buffer is too short — must not throw, returns nothing.
        val buf = byteArrayOf(0x00, 0x01, 0x08, 0x00)
        assertEquals(0, PcanFrameParser.parse(buf, buf.size).size)
    }
}
