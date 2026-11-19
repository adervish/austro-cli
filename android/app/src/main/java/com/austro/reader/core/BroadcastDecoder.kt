package com.austro.reader.core

/**
 * Kotlin port of the recovered AE300 broadcast decoder (AustroCore/BroadcastDecoder.swift),
 * itself recovered from Wizard 1.3.7.438 (Engine12.EngFunc1/EngFunc2). Pure decode logic,
 * no hardware access — kept separate from the USB transport so it stays portable/testable.
 */

enum class ECUSide(val label: String) { A("A"), B("B") }

enum class BroadcastGroup { ENGINE1, ENGINE2 }

/** A standard/extended CAN frame as delivered by the transport. */
data class CanFrame(
    val id: Int,
    val data: ByteArray,
    val isExtended: Boolean = false,
    val isRemote: Boolean = false,
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is CanFrame) return false
        return id == other.id && isExtended == other.isExtended &&
            isRemote == other.isRemote && data.contentEquals(other.data)
    }
    override fun hashCode(): Int {
        var r = id; r = 31 * r + data.contentHashCode()
        r = 31 * r + isExtended.hashCode(); r = 31 * r + isRemote.hashCode(); return r
    }
}

/** One decoded reading. A measurement has [value]; a discrete state has [status]. */
data class Reading(
    val name: String,
    val unit: String,
    val value: Double?,
    val status: String?,
) {
    val display: String
        get() = when {
            status != null -> status
            value == null -> "Not available"
            else -> formatValue(value) + if (unit.isEmpty()) "" else " $unit"
        }

    private fun formatValue(v: Double): String = String.format("%.1f", v)
}

/** A single broadcast group's readings for one ECU (not a merged snapshot). */
data class Broadcast(
    val ecu: ECUSide,
    val node: Int,
    val group: BroadcastGroup,
    val canId: Int,
    val readings: List<Reading>,
)

class BroadcastDecoder(val node: Int = 0) {
    init {
        require(node in 0..3) { "Engine node must be between 0 and 3." }
    }

    /** Returns null for frames that are not AE300 broadcasts for this node. */
    fun decode(frame: CanFrame): Broadcast? {
        if (frame.isExtended || frame.isRemote) return null
        val ecu: ECUSide
        val group: BroadcastGroup
        when (frame.id) {
            0x300 + node -> { ecu = ECUSide.A; group = BroadcastGroup.ENGINE1 }
            0x310 + node -> { ecu = ECUSide.A; group = BroadcastGroup.ENGINE2 }
            0x400 + node -> { ecu = ECUSide.B; group = BroadcastGroup.ENGINE1 }
            0x410 + node -> { ecu = ECUSide.B; group = BroadcastGroup.ENGINE2 }
            else -> return null
        }
        require(frame.data.size == 8) { "Engine broadcast requires 8 bytes; received ${frame.data.size}." }
        val b = IntArray(8) { frame.data[it].toInt() and 0xFF }

        fun numeric(name: String, unit: String, raw: Int, unavailable: Int,
                    scale: Double = 1.0, offset: Double = 0.0): Reading =
            Reading(name, unit, if (raw == unavailable) null else raw * scale + offset, null)

        fun state(name: String, raw: Int, zero: String, one: String): Reading =
            Reading(name, "", null, if (raw == 0) zero else if (raw == 1) one else "Not available")

        val readings: List<Reading> = when (group) {
            BroadcastGroup.ENGINE1 -> listOf(
                numeric("Propeller speed", "rpm", b[0] or (b[1] shl 8), 0xFFFF),
                numeric("Oil pressure", "hPa", b[2] or ((b[3] and 0xF) shl 8), 0xFFF, scale = 5.0),
                numeric("Oil temperature", "°C", b[4], 0xFF, offset = -50.0),
                numeric("Coolant temperature", "°C", b[5], 0xFF, offset = -50.0),
                numeric("Gearbox oil temperature", "°C", b[6], 0xFF, offset = -50.0),
            )
            BroadcastGroup.ENGINE2 -> listOf(
                numeric("Battery voltage", "V", b[0], 0xFF, scale = 0.2),
                numeric("Engine performance", "%", b[4], 0xFF, scale = 0.5),
                numeric("Fuel flow", "L/h", b[5] or ((b[6] and 0xF) shl 8), 0xFFF, scale = 0.1),
                state("Caution lamp", b[3] and 3, "Off", "On"),
                state("Fuel pressure warning", (b[2] shr 4) and 3, "OK", "Too low"),
                state("ECU status", (b[3] shr 2) and 3, "Active", "Passive"),
                state("Voter output", (b[3] shr 4) and 3, "ECU A", "ECU B"),
            )
        }
        return Broadcast(ecu, node, group, frame.id, readings)
    }
}
