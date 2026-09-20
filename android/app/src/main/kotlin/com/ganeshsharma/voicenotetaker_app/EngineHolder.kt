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
import android.os.Handler
import android.os.Looper
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

    /**
     * "Send to Instinct". Its own channel rather than a few more methods on
     * the background one, because this is the only channel Kotlin CALLS INTO
     * Dart on, and a method-call handler can only be set once per channel.
     */
    private const val ASSISTANT_CHANNEL = "com.ganeshsharma.voicenotetaker_app/assistant"
    private const val NOTIFICATION_PERMISSION_REQUEST = 7021

    /**
     * The longest the CPU lock is ever held. A 1-hour note is about 9 minutes
     * of two cores; 30 minutes is far past anything the policy would start and
     * is a backstop against a lock this process forgot, never a budget.
     */
    private const val CPU_LOCK_TIMEOUT_MS = 30L * 60L * 1000L

    /** The activity on screen, if any. Only permission requests need one. */
    @SuppressLint("StaticFieldLeak")
    var activity: Activity? = null

    /** The live assistant channel, or null while there is no engine. */
    private var assistant: MethodChannel? = null

    /**
     * The live background channel. Held for the same reason as [assistant]:
     * Kotlin calls INTO Dart on it to say that the keep-alive stopped.
     */
    private var background: MethodChannel? = null

    /**
     * The Dart call waiting on the notification prompt. A permission request
     * is answered in `onRequestPermissionsResult`, not when the dialog is
     * raised, and the Dart side has a SECOND thing to ask for straight after -
     * so this is what stops two system dialogs being raised at once.
     */
    private var pendingNotifications: MethodChannel.Result? = null

    /**
     * Held only while a transcription runs with the app off screen. See the
     * WAKE_LOCK note in `AndroidManifest.xml`.
     */
    private var cpuLock: PowerManager.WakeLock? = null

    /**
     * An Undo tapped before Dart was listening - the notification outlived the
     * process. Dart collects it with `takePendingUndo` as it starts.
     */
    private var pendingUndo: String? = null

    fun obtain(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
        val app = context.applicationContext
        val engine = FlutterEngine(app)
        installBackgroundChannel(app, engine)
        installAssistantChannel(app, engine)
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
        assistant = null
        background = null
        releaseCpu()
        engine.destroy()
    }

    /**
     * The Undo button on the notification was tapped.
     *
     * Nothing is decided here: Dart's outbox owns the undo window and is the
     * only thing that may take an entry out. With no engine running, one is
     * started and the id waits for it.
     */
    fun deliverUndo(context: Context, noteId: String) {
        val channel = assistant
        if (channel == null) {
            pendingUndo = noteId
            obtain(context)
            return
        }
        Handler(Looper.getMainLooper()).post {
            channel.invokeMethod("undoTapped", noteId)
        }
    }

    private fun installAssistantChannel(app: Context, engine: FlutterEngine) {
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, ASSISTANT_CHANNEL)
        assistant = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "showUndo" -> {
                    UndoNotification.show(
                        app,
                        call.argument<String>("noteId") ?: "",
                        call.argument<String>("title") ?: "",
                        call.argument<String>("text") ?: "",
                        call.argument<Number>("readyAt")?.toLong() ?: 0L,
                    )
                    result.success(null)
                }
                "hideUndo" -> {
                    UndoNotification.cancel(app)
                    result.success(null)
                }
                "takePendingUndo" -> {
                    val waiting = pendingUndo
                    pendingUndo = null
                    result.success(waiting)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun installBackgroundChannel(app: Context, engine: FlutterEngine) {
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, BACKGROUND_CHANNEL)
        background = channel
        channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    // ANSWERS WITH WHETHER THE SERVICE IS ACTUALLY RUNNING.
                    // A refused start that reported success was remembered by
                    // Dart as done and never asked for again, and the switch
                    // stayed green over nothing.
                    "start" -> result.success(
                        ListeningService.start(
                            app,
                            call.argument<String>("title") ?: "",
                            call.argument<String>("text") ?: "",
                        )
                    )
                    "stop" -> {
                        ListeningService.stop(app)
                        result.success(null)
                    }
                    "notificationsAllowed" -> result.success(notificationsAllowed(app))
                    // Answered from `onPermissionsResult`, once the user has
                    // tapped something - see [pendingNotifications].
                    "requestNotifications" -> requestNotifications(app, result)
                    "backgroundWorkAllowed" ->
                        result.success(ignoringBatteryOptimizations(app))
                    "requestBackgroundWork" -> {
                        requestIgnoreBatteryOptimizations(app)
                        result.success(null)
                    }
                    // iOS asks the system for a window; Android's foreground
                    // service is already the window, so there is nothing to
                    // ask for and nothing to withdraw.
                    "scheduleWork", "cancelWork" -> result.success(null)
                    "holdCpu" -> {
                        holdCpu(app)
                        result.success(null)
                    }
                    "releaseCpu" -> {
                        releaseCpu()
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

    /**
     * The foreground service stopped without Dart asking it to - refused at
     * start, or killed. Dart forgets the notification text it thinks is up, so
     * the next change asks again instead of believing it is already running.
     */
    fun reportKeepAliveStopped() {
        val channel = background ?: return
        Handler(Looper.getMainLooper()).post {
            channel.invokeMethod("keepAliveStopped", null)
        }
    }

    /**
     * A partial wake lock, so a transcription started with the screen off runs
     * to the end instead of being frozen between audio packets.
     *
     * TIMED, always. A lock this process forgot to release would hold the CPU
     * until the phone rebooted; the timeout is well past the longest job the
     * policy would start and it is released the moment the run ends anyway.
     */
    private fun holdCpu(app: Context) {
        if (cpuLock?.isHeld == true) return
        val power = app.getSystemService(Context.POWER_SERVICE) as PowerManager
        val lock = power.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "voicenotetaker:transcribe",
        )
        lock.setReferenceCounted(false)
        try {
            lock.acquire(CPU_LOCK_TIMEOUT_MS)
        } catch (refused: SecurityException) {
            // No WAKE_LOCK permission on this build: the job still runs, it
            // may just be slower with the screen off.
            return
        }
        cpuLock = lock
    }

    private fun releaseCpu() {
        val lock = cpuLock ?: return
        cpuLock = null
        if (lock.isHeld) lock.release()
    }

    private fun notificationsAllowed(app: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            app.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * Raises the notification prompt and answers [result] only once the user
     * has. Answers straight away where there is nothing to ask: below
     * Android 13, already granted, or no activity on screen to ask with.
     */
    private fun requestNotifications(app: Context, result: MethodChannel.Result) {
        val host = activity
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            notificationsAllowed(app) ||
            host == null
        ) {
            result.success(null)
            return
        }
        // A prompt already up: answer this one now rather than lose the first
        // result. A MethodChannel result may be answered exactly once.
        pendingNotifications?.success(null)
        pendingNotifications = result
        try {
            host.requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATION_PERMISSION_REQUEST,
            )
        } catch (refused: RuntimeException) {
            answerNotifications()
        }
    }

    /**
     * The user answered the notification prompt, or the activity went away
     * before they did. Either way the Dart call must be let go, or the second
     * thing it asks for is never asked.
     */
    fun onPermissionsResult(requestCode: Int) {
        if (requestCode != NOTIFICATION_PERMISSION_REQUEST) return
        answerNotifications()
    }

    /** Called when the host activity is destroyed with a prompt outstanding. */
    fun releasePendingPermission() = answerNotifications()

    private fun answerNotifications() {
        val waiting = pendingNotifications ?: return
        pendingNotifications = null
        waiting.success(null)
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
        if (launch(app, direct)) {
            // MIUI SHOWS THE AOSP DIALOG AND THEN LARGELY IGNORES THE ANSWER.
            // Its own per-app battery page - "No restrictions" - is the switch
            // that actually keeps the service alive, so on a Xiaomi the user is
            // taken there as well; the Keep listening sheet says to expect it.
            if (isXiaomi()) {
                launch(app, Intent("miui.intent.action.HIDDEN_APPS_CONFIG_ACTIVITY"))
            }
            return
        }
        launch(app, Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
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
        val millis = when (pattern) {
            // A tick: notes are saving again.
            "resumed" -> 60L
            // A short double-tap's worth: the assistant heard its name. Short
            // on purpose - it is a confirmation, not an alarm.
            "assistantHeard" -> 120L
            // A firm buzz: notes have stopped saving.
            else -> 400L
        }
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
            // The component name is current on MIUI 12-14 and HyperOS, but it
            // is often not exported to third-party apps, which throws - so the
            // published action and the security centre's own front door are
            // tried after it, and the app's details page after those. MIUI
            // puts an Autostart switch there too.
            val pages = listOf(
                Intent().setComponent(
                    ComponentName(
                        "com.miui.securitycenter",
                        "com.miui.permcenter.autostart.AutoStartManagementActivity",
                    )
                ),
                Intent("miui.intent.action.OP_AUTO_START").addCategory(Intent.CATEGORY_DEFAULT),
                Intent().setComponent(
                    ComponentName(
                        "com.miui.securitycenter",
                        "com.miui.securityscan.MainActivity",
                    )
                ),
            )
            for (page in pages) if (launch(app, page)) return true
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
