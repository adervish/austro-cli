package com.austro.reader.can

import com.austro.reader.core.CanFrame

/**
 * Pure (Android-free) decoder for the classic PCAN-USB bulk RX buffer format,
 * implemented from the GPL kernel driver `pcan_usb.c` (pcan_usb_decode_msg /
 * decode_data / decode_status) as a protocol reference. Kept separate from the
 * USB transport so it can be unit-tested on the JVM.
 *
 * Each bulk buffer is self-contained (its own record count in byte 1), so a
 * malformed/unknown record only drops the remainder of THAT buffer; the next
 * bulk read re-syncs.
 */
object PcanFrameParser {
    const val MSG_HEADER_LEN = 2

    // status/len byte flags
    private const val SL_TIMESTAMP = 0x80
    private const val SL_INTERNAL = 0x40
    private const val SL_EXT_ID = 0x20
    private const val SL_RTR = 0x10
    private const val SL_DLC = 0x0F

    // internal record function codes
    private const val REC_ANALOG = 2
    private const val REC_BUSLOAD = 3
    private const val CMD_ARGS = 2
    private const val TX_SRR = 0x01

    fun parse(buf: ByteArray, len: Int): List<CanFrame> {
        if (len <= MSG_HEADER_LEN) return emptyList()
        val recCnt = buf[1].toInt() and 0xFF
        val out = ArrayList<CanFrame>(recCnt)
        val st = Parse(ptr = MSG_HEADER_LEN, recTsIdx = 0)
        try {
            var recIdx = 0
            while (recIdx < recCnt && st.ptr < len) {
                val sl = u8(buf, st.ptr, len); st.ptr += 1
                if ((sl and SL_INTERNAL) != 0) decodeStatus(buf, len, st, sl)
                else out.add(decodeData(buf, len, st, sl))
                recIdx++
            }
        } catch (_: IndexOutOfBoundsException) {
            // truncated/unknown record — keep what we decoded, re-sync next buffer
        }
        return out
    }

    private class Parse(var ptr: Int, var recTsIdx: Int)

    private fun decodeData(buf: ByteArray, len: Int, st: Parse, sl: Int): CanFrame {
        val recLen = sl and SL_DLC
        val canId: Int
        val extended: Boolean
        val idFlags: Long
        if ((sl and SL_EXT_ID) != 0) {
            idFlags = u32(buf, st.ptr, len); st.ptr += 4
            canId = (idFlags ushr 3).toInt() and 0x1FFFFFFF
            extended = true
        } else {
            idFlags = u16(buf, st.ptr, len).toLong(); st.ptr += 2
            canId = (idFlags ushr 5).toInt() and 0x7FF
            extended = false
        }
        readTimestamp(buf, len, st)
        if ((sl and SL_RTR) != 0) {
            return CanFrame(canId, ByteArray(0), isExtended = extended, isRemote = true)
        }
        require(st.ptr + recLen <= len)
        val take = minOf(recLen, 8)
        val data = ByteArray(take)
        System.arraycopy(buf, st.ptr, data, 0, take)
        st.ptr += recLen
        if ((idFlags and TX_SRR.toLong()) != 0L) st.ptr += 1  // SRR private-id echo (TX detail)
        return CanFrame(canId, data, isExtended = extended, isRemote = false)
    }

    private fun decodeStatus(buf: ByteArray, len: Int, st: Parse, sl: Int) {
        var recLen = sl and SL_DLC
        val f = u8(buf, st.ptr, len)
        u8(buf, st.ptr + 1, len) // number (bounds check only)
        st.ptr += CMD_ARGS
        if ((sl and SL_TIMESTAMP) != 0) readTimestamp(buf, len, st)
        when (f) {
            REC_ANALOG -> recLen = 2
            REC_BUSLOAD -> recLen = 1
            else -> { /* ERROR/TS/BUSEVT read in place; advance by recLen */ }
        }
        require(st.ptr + recLen <= len)
        st.ptr += recLen
    }

    private fun readTimestamp(buf: ByteArray, len: Int, st: Parse) {
        if (st.recTsIdx == 0) { require(st.ptr + 2 <= len); st.ptr += 2 }
        else { require(st.ptr + 1 <= len); st.ptr += 1 }
        st.recTsIdx++
    }

    private fun u8(buf: ByteArray, i: Int, len: Int): Int {
        if (i < 0 || i >= len) throw IndexOutOfBoundsException()
        return buf[i].toInt() and 0xFF
    }
    private fun u16(buf: ByteArray, i: Int, len: Int): Int {
        if (i + 2 > len) throw IndexOutOfBoundsException()
        return (buf[i].toInt() and 0xFF) or ((buf[i + 1].toInt() and 0xFF) shl 8)
    }
    private fun u32(buf: ByteArray, i: Int, len: Int): Long {
        if (i + 4 > len) throw IndexOutOfBoundsException()
        return (buf[i].toLong() and 0xFF) or
            ((buf[i + 1].toLong() and 0xFF) shl 8) or
            ((buf[i + 2].toLong() and 0xFF) shl 16) or
            ((buf[i + 3].toLong() and 0xFF) shl 24)
    }
}
