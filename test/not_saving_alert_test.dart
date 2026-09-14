import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/continuous_status.dart';
import 'package:voicenotetaker_app/model/not_saving_alert.dart';
import 'package:voicenotetaker_app/model/notes_saving.dart';

/// When the phone buzzes about notes not being saved - the pure rules.
void main() {
  final t0 = DateTime.utc(2026, 9, 15, 9);
  DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

  group('NotesSaving.from', () {
    test('saving, muted, off and not saving each map to their own state', () {
      expect(NotesSaving.from(ContinuousStatus.off), NotesSaving.off);
      expect(NotesSaving.from(ContinuousStatus.listening), NotesSaving.saving);
      expect(NotesSaving.from(ContinuousStatus.hearingSpeech), NotesSaving.saving);
      expect(NotesSaving.from(ContinuousStatus.muted), NotesSaving.muted);
      expect(NotesSaving.from(ContinuousStatus.micOff), NotesSaving.micOff);
      expect(NotesSaving.from(ContinuousStatus.needsFirmwareUpdate), NotesSaving.needsUpdate);
      expect(NotesSaving.from(ContinuousStatus.notConnected), NotesSaving.disconnected);
    });

    test('an SD-card recorder away from the phone is still saving', () {
      final away = NotesSaving.from(
        ContinuousStatus.notConnected,
        storage: RecorderStorage.card,
      );
      expect(away, NotesSaving.savingOnRecorder);
      expect(away.isSaving, isTrue);
      expect(away.isLosingNotes, isFalse);
    });

    test('only lost notes the wearer did not choose count as losing', () {
      expect(
        NotesSaving.values.where((s) => s.isLosingNotes).toSet(),
        <NotesSaving>{
          NotesSaving.micOff,
          NotesSaving.disconnected,
          NotesSaving.needsUpdate,
          NotesSaving.pairedToAnother,
          NotesSaving.oldPairing,
        },
      );
    });
  });

  group('NotSavingAlertPolicy', () {
    test('nothing for the first 30 s, then one alert', () {
      final policy = NotSavingAlertPolicy();
      expect(policy.update(NotesSaving.disconnected, at(0)), NotSavingAction.none);
      expect(policy.nextCheck(), at(30));
      expect(policy.update(NotesSaving.disconnected, at(29)), NotSavingAction.none);
      expect(policy.update(NotesSaving.disconnected, at(30)), NotSavingAction.alert);
      expect(policy.alerting, isTrue);
      expect(policy.nextCheck(), isNull, reason: 'nothing more to wait for');
      expect(policy.update(NotesSaving.disconnected, at(300)), NotSavingAction.none,
          reason: 'one alert per episode');
    });

    test('a link back inside the grace period is not news', () {
      final policy = NotSavingAlertPolicy();
      policy.update(NotesSaving.disconnected, at(0));
      expect(policy.update(NotesSaving.saving, at(20)), NotSavingAction.none);
      expect(policy.nextCheck(), isNull);
      // The clock starts again with the next drop.
      policy.update(NotesSaving.disconnected, at(25));
      expect(policy.update(NotesSaving.disconnected, at(50)), NotSavingAction.none);
      expect(policy.update(NotesSaving.disconnected, at(55)), NotSavingAction.alert);
    });

    test('saving again after an alert buzzes once, short', () {
      final policy = NotSavingAlertPolicy();
      policy.update(NotesSaving.disconnected, at(0));
      policy.update(NotesSaving.disconnected, at(30));
      expect(policy.update(NotesSaving.saving, at(60)), NotSavingAction.resumed);
      expect(policy.alerting, isFalse);
      expect(policy.update(NotesSaving.saving, at(90)), NotSavingAction.none);
    });

    test('flapping buzzes at most once per 10 min; the rest are silent', () {
      final policy = NotSavingAlertPolicy();
      policy.update(NotesSaving.disconnected, at(0));
      expect(policy.update(NotesSaving.disconnected, at(30)), NotSavingAction.alert);
      expect(policy.update(NotesSaving.saving, at(40)), NotSavingAction.resumed);
      policy.update(NotesSaving.disconnected, at(100));
      expect(policy.update(NotesSaving.disconnected, at(130)), NotSavingAction.alertSilently);
      expect(policy.update(NotesSaving.saving, at(140)), NotSavingAction.cleared,
          reason: 'no resume buzz for an alert that did not buzz');
      policy.update(NotesSaving.micOff, at(600));
      expect(policy.update(NotesSaving.micOff, at(630)), NotSavingAction.alert,
          reason: '10 min after the last buzz');
    });

    test('muted is the wearer\'s choice: never an alert, and it ends one silently',
        () {
      final policy = NotSavingAlertPolicy();
      expect(policy.update(NotesSaving.muted, at(0)), NotSavingAction.none);
      expect(policy.update(NotesSaving.muted, at(600)), NotSavingAction.none);
      expect(policy.nextCheck(), isNull);

      policy.update(NotesSaving.disconnected, at(700));
      policy.update(NotesSaving.disconnected, at(730));
      expect(policy.update(NotesSaving.muted, at(740)), NotSavingAction.cleared);
    });

    test('always listening off: never an alert, and it ends one silently', () {
      final policy = NotSavingAlertPolicy();
      expect(policy.update(NotesSaving.off, at(0)), NotSavingAction.none);
      expect(policy.update(NotesSaving.off, at(3600)), NotSavingAction.none);
      policy.update(NotesSaving.needsUpdate, at(3600));
      policy.update(NotesSaving.needsUpdate, at(3630));
      expect(policy.update(NotesSaving.off, at(3631)), NotSavingAction.cleared);
    });

    test('an SD recorder away from the phone never alerts', () {
      final policy = NotSavingAlertPolicy();
      expect(policy.update(NotesSaving.savingOnRecorder, at(0)), NotSavingAction.none);
      expect(policy.update(NotesSaving.savingOnRecorder, at(3600)), NotSavingAction.none);
    });

    test('changing reason mid-episode does not restart the clock', () {
      final policy = NotSavingAlertPolicy();
      policy.update(NotesSaving.micOff, at(0));
      expect(policy.update(NotesSaving.disconnected, at(15)), NotSavingAction.none);
      expect(policy.update(NotesSaving.disconnected, at(30)), NotSavingAction.alert);
    });
  });
}
