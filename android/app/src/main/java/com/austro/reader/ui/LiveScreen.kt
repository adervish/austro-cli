@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.austro.reader.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.background
import com.austro.reader.LiveViewModel
import com.austro.reader.core.Broadcast
import com.austro.reader.core.BroadcastGroup
import com.austro.reader.core.ECUSide

@Composable
fun AustroApp(vm: LiveViewModel) {
    MaterialTheme {
        Surface(Modifier.fillMaxSize()) {
            var tab by androidx.compose.runtime.remember { androidx.compose.runtime.mutableIntStateOf(0) }
            Column(Modifier.fillMaxSize()) {
                androidx.compose.material3.TabRow(selectedTabIndex = tab) {
                    listOf("Live", "Faults", "Flash", "Log").forEachIndexed { i, label ->
                        androidx.compose.material3.Tab(selected = tab == i, onClick = { tab = i },
                            text = { Text(label) })
                    }
                }
                when (tab) {
                    0 -> LiveScreen(vm)
                    1 -> FaultsScreen(vm)
                    2 -> FlashScreen(vm)
                    else -> Ae3Screen()
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LiveScreen(vm: LiveViewModel) {
    Scaffold(topBar = { TopAppBar(title = { Text("Austro Reader — Live") }) }) { pad ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(pad).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item { StatusCard(vm) }
            for (side in ECUSide.entries) {
                item { Text("ECU ${side.label}", style = MaterialTheme.typography.titleMedium) }
                item { GroupCard(vm, side, BroadcastGroup.ENGINE1, "ENG1") }
                item { GroupCard(vm, side, BroadcastGroup.ENGINE2, "ENG2") }
            }
        }
    }
}

@Composable
private fun StatusCard(vm: LiveViewModel) {
    Card {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                StatusDot(if (vm.connected) Color(0xFF2E7D32) else Color.Gray)
                Spacer(Modifier.width(8.dp))
                Text(vm.status, modifier = Modifier.weight(1f))
                Button(onClick = { if (vm.connected) vm.disconnect() else vm.connect() }) {
                    Text(if (vm.connected) "Disconnect" else "Connect")
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Engine node", modifier = Modifier.weight(1f))
                for (n in 0..3) {
                    FilterChip(
                        selected = vm.node == n,
                        onClick = { vm.selectNode(n) },
                        label = { Text("$n") },
                        modifier = Modifier.padding(start = 4.dp),
                    )
                }
            }
            vm.info?.let { info ->
                LabeledRow("Adapter", info.productName + (info.serial?.let { " · $it" } ?: ""))
                LabeledRow("Manufacturer", info.manufacturer)
            }
            LabeledRow("Frames received", vm.frameCount.toString())
            if (vm.connected && vm.frameCount == 0) {
                Text(
                    "Channel open, no frames yet. With the engine disconnected this is expected.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            vm.error?.let {
                Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

@Composable
private fun GroupCard(vm: LiveViewModel, side: ECUSide, group: BroadcastGroup, title: String) {
    val entry = vm.latest[side to group]
    Card {
        Column(Modifier.padding(16.dp).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row {
                Text(title, style = MaterialTheme.typography.labelLarge, modifier = Modifier.weight(1f))
                if (entry != null) {
                    val age = (vm.now - entry.millis).coerceAtLeast(0)
                    val stale = age > vm.staleAfterMs
                    Text(
                        String.format("0x%03X · %s", entry.broadcast.canId,
                            if (stale) "stale (${age / 1000}s)" else "updated ${age / 100 / 10.0}s ago"),
                        style = MaterialTheme.typography.labelSmall,
                        color = if (stale) Color(0xFFEF6C00) else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                } else {
                    Text(if (vm.connected) "waiting…" else "—",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            entry?.broadcast?.let { b: Broadcast ->
                for (r in b.readings) LabeledRow(r.name, r.display)
            }
        }
    }
}

@Composable
private fun LabeledRow(name: String, value: String) {
    Row(Modifier.fillMaxWidth()) {
        Text(name, modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
        Text(value, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun StatusDot(color: Color) {
    androidx.compose.foundation.layout.Box(
        Modifier.size(10.dp).clip(CircleShape).background(color)
    )
}
