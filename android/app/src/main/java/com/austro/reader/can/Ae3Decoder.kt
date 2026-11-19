package com.austro.reader.can

import android.util.Xml
import org.xmlpull.v1.XmlPullParser
import java.io.ByteArrayInputStream
import java.util.Calendar
import java.util.TimeZone

/**
 * Decoder for AE300 Wizard `.ae3` data-logger XML (RECMAN_HEXDUMP_DATLOG).
 * Port of the validated reference (RecManDataLogger + ConfigLiveView scaling).
 * Operates on the decrypted XML (see [Ae3Crypto]).
 */
object Ae3Decoder {
    data class Signal(val name: String, val unit: String)
    data class Row(val ecu: String, val session: Int, val epochMillis: Long, val values: DoubleArray)

    val signals = listOf(
        Signal("Boost Pressure", "hPa"), Signal("Ambient Air Pressure", "hPa"),
        Signal("Propeller Speed", "rpm"), Signal("Engine Oil Pressure", "hPa"),
        Signal("Rail Pressure", "bar"), Signal("Power Lever Position", "%"),
        Signal("Coolant Temperature", "°C"), Signal("Intake Air Temperature", "°C"),
        Signal("Battery Voltage", "V"), Signal("Fuel Pressure", "hPa"),
        Signal("Gearbox Oil Temperature", "°C"), Signal("Engine Oil Temperature", "°C"),
        Signal("Prop Actuator Duty Cycle", "%"), Signal("Engine Status", "bin"),
        Signal("Engine Oil Level", "mm"), Signal("Engine Load", "%"),
    )
    private val COEF = doubleArrayOf(1.0,1.0,1.0,1.0,0.1,50.0/4096,0.1,0.1,20.0/1023,1.0,0.1,0.1,0.01,1.0,0.1,50.0/4096)
    private val OFFSET = doubleArrayOf(0.0,0.0,0.0,0.0,0.0,0.0,-273.14,-273.14,0.0,0.0,-273.14,-273.14,0.0,0.0,0.0,0.0)
    private const val PAY = 65528

    private class Sector(val id: Int, val data: IntArray, val type: String)
    private class Session { var leadInIx = 0; var leadOutIx = 0; var dtLeadIn = 0L; var dtLeadOut = 0L; var channels: IntArray? = null }

    fun decode(xml: ByteArray): List<Row> {
        val out = ArrayList<Row>()
        for (ecu in listOf("A", "B")) {
            val sectors = parseSectors(xml, ecu)
            if (sectors.isNotEmpty()) out.addAll(decodeEcu(ecu, sectors))
        }
        return out
    }

    /** Decode raw flash sectors read directly from the ECU: list of (ecu, id, fullBytes). */
    fun decode(rawSectors: List<Triple<String, Int, IntArray>>): List<Row> {
        val byEcu = HashMap<String, ArrayList<Sector>>()
        for ((ecu, id, bytes) in rawSectors) {
            val al = ArrayList<Int>(bytes.size); for (x in bytes) al.add(x and 0xFF)
            byEcu.getOrPut(ecu) { ArrayList() }.add(makeSector(id, al))
        }
        val out = ArrayList<Row>()
        for (ecu in listOf("A", "B")) byEcu[ecu]?.let { if (it.isNotEmpty()) out.addAll(decodeEcu(ecu, it)) }
        return out
    }

    /** Rebuild the RECMAN_HEXDUMP_DATLOG XML from raw ECU sectors, for writing a .ae3. */
    fun buildHexdumpXML(sectors: List<Triple<String, Int, IntArray>>, fileName: String): ByteArray {
        val sb = StringBuilder(64 * 1024)
        sb.append("﻿<?xml version=\"1.0\" encoding=\"utf-8\"?><RECMAN_HEXDUMP_DATLOG>")
        sb.append("<FILE_ID><FILE_NAME>").append(fileName).append("</FILE_NAME></FILE_ID>")
        for (ecu in listOf("A", "B")) {
            val secs = sectors.filter { it.first == ecu }.sortedBy { it.second }
            if (secs.isEmpty()) continue
            sb.append("<SECTORS xmlns=\"").append(ecu).append("\">")
            for ((_, id, raw) in secs) {
                sb.append("<SECTOR><ID>").append(id).append("</ID><DATA>")
                for (b in raw) sb.append("<B>").append(b and 0xFF).append("</B>")
                sb.append("</DATA></SECTOR>")
            }
            sb.append("</SECTORS>")
        }
        sb.append("</RECMAN_HEXDUMP_DATLOG>")
        return sb.toString().toByteArray(Charsets.UTF_8)
    }

    // ---- per-ECU ----
    private lateinit var P: IntArray

