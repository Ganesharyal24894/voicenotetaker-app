import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/controller/voices_controller.dart';
import 'package:voicenotetaker_app/model/enrolment_check.dart';
import 'package:voicenotetaker_app/model/voice_sample.dart';
import 'package:voicenotetaker_app/services/library_service.dart';
import 'package:voicenotetaker_app/services/voices/enrolment_service.dart';
import 'package:voicenotetaker_app/services/voices/voice_library.dart';
import 'package:voicenotetaker_app/services/voices/voiceprint_store.dart';

import '../view/harness.dart' show MemoryFileStore;
import 'voice_library_test.dart' show along, rec, voicesDir, voicesOf;

/// The recorder as the voices controller sees it: a take is a file, and the
/// link can be dropped by hand.
class FakeRecorder extends ChangeNotifier implements VoiceSampleRecorder {
  FakeRecorder(this.disk);

  final MemoryFileStore disk;
  String? path;
  bool connected = true;
  bool refuse = false;
  int stops = 0;
  bool _cut = false;

  @override
  bool get isConnected => connected;

  @override
  bool get voiceSampleInterrupted => _cut;

  void dropLink() {
    _cut = true;
    notifyListeners();
  }

  @override
  Future<bool> startVoiceSample(String path) async {
    if (refuse) return false;
    this.path = path;
    disk.files[path] = <int>[1, 2, 3];
    return true;
  }

  @override
  Future<VoiceSampleTake?> stopVoiceSample() async {
    stops++;
    final take = VoiceSampleTake(
      path: path!,
      audio: const Duration(seconds: 60),
      linkLost: _cut,
    );
    _cut = false;
    return take;
  }
}

/// Answers whatever verdict a test sets.
class FakeEnrolment implements EnrolmentService {
  bool ready = true;
  EnrolmentVerdict verdict = EnrolmentVerdict.ok(
    embedding: along(0),
    speech: const Duration(seconds: 58),
  );
  bool? lastLinkLost;

  @override
  Future<bool> modelsReady() async => ready;

  @override
  Future<EnrolmentVerdict> check(
    String path, {
    bool linkLost = false,
    void Function(double fraction)? onProgress,
  }) async {
    lastLinkLost = linkLost;
    onProgress?.call(0.5);
    if (linkLost) {
      return const EnrolmentVerdict.retry(EnrolmentProblem.linkLost);
    }
    return verdict;
  }
}

