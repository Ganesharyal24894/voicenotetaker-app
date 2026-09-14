/// The one line under the device name on Home: are my notes being saved?
///
/// PURE. It answers from the facts the controller already resolves -
/// [ContinuousStatus] for always-listening, the link and the charger for the
/// rest - so the header and the notification cannot disagree.
library;

import 'continuous_status.dart';

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
  }) {
    return switch (continuous) {
      ContinuousStatus.listening ||
      ContinuousStatus.hearingSpeech =>
        const HomeStatus('Saving notes', HomeStatusTone.good),
      ContinuousStatus.muted =>
        const HomeStatus('Muted on the recorder', HomeStatusTone.warning),
      ContinuousStatus.needsFirmwareUpdate =>
        const HomeStatus('Not saving — recorder needs an update', HomeStatusTone.warning),
      ContinuousStatus.notConnected =>
        const HomeStatus('Not saving — recorder disconnected', HomeStatusTone.warning),
      ContinuousStatus.off => connected
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
