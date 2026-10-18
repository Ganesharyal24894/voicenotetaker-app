import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/firmware_update_state.dart';
import 'package:voicenotetaker_app/view/firmware/update_copy.dart';
import 'package:voicenotetaker_app/view/firmware/update_progress.dart';

import 'update_fakes.dart';

void main() {
  late DateTime now;
  late ValueNotifier<UpdateState> state;
  late UpdateProgress progress;

  setUp(() {
    now = DateTime(2026, 10, 18, 9);
    state = ValueNotifier<UpdateState>(const UpdateIdle());
    progress = UpdateProgress(state, now: () => now);
  });

  tearDown(() {
    progress.dispose();
    state.dispose();
  });

  void at(int seconds, int percent) {
    now = DateTime(2026, 10, 18, 9).add(Duration(seconds: seconds));
    state.value = UpdateTransferring(release020(), percent: percent);
  }

  test('no estimate below 10%, then one from the rate so far', () {
    at(0, 0);
    at(30, 9);
    expect(progress.remaining, isNull);
    at(40, 10);
    // 4 s a percent, 90% to go.
    expect(progress.remaining, const Duration(seconds: 360));
  });

  test('the rate is measured from where it was first seen', () {
    state.value = UpdateWaitingForBootloader(release020());
    at(0, 50);
    at(20, 60);
    expect(progress.remaining, const Duration(seconds: 80));
  });

  test('the last percent survives a failure, and a new run clears it', () {
    at(0, 0);
    at(10, 61);
    state.value = const UpdateFailed(UpdateFailure.transferFailed, canRetry: true);
    expect(progress.lastPercent, 61);
    expect(progress.remaining, isNull);

    state.value = UpdateWaitingForBootloader(release020());
    expect(progress.lastPercent, isNull);
  });

  test('time left is rounded up, in plain words', () {
    expect(UpdateCopy.timeLeft(const Duration(seconds: 40)),
        'Less than a minute left');
    expect(UpdateCopy.timeLeft(const Duration(seconds: 60)), 'About 1 minute left');
    expect(UpdateCopy.timeLeft(const Duration(seconds: 61)),
        'About 2 minutes left');
    expect(UpdateCopy.timeLeft(const Duration(seconds: 174)),
        'About 3 minutes left');
  });

  test('the published line drops the date when there is none', () {
    expect(UpdateCopy.published(release020()), 'Version 0.2.0, published 14 Oct');
  });
}