    private fun decodeEcu(ecu: String, raw: List<Sector>): List<Row> {
        var keep = raw.filter { it.id > 15 && it.id < 140 && it.type != "notModified" && it.type != "erased" && it.type != "unknown" }
            .sortedBy { it.id }.toMutableList()
        if (keep.isEmpty()) return emptyList()
        var active = keep.indexOfFirst { it.type == "active" }.let { if (it == -1) keep.size - 1 else it }
        if (active < keep.size - 1) {
            val moved = keep.subList(active + 1, keep.size).toList()
            keep = (moved + keep.subList(0, active + 1)).toMutableList()
        }
        val total = keep.sumOf { it.data.size }
        P = IntArray(total)
        var p = 0
        for (s in keep) { System.arraycopy(s.data, 0, P, p, s.data.size); p += s.data.size }

        val rows = ArrayList<Row>()
        decodeLeadInLeadOut().forEachIndexed { si, s -> rows.addAll(extractValues(s, ecu, si)) }
        return rows
    }

    private fun bcd(b: Int) = (b shr 4) * 10 + (b and 0xF)

    private fun mkTime(ix: Int): Long {
        if (ix < 0 || ix + 5 >= P.size) return Long.MIN_VALUE
        val y = bcd(P[ix]); val mo = bcd(P[ix+1]); val d = bcd(P[ix+2]); val h = bcd(P[ix+3]); val mi = bcd(P[ix+4]); val s = bcd(P[ix+5])
        if (y < 0 || y >= 120 || mo < 1 || mo > 12 || d < 1 || d > 31 || h < 0 || h > 23 || mi < 0 || mi > 59 || s < 0 || s > 59) return Long.MIN_VALUE
        val c = Calendar.getInstance(TimeZone.getTimeZone("UTC"))
        c.clear(); c.set(2000 + y, mo - 1, d, h, mi, s)
        return c.timeInMillis
    }

    private fun mkChanConf(ix: Int): IntArray? {
        if (ix < 0 || ix + 24 > P.size) return null
        val nib = IntArray(48)
        var k = 0
        for (i in ix until ix + 24) { nib[k++] = P[i] shr 4; nib[k++] = P[i] and 0xF }
        val ch = ArrayList<Int>()
        var j = 0
        while (j + 2 < nib.size) { ch.add((nib[j] shl 8) or ((nib[j+1] and 0xF) shl 4) or (nib[j+2] and 0xF)); j += 3 }
        return ch.toIntArray()
    }

    private fun getLeadOutIndex(startIndex: Int): Int {
        var result = 0
        var num = startIndex
        while (num > 25) {
            if (P[num] == 0) {
                var b = 0; var broke = false
                var num2 = num
                while (num2 > num - 25) { b = (b + P[num2]) and 0xFF; if (b > 0) { broke = true; break }; num2-- }
                if (!broke && b == 0) {
                    result = num + 7; b = 0
                    var num3 = result
                    while (num3 > result - 32) { if (num3 in P.indices) b = (b + P[num3]) and 0xFF; num3-- }
                    if (b == 0xFF) { result = num - 25 + 1; break }
                    result = 0
                }
            }
            num--
        }
        return result
    }

    private fun recLen(ch: IntArray) = if (ch.size % 2 != 0) (ch.size + 1) * 2 else ch.size * 2

    private fun decodeLeadInLeadOut(): List<Session> {
        val list = ArrayList<Session>()
        var num = P.size - 1
        if (num <= 32) return list
        num = getLeadOutIndex(num)
        if (num <= 32) return list
        list.add(Session().apply { leadInIx = num + 64 })
        var item = Session().apply { leadOutIx = num }
        while (num > 32) {
            num = getLeadOutIndex(num)
            item.leadInIx = num + 64
            list.add(item)
            item = Session().apply { leadOutIx = num }
            if (num <= 32) break
        }
        for (i in list.indices) {
            val it = list[i]
            if (i != list.size - 1) { it.dtLeadIn = mkTime(it.leadInIx - 32); it.channels = mkChanConf(it.leadInIx - 26) }
            if (i != 0) it.dtLeadOut = mkTime(it.leadOutIx + 25)
        }
        if (list.size > 1) {
            list[list.size - 1].channels = list[list.size - 2].channels
            findLeadOutFirst(list[0])
            findLeadInLast(list[list.size - 1])
        }
        return list.filter { it.leadOutIx - it.leadInIx > 32 }
    }

    private fun scUp(posEnd: Int, posStart: Int): Int { // returns new posStart or -1 if no change
        val n = posEnd / PAY
        return if (posStart / PAY != n) n * PAY else -1
    }

    private fun findLeadOutFirst(it: Session) {
        val ch = it.channels ?: return
        val count = recLen(ch); var num = 0; var flag = false
        var i = it.leadInIx
        while (i < P.size && !flag) {
            if (i + count < P.size - 1) {
                val up = scUp(i + count, i)
                if (up >= 0) { i = up; continue }
                num++
                var j = 0
                while (j < count && i + j < P.size && P[i + j] == 0xFF) {
                    if (j == count - 1) { flag = true; it.leadOutIx = i - count + 1; it.dtLeadOut = it.dtLeadIn + (num - 1) * 1000L }
                    j++
                }
            } else { it.leadOutIx = i - count + 1; it.dtLeadOut = it.dtLeadIn + (num - 1) * 1000L; break }
            i += count
        }
    }

