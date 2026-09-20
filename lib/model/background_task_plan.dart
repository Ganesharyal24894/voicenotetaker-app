/// When to ask iOS for a block of background CPU time, and on what terms.
///
/// PURE: no clock, no I/O, no platform. `AppController` reads the library and
/// asks; every rule below is a unit test.
///
/// WHY THIS EXISTS. Android keeps this app's isolate alive with a
/// `connectedDevice` foreground service, so a queued transcript simply carries
/// on running off screen under [BackgroundTranscriptionPolicy]. iOS has no
/// such thing. What it has instead is `BGProcessingTask`: the app asks the
/// system for a window, the system picks its own moment - typically while the
/// phone is idle, charging and on Wi-Fi, often overnight - and hands back
/// several minutes of CPU. That is the ONLY sanctioned way to run minutes of
/// neural inference on an iPhone without the app on screen.
///
/// THE RULES
///
///   * Ask only when there is something to do. An empty queue that asks anyway
///     spends the user's background-execution budget on nothing, and iOS
///     answers a request it is asked too often by running it less.
///   * Ask only when the model is installed. Nothing can be transcribed
///     without it, and the window would be handed back unused.
///   * Ask for a charger. A one-hour note is about nine minutes of two cores;
///     that is not work to take out of someone's battery while their phone is
///     in a pocket. It is also what makes iOS likely to schedule the window at
///     all - the system runs power-hungry processing tasks when the phone is
///     plugged in and still.
///   * Never ask for the network. Transcription is entirely on-device; saying
///     otherwise would make the window harder to earn for no reason.
///   * [earliestDelay] is a floor, not a promise. iOS may run the task hours
///     later, or not at all if the user never plugs the phone in. Nothing in
///     the app may depend on it having run - the queue is still there on the
///     next foreground, and that is what the user is told.
library;

/// What the app asks iOS for: one `BGProcessingTaskRequest`.
class BackgroundTaskRequest {
  const BackgroundTaskRequest({
    required this.requiresExternalPower,
    required this.requiresNetworkConnectivity,
    required this.earliestDelay,
  });

  /// `BGProcessingTaskRequest.requiresExternalPower`.
  final bool requiresExternalPower;

  /// `BGProcessingTaskRequest.requiresNetworkConnectivity`.
  final bool requiresNetworkConnectivity;

  /// How far out `earliestBeginDate` is set from now.
  final Duration earliestDelay;

  @override
  bool operator ==(Object other) =>
      other is BackgroundTaskRequest &&
      other.requiresExternalPower == requiresExternalPower &&
      other.requiresNetworkConnectivity == requiresNetworkConnectivity &&
      other.earliestDelay == earliestDelay;

  @override
  int get hashCode => Object.hash(
        requiresExternalPower,
        requiresNetworkConnectivity,
        earliestDelay,
      );

  @override
  String toString() => 'BackgroundTaskRequest(power: $requiresExternalPower, '
      'network: $requiresNetworkConnectivity, after: $earliestDelay)';
}

abstract final class BackgroundTaskPlan {
  /// The identifier registered in `Info.plist` under
  /// `BGTaskSchedulerPermittedIdentifiers` and in `AppDelegate.swift`. It must
  /// match all three places exactly or iOS refuses the request.
  static const String transcribeTaskId =
      'com.ganeshsharma.voicenotetaker_app.transcribe';

  /// The floor on `earliestBeginDate`. Short enough that a phone put on the
  /// charger straight after a walk can be used tonight; long enough that
  /// leaving the app does not ask for a window the user would rather spend on
  /// opening the app themselves.
  static const Duration earliestDelay = Duration(minutes: 15);

  /// The request to make, or null when there is nothing worth asking for.
  static BackgroundTaskRequest? plan({
    required int pending,
    required bool modelReady,
  }) {
    if (pending <= 0 || !modelReady) return null;
    return const BackgroundTaskRequest(
      requiresExternalPower: true,
      requiresNetworkConnectivity: false,
      earliestDelay: earliestDelay,
    );
  }
}
