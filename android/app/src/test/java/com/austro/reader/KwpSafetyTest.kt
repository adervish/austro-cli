package com.austro.reader

import com.austro.reader.can.CanLink
import com.austro.reader.can.IsoTp
import com.austro.reader.can.Kwp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Locks the read-only safety guarantee: the phone must never transmit a write/erase/program
 * service to the ECU. Guards against a future change widening the allowlist or adding an
 * ungated transmit path.
 */
class KwpSafetyTest {

    @Test
    fun allowlistIsExactlyTheReadOnlyServices() {
        // start/stop comm, session, security (auth), tester-present, read-by-local-id,
        // read ident, DTC list/detail. Nothing that writes ECU memory.
        assertEquals(setOf(0x81, 0x10, 0x27, 0x3E, 0x21, 0x20, 0x1A, 0x18, 0x17), Kwp.readOnlySIDs)
    }

    @Test
    fun noWriteEraseOrProgramServiceIsEverAllowed() {
        // 0x3B WriteDataByLocalId, 0x3D WriteMemoryByAddress, 0x2E/0x2C WriteData,
        // 0x14 ClearDTC, 0x34 RequestDownload, 0x36 TransferData, 0x37 TransferExit,
        // 0x31 RoutineControl, 0x11 ECUReset, 0x85 ControlDTCSetting, 0x2F IOControl.
        for (w in listOf(0x3B, 0x3D, 0x2E, 0x2C, 0x14, 0x34, 0x36, 0x37, 0x31, 0x11, 0x85, 0x2F)) {
            assertFalse("write/erase service 0x%02X must NOT be in the allowlist".format(w),
                w in Kwp.readOnlySIDs)
        }
    }

    /** Scripted link: replies once to the DTC-list request, records every transmitted SID. */
    private class RecordingLink : CanLink {
        val sentSids = ArrayList<Int>()
        private var replied = false
        override fun send(id: Int, data: ByteArray) {
            // ISO-TP single frame: data[0]=length prefix, data[1]=service id.
            if (data.size >= 2) sentSids.add(data[1].toInt() and 0xFF)
        }
        override fun recv(timeoutMs: Int): Pair<Int, ByteArray>? {
            if (replied) return null
            replied = true
            return 0x7E8 to byteArrayOf(0x02, 0x58, 0x00, 0, 0, 0, 0, 0)  // 0x58 = DTC list, count 0
        }
    }

    @Test
    fun aReadFlowOnlyTransmitsAllowedServices() {
        val link = RecordingLink()
        val kwp = Kwp(IsoTp(link, txId = 0x7E0, rxId = 0x7E8))
        kwp.readDTCList()
        assertTrue("a read flow must transmit at least one request", link.sentSids.isNotEmpty())
        for (sid in link.sentSids) {
            val isFlowControl = (sid and 0xF0) == 0x30   // ISO-TP transport ACK, not a service
            assertTrue("transmitted SID 0x%02X must be read-only (or ISO-TP flow control)".format(sid),
                sid in Kwp.readOnlySIDs || isFlowControl)
        }
    }
}
