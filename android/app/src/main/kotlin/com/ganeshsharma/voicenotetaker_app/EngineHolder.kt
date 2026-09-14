package com.ganeshsharma.voicenotetaker_app

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.app.NotificationManager
import android.media.AudioAttributes
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * The ONE Flutter engine, owned by the process rather than by the activity.
 *
 * WHY. A plain `FlutterActivity` destroys its engine when it is destroyed - and
 * swiping the app away from recents destroys it. The engine runs the Dart
 * isolate that holds the BLE link, decodes the audio and writes the open note,
 * so always-listening would die with the activity even though the foreground
 * service kept the process alive. Holding the engine here lets the activity
 * come and go while the isolate carries on; opening the app again re-attaches
 * a new activity to the same, still-running Dart state.
 *
 * The service can also create it: when Android restarts the (sticky) service
 * after killing the process, the engine is started headless and `main()` runs,
 * which is what brings always-listening back without the user opening the app.
 */
object EngineHolder {
    private const val ENGINE_ID = "main"
    private const val BACKGROUND_CHANNEL = "com.ganeshsharma.voicenotetaker_app/background"
    private const val NOTIFICATION_PERMISSION_REQUEST = 7021

    /** The activity on screen, if any. Only permission requests need one. */
    @SuppressLint("StaticFieldLeak")
    var activity: Activity? = null

    fun obtain(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
        val app = context.applicationContext
        val engine = FlutterEngine(app)
        installBackgroundChannel(app, engine)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        return engine
    }

    /**
     * Drops the engine when nothing needs it to outlive the activity, which is
     * exactly the old behaviour: with always-listening off, closing the app
     * ends the Dart side and releases the link.
     */
    fun releaseIfIdle() {
        if (ListeningService.running) return
        val engine = FlutterEngineCache.getInstance().get(ENGINE_ID) ?: return
        FlutterEngineCache.getInstance().remove(ENGINE_ID)
        engine.destroy()
    }

    private fun installBackgroundChannel(app: Context, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, BACKGROUND_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        ListeningService.start(
                            app,
                            call.argument<String>("title") ?: "",
                            call.argument<String>("text") ?: "",
                        )
                        result.success(null)
                    }
                    "stop" -> {
                        ListeningService.stop(app)
                        result.success(null)
                    }
                    "notificationsAllowed" -> result.success(notificationsAllowed(app))
                    "requestNotifications" -> {
                        requestNotifications()
                        result.success(null)
                    }
                    "ignoringBatteryOptimizations" ->
                        result.success(ignoringBatteryOptimizations(app))
                    "requestIgnoreBatteryOptimizations" -> {
                        requestIgnoreBatteryOptimizations(app)
                        result.success(null)
                    }
                    "thermalStatus" -> result.success(thermalStatus(app))
                    "hasAutostartSettings" -> result.success(isXiaomi())
                    "openAutostartSettings" -> result.success(openAutostartSettings(app))
                    "vibrate" -> {
                        vibrate(app, call.argument<String>("pattern"))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun notificationsAllowed(app: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            app.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    /** Needs an activity; without one on screen there is nobody to ask. */
    private fun requestNotifications() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        activity?.requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST,
        )
    }

    private fun ignoringBatteryOptimizations(app: Context): Boolean {
        val power = app.getSystemService(Context.POWER_SERVICE) as PowerManager
        return power.isIgnoringBatteryOptimizations(app.packageName)
    }

    /**
     * The direct "allow" dialog. Needs REQUEST_IGNORE_BATTERY_OPTIMIZATIONS in
     * the manifest; falls back to the list page where it is refused.
     */
    @SuppressLint("BatteryLife")
    private fun requestIgnoreBatteryOptimizations(app: Context) {
        val direct = Intent(
            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            Uri.fromParts("package", app.packageName, null),
        )
        if (!launch(app, direct)) {
            launch(app, Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        }
    }

    /**
     * `PowerManager.THERMAL_STATUS_*` (0 none .. 6 shutdown), or null below
     * Android 10 where there is no such API. Background transcription pauses
     * from MODERATE up; see `background_transcription_policy.dart`.
     */
    private fun thermalStatus(app: Context): Int? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val power = app.getSystemService(Context.POWER_SERVICE) as PowerManager
        return power.currentThermalStatus
    }

    /**
     * The not-saving alert's buzz (see `lib/drivers/haptics.dart`).
     *
     * A NOTIFICATION vibration, so it follows the phone's rules: nothing in
     * silent mode or Do Not Disturb (checked here as well, because not every
     * vendor applies the usage to a direct vibrate), and the system's
     * "vibrate for notifications" setting applies from Android 13 through
     * [VibrationAttributes.USAGE_NOTIFICATION].
     */
    @Suppress("DEPRECATION")
    private fun vibrate(app: Context, pattern: String?) {
        val millis = if (pattern == "resumed") 60L else 400L
        val audio = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (audio.ringerMode == AudioManager.RINGER_MODE_SILENT) return
        val notifications = app.getSystemService(NotificationManager::class.java)
        val filter = notifications?.currentInterruptionFilter
            ?: NotificationManager.INTERRUPTION_FILTER_UNKNOWN
        if (filter != NotificationManager.INTERRUPTION_FILTER_ALL &&
            filter != NotificationManager.INTERRUPTION_FILTER_UNKNOWN
        ) {
            return
        }
        val vibrator: Vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (app.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager)
                .defaultVibrator
        } else {
            app.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
        if (!vibrator.hasVibrator()) return
        val audioAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        try {
            when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> vibrator.vibrate(
                    VibrationEffect.createOneShot(millis, VibrationEffect.DEFAULT_AMPLITUDE),
                    VibrationAttributes.createForUsage(VibrationAttributes.USAGE_NOTIFICATION),
                )
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O -> vibrator.vibrate(
                    VibrationEffect.createOneShot(millis, VibrationEffect.DEFAULT_AMPLITUDE),
                    audioAttributes,
                )
                else -> vibrator.vibrate(millis, audioAttributes)
            }
        } catch (refused: SecurityException) {
            // No VIBRATE permission on this build: the notification still says it.
        }
    }

    private fun isXiaomi(): Boolean {
        val maker = Build.MANUFACTURER.lowercase()
        return maker == "xiaomi" || maker == "redmi" || maker == "poco"
    }

    /**
     * MIUI's autostart page is not a public intent, so it is tried by component
     * name and falls back to the app's own details page, which on MIUI carries
     * an "Autostart" switch as well.
     */
    private fun openAutostartSettings(app: Context): Boolean {
        if (isXiaomi()) {
            val miui = Intent().setComponent(
                ComponentName(
                    "com.miui.securitycenter",
                    "com.miui.permcenter.autostart.AutoStartManagementActivity",
                )
            )
            if (launch(app, miui)) return true
        }
        return launch(
            app,
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", app.packageName, null),
            ),
        )
    }

    /** From the activity when there is one, else as a new task. */
    private fun launch(app: Context, intent: Intent): Boolean = try {
        val host = activity
        if (host != null) {
            host.startActivity(intent)
        } else {
            app.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
        true
    } catch (notFound: ActivityNotFoundException) {
        false
    } catch (refused: SecurityException) {
        false
    }
}
