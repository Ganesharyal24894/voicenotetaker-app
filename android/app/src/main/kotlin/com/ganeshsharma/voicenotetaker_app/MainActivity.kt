package com.ganeshsharma.voicenotetaker_app

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.StatFs
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Host activity, plus the one platform channel the app owns itself: opening
 * the settings pages the edge-state screens point at.
 *
 * Both intents are PUBLIC framework actions, so nothing here needs a new
 * manifest permission - opening Settings is navigation, not a permission.
 * `ACTION_APPLICATION_DETAILS_SETTINGS` needs the app's own package URI and no
 * `<queries>` entry, because Settings is a system app that package visibility
 * does not hide.
 *
 * THE ENGINE IS NOT THE ACTIVITY'S. It comes from [EngineHolder] and is not
 * destroyed with the activity, so always-listening survives the app being
 * swiped away; see that file. With always-listening off it is released on the
 * way out, which is the old behaviour.
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "com.ganeshsharma.voicenotetaker_app/settings"
        const val BLUETOOTH_CHANNEL = "com.ganeshsharma.voicenotetaker_app/bluetooth"
        const val STORAGE_CHANNEL = "com.ganeshsharma.voicenotetaker_app/storage"
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine =
        EngineHolder.obtain(context)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        EngineHolder.activity = this
        super.onCreate(savedInstanceState)
    }

    override fun onDestroy() {
        if (EngineHolder.activity === this) EngineHolder.activity = null
        // A permission prompt this activity raised can no longer be answered.
        // The Dart call waiting on it must be let go, or the second thing the
        // permissions sheet asks for is never asked.
        EngineHolder.releasePendingPermission()
        super.onDestroy()
        if (isFinishing) EngineHolder.releaseIfIdle()
    }

    /**
     * The user answered a permission prompt. `super` hands it to the plugins;
     * the notification prompt is this app's own and is answered here.
     */
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        EngineHolder.onPermissionsResult(requestCode)
    }

    /**
     * The activity is going but the engine is not - always-listening keeps it.
     * These three handlers close over THIS activity (`startActivity`,
     * `getSystemService`), so leaving them installed holds a destroyed
     * activity and its whole view hierarchy for as long as the engine lives,
     * and a call arriving off screen would run against it. The next activity
     * installs its own in `configureFlutterEngine`.
     */
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        for (name in listOf(CHANNEL, BLUETOOTH_CHANNEL, STORAGE_CHANNEL)) {
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, name)
                .setMethodCallHandler(null)
        }
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openBluetoothSettings" ->
                        result.success(start(Intent(Settings.ACTION_BLUETOOTH_SETTINGS)))
                    "openAppSettings" ->
                        result.success(
                            start(
                                Intent(
                                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                    Uri.fromParts("package", packageName, null)
                                )
                            )
                        )
                    else -> result.notImplemented()
                }
            }
        // The one Bluetooth fact `universal_ble` does not expose: which LE
        // devices this phone is bonded with, by IDENTITY address. The recorder
        // advertises a rotating private address, so reconnecting goes through
        // the bonded address rather than one seen in a scan.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BLUETOOTH_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "bondedDevices" ->
                        result.success(bondedAddresses(call.argument<String>("name")))
                    else -> result.notImplemented()
                }
            }
        // Free space, which Dart has no API for at all. Used to refuse a
        // 197 MB model download BEFORE it starts rather than 197 MB later.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, STORAGE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "freeBytes" -> result.success(freeBytes(call.argument<String>("path")))
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Bytes available to THIS APP on the filesystem holding [path], or null
     * when the path cannot be read. `availableBytes`, not `freeBytes`: the
     * reserve the kernel keeps back is not room this app may have.
     */
    private fun freeBytes(path: String?): Long? = try {
        StatFs(path ?: filesDir.absolutePath).availableBytes
    } catch (bad: IllegalArgumentException) {
        null
    }

    /**
     * Addresses of bonded LE devices named [name] (all bonded LE devices when
     * null). Empty, not an error, when Bluetooth is off or BLUETOOTH_CONNECT
     * has not been granted - the caller then falls back to the id it has.
     */
    private fun bondedAddresses(name: String?): List<String> = try {
        val adapter = (getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager?)?.adapter
        adapter?.bondedDevices.orEmpty()
            .filter { it.type != BluetoothDevice.DEVICE_TYPE_CLASSIC }
            .filter { name == null || it.name == name }
            .map { it.address }
    } catch (denied: SecurityException) {
        emptyList()
    }

    /**
     * Returns false rather than throwing when no activity can handle the
     * intent: a device with a locked-down Settings is a fact for the UI to
     * report, not a crash.
     */
    private fun start(intent: Intent): Boolean = try {
        startActivity(intent)
        true
    } catch (notFound: ActivityNotFoundException) {
        false
    }
}
