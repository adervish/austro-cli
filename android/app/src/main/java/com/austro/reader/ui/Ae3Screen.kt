@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.austro.reader.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.austro.reader.can.Keys
import com.austro.reader.can.Ae3Crypto
import com.austro.reader.can.Ae3Decoder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

private data class SessionSummary(val ecu: String, val session: Int, val count: Int, val start: Long, val end: Long)
private data class SignalStat(val name: String, val unit: String, val min: Double, val mean: Double, val max: Double)

@Composable
fun Ae3Screen() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var status by remember { mutableStateOf("No log loaded") }
    var error by remember { mutableStateOf<String?>(null) }
    var loading by remember { mutableStateOf(false) }
    var sessions by remember { mutableStateOf<List<SessionSummary>>(emptyList()) }
    var stats by remember { mutableStateOf<List<SignalStat>>(emptyList()) }
    var allRows by remember { mutableStateOf<List<Ae3Decoder.Row>>(emptyList()) }
    var selected by remember { mutableStateOf<Int?>(null) }

    val df = remember { SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") } }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        error = null; loading = true; status = "Decoding…"
        scope.launch {
            try {
                val rows = withContext(Dispatchers.IO) {
                    val raw = context.contentResolver.openInputStream(uri)!!.use { it.readBytes() }
                    // Decide by content, not filename: SAF content:// URIs don't carry the .ae3
                    // extension. Already-decrypted XML begins with '<' or a UTF-8 BOM; a .ae3 is
                    // AES ciphertext, so anything else needs decrypting first.
                    val looksXml = raw.isNotEmpty() && (raw[0] == '<'.code.toByte() ||
                        (raw.size >= 3 && raw[0] == 0xEF.toByte() && raw[1] == 0xBB.toByte() && raw[2] == 0xBF.toByte()))
                    val xml = if (looksXml) raw else {
                        val pass = Keys.passphrase()
                        if (pass.isEmpty()) throw IllegalStateException("The .ae3 passphrase is not set. Add it on the Keys tab.")
                        Ae3Crypto.decryptAe3(raw, pass)
                    }
                    Ae3Decoder.decode(xml)
                }
                val byKey = rows.groupBy { "${it.ecu}-${it.session}" }
                sessions = byKey.values.map { g ->
                    val sorted = g.sortedBy { it.epochMillis }
                    SessionSummary(sorted.first().ecu, sorted.first().session, g.size,
                        sorted.first().epochMillis, sorted.last().epochMillis)
                }.sortedWith(compareBy({ it.ecu }, { it.start }))
                stats = Ae3Decoder.signals.mapIndexed { i, sig ->
                    var mn = Double.MAX_VALUE; var mx = -Double.MAX_VALUE; var sum = 0.0; var n = 0
                    for (r in rows) { val v = r.values[i]; if (v < mn) mn = v; if (v > mx) mx = v; sum += v; n++ }
                    if (n == 0) { mn = 0.0; mx = 0.0 }
                    SignalStat(sig.name, sig.unit, mn, if (n > 0) sum / n else 0.0, mx)
                }
                allRows = rows
                selected = null
                status = "${rows.size} rows, ${sessions.size} sessions"
            } catch (e: Exception) {
                error = e.message ?: e.toString(); status = "No log loaded"
            } finally { loading = false }
        }
    }

    LazyColumn(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Card { Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Data-logger (.ae3) viewer", style = MaterialTheme.typography.titleMedium)
                Text(status, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                    Button(onClick = { picker.launch(arrayOf("*/*")) }) { Text("Open .ae3 / .xml") }
                    if (loading) { Text("  "); CircularProgressIndicator() }
                }
                error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
            } }
        }
        if (sessions.isNotEmpty()) {
            item { Text("Sessions", style = MaterialTheme.typography.titleSmall) }
            items(sessions) { s ->
                Row(Modifier.fillMaxWidth()) {
                    Text("ECU ${s.ecu} · #${s.session}", Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                    Text("${s.count} rows · ${df.format(s.start)} → ${df.format(s.end)}",
                        style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace)
                }
            }
        }
        selected?.let { idx ->
            item {
                val sig = Ae3Decoder.signals[idx]
                val values = allRows.mapNotNull { it.values.getOrNull(idx)?.takeIf { v -> v > -273.0 } }
                Card {
                    Column(Modifier.padding(12.dp)) {
                        Text("${sig.name} (${sig.unit})", style = MaterialTheme.typography.titleSmall)
                        if (values.size >= 2) {
                            Text(String.format(Locale.US, "min %.1f   max %.1f   %d pts",
                                values.min(), values.max(), values.size),
                                style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace)
                            SignalChart(values, MaterialTheme.colorScheme.primary)
                        } else {
                            Text("Not enough valid data to graph.", style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
            }
        }
        if (stats.isNotEmpty()) {
            item { Text("Signals — tap one to graph it (min / mean / max)", style = MaterialTheme.typography.titleSmall) }
            itemsIndexed(stats) { i, st ->
                Row(Modifier.fillMaxWidth().clickable { selected = if (selected == i) null else i }
                    .padding(vertical = 4.dp)) {
                    Text((if (selected == i) "▸ " else "") + st.name, Modifier.weight(1f),
                        style = MaterialTheme.typography.bodyMedium,
                        color = if (selected == i) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface)
                    Text(String.format(Locale.US, "%.1f / %.1f / %.1f %s", st.min, st.mean, st.max, st.unit),
                        style = MaterialTheme.typography.bodyMedium, fontFamily = FontFamily.Monospace)
                }
            }
        }
    }
}

/** Minimal line chart for one signal's values over time (downsampled for a smooth draw). */
@Composable
private fun SignalChart(values: List<Double>, lineColor: Color) {
    val mn = values.min()
    val mx = values.max()
    val range = (mx - mn).let { if (it == 0.0) 1.0 else it }
    // Downsample to ~600 points so very long flights still draw fast.
    val step = maxOf(1, values.size / 600)
    val pts = values.filterIndexed { i, _ -> i % step == 0 }
    Canvas(Modifier.fillMaxWidth().height(200.dp).padding(top = 8.dp)) {
        val w = size.width; val h = size.height
        drawLine(lineColor.copy(alpha = 0.25f), Offset(0f, h), Offset(w, h), 1f)      // baseline
        drawLine(lineColor.copy(alpha = 0.15f), Offset(0f, 0f), Offset(w, 0f), 1f)    // top
        val n = pts.size
        if (n < 2) return@Canvas
        val path = Path()
        for (i in pts.indices) {
            val x = w * i / (n - 1)
            val y = (h - ((pts[i] - mn) / range).toFloat() * h).coerceIn(0f, h)
            if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        drawPath(path, lineColor, style = Stroke(width = 3f))
    }
}
