package com.ganeshsharma.voicenotetaker_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * "Sending to Instinct - Undo", for the five seconds before an instruction
 * goes, when the app is not on screen.
 *
 * WHY NOT THE EXISTING NOTIFICATION. `ListeningService` posts one notification
 * on the `listening` channel: IMPORTANCE_LOW, ongoing, and it says whether
 * notes are being saved. Folding an Undo into it would (a) replace the one
 * line the wearer relies on, (b) never be seen - a LOW channel does not come
 * forward, and this has five seconds to be noticed - and (c) leave an Undo
 * button on a permanent notification after the window had shut. So this is a
 * second notification, on its own channel, that removes itself.
 *
 * SILENT BY DESIGN. The channel has no sound and no vibration of its own: the
 * phone has already buzzed once through `EngineHolder.vibrate` the moment the
 * wake phrase was recognised, and one event should not announce itself twice.
 * It is IMPORTANCE_HIGH only so that it is actually seen inside the window.
 *
 * THE COUNTDOWN IS THE SYSTEM'S. `setUsesChronometer` with
 * `setChronometerCountDown` counts down to `readyAt` without this process
 * being woken once a second to redraw it.
 */
object UndoNotification {
    const val CHANNEL_ID = "assistant-undo"

    /** Not 4117: that one is the always-listening service's. */
    const val NOTIFICATION_ID = 4118

    const val ACTION_UNDO = "com.ganeshsharma.voicenotetaker_app.ASSISTANT_UNDO"
    const val EXTRA_NOTE_ID = "noteId"

    /**
     * [readyAt] is when the instruction goes, in epoch milliseconds - the same
     * moment the outbox holds, so the notification and the queue cannot
     * disagree about how long is left.
     */
    @Suppress("DEPRECATION")
    fun show(context: Context, noteId: String, title: String, text: String, readyAt: Long) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            manager.getNotificationChannel(CHANNEL_ID) == null
        ) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Sending to Instinct",
                NotificationManager.IMPORTANCE_HIGH,
            )
            channel.setSound(null, null)
            channel.enableVibration(false)
            channel.setShowBadge(false)
            manager.createNotificationChannel(channel)
        }

        val undo = PendingIntent.getBroadcast(
            context,
            noteId.hashCode(),
            Intent(context, UndoReceiver::class.java)
                .setAction(ACTION_UNDO)
                .putExtra(EXTRA_NOTE_ID, noteId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val open = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            Notification.Builder(context).setPriority(Notification.PRIORITY_HIGH)
        }
        builder
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(open)
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .addAction(0, "Undo", undo)
        val left = readyAt - System.currentTimeMillis()
        if (left > 0) {
            // Gone on its own when the window shuts, even if nothing here runs
            // again - an Undo button that no longer undoes anything is worse
            // than no button.
            builder.setTimeoutAfter(left)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                builder.setWhen(readyAt).setUsesChronometer(true).setChronometerCountDown(true)
            }
        }
        try {
            manager.notify(NOTIFICATION_ID, builder.build())
        } catch (refused: SecurityException) {
            // POST_NOTIFICATIONS was not granted. The banner in the app is
            // still there on the next glance at the screen.
        }
    }

    fun cancel(context: Context) {
        context.getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
    }
}
