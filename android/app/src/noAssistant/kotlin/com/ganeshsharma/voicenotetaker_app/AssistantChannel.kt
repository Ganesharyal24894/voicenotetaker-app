package com.ganeshsharma.voicenotetaker_app

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine

/**
 * The assistant's channel on a build without the feature: nothing.
 *
 * The real one is in `src/assistant` and is compiled instead of this only when
 * the app is built with `--dart-define=ASSISTANT=true` - see
 * `android/app/build.gradle.kts`. The Dart side of such a build never calls
 * the channel, so there is nothing to answer.
 */
object AssistantChannel {
    @Suppress("UNUSED_PARAMETER")
    fun install(app: Context, engine: FlutterEngine) = Unit

    fun release() = Unit
}