void main() {
  late MemoryFileStore disk;
  late FakeRecorder recorder;
  late FakeEnrolment enrolment;
  late VoiceLibrary library;
  late VoicesController voices;
  late DateTime now;
  late List<EnrolmentState> states;
  final tv = '$rec/voicenote-20261018-090000.wav';

  setUp(() async {
    disk = MemoryFileStore();
    recorder = FakeRecorder(disk);
    enrolment = FakeEnrolment();
    now = DateTime(2026, 10, 18, 10, 15);
    library = VoiceLibrary(
      fileStore: disk,
      recordingsDirectory: rec,
      store: VoiceprintStore(fileStore: disk, directory: voicesDir),
      clock: () => now,
    );
    voices = VoicesController(
      library: library,
      enrolment: enrolment,
      recorder: recorder,
      fileStore: disk,
      voicesDirectory: voicesDir,
      clock: () => now,
      tick: const Duration(milliseconds: 5),
    );
    states = <EnrolmentState>[];
    voices.addListener(() {
      if (states.isEmpty || states.last != voices.enrolment) {
        states.add(voices.enrolment);
      }
    });
    await library.noteHeard(tv, voicesOf(<(String, int)>[('S1', 5)]));
    await voices.load();
  });

  tearDown(() async {
    voices.dispose();
    await library.dispose();
  });

  group('before recording', () {
    test('no recorder: blocked, with Connect to offer', () async {
      recorder.connected = false;

      await voices.startEnrolment();

      final state = voices.enrolment as EnrolmentBlocked;
      expect(state.reason, EnrolmentBlock.notConnected);
      expect(recorder.path, isNull);
    });

    test('no speaker pack: blocked, with the download to offer', () async {
      enrolment.ready = false;

      await voices.prepare();

      expect(
        (voices.enrolment as EnrolmentBlocked).reason,
        EnrolmentBlock.modelsMissing,
      );
    });

    test('everything there: the intro', () async {
      await voices.prepare();

      expect(voices.enrolment, isA<EnrolmentIdle>());
    });
  });

  group('recording', () {
    test('records into voices/, and Done is offered from 45 s', () async {
      await voices.startEnrolment();

      expect(recorder.path, startsWith('$voicesDir/enrol-'));
      expect(recorder.path, endsWith('.wav'));
      expect((voices.enrolment as EnrolmentRecording).canFinish, isFalse);

      now = now.add(const Duration(seconds: 46));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final state = voices.enrolment as EnrolmentRecording;
      expect(state.elapsed, const Duration(seconds: 46));
      expect(state.canFinish, isTrue);
    });

    test('a good take: checking, then done, then past notes matched again',
        () async {
      disk.files['$voicesDir/enrol-1.wav'] = <int>[9];
      await voices.startEnrolment();
      final take = recorder.path!;

      await voices.finishEnrolment();

      expect(states.whereType<EnrolmentChecking>(), isNotEmpty);
      expect(voices.enrolment, isA<EnrolmentDone>());
      expect(voices.isEnrolled, isTrue);
      expect(voices.enrolledAt, now);
      expect(disk.files.keys, contains(take), reason: 'the WAV is kept');
      expect(disk.files.keys, isNot(contains('$voicesDir/enrol-1.wav')));
      expect(voices.backgroundCount, 1);
      expect(voices.rematchProgress, isNull);
      expect(
        disk.files.keys,
        contains(RecordingNaming.backgroundPathOf(tv)),
      );
    });

    test('too short: retry with the reason, and the take is thrown away',
        () async {
      enrolment.verdict = const EnrolmentVerdict.retry(
        EnrolmentProblem.tooShort,
        speech: Duration(seconds: 20),
      );
      await voices.startEnrolment();
      final take = recorder.path!;

      await voices.finishEnrolment();

      final state = voices.enrolment as EnrolmentRetry;
      expect(state.verdict.problem, EnrolmentProblem.tooShort);
      expect(state.verdict.speech, const Duration(seconds: 20));
      expect(voices.isEnrolled, isFalse);
      expect(disk.files.keys, isNot(contains(take)));
    });

    test('the link dropping ends it at once, as link lost', () async {
      await voices.startEnrolment();

      recorder.dropLink();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(recorder.stops, 1);
      expect(enrolment.lastLinkLost, isTrue);
      expect(
        (voices.enrolment as EnrolmentRetry).verdict.problem,
        EnrolmentProblem.linkLost,
      );
    });

    test('a recorder that will not start is a retry, not a hang', () async {
      recorder.refuse = true;

      await voices.startEnrolment();

      expect(voices.enrolment, isA<EnrolmentRetry>());
    });

    test('cancel keeps nothing', () async {
      await voices.startEnrolment();
      final take = recorder.path!;

      await voices.cancelEnrolment();

      expect(voices.enrolment, isA<EnrolmentIdle>());
      expect(disk.files.keys, isNot(contains(take)));
      expect(voices.isEnrolled, isFalse);
    });
  });

  group('after enrolment', () {
    setUp(() async {
      await voices.startEnrolment();
      await voices.finishEnrolment();
    });

    test('remove my voice: notes go back to showing everything', () async {
      await voices.removeMyVoice();

      expect(voices.isEnrolled, isFalse);
      expect(voices.backgroundCount, 0);
      expect(
        disk.files.keys.where((p) => p.startsWith('$voicesDir/enrol-')),
        isEmpty,
      );
    });

    test('naming someone lists them and brings their notes back', () async {
      final id = await voices.tag(tv, 'S1', name: 'Priya');

      expect(voices.people.map((p) => p.name), <String?>['Priya']);
      expect(voices.backgroundCount, 0);

      await voices.rename(id!, 'Priya S');
      expect(voices.people.single.name, 'Priya S');

      await voices.untag(tv, 'S1');
      expect(voices.people, isEmpty);
      expect(voices.backgroundCount, 1);
    });

    test('forgetting someone hides their notes again', () async {
      final id = await voices.tag(tv, 'S1', name: 'Priya');

      await voices.forget(id!);

      expect(voices.people, isEmpty);
      expect(voices.backgroundCount, 1);
    });

    test('"Show in notes" brings one note back', () async {
      await voices.keep(tv, true);

      expect(voices.backgroundCount, 0);
    });
  });
}
