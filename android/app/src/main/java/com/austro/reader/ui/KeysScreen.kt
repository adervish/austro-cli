@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.austro.reader.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.austro.reader.can.Keys

/**
 * Paste-in entry for the two keys. Stored values are never shown back: each key only
 * reports whether it is set, and the entry fields are masked and cleared after saving.
 */
@Composable
fun KeysScreen() {
    var passText by remember { mutableStateOf("") }
    var maskText by remember { mutableStateOf("") }
    var message by remember { mutableStateOf<String?>(null) }
    var isError by remember { mutableStateOf(false) }
    var version by remember { mutableIntStateOf(0) }   // bumped to re-read the stored state

    fun state(stored: Boolean, builtIn: Boolean) = when {
        stored -> "Set on this device"
        builtIn -> "Using the key built into this copy of the app"
        else -> "Not set"
    }
    val passState = remember(version) { state(Keys.hasStoredPassphrase(), Keys.hasBuiltInPassphrase()) }
    val maskState = remember(version) { state(Keys.hasStoredMask(), Keys.hasBuiltInMask()) }
    val anyStored = remember(version) { Keys.hasStoredPassphrase() || Keys.hasStoredMask() }

    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("Keys", style = MaterialTheme.typography.headlineSmall)
        Text(
            "Paste the two keys from your own licensed AE300 Wizard. They stay on this " +
                "device, are not included in backups, and are never shown again after saving. " +
                "The Live tab works without them.",
            style = MaterialTheme.typography.bodyMedium,
        )

        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(".ae3 passphrase", style = MaterialTheme.typography.titleMedium)
                Text("Needed to open and save .ae3 files (Log and Flash tabs).",
                    style = MaterialTheme.typography.bodySmall)
                Text("Status: $passState", style = MaterialTheme.typography.bodyMedium)
                OutlinedTextField(
                    value = passText, onValueChange = { passText = it },
                    label = { Text("Paste passphrase") }, singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    modifier = Modifier.fillMaxWidth(),
                )
                Button(enabled = passText.isNotBlank(), onClick = {
                    val err = Keys.savePassphrase(passText)
                    isError = err != null; message = err ?: "Passphrase saved."
                    if (err == null) passText = ""
                    version++
                }) { Text("Save passphrase") }
            }
        }

        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("ECU security key mask", style = MaterialTheme.typography.titleMedium)
                Text("Needed to read fault codes and the datalogger (Faults and Flash tabs). " +
                    "Paste the 32 numbers (8 rows of 4) in any layout: the contents of " +
                    "ae3-ukey.json, or the numbers copied straight from the Wizard.",
                    style = MaterialTheme.typography.bodySmall)
                Text("Status: $maskState", style = MaterialTheme.typography.bodyMedium)
                OutlinedTextField(
                    value = maskText, onValueChange = { maskText = it },
                    label = { Text("Paste key mask") }, singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    modifier = Modifier.fillMaxWidth(),
                )
                Button(enabled = maskText.isNotBlank(), onClick = {
                    val err = Keys.saveMask(maskText)
                    isError = err != null; message = err ?: "Key mask saved."
                    if (err == null) maskText = ""
                    version++
                }) { Text("Save key mask") }
            }
        }

        message?.let {
            Text(it, color = if (isError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary,
                style = MaterialTheme.typography.bodyMedium)
        }

        Row {
            OutlinedButton(enabled = anyStored, onClick = {
                Keys.clear(); passText = ""; maskText = ""
                isError = false; message = "Keys removed from this device."
                version++
            }) { Text("Remove keys from this device") }
        }
    }
}
