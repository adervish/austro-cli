package com.austro.reader

import com.austro.reader.can.Keys
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/** Paste-tolerant parsing of the two keys. Uses made-up values only. */
class KeysTest {
    private val nums = (1..32).toList()
    private fun expectRows(rows: Array<IntArray>?) {
        assertNotNull(rows)
        assertEquals(8, rows!!.size)
        assertArrayEquals(intArrayOf(1, 2, 3, 4), rows[0])
        assertArrayEquals(intArrayOf(29, 30, 31, 32), rows[7])
    }

    @Test fun parsesJson() {
        val json = nums.chunked(4).joinToString(",", "[", "]") { it.joinToString(",", "[", "]") }
        expectRows(Keys.parseMask(json))
    }

    @Test fun parsesJsonWithWhitespaceAndNewlines() {
        val json = nums.chunked(4).joinToString(",\n  ", "[\n  ", "\n]\n") { it.joinToString(", ", "[ ", " ]") }
        expectRows(Keys.parseMask(json))
    }

    @Test fun parsesCSharpBracesAndHex() {
        val cs = nums.chunked(4).joinToString(", ", "{ ", " };") { row ->
            row.joinToString(", ", "{ ", " }") { "0x%02X".format(it) }
        }
        expectRows(Keys.parseMask(cs))
    }

    @Test fun parsesBareNumbers() = expectRows(Keys.parseMask(nums.joinToString(" ")))

    @Test fun roundTripsThroughStoredForm() {
        val rows = Keys.parseMask(nums.joinToString(","))!!
        expectRows(Keys.parseMask(Keys.maskToJson(rows)))
    }

    @Test fun rejectsWrongCountRangeAndProse() {
        assertNull(Keys.parseMask(""))
        assertNull(Keys.parseMask((1..31).joinToString(",")))
        assertNull(Keys.parseMask((1..33).joinToString(",")))
        assertNull(Keys.parseMask((nums.dropLast(1) + 256).joinToString(",")))
        assertNull(Keys.parseMask(nums.joinToString(",") { "-$it" }))
        assertNull(Keys.parseMask("the mask is " + nums.joinToString(",")))
    }

    @Test fun normalizesPassphrase() {
        assertEquals("abc", Keys.normalizePassphrase("  abc\n"))
        assertEquals("abc", Keys.normalizePassphrase("\"abc\""))
        assertNull(Keys.normalizePassphrase("   "))
    }
}
