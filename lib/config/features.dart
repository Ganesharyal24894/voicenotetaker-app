/// Features that are compiled in only when a build asks for them.
library;

/// "Instinct, ...": a note that begins with the wake phrase is emailed to the
/// user's assistant. Off unless built with --dart-define=ASSISTANT=true.
///
/// Off, `main.dart` builds none of it and the AOT compiler drops the feature's
/// Dart code from the app; the same define switches its Android half on in
/// `android/app/build.gradle.kts`. On, it is still off at runtime until the
/// user turns it on in Recorder settings - see `doc/assistant-instructions.md`.
const bool kAssistant = bool.fromEnvironment('ASSISTANT');
