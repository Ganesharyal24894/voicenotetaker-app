package com.ganeshsharma.voicenotetaker_app

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * "Send to Instinct": the Undo notification's half of the assistant feature.
 *
 * IN THIS SOURCE SET ONLY WHEN THE APP IS BUILT WITH
 * `--dart-define=ASSISTANT=true` - see `android/app/build.gradle.kts`. A build
 * without it gets the empty `src/noAssistant` twin of this object, and none of
 * [UndoNotification], [UndoReceiver] or the receiver's manifest entry.
 *
 * Its own channel rather than a few more methods on the background one,
 * because this is the only channel Kotlin CALLS INTO Dart on, and a
 * method-call handler can only be set once per channel.
 */
object AssistantChannel {
    private const val NAME = "com.ganeshsharma.voicenotetaker_app/assistant"

    /** The live channel, or null while there is no engine. */
    private var channel: MethodChannel? = null

    /**
     * An Undo tapped before Dart was listening - the notification outlived the
     * process. Dart collects it with `takePendingUndo` as it starts.
     */
    private var pendingUndo: String? = null

    /** Called by [EngineHolder] for every engine it creates. */
    fun install(app: Context, engine: FlutterEngine) {
        val created = MethodChannel(engine.dartExecutor.binaryMessenger, NAME)
        channel = created
        created.setMethodCallHandler { call, result ->
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

    /** The engine is going away. */
    fun release() {
        channel = null
    }

    /**
     * The Undo button on the notification was tapped.
     *
     * Nothing is decided here: Dart's outbox owns the undo window and is the
     * only thing that may take an entry out. With no engine running, one is
     * started and the id waits for it.
     */
    fun deliverUndo(context: Context, noteId: String) {
        val live = channel
        if (live == null) {
            pendingUndo = noteId
            EngineHolder.obtain(context)
            return
        }
        Handler(Looper.getMainLooper()).post {
            live.invokeMethod("undoTapped", noteId)
        }
    }
}
