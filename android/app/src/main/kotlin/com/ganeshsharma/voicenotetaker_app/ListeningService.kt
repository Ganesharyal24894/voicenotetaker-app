package com.ganeshsharma.voicenotetaker_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Always-listening's foreground service: type `connectedDevice`, one quiet
 * notification, and no work of its own.
 *
 * THE WORK IS IN DART. The BLE link, the decoding and the note on disk all run
 * in the engine [EngineHolder] keeps. This service exists so Android keeps the
 * process - and with it that engine - alive with the screen off and after the
 * app is swiped away, and so the user can always see that it is running.
 *
 * STICKY, so a process the system killed is brought back; the restart starts
 * the engine headless and `main()` reconnects. On Android 12+ that restart may
 * only call `startForeground` when the app is exempt from battery optimisation,
 * which is why turning always-listening on asks for the exemption.
 *
 * NO WAKE LOCK HERE. Audio notifications wake the CPU on their own, and the
 * one-minute keep-alive read is allowed to slip in Doze - see
 * doc/continuous-mode.md. The one wake lock this app takes is
 * `EngineHolder.holdCpu`, held only for the length of a transcription run off
 * screen, because inference on a worker thread has nothing waking it.
 */
class ListeningService : Service() {

    companion object {
        private const val TAG = "ListeningService"
        private const val CHANNEL_ID = "listening"
        private const val NOTIFICATION_ID = 4117
        private const val ACTION_START = "start"
        private const val ACTION_STOP = "stop"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_TEXT = "text"

        /** True between a successful startForeground and onDestroy. */
        @Volatile
        var running = false
            private set

        /**
         * False when Android refused the start. The caller TELLS DART, which
         * forgets the notification text it thinks is up and asks again on the
         * next change or the next time the app is opened - a refusal that was
         * reported as success was never retried, because the text rarely
         * changes twice.
         */
        fun start(context: Context, title: String, text: String): Boolean {
            val intent = Intent(context, ListeningService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_TITLE, title)
                .putExtra(EXTRA_TEXT, text)
            return try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                true
            } catch (refused: RuntimeException) {
                // ForegroundServiceStartNotAllowedException on 12+ when started
                // from the background without an exemption.
                Log.w(TAG, "could not start: $refused")
                false
            }
        }

        fun stop(context: Context) {
            if (!running) return
            val service = Intent(context, ListeningService::class.java)
            try {
                context.startService(service.setAction(ACTION_STOP))
            } catch (refused: RuntimeException) {
                // A background `startService` is refused on O+ outside the
                // foreground-service exemption, and `running` can be stale.
                // Stopping outright takes the notification down just the same.
                Log.w(TAG, "could not ask to stop: $refused")
                try {
                    context.stopService(service)
                } catch (ignored: RuntimeException) {
                    Log.w(TAG, "could not stop: $ignored")
                }
            }
        }
    }

    private var title = "voiceNotetaker"
    private var text = ""

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            running = false
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }
        intent?.getStringExtra(EXTRA_TITLE)?.let { title = it }
        intent?.getStringExtra(EXTRA_TEXT)?.let { text = it }
        try {
            startForegroundCompat(buildNotification())
            running = true
        } catch (refused: RuntimeException) {
            // SecurityException on 14+ when BLUETOOTH_CONNECT has been revoked -
            // the `connectedDevice` type demands it - and
            // ForegroundServiceStartNotAllowedException on 12+ from the
            // background. Dart is told, so the switch does not stay green over
            // a service that is not running.
            Log.w(TAG, "startForeground refused: $refused")
            EngineHolder.reportKeepAliveStopped()
            stopSelf()
            return START_NOT_STICKY
        }
        // UNCONDITIONALLY, not only for the null intent of a sticky restart.
        // The app can be swiped away between Dart asking for this service and
        // this line running, and `releaseIfIdle` sees `running` still false and
        // destroys the engine - leaving a notification with no isolate behind
        // it. `obtain` is idempotent and cheap, so asking always is the fix.
        EngineHolder.obtain(this)
        return START_STICKY
    }

    override fun onDestroy() {
        val wasRunning = running
        running = false
        // Killed by the system or by a vendor task killer rather than by Dart
        // asking: the same "ask again" path as a refused start.
        if (wasRunning) EngineHolder.reportKeepAliveStopped()
        super.onDestroy()
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    @Suppress("DEPRECATION")
    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            stopForeground(true)
        }
    }

    @Suppress("DEPRECATION")
    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                // LOW: no sound, no heads-up, no badge. It is a status, not news.
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    "Always listening",
                    NotificationManager.IMPORTANCE_LOW,
                )
                channel.setShowBadge(false)
                manager.createNotificationChannel(channel)
            }
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this).setPriority(Notification.PRIORITY_LOW)
        }
        return builder
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setShowWhen(false)
            .build()
    }
}