    private fun findLeadInLast(it: Session) {
        val ch = it.channels ?: return
        val count = recLen(ch); var num = 0; var num2 = it.leadOutIx - count
        while (num2 > 31) {
            if ((num2 + 1) / PAY != (num2 + count) / PAY) {
                var n3 = num2 + count
                while (n3 >= num2) { n3--; if (n3 < 0 || n3 >= P.size || P[n3] != 0xFF) break }
                num2 = n3 - count + 1
            } else num2 -= count
            num++
        }
        it.leadInIx = num2; it.dtLeadIn = it.dtLeadOut - num * 1000L
    }

    private fun extractValues(s: Session, ecu: String, session: Int): List<Row> {
        val ch = s.channels ?: return emptyList()
        val num = recLen(ch)
        val rows = ArrayList<Row>()
        var num3 = s.leadInIx; var k = 0
        if (s.dtLeadIn == Long.MIN_VALUE) return rows
        while (num3 <= s.leadOutIx - (num - 1)) {
            var i = num3 + 1
            val num4 = num3 + 1 + num
            if (i / PAY != num4 / PAY) {
                while (i < num4 && i < s.leadOutIx && (i == s.leadInIx || i == s.leadOutIx || i % PAY != 0)) i++
                num3 = i; continue
            }
            val vals = DoubleArray(16)
            var j = 0
            while (j < num) {
                val b = j shr 1; val p = num3 + j
                if (p + 1 >= P.size) break
                val v = ((P[p] shl 8) or P[p + 1]).toShort().toInt()
                if (b < 16) vals[b] = v * COEF[b] + OFFSET[b]
                j += 2
            }
            rows.add(Row(ecu, session, s.dtLeadIn + k * 1000L, vals))
            k++; num3 += num
        }
        return rows
    }

    // ---- XML sector parsing ----
    private fun parseSectors(xml: ByteArray, wantEcu: String): List<Sector> {
        val sectors = ArrayList<Sector>()
        val parser = Xml.newPullParser()
        // Keep xmlns="A"/"B" readable as a plain attribute (with namespace processing on it
        // would be consumed as a namespace decl and the ECU marker would be lost).
        parser.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, false)
        parser.setInput(ByteArrayInputStream(xml), "UTF-8")
        var curEcu: String? = null
        var curId: Int? = null
        var bytes: ArrayList<Int>? = null
        var text = StringBuilder()
        var inB = false
        var event = parser.eventType
        while (event != XmlPullParser.END_DOCUMENT) {
            when (event) {
                XmlPullParser.START_TAG -> when (parser.name) {
                    "SECTORS" -> curEcu = parser.getAttributeValue(null, "xmlns")
                    "SECTOR" -> { curId = null; bytes = ArrayList(65538) }
                    "ID" -> text = StringBuilder()
                    "B" -> { inB = true; text = StringBuilder() }
                }
                XmlPullParser.TEXT -> text.append(parser.text)
                XmlPullParser.END_TAG -> {
                    if (curEcu == wantEcu) {
                        when (parser.name) {
                            "ID" -> curId = text.toString().trim().toIntOrNull()
                            "B" -> { text.toString().trim().toIntOrNull()?.let { bytes?.add(it) }; inB = false }
                            "SECTOR" -> {
                                val b = bytes
                                val id = curId
                                if (id != null && b != null && b.size > 10) sectors.add(makeSector(id, b))
                                bytes = null
                            }
                            "SECTORS" -> curEcu = null
                        }
                    } else if (parser.name == "SECTORS") curEcu = null
                }
            }
            event = parser.next()
        }
        return sectors
    }

    private fun makeSector(id: Int, raw: ArrayList<Int>): Sector {
        val n = raw.size
        val data = IntArray(n - 10) { raw[it + 2] }   // raw[2 .. n-8)
        val c0 = raw[n-1]; val c1 = raw[n-2]; val c2 = raw[n-3]; val c3 = raw[n-4]
        val type = when {
            c0 == 0xFF && c1 == 0xFF && c2 == 0xFF && c3 == 0xFF -> "notModified"
            c0 == 0xFE && c1 == 0xFE && c2 == 0xFE && c3 == 0xFE -> "erased"
            c0 == 0xAA && c1 == 0xAA && c2 == 0xAA && c3 == 0xAA -> "active"
            c0 == 0xA8 && c1 == 0xA8 && c2 == 0xA8 && c3 == 0xA8 -> "fullNotLocked"
            c0 == 0x00 && c1 == 0x00 && c2 == 0x00 && c3 == 0x00 -> "locked"
            else -> "unknown"
        }
        return Sector(id, data, type)
    }
}
