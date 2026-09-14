/// Are my notes being saved? One answer, for the header, the settings screen
/// and the not-saving alert.
///
/// PURE, and derived from [ContinuousStatus] rather than resolved a second
/// time from the same facts: two resolvers would sooner or later disagree.
library;

import 'continuous_status.dart';

/// Where a recorder can keep audio by itself.
///
/// Every recorder today is [none]: audio exists only while a phone receives
/// it. [card] is the future SD-card recorder, which keeps recording while the
/// phone is away and syncs later - so a lost link there is not a lost note.
enum RecorderStorage { none, card }

enum NotesSaving {
  /// Always listening is off. Nothing to save, nothing to warn about.
  off,

  /// Notes are being saved on the phone.
  saving,

  /// The phone is away, but the recorder keeps the audio on its card. Neutral,
  /// never an alarm.
  savingOnRecorder,

  /// The wearer muted the recorder. Their choice: shown, never alarmed.
  muted,

  /// Connected, but the recorder turned its mic off to save battery.
  micOff,

  /// No link, and nowhere else keeps the audio.
  disconnected,

  /// The recorder's firmware cannot always-listen.
  needsUpdate,

  /// No link: the recorder is paired to another phone.
  pairedToAnother,

  /// No link: this phone's pairing with the recorder is stale.
  oldPairing;

  /// Notes are being lost and the wearer did not choose it: what the alert
  /// buzzes for.
  bool get isLosingNotes =>
      this == micOff ||
      this == disconnected ||
      this == needsUpdate ||
      this == pairedToAnother ||
      this == oldPairing;

  /// Notes are being kept somewhere.
  bool get isSaving => this == saving || this == savingOnRecorder;

  static NotesSaving from(
    ContinuousStatus status, {
    RecorderStorage storage = RecorderStorage.none,
  }) =>
      switch (status) {
        ContinuousStatus.off => NotesSaving.off,
        ContinuousStatus.listening ||
        ContinuousStatus.hearingSpeech =>
          NotesSaving.saving,
        ContinuousStatus.muted => NotesSaving.muted,
        ContinuousStatus.micOff => NotesSaving.micOff,
        ContinuousStatus.needsFirmwareUpdate => NotesSaving.needsUpdate,
        ContinuousStatus.pairedToAnother => NotesSaving.pairedToAnother,
        ContinuousStatus.oldPairing => NotesSaving.oldPairing,
        ContinuousStatus.notConnected => storage == RecorderStorage.card
            ? NotesSaving.savingOnRecorder
            : NotesSaving.disconnected,
      };
}
