@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.austro.reader.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.austro.reader.LiveViewModel
import java.util.Locale

/** Ground / engine-off reminder shown on the diagnostic tabs (these transmit to the ECU). */
@Composable
private fun GroundWarning() {
    Card(Modifier.fillMaxWidth().padding(bottom = 12.dp)) {
        Text(
            "Ground / engine off. These reads transmit to the ECU. Disconnect Live first — " +
                "it shares the one adapter.",
            Modifier.padding(12.dp), style = MaterialTheme.typography.bodySmall
        )
    }
}

@Composable
private fun EcuPicker(selected: String, enabled: Boolean, onSelect: (String) -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("ECU", Modifier.padding(end = 4.dp))
        listOf("A", "B").forEach { e ->
            FilterChip(selected = selected == e, enabled = enabled, onClick = { onSelect(e) },
                label = { Text(e) })
        }
    }
}

@Composable
fun FaultsScreen(vm: LiveViewModel) {
    Column(Modifier.fillMaxSize().padding(16.dp)) {
        Text("Fault codes (DTCs)", style = MaterialTheme.typography.headlineSmall,
            modifier = Modifier.padding(bottom = 12.dp))
        GroundWarning()
        EcuPicker(vm.faultsEcu, enabled = !vm.diagBusy) { vm.faultsEcu = it }
        Row(Modifier.fillMaxWidth().padding(vertical = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(onClick = { vm.readFaults(vm.faultsEcu) }, enabled = !vm.diagBusy) {
                Text("Read fault codes")
            }
            if (vm.diagBusy) CircularProgressIndicator(Modifier.padding(4.dp))
        }
        if (vm.diagStatus.isNotEmpty()) {
            Text(vm.diagStatus, style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(bottom = 8.dp))
        }
        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(vm.faults) { d ->
                Card(Modifier.fillMaxWidth()) {
                    Row(Modifier.fillMaxWidth().padding(12.dp),
                        horizontalArrangement = Arrangement.SpaceBetween) {
                        Text(String.format(Locale.US, "0x%04X", d.id), fontFamily = FontFamily.Monospace)
                        val state = listOfNotNull(
                            if (d.active) "active" else null,
                            if (d.stored) "stored" else null
                        ).joinToString("+").ifEmpty { "—" }
                        Text("$state   freq ${d.frequency}", style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        }
    }
}

@Composable
fun FlashScreen(vm: LiveViewModel) {
    Column(Modifier.fillMaxSize().padding(16.dp)) {
        Text("Flash datalogger → .ae3", style = MaterialTheme.typography.headlineSmall,
            modifier = Modifier.padding(bottom = 12.dp))
        GroundWarning()
        EcuPicker(vm.flashEcu, enabled = !vm.diagBusy) { vm.flashEcu = it }
        Row(Modifier.fillMaxWidth().padding(top = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Hours", Modifier.padding(end = 4.dp))
            listOf(1, 2, 5, 0).forEach { h ->
                FilterChip(selected = vm.flashHours == h, enabled = !vm.diagBusy,
                    onClick = { vm.flashHours = h },
                    label = { Text(if (h == 0) "all" else "$h") })
            }
        }
        Row(Modifier.fillMaxWidth().padding(vertical = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(onClick = { vm.readFlash(vm.flashEcu, vm.flashHours.takeIf { it > 0 }) },
                enabled = !vm.diagBusy) { Text("Read datalogger") }
        }
        if (vm.diagBusy && vm.flashProgress > 0f) {
            LinearProgressIndicator(progress = { vm.flashProgress },
                modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp))
        }
        if (vm.diagStatus.isNotEmpty()) {
            Text(vm.diagStatus, style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(bottom = 8.dp))
        }
        vm.savedPath?.let { p ->
            Card(Modifier.fillMaxWidth().padding(bottom = 8.dp)) {
                Text("Saved to:\n$p", Modifier.padding(12.dp),
                    style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace)
            }
        }
        LazyColumn(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            items(vm.flashSummary) { line ->
                Text(line, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace)
            }
        }
    }
}
