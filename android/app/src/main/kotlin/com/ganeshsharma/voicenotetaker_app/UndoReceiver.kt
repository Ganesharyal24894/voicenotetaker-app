package com.ganeshsharma.voicenotetaker_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * The Undo button on the notification.
 *
 * It does NOT decide anything: the outbox in Dart owns whether the window is
 * still open, and it is the only thing that may take an entry out. All this
 * does is take the notification down and hand the note's id across.
 *
 * The process may not be running when this fires - the user is looking at a
 * notification from a phone in a pocket - so [EngineHolder.deliverUndo] starts
 * the Dart side if it has to and parks the id until Dart asks for it.
 */
class UndoReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != UndoNotification.ACTION_UNDO) return
        val noteId = intent.getStringExtra(UndoNotification.EXTRA_NOTE_ID) ?: return
        UndoNotification.cancel(context)
        EngineHolder.deliverUndo(context.applicationContext, noteId)
    }
}
