import 'dart:async';

import 'package:flutter/services.dart';

import 'undo_notification.dart';

/// [UndoNotifications] over the app's own assistant channel, answered by
/// `EngineHolder.kt` and drawn by `UndoNotification.kt`.
///
/// ITS OWN CHANNEL, not the background one, because this is the only channel
/// Kotlin calls INTO Dart on and a method-call handler can only be set once.
///
/// A MISSING HANDLER IS A QUIET NO-OP - iOS, and every widget test. The app
/// then has the in-app banner and nothing else, which is exactly what iOS was
/// always going to get.
class MethodChannelUndoNotifications implements UndoNotifications {
  MethodChannelUndoNotifications();

  static const MethodChannel channel =
      MethodChannel('com.ganeshsharma.voicenotetaker_app/assistant');

  void Function(String noteId)? _onUndo;

  @override
  void listen(void Function(String noteId) onUndo) {
    _onUndo = onUndo;
    channel.setMethodCallHandler(_handle);
    // A tap that arrived while the process was dead: Kotlin parked the id and
    // this is the first moment anything could act on it.
    unawaited(_collectPending());
  }

  Future<void> _handle(MethodCall call) async {
    if (call.method != 'undoTapped') return;
    final noteId = call.arguments;
    if (noteId is String && noteId.isNotEmpty) _onUndo?.call(noteId);
  }

  Future<void> _collectPending() async {
    try {
      final noteId = await channel.invokeMethod<String>('takePendingUndo');
      if (noteId != null && noteId.isNotEmpty) _onUndo?.call(noteId);
    } on PlatformException {
      // Nothing waiting is not a failure.
    } on MissingPluginException {
      // iOS, and tests.
    }
  }

  @override
  Future<void> show({
    required String noteId,
    required String instruction,
    required DateTime readyAt,
  }) async {
    try {
      await channel.invokeMethod<void>('showUndo', <String, Object?>{
        'noteId': noteId,
        'title': 'Sending to Instinct',
        'text': instruction,
        'readyAt': readyAt.millisecondsSinceEpoch,
      });
    } on PlatformException {
      // Notifications refused. The banner in the app still says it.
    } on MissingPluginException {
      // iOS, and tests.
    }
  }

  @override
  Future<void> hide() async {
    try {
      await channel.invokeMethod<void>('hideUndo');
    } on PlatformException {
      // Nothing to take down.
    } on MissingPluginException {
      // iOS, and tests.
    }
  }
}
