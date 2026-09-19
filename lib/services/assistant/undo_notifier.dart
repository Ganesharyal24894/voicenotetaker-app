import 'dart:async';

import '../../controller/assistant_controller.dart';
import '../../drivers/undo_notification.dart';
import '../../model/assistant/assistant_send.dart';

/// Puts the Undo notification up while an instruction can still be stopped and
/// the app is not on screen, and takes it down the moment either stops being
/// true.
///
/// ONE AT A TIME, AND ONLY IN THE BACKGROUND. With the app on screen the
/// banner above the tab bar is the whole story and a notification would be a
/// second copy of it; with the app away, the notification is the only way the
/// user hears about it in the five seconds it matters.
///
/// IT DECIDES NOTHING. Whether the window is open comes from
/// [AssistantController.undoRemaining], and an Undo tap is handed straight to
/// [AssistantController.undo] - which is what says whether it was in time.
class AssistantUndoNotifier {
  AssistantUndoNotifier({
    required this.assistant,
    required this.notifications,
  }) {
    assistant.addListener(_sync);
    notifications.listen(_undo);
  }

  final AssistantController assistant;
  final UndoNotifications notifications;

  /// What is on screen now, so the notification is not posted and cancelled
  /// on every notification from the controller.
  String? _showing;

  bool _foreground = true;
  bool _disposed = false;

  /// Told by the app root as it comes and goes.
  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    _sync();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    assistant.removeListener(_sync);
    if (_showing != null) unawaited(notifications.hide());
    _showing = null;
  }

  /// The one entry whose undo window is still open, or null.
  AssistantSend? get _open {
    for (final send in assistant.recentSends(5)) {
      if (send.status == AssistantSendStatus.pendingUndo &&
          assistant.undoRemaining(send.noteId) > Duration.zero) {
        return send;
      }
    }
    return null;
  }

  void _sync() {
    if (_disposed) return;
    final send = _foreground ? null : _open;
    if (send == null) {
      if (_showing == null) return;
      _showing = null;
      unawaited(notifications.hide());
      return;
    }
    if (_showing == send.noteId) return;
    _showing = send.noteId;
    unawaited(
      notifications.show(
        noteId: send.noteId,
        instruction: send.instruction,
        readyAt: send.readyAt,
      ),
    );
  }

  void _undo(String noteId) {
    _showing = null;
    unawaited(assistant.undo(noteId));
  }
}
