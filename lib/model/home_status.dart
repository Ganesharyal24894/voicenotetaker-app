/// The one line under the device name on Home: are my notes being saved?
///
/// PURE. It answers from [NotesSaving] for always-listening, and the link and
/// the charger for the rest, so the header, the settings screen and the
/// notification cannot disagree.
library;

import 'continuous_status.dart';
import 'notes_saving.dart';

enum HomeStatusTone {
  /// All is well; the dot breathes.
  good,

  /// Notes are not being saved, or something needs the wearer. Amber.
  warning,

  /// Nothing is happening, and nothing is wrong with that. Grey.
  idle,
}

class HomeStatus {
  const HomeStatus(this.label, this.tone);

  final String label;
  final HomeStatusTone tone;

  static HomeStatus resolve({
    required ContinuousStatus continuous,
    required bool connected,
    required bool charging,
    RecorderStorage storage = RecorderStorage.none,
  }) {
    return switch (NotesSaving.from(continuous, storage: storage)) {
      NotesSaving.saving =>
        const HomeStatus('Saving notes', HomeStatusTone.good),
      NotesSaving.savingOnRecorder =>
        const HomeStatus('Saving on recorder · syncs when back', HomeStatusTone.idle),
      NotesSaving.muted =>
        const HomeStatus('Muted on the recorder', HomeStatusTone.warning),
      NotesSaving.micOff =>
        const HomeStatus('Not saving — mic off to save battery', HomeStatusTone.warning),
      NotesSaving.needsUpdate =>
        const HomeStatus('Not saving — recorder needs an update', HomeStatusTone.warning),
      NotesSaving.pairedToAnother =>
        const HomeStatus('Not saving — paired to another phone', HomeStatusTone.warning),
      NotesSaving.oldPairing =>
        const HomeStatus('Not saving — pairing needs a reset', HomeStatusTone.warning),
      NotesSaving.disconnected =>
        const HomeStatus('Not saving — recorder disconnected', HomeStatusTone.warning),
      NotesSaving.off => connected
          ? HomeStatus(charging ? 'Charging' : 'Connected', HomeStatusTone.good)
          : const HomeStatus('Not connected', HomeStatusTone.idle),
    };
  }

  @override
  bool operator ==(Object other) =>
      other is HomeStatus && other.label == label && other.tone == tone;

  @override
  int get hashCode => Object.hash(label, tone);

  @override
  String toString() => 'HomeStatus($label, $tone)';
}
