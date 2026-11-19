package com.austro.reader

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.core.content.ContextCompat
import com.austro.reader.can.Keys
import com.austro.reader.can.PcanUsbSource
import com.austro.reader.ui.AustroApp

class MainActivity : ComponentActivity() {

    private val viewModel: LiveViewModel by viewModels()

    private val usbReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                PcanUsbSource.ACTION_USB_PERMISSION -> {
                    val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                    viewModel.onPermissionResult(granted)   // resumes the pending Live/Faults/Flash action
                }
                UsbManager.ACTION_USB_DEVICE_DETACHED -> viewModel.disconnect()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Keys.init(this)

        val filter = IntentFilter().apply {
            addAction(PcanUsbSource.ACTION_USB_PERMISSION)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        ContextCompat.registerReceiver(this, usbReceiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)

        // If launched by attaching the adapter, offer to connect immediately.
        if (intent?.action == UsbManager.ACTION_USB_DEVICE_ATTACHED) viewModel.connect()

        setContent { AustroApp(viewModel) }
    }

    override fun onDestroy() {
        runCatching { unregisterReceiver(usbReceiver) }
        super.onDestroy()
    }
}
