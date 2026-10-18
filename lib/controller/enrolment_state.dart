import 'package:flutter/foundation.dart';

import '../model/enrolment_check.dart';
import '../model/voice_sample.dart';
import 'app_controller.dart';

/// Where the owner's guided voice recording stands, for the enrolment screen.
///
/// idle -> recording -> checking -> done, or -> retry; blocked before any of
/// it when the recorder or the speaker pack is missing.
sealed class EnrolmentState {
  const EnrolmentState();
}

/// Nothing running; the intro.
class EnrolmentIdle extends EnrolmentState {
  const EnrolmentIdle();
}

enum EnrolmentBlock {
  /// No recorder connected: the screen offers Connect.
  notConnected,

  /// The speaker pack is not installed: the screen offers the download.
  modelsMissing,
}

class EnrolmentBlocked extends EnrolmentState {
  const EnrolmentBlocked(this.reason);

  final EnrolmentBlock reason;
}

class EnrolmentRecording extends EnrolmentState {
  const EnrolmentRecording(this.elapsed);

  final Duration elapsed;

  /// Done is offered from here; the check wants at least this much talking.
  bool get canFinish => elapsed >= EnrolmentCheck.minSpeech;
}

class EnrolmentChecking extends EnrolmentState {
  const EnrolmentChecking([this.progress = 0]);

  /// `0.0`-`1.0`.
  final double progress;
}

/// Enrolled. Past notes are matched again after this; see
/// `VoicesController.rematchProgress`.
class EnrolmentDone extends EnrolmentState {
  const EnrolmentDone();
}

class EnrolmentRetry extends EnrolmentState {
  const EnrolmentRetry(this.verdict);

  final EnrolmentVerdict verdict;
}

/// What the enrolment needs from the recorder, and nothing else.
///
/// THE SEAM BETWEEN THE VOICES CONTROLLER AND [AppController], written like
/// `SpeakersController`: every member is the [AppController] member of the
/// same name, so [AppControllerVoiceSamples] is plain delegation.
abstract interface class VoiceSampleRecorder implements Listenable {
  bool get isConnected;

  /// The link dropped while recording; the take must still be stopped.
  bool get voiceSampleInterrupted;

  Future<bool> startVoiceSample(String path);

  Future<VoiceSampleTake?> stopVoiceSample();
}

/// [VoiceSampleRecorder] over the real [AppController].
class AppControllerVoiceSamples implements VoiceSampleRecorder {
  AppControllerVoiceSamples(this._app);

  final AppController _app;

  @override
  void addListener(VoidCallback listener) => _app.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _app.removeListener(listener);

  @override
  bool get isConnected => _app.isConnected;

  @override
  bool get voiceSampleInterrupted => _app.voiceSampleInterrupted;

  @override
  Future<bool> startVoiceSample(String path) => _app.startVoiceSample(path);

  @override
  Future<VoiceSampleTake?> stopVoiceSample() => _app.stopVoiceSample();
}
