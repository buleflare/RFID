package com.mm.ylp.rfid_test

import android.app.PendingIntent
import android.content.Intent
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.MifareClassic
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var nfcAdapter: NfcAdapter? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        println("DEBUG: Configuring Flutter engine")
        // Setup plugin
        MifareClassicPlugin.setup(flutterEngine, this)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        println("DEBUG: Activity onCreate")

        // Initialize NFC adapter
        nfcAdapter = NfcAdapter.getDefaultAdapter(this)
        if (nfcAdapter == null) {
            println("DEBUG: NFC not available on this device")
        } else {
            println("DEBUG: NFC adapter initialized")
        }

        // Handle NFC intent if app started from tag
        intent?.let {
            println("DEBUG: Handling onCreate intent: ${it.action}")
            MifareClassicPlugin.onNewIntent(this, it)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        println("DEBUG: onNewIntent: ${intent.action}")
        MifareClassicPlugin.onNewIntent(this, intent)
    }

    override fun onResume() {
        super.onResume()
        println("DEBUG: Activity onResume - enabling NFC foreground dispatch")

        val nfcAdapter = NfcAdapter.getDefaultAdapter(this) ?: return

        try {
            val intent = Intent(this, javaClass).apply {
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            }
            val pendingIntent = PendingIntent.getActivity(
                this, 0, intent, PendingIntent.FLAG_MUTABLE
            )
            val techList = arrayOf(arrayOf(MifareClassic::class.java.name))

            nfcAdapter.enableForegroundDispatch(this, pendingIntent, null, techList)
            println("DEBUG: NFC foreground dispatch enabled")
        } catch (e: Exception) {
            println("DEBUG: Error enabling NFC foreground dispatch: ${e.message}")
        }
    }

    override fun onPause() {
        super.onPause()
        println("DEBUG: Activity onPause - disabling NFC foreground dispatch")

        val nfcAdapter = NfcAdapter.getDefaultAdapter(this) ?: return

        try {
            nfcAdapter.disableForegroundDispatch(this)
            println("DEBUG: NFC foreground dispatch disabled")
        } catch (e: Exception) {
            println("DEBUG: Error disabling NFC foreground dispatch: ${e.message}")
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        println("DEBUG: Activity onDestroy")
    }
}