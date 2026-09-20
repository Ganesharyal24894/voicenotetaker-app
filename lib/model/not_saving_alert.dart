/// When the phone buzzes because notes are not being saved.
///
/// PURE: it is handed the saving state and the time, and answers with what to
/// do. The controller owns the timer and the platform calls.
///
/// THE RULES
///
///   * Only while notes are being LOST ([NotesSaving.isLosingNotes]) - not
///     when always-listening is off, not when the wearer is in privacy mode
///     (their choice), not when the recorder has gone to sleep (its own
///     doing, and motion wakes it), and not when an SD-card recorder is
///     keeping the audio.
///   * Only after [grace] of it without a break: a link that drops and comes
///     straight back is not news.
///   * At most one not-saving buzz per [buzzInterval]. A flapping link still
///     updates the notification, silently.
///   * When saving resumes after an alert that buzzed: one short buzz. After a
///     silent alert, silently.
///   * The wearer turning always-listening off or on privacy mode ends an
///     alert silently, and so does a drop that turns out to be a sleep.
library;

import 'notes_saving.dart';

enum NotSavingAction {
  /// Nothing to change.
  none,

  /// Notes stopped saving: buzz once and say so in the notification.
  alert,

  /// Notes stopped saving again inside [NotSavingAlertPolicy.buzzInterval]:
  /// say so in the notification, no buzz.
  alertSilently,

  /// Saving resumed after an alert that buzzed: one short buzz, notification
  /// back to normal.
  resumed,

  /// The alert is over without a buzz: resumed after a silent alert, or the
  /// wearer turned listening off or on privacy mode, or the recorder turned
  /// out to be asleep.
  cleared,
}

class NotSavingAlertPolicy {
  NotSavingAlertPolicy({
    this.grace = defaultGrace,
    this.buzzInterval = defaultBuzzInterval,
  });

  static const Duration defaultGrace = Duration(seconds: 30);
  static const Duration defaultBuzzInterval = Duration(minutes: 10);

  final Duration grace;
  final Duration buzzInterval;

  DateTime? _losingSince;
  DateTime? _lastBuzz;
  bool _alerting = false;
  bool _alertBuzzed = false;

  /// Whether an alert is showing now.
  bool get alerting => _alerting;

  /// Takes the saving [state] at [now] and says what to do.
  ///
  /// [atRest] is the recorder believed to be asleep, or a clean drop still
  /// being decided - see `RecorderSleepWatch`. NOTHING BUZZES THEN: the
  /// recorder let the link go on purpose, motion wakes it, and a wearer buzzed
  /// at 02:00 about a device doing exactly what it was asked to do turns the
  /// feature off. A drop that is a real fault - a supervision timeout, a flat
  /// cell, a recorder that will not let us in - never sets this.
  NotSavingAction update(NotesSaving state, DateTime now, {bool atRest = false}) {
    if (state.isLosingNotes && !atRest) {
      final since = _losingSince ??= now;
      if (_alerting || now.difference(since) < grace) {
        return NotSavingAction.none;
      }
      _alerting = true;
      final last = _lastBuzz;
      if (last == null || now.difference(last) >= buzzInterval) {
        _lastBuzz = now;
        _alertBuzzed = true;
        return NotSavingAction.alert;
      }
      _alertBuzzed = false;
      return NotSavingAction.alertSilently;
    }
    _losingSince = null;
    if (!_alerting) return NotSavingAction.none;
    _alerting = false;
    final buzzed = _alertBuzzed;
    _alertBuzzed = false;
    return state.isSaving && buzzed
        ? NotSavingAction.resumed
        : NotSavingAction.cleared;
  }

  /// When [update] should be asked again even if nothing changes: the moment
  /// the grace period runs out. Null when no check is pending.
  DateTime? nextCheck() {
    final since = _losingSince;
    if (since == null || _alerting) return null;
    return since.add(grace);
  }
}
