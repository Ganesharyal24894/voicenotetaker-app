/// The "Sending to Instinct - Undo" notification, for when the app is not on
/// screen.
///
/// A SEAM LIKE EVERY OTHER DRIVER, for the usual reason: a widget test and a
/// unit test must be able to watch the notification go up and come down
/// without an Android in the room. The Android implementation is
/// `undo_notification_channel.dart`; on iOS there is none, and
/// `AssistantUndoNotifier` is simply not given one - see
/// `doc/assistant-instructions.md` on why an iPhone gets the banner and
/// nothing else.
library;

abstract class UndoNotifications {
  /// Puts the notification up for [noteId], or updates the one that is there.
  ///
  /// [instruction] is what was said, with the wake phrase already stripped -
  /// the same one line the in-app banner shows. [readyAt] is the moment the
  /// instruction goes, so the countdown on the notification is the outbox's
  /// own deadline rather than a second one that could drift.
  Future<void> show({
    required String noteId,
    required String instruction,
    required DateTime readyAt,
  });

  /// Takes it down - the window closed, the user undid it, or the app came
  /// back to the screen.
  Future<void> hide();

  /// Called with the note's id when the user taps Undo on the notification.
  /// Called once per tap, and also once at startup for a tap that arrived
  /// while there was nothing listening.
  void listen(void Function(String noteId) onUndo);
}
