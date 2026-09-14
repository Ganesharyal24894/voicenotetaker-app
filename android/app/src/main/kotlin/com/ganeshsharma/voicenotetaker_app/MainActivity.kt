package com.ganeshsharma.voicenotetaker_app

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
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
        super.onDestroy()
        if (isFinishing) EngineHolder.releaseIfIdle()
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
