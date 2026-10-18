import 'package:flutter/foundation.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/model/firmware_update.dart';
import 'package:voicenotetaker_app/model/firmware_update_state.dart';
import 'package:voicenotetaker_app/services/firmware/firmware_update_service.dart';

/// The update service as the screens see it: a state the test sets, a
/// decision the test sets, and counts of what the screens asked for.
class FakeUpdates extends Fake implements FirmwareUpdateService {
  FakeUpdates({
    UpdateState state = const UpdateIdle(),
    this.decision = const UpdateNone(),
    this.installedVersion,
    this.latestRelease,
  }) : _state = ValueNotifier<UpdateState>(state);

  final ValueNotifier<UpdateState> _state;

  @override
  UpdateDecision decision;

  @override
  FirmwareVersion? installedVersion;

  @override
  FirmwareRelease? latestRelease;

  int installs = 0;
  int retries = 0;
  int dismissals = 0;

  @override
  ValueListenable<UpdateState> get state => _state;

  /// Sets the state, and with it whatever the decision now is.
  void emit(UpdateState next, {UpdateDecision? decision}) {
    if (decision != null) this.decision = decision;
    _state.value = next;
  }

  @override
  Future<void> install() async => installs++;

  @override
  Future<void> retry() async => retries++;

  @override
  void dismiss() => dismissals++;
}

FirmwareVersion v(String text) => FirmwareVersion.tryParse(text)!;

/// 0.2.0, published 14 Oct, with the canvas's notes.
FirmwareRelease release020({String notes = canvasNotes}) => FirmwareRelease(
      version: v('0.2.0'),
      zipName: 'voiceNotetaker-0.2.0.zip',
      zipUrl: 'https://example.test/voiceNotetaker-0.2.0.zip',
      sha256: '00',
      sizeBytes: 200000,
      publishedAt: DateTime(2026, 10, 14, 12),
      notes: notes,
    );

const String canvasNotes = 'Quieter speech is picked up more reliably. The '
    'battery estimate settles faster after a charge.';

/// A recorder on 0.1.0, connected and on its charger, with 0.2.0 out.
FakeUpdates offered() {
  final release = release020();
  return FakeUpdates(
    state: UpdateAvailable(release),
    decision: UpdateOffered(release),
    installedVersion: v('0.1.0'),
    latestRelease: release,
  );
}

/// The same, with [reason] in the way.
FakeUpdates blocked(UpdateBlockReason reason) {
  final release = release020();
  return FakeUpdates(
    state: UpdateAvailable(release, blockedBy: reason),
    decision: UpdateBlocked(release, reason),
    installedVersion:
        reason == UpdateBlockReason.unknownVersion ? null : v('0.1.0'),
    latestRelease: release,
  );
}
