import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/disk_space.dart';
import 'package:voicenotetaker_app/drivers/download_client.dart';
import 'package:voicenotetaker_app/drivers/file_store.dart';
import 'package:voicenotetaker_app/drivers/hashing.dart';
import 'package:voicenotetaker_app/drivers/hashing_crypto.dart';
import 'package:voicenotetaker_app/drivers/network_status.dart';
import 'package:voicenotetaker_app/model/model_download.dart';
import 'package:voicenotetaker_app/model/transcription.dart';
import 'package:voicenotetaker_app/services/transcription/model_download_service.dart';
import 'package:voicenotetaker_app/services/transcription/speech_model_store.dart';

/// The downloader, with no socket and no filesystem anywhere near it.
///
/// Everything a 197 MB download can do wrong on a phone happens here in
/// milliseconds: the connection dies half way, the app is killed, the disk is
/// full, the bytes arrive corrupt, the user is on mobile data, the user
/// changes their mind.
void main() {
  late _MemoryStore files;
  late _FakeClient client;
  late SpeechModelStore models;

  /// Every backoff the service asked for, in order. Nothing sleeps: the test
  /// reads the schedule instead of living through it.
  late List<Duration> waits;

  setUp(() {
    files = _MemoryStore();
    client = _FakeClient();
    models = SpeechModelStore(fileStore: files, modelsDirectory: '/models');
    waits = <Duration>[];
  });

  ModelDownloadService build({
    NetworkStatus network = const FixedNetworkStatus(NetworkKind.unmetered),
    DiskSpace diskSpace = const FixedDiskSpace(),
    Hashing? hashing,
    DownloadRetryPolicy retry = const DownloadRetryPolicy(maxAttempts: 3),
    int headroomBytes = 0,
    Future<void> Function(Duration)? delay,
  }) =>
      ModelDownloadService(
        fileStore: files,
        models: models,
        client: client,
        hashing: hashing ?? const CryptoHashing(),
        network: network,
        diskSpace: diskSpace,
        catalogue: <ModelRelease>[_release],
        delay: delay ??
            (Duration duration) async {
              waits.add(duration);
            },
        retry: retry,
        // The middle of the jitter, so the numbers in a test are the numbers
        // in the policy.
        roll: () => 0.5,
        headroomBytes: headroomBytes,
        progressStepBytes: 0,
      );

  group('a clean install', () {
    test('every file lands under the name the engine loads', () async {
      client.serve(_release);
      final service = build();

      await service.download(_release);

      expect(files.bytes['/models/test-set/one.bin'], _one);
      expect(files.bytes['/models/test-set/two.bin'], _two);
      expect(service.statusOf(_release).state, ModelInstallState.installed);
      expect(service.statusOf(_release).progress, 1);
    });

    test('nothing is left behind under a .part name', () async {
      client.serve(_release);
      await build().download(_release);

      expect(
        files.bytes.keys.where((p) => p.endsWith('.part')),
        isEmpty,
      );
    });

    test('the states go missing -> downloading -> verifying -> installed',
        () async {
      client.serve(_release);
      final service = build();
      final seen = <ModelInstallState>[];
      service.changes.listen((s) => seen.add(s.state));

      expect(service.statusOf(_release).state, ModelInstallState.notInstalled);
      await service.download(_release);
      await pumpEventQueue();

      expect(seen.first, ModelInstallState.downloading);
      expect(seen, contains(ModelInstallState.verifying));
      expect(seen.last, ModelInstallState.installed);
      // It never claims to be installed before it has been verified.
      expect(
        seen.indexOf(ModelInstallState.verifying),
        lessThan(seen.lastIndexOf(ModelInstallState.installed)),
      );
    });

    test('progress only ever goes up, and ends at the whole set', () async {
      client.serve(_release);
      final service = build();
      final progress = <int>[];
      service.changes.listen((s) => progress.add(s.bytesDone));

      await service.download(_release);
      await pumpEventQueue();

      expect(progress, isNotEmpty);
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
      }
      expect(progress.last, _release.totalBytes);
    });

    test('a file already installed is not fetched again', () async {
      client.serve(_release);
      files.put('/models/test-set/one.bin', _one);
      final service = build();

      await service.download(_release);

      expect(client.requests.map((r) => r.url), <String>['url://two']);
      expect(service.statusOf(_release).isInstalled, isTrue);
    });

    test('a set that is already there installs without a request', () async {
      files.put('/models/test-set/one.bin', _one);
      files.put('/models/test-set/two.bin', _two);
      final service = build();

      await service.download(_release);

      expect(client.requests, isEmpty);
      expect(service.statusOf(_release).isInstalled, isTrue);
    });
  });

  group('resuming', () {
    test('a .part file left by a kill is resumed with a Range request',
        () async {
      client.serve(_release);
      // The app died with the first 30 bytes of `one.bin` on disk.
      files.put('/models/test-set/one.bin.part', _one.sublist(0, 30));
      final service = build();

      await service.download(_release);

      expect(client.requests.first.url, 'url://one');
      expect(client.requests.first.from, 30);
      expect(files.bytes['/models/test-set/one.bin'], _one);
      expect(service.statusOf(_release).isInstalled, isTrue);
    });

    test('a .part file longer than the file is thrown away, not resumed',
        () async {
      client.serve(_release);
      files.put('/models/test-set/one.bin.part', Uint8List(_one.length + 5));
      final service = build();

      await service.download(_release);

      expect(client.requests.first.from, 0, reason: 'starts again from zero');
      expect(files.bytes['/models/test-set/one.bin'], _one);
    });

    test('a complete .part file is verified and installed, not re-fetched',
        () async {
      client.serve(_release);
      files.put('/models/test-set/one.bin.part', _one);
      final service = build();

      await service.download(_release);

      expect(client.requests.map((r) => r.url), <String>['url://two']);
      expect(files.bytes['/models/test-set/one.bin'], _one);
    });

    test('a connection that breaks half way is retried from where it stopped',
        () async {
      client.serve(_release);
      client.breakAfter['url://one'] = 40;
      final service = build();

      await service.download(_release);

      final forOne =
          client.requests.where((r) => r.url == 'url://one').toList();
      expect(forOne, hasLength(2));
      expect(forOne.first.from, 0);
      expect(forOne.last.from, 40, reason: 'carries on, does not start again');
      expect(files.bytes['/models/test-set/one.bin'], _one);
      expect(service.statusOf(_release).isInstalled, isTrue);
    });

    test('a server that ignores the Range and sends the lot is still handled',
        () async {
      client.serve(_release);
      files.put('/models/test-set/one.bin.part', _one.sublist(0, 30));
      client.ignoreRange.add('url://one');
      final service = build();

      await service.download(_release);

      expect(files.bytes['/models/test-set/one.bin'], _one,
          reason: 'the 30 bytes were dropped rather than doubled up');
    });

    test('it gives up after the attempts are used, with a friendly line',
        () async {
      client.serve(_release);
      client.breakAfter['url://one'] = 10;
      client.breakForever.add('url://one');
      final service = build(retry: const DownloadRetryPolicy(maxAttempts: 3));

      await service.download(_release);

      final status = service.statusOf(_release);
      expect(status.state, ModelInstallState.failed);
      expect(status.failure!.problem, ModelDownloadProblem.network);
      expect(status.failure!.message, contains('Try again'));
      expect(files.bytes.containsKey('/models/test-set/one.bin'), isFalse);
      expect(files.bytes['/models/test-set/one.bin.part'], isNotNull,
          reason: 'what arrived is kept, so Retry carries on');
    });
  });

  group('what arrived is checked before it becomes a model', () {
    test('a wrong sha256 throws the file away and says so plainly', () async {
      client.serve(_release);
      client.files['url://one'] = Uint8List.fromList(
        List<int>.filled(_one.length, 7),
      );
      final service = build();

      await service.download(_release);

      final status = service.statusOf(_release);
      expect(status.state, ModelInstallState.failed);
      expect(status.failure!.problem, ModelDownloadProblem.corrupt);
      expect(status.failure!.message, contains('did not arrive intact'));
      expect(files.bytes.containsKey('/models/test-set/one.bin.part'), isFalse,
          reason: 'corrupt bytes are not kept and not resumed');
      expect(files.bytes.containsKey('/models/test-set/one.bin'), isFalse);
    });

    test('the right bytes at the wrong length are refused too', () async {
      client.serve(_release);
      client.files['url://one'] = Uint8List.fromList(<int>[..._one, 9]);
      final service = build();

      await service.download(_release);

      expect(service.statusOf(_release).failure!.problem,
          ModelDownloadProblem.corrupt);
    });
  });

  group('before the first byte', () {
    test('a full disk fails early, in megabytes, and asks for nothing',
        () async {
      client.serve(_release);
      final service = build(
        diskSpace: const FixedDiskSpace(10),
        headroomBytes: 1000,
      );

      await service.download(_release);

      final status = service.statusOf(_release);
      expect(status.state, ModelInstallState.failed);
      expect(status.failure!.problem, ModelDownloadProblem.notEnoughSpace);
      expect(status.failure!.message, contains('Free about'));
      expect(client.requests, isEmpty, reason: 'nothing was even asked for');
    });

    test('a disk that will not say lets the download run', () async {
      client.serve(_release);
      final service = build(diskSpace: const FixedDiskSpace());

      await service.download(_release);

      expect(service.statusOf(_release).isInstalled, isTrue);
    });

    test('only what is still to come counts against the free space', () async {
      client.serve(_release);
      files.put('/models/test-set/one.bin', _one);
      // Room for `two.bin` alone, not for the pair.
      final service = build(diskSpace: FixedDiskSpace(_two.length));

      await service.download(_release);

      expect(service.statusOf(_release).isInstalled, isTrue);
    });
  });

  group('Wi-Fi only, unless the user says otherwise', () {
    test('mobile data is refused by default, before any request', () async {
      client.serve(_release);
      final service =
          build(network: const FixedNetworkStatus(NetworkKind.metered));

      await service.download(_release);

      final status = service.statusOf(_release);
      expect(status.state, ModelInstallState.failed);
      expect(status.failure!.problem, ModelDownloadProblem.needsWifi);
      expect(client.requests, isEmpty);
    });

    test('mobile data is used when the user has allowed it', () async {
      client.serve(_release);
      final service =
          build(network: const FixedNetworkStatus(NetworkKind.metered));

      await service.download(_release, allowMobileData: true);

      expect(service.statusOf(_release).isInstalled, isTrue);
    });

    test('no network at all is its own message', () async {
      client.serve(_release);
      final service =
          build(network: const FixedNetworkStatus(NetworkKind.none));

      await service.download(_release, allowMobileData: true);

      expect(service.statusOf(_release).failure!.problem,
          ModelDownloadProblem.offline);
    });

    test('a phone that cannot report its radio is allowed to download',
        () async {
      client.serve(_release);
      final service =
          build(network: const FixedNetworkStatus(NetworkKind.unknown));

      await service.download(_release);

      expect(service.statusOf(_release).isInstalled, isTrue);
    });
  });

  group('stopping', () {
    test('a cancel half way keeps what arrived and installs nothing',
        () async {
      client.serve(_release);
      final gate = client.holdAfterFirstChunk('url://one');
      final service = build();

      final running = service.download(_release);
      await client.firstChunkSent.future;
      // `cancel` waits for the job to stop, so the body has to be let go
      // before it can complete.
      final cancelled = service.cancel(_release);
      gate.complete();
      await running;
      await cancelled;

      expect(files.bytes.containsKey('/models/test-set/one.bin'), isFalse);
      expect(files.bytes['/models/test-set/one.bin.part'], isNotNull);
      final status = service.statusOf(_release);
      expect(status.state, ModelInstallState.notInstalled);
      expect(status.failure, isNull, reason: 'a cancel is not a failure');
    });

    test('asking again after a cancel carries on from there', () async {
      client.serve(_release);
      final gate = client.holdAfterFirstChunk('url://one');
      final service = build();

      final running = service.download(_release);
      await client.firstChunkSent.future;
      final cancelled = service.cancel(_release);
      gate.complete();
      await running;
      await cancelled;
      final got = files.bytes['/models/test-set/one.bin.part']!.length;

      await service.download(_release);

      expect(client.requests.last.url, 'url://two');
      expect(
        client.requests.firstWhere((r) => r.url == 'url://one' && r.from > 0)
            .from,
        got,
      );
      expect(service.statusOf(_release).isInstalled, isTrue);
    });

    test('two downloads of one set never run at once', () async {
      client.serve(_release);
      final gate = client.holdAfterFirstChunk('url://one');
      final service = build();

      final first = service.download(_release);
      await client.firstChunkSent.future;
      await service.download(_release); // returns at once, starts nothing
      gate.complete();
      await first;

      final starts =
          client.requests.where((r) => r.url == 'url://one' && r.from == 0);
      expect(starts, hasLength(1));
    });

    test('going off screen pauses, and coming back carries on', () async {
      client.serve(_release);
      final gate = client.holdAfterFirstChunk('url://one');
      final service = build();

      final running = service.download(_release);
      await client.firstChunkSent.future;
      service.pauseAll();
      gate.complete();
      await running;

      final paused = service.statusOf(_release);
      expect(paused.state, ModelInstallState.downloading);
      expect(paused.paused, isTrue, reason: 'not a failure, and not a cancel');
      expect(paused.failure, isNull);

      await service.resumeAll();
      await pumpEventQueue();

      expect(service.statusOf(_release).isInstalled, isTrue);
    });

    test('a cancel clears a pause, so opening the app does not restart it',
        () async {
      client.serve(_release);
      final gate = client.holdAfterFirstChunk('url://one');
      final service = build();

      final running = service.download(_release);
      await client.firstChunkSent.future;
      service.pauseAll();
      gate.complete();
      await running;
      await service.cancel(_release);

      final before = client.requests.length;
      await service.resumeAll();
      await pumpEventQueue();

      expect(client.requests, hasLength(before));
    });
  });

  group('making room again', () {
    test('delete removes every file and the part files with them', () async {
      client.serve(_release);
      final service = build();
      await service.download(_release);
      files.put('/models/test-set/two.bin.part', Uint8List(3));

      await service.remove(_release);

      expect(
        files.bytes.keys.where((p) => p.startsWith('/models/test-set/')),
        isEmpty,
      );
      expect(service.statusOf(_release).state, ModelInstallState.notInstalled);
      expect(service.installedBytes, 0);
    });

    test('installedBytes is what the installed sets take up', () async {
      client.serve(_release);
      final service = build();
      expect(service.installedBytes, 0);

      await service.download(_release);

      expect(service.installedBytes, _release.totalBytes);
    });
  });

  group('looking at the disk', () {
    test('refresh finds a set pushed in by cable', () async {
      final service = build();
      files.put('/models/test-set/one.bin', _one);
      files.put('/models/test-set/two.bin', _two);

      await service.refresh();

      expect(service.statusOf(_release).isInstalled, isTrue);
    });

    test('a half-pushed set reads as not installed, with its bytes counted',
        () async {
      final service = build();
      files.put('/models/test-set/one.bin', _one);

      await service.refresh();

      final status = service.statusOf(_release);
      expect(status.state, ModelInstallState.notInstalled);
      expect(status.bytesDone, _one.length);
    });

    test('a truncated file is not mistaken for a model', () async {
      final service = build();
      files.put('/models/test-set/one.bin', _one.sublist(0, 10));
      files.put('/models/test-set/two.bin', _two);

      await service.refresh();

      expect(service.statusOf(_release).isInstalled, isFalse);
    });
  });

  group('the store the loader and the downloader share', () {
    test('both look in the same directory', () {
      expect(models.releaseDirectory(_release), '/models/test-set');
      expect(
        models.directoryFor(SpeechModels.indicConformerHindiInt8),
        models.directoryNamed('indicconformer-hi-int8'),
      );
    });

    test('a part file is beside the real one and named nothing loads',
        () async {
      final part = models.partPathOf(_release, _release.files.first);
      expect(part, '/models/test-set/one.bin.part');
      expect(part.endsWith('.bin'), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // The cold CDN. A release asset nobody has fetched yet answered 504 over
  // and over on a real phone and only served bytes after about a minute.
  // -------------------------------------------------------------------------

  group('the retry policy, on its own', () {
    const policy = DownloadRetryPolicy.standard;

    test('the wait doubles from a second and stops at the ceiling', () {
      final seconds = <int>[
        for (var attempt = 1; attempt < policy.maxAttempts; attempt++)
          policy.delayFor(attempt).inSeconds,
      ];

      expect(seconds, <int>[1, 2, 4, 8, 16, 20, 20, 20]);
    });

    test('the jitter never leaves a fifth either side of the wait', () {
      for (var attempt = 1; attempt < policy.maxAttempts; attempt++) {
        final nominal = policy.delayFor(attempt).inMicroseconds;
        final shortest = policy.delayFor(attempt, roll: 0).inMicroseconds;
        final longest = policy.delayFor(attempt, roll: 1).inMicroseconds;

        expect(shortest, (nominal * 0.8).round());
        expect(longest, (nominal * 1.2).round());
        for (final roll in <double>[0, 0.1, 0.37, 0.5, 0.9, 1]) {
          final delay = policy.delayFor(attempt, roll: roll).inMicroseconds;
          expect(delay, inInclusiveRange(shortest, longest));
        }
      }
      // A roll outside 0..1 cannot widen it.
      expect(policy.delayFor(1, roll: 9), policy.delayFor(1, roll: 1));
      expect(policy.delayFor(1, roll: -9), policy.delayFor(1, roll: 0));
    });

    test('it outlasts the minute that was measured, and stops under two', () {
      var nominal = Duration.zero;
      for (var attempt = 1; attempt < policy.maxAttempts; attempt++) {
        nominal += policy.delayFor(attempt);
      }

      expect(nominal, const Duration(seconds: 91));
      expect(policy.longestTotalWait,
          greaterThan(const Duration(seconds: 60)),
          reason: 'the observed warm-up has to fit inside it');
      expect(policy.longestTotalWait,
          lessThanOrEqualTo(const Duration(minutes: 2)),
          reason: 'past two minutes a person would rather be told');
    });

    test('a server that names a wait gets that wait, un-jittered', () {
      expect(
        policy.delayFor(1, roll: 1, retryAfter: const Duration(seconds: 7)),
        const Duration(seconds: 7),
      );
      expect(
        policy.delayFor(6, roll: 0, retryAfter: const Duration(seconds: 7)),
        const Duration(seconds: 7),
        reason: 'it beats the guess whichever attempt this is',
      );
    });

    test('a server that asks for an hour is not waited for', () {
      expect(
        policy.delayFor(1, retryAfter: const Duration(hours: 1)),
        policy.maxServerDelay,
      );
      expect(
        policy.delayFor(1, retryAfter: Duration.zero),
        Duration.zero,
      );
    });

    test('only the transient statuses are worth asking again about', () {
      for (final status in <int>[408, 425, 429, 500, 502, 503, 504]) {
        expect(policy.shouldRetryStatus(status), isTrue, reason: '$status');
        expect(policy.shouldRetry(status), isTrue, reason: '$status');
      }
      for (final status in <int>[200, 206, 400, 401, 403, 404, 410, 416, 451]) {
        expect(policy.shouldRetryStatus(status), isFalse, reason: '$status');
        expect(policy.shouldRetry(status), isFalse, reason: '$status');
      }
    });

    test('anything that never became a status is the wire, so it retries', () {
      expect(policy.shouldRetry(const DownloadException('socket closed')),
          isTrue);
      expect(policy.shouldRetry(TimeoutException('no answer')), isTrue);
    });

    test('there is a last attempt, and it does not wait after it', () {
      expect(policy.canRetry(policy.maxAttempts - 1), isTrue);
      expect(policy.canRetry(policy.maxAttempts), isFalse);
      expect(policy.delayFor(0), Duration.zero);
    });
  });

  group('Retry-After, as the header actually arrives', () {
    final now = DateTime.utc(2026, 9, 18, 12);

    test('a number is seconds', () {
      expect(parseRetryAfter('7'), const Duration(seconds: 7));
      expect(parseRetryAfter('  7 '), const Duration(seconds: 7));
      expect(parseRetryAfter('0'), Duration.zero);
      expect(parseRetryAfter('-3'), Duration.zero);
    });

    test('a date is how long until it', () {
      expect(
        parseRetryAfter('Fri, 18 Sep 2026 12:00:30 GMT', now: now),
        const Duration(seconds: 30),
      );
      expect(
        parseRetryAfter('Fri, 18 Sep 2026 11:59:00 GMT', now: now),
        Duration.zero,
        reason: 'a date already past means go ahead',
      );
    });

    test('a header that makes no sense is no header at all', () {
      expect(parseRetryAfter(null), isNull);
      expect(parseRetryAfter(''), isNull);
      expect(parseRetryAfter('   '), isNull);
      expect(parseRetryAfter('soon'), isNull);
    });
  });

  group('a cold CDN', () {
    test('504 after 504 is waited out, not given up on', () async {
      client.serve(_release);
      client.statuses['url://one'] = <int>[504, 504, 504, 504];
      final service = build(retry: DownloadRetryPolicy.standard);

      await service.download(_release);

      expect(service.statusOf(_release).isInstalled, isTrue);
      expect(
        client.requests.where((r) => r.url == 'url://one'), 
        hasLength(5),
      );
      expect(waits, <Duration>[
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 4),
        const Duration(seconds: 8),
      ]);
    });

    test('the old three tries in seven seconds would have missed it', () {
      // The shape of the bug, as a number: the whole of the old schedule is
      // spent inside the warm-up that was measured.
      const old = DownloadRetryPolicy(maxAttempts: 3, jitterFraction: 0);
      var total = Duration.zero;
      for (var attempt = 1; attempt < old.maxAttempts; attempt++) {
        total += old.delayFor(attempt);
      }

      expect(total, lessThan(const Duration(seconds: 10)));
      expect(DownloadRetryPolicy.standard.longestTotalWait,
          greaterThan(total * 6));
    });

    test('every wait fits inside two minutes, even at the last try', () async {
      client.serve(_release);
      // A gateway that never wakes up: every one of the tries is used.
      client.statuses['url://one'] = List<int>.filled(
        DownloadRetryPolicy.standard.maxAttempts,
        504,
      );
      final service = build(retry: DownloadRetryPolicy.standard);

      await service.download(_release);

      expect(service.statusOf(_release).state, ModelInstallState.failed);
      expect(service.statusOf(_release).failure!.detail, contains('attempts'));
      expect(waits, hasLength(DownloadRetryPolicy.standard.maxAttempts - 1));
      expect(
        waits.fold<Duration>(Duration.zero, (sum, wait) => sum + wait),
        lessThanOrEqualTo(const Duration(minutes: 2)),
      );
    });

    test('a 503 that names its own wait is obeyed', () async {
      client.serve(_release);
      client.statuses['url://one'] = <int>[503];
      client.retryAfter['url://one'] = const Duration(seconds: 7);
      final service = build(retry: DownloadRetryPolicy.standard);

      await service.download(_release);

      expect(waits, <Duration>[const Duration(seconds: 7)]);
      expect(service.statusOf(_release).isInstalled, isTrue);
    });

    test('404 stops at once: waiting will not make the file exist', () async {
      client.serve(_release);
      client.files.remove('url://one');
      final service = build(retry: DownloadRetryPolicy.standard);

      await service.download(_release);

      final status = service.statusOf(_release);
      expect(status.state, ModelInstallState.failed);
      expect(status.failure!.problem, ModelDownloadProblem.network);
      expect(status.failure!.detail, contains('404'));
      expect(client.requests, hasLength(1));
      expect(waits, isEmpty, reason: 'nobody was kept waiting for a 404');
    });

    test('403 stops at once too', () async {
      client.serve(_release);
      client.statuses['url://one'] = <int>[403];
      final service = build(retry: DownloadRetryPolicy.standard);

      await service.download(_release);

      expect(service.statusOf(_release).state, ModelInstallState.failed);
      expect(client.requests, hasLength(1));
      expect(waits, isEmpty);
    });

    test('a hash that does not match is never retried', () async {
      client.serve(_release);
      client.files['url://one'] =
          Uint8List.fromList(List<int>.filled(_one.length, 7));
      final service = build(retry: DownloadRetryPolicy.standard);

      await service.download(_release);

      expect(service.statusOf(_release).failure!.problem,
          ModelDownloadProblem.corrupt);
      expect(client.requests.where((r) => r.url == 'url://one'), hasLength(1));
      expect(waits, isEmpty);
    });

    test('a retry carries on from the bytes on disk, it does not start again',
        () async {
      client.serve(_release);
      files.put('/models/test-set/one.bin.part', _one.sublist(0, 30));
      client.statuses['url://one'] = <int>[504, 504];
      final service = build(retry: DownloadRetryPolicy.standard);

      await service.download(_release);

      final forOne = client.requests.where((r) => r.url == 'url://one');
      expect(forOne.map((r) => r.from), <int>[30, 30, 30],
          reason: 'the 30 bytes already there are asked for once, not thrice');
      expect(files.bytes['/models/test-set/one.bin'], _one);
      expect(service.statusOf(_release).isInstalled, isTrue);
    });

    test('a range the server will not serve throws the part away, once',
        () async {
      client.serve(_release);
      files.put('/models/test-set/one.bin.part', _one.sublist(0, 30));
      client.statuses['url://one'] = <int>[416];
      final service = build(retry: DownloadRetryPolicy.standard);

      await service.download(_release);

      expect(client.requests.map((r) => r.from).take(2), <int>[30, 0]);
      expect(files.bytes['/models/test-set/one.bin'], _one);
      expect(waits, isEmpty, reason: '416 is a restart, not a backoff');
    });

    test('a part file is never installed as the model', () async {
      client.serve(_release);
      client.statuses['url://one'] = <int>[504, 504, 504];
      final service =
          build(retry: const DownloadRetryPolicy(maxAttempts: 3));

      await service.download(_release);

      expect(service.statusOf(_release).state, ModelInstallState.failed);
      expect(files.bytes.containsKey('/models/test-set/one.bin'), isFalse);
      expect(service.statusOf(_release).isInstalled, isFalse);
    });
  });

  group('while it is retrying, the screen is not stuck', () {
    test('it says it is still trying, and stops saying so when it works',
        () async {
      client.serve(_release);
      client.statuses['url://one'] = <int>[504];
      final service = build(retry: DownloadRetryPolicy.standard);
      final seen = <ModelInstallStatus>[];
      service.changes.listen(seen.add);

      await service.download(_release);
      await pumpEventQueue();

      expect(seen.where((s) => s.retrying), isNotEmpty,
          reason: 'the bar standing still gets a sentence');
      final retrying = seen.firstWhere((s) => s.retrying);
      expect(retrying.state, ModelInstallState.downloading);
      expect(retrying.failure, isNull, reason: 'it has not failed, it waits');
      expect(seen.last.retrying, isFalse);
      expect(seen.last.state, ModelInstallState.installed);
    });

    test('Cancel works during a backoff, it does not wait the wait out',
        () async {
      client.serve(_release);
      client.statuses['url://one'] = <int>[504, 504, 504, 504, 504];
      final service = build(
        retry: DownloadRetryPolicy.standard,
        // A sleep that never ends: only the cancel can let the job go.
        delay: (_) => Completer<void>().future,
      );
      final waiting = Completer<void>();
      service.changes.listen((status) {
        if (status.retrying && !waiting.isCompleted) waiting.complete();
      });

      final running = service.download(_release);
      await waiting.future;
      await service.cancel(_release).timeout(const Duration(seconds: 5));
      await running.timeout(const Duration(seconds: 5));

      final status = service.statusOf(_release);
      expect(status.state, ModelInstallState.notInstalled);
      expect(status.failure, isNull, reason: 'a cancel is not a failure');
      expect(status.retrying, isFalse);
      expect(files.bytes.containsKey('/models/test-set/one.bin'), isFalse);
    });

    test('going off screen ends the backoff too', () async {
      client.serve(_release);
      client.statuses['url://one'] = <int>[504, 504, 504];
      final service = build(
        retry: DownloadRetryPolicy.standard,
        delay: (_) => Completer<void>().future,
      );
      final waiting = Completer<void>();
      service.changes.listen((status) {
        if (status.retrying && !waiting.isCompleted) waiting.complete();
      });

      final running = service.download(_release);
      await waiting.future;
      service.pauseAll();
      await running.timeout(const Duration(seconds: 5));

      expect(service.statusOf(_release).paused, isTrue);
    });
  });

}

// ---------------------------------------------------------------------------
// The set under test: two small files with their real sha256s.
// ---------------------------------------------------------------------------

final Uint8List _one =
    Uint8List.fromList(List<int>.generate(100, (i) => i % 251));
final Uint8List _two =
    Uint8List.fromList(List<int>.generate(57, (i) => (i * 7) % 253));

String _sha256Of(List<int> bytes) {
  final sink = const CryptoHashing().startSha256();
  sink.add(bytes);
  return sink.finish();
}

final ModelRelease _release = ModelRelease(
  id: 'test-set',
  displayName: 'Test set',
  enables: 'Nothing at all; it is a test.',
  directoryName: 'test-set',
  feature: ModelFeature.speakerDetection,
  files: <DownloadableFile>[
    DownloadableFile(
      file: SpeechModelFile(name: 'one.bin', sizeBytes: _one.length),
      sha256: _sha256Of(_one),
      url: 'url://one',
    ),
    DownloadableFile(
      file: SpeechModelFile(name: 'two.bin', sizeBytes: _two.length),
      sha256: _sha256Of(_two),
      url: 'url://two',
    ),
  ],
);

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _Request {
  _Request(this.url, this.from);

  final String url;
  final int from;

  @override
  String toString() => '$url@$from';
}

/// A server the test writes: it can break, ignore a range, answer the wrong
/// status, or hold the body open until the test lets go.
class _FakeClient implements DownloadClient {
  final Map<String, Uint8List> files = <String, Uint8List>{};
  final List<_Request> requests = <_Request>[];

  /// url -> bytes to send before the connection dies.
  final Map<String, int> breakAfter = <String, int>{};

  /// urls that keep breaking however often they are retried.
  final Set<String> breakForever = <String>{};

  /// urls that answer 200 to a range request.
  final Set<String> ignoreRange = <String>{};

  /// url -> the statuses to answer before any bytes are served. One per
  /// request, in order: `[504, 504]` is a cold asset that wakes up on the
  /// third ask.
  final Map<String, List<int>> statuses = <String, List<int>>{};

  /// What those statuses carry in `Retry-After`.
  final Map<String, Duration> retryAfter = <String, Duration>{};

  int chunkSize = 8;

  Completer<void>? _gate;
  String? _gateUrl;
  Completer<void> firstChunkSent = Completer<void>();

  void serve(ModelRelease release) {
    files['url://one'] = _one;
    files['url://two'] = _two;
  }

  /// Sends one chunk of [url], then waits for the returned completer.
  Completer<void> holdAfterFirstChunk(String url) {
    _gateUrl = url;
    _gate = Completer<void>();
    firstChunkSent = Completer<void>();
    return _gate!;
  }

  @override
  Future<DownloadResponse> get(String url, {int from = 0}) async {
    requests.add(_Request(url, from));
    final queued = statuses[url];
    if (queued != null && queued.isNotEmpty) {
      return DownloadResponse(
        statusCode: queued.removeAt(0),
        contentLength: 0,
        body: const Stream<List<int>>.empty(),
        retryAfter: retryAfter[url],
        abort: () async {},
      );
    }
    final bytes = files[url];
    if (bytes == null) {
      return DownloadResponse(
        statusCode: 404,
        contentLength: 0,
        body: const Stream<List<int>>.empty(),
        abort: () async {},
      );
    }
    final ignoring = ignoreRange.contains(url);
    final start = ignoring ? 0 : from;
    final payload = Uint8List.sublistView(bytes, start);
    var limit = breakAfter[url];
    if (limit != null && !breakForever.contains(url)) breakAfter.remove(url);
    if (limit != null && start > 0 && !breakForever.contains(url)) {
      limit = null;
    }
    return DownloadResponse(
      statusCode: start > 0 ? 206 : 200,
      contentLength: payload.length,
      body: _emit(url, payload, limit),
      abort: () async {},
    );
  }

  Stream<List<int>> _emit(String url, Uint8List payload, int? breakAt) async* {
    var sent = 0;
    for (var i = 0; i < payload.length; i += chunkSize) {
      if (breakAt != null && sent >= breakAt) {
        throw const DownloadException('the connection died');
      }
      final end =
          (i + chunkSize) > payload.length ? payload.length : i + chunkSize;
      yield Uint8List.sublistView(payload, i, end);
      sent += end - i;
      if (_gateUrl == url && _gate != null) {
        if (!firstChunkSent.isCompleted) firstChunkSent.complete();
        final gate = _gate!;
        _gate = null;
        _gateUrl = null;
        await gate.future;
      }
    }
  }

  @override
  void close() {}
}

/// An in-memory [FileStore] that appends and renames, which is all a download
/// needs of a disk.
class _MemoryStore implements FileStore {
  final Map<String, Uint8List> bytes = <String, Uint8List>{};

  void put(String path, List<int> data) =>
      bytes[path] = Uint8List.fromList(data);

  @override
  Future<FileSink> openWrite(String path) async {
    bytes[path] = Uint8List(0);
    return _Sink(this, path);
  }

  @override
  Future<FileSink> openAppend(String path) async {
    bytes.putIfAbsent(path, () => Uint8List(0));
    return _Sink(this, path);
  }

  @override
  Future<void> move(String from, String to) async {
    final data = bytes.remove(from);
    if (data == null) throw StateError('no such file: $from');
    bytes[to] = data;
  }

  @override
  Future<Uint8List> read(String path) async {
    final data = bytes[path];
    if (data == null) throw StateError('no such file: $path');
    return data;
  }

  @override
  Future<Uint8List> readRange(String path, int start, int end) async {
    final data = bytes[path];
    if (data == null) return Uint8List(0);
    final from = start.clamp(0, data.length);
    final to = end.clamp(from, data.length);
    return Uint8List.sublistView(data, from, to);
  }

  @override
  Future<FileInfo?> stat(String path) async {
    final data = bytes[path];
    if (data == null) return null;
    return FileInfo(
      path: path,
      sizeBytes: data.length,
      modifiedAt: DateTime(2026, 9, 18),
    );
  }

  @override
  Future<void> writeBytes(String path, List<int> data) async => put(path, data);

  @override
  Future<void> patchBytes(String path, int offset, List<int> data) async =>
      bytes[path]!.setRange(offset, offset + data.length, data);

  @override
  Future<bool> exists(String path) async => bytes.containsKey(path);

  @override
  Future<void> delete(String path) async => bytes.remove(path);

  @override
  Future<List<String>> list(String directory) async =>
      bytes.keys.where((p) => p.startsWith('$directory/')).toList()..sort();

  @override
  String join(String directory, String name) => '$directory/$name';
}

class _Sink implements FileSink {
  _Sink(this._store, this._path);

  final _MemoryStore _store;
  final String _path;

  @override
  int get bytesWritten => _store.bytes[_path]!.length;

  @override
  Future<void> add(List<int> data) async {
    final current = _store.bytes[_path] ?? Uint8List(0);
    _store.bytes[_path] =
        Uint8List.fromList(<int>[...current, ...data]);
  }

  @override
  Future<void> patch(int offset, List<int> data) async =>
      _store.bytes[_path]!.setRange(offset, offset + data.length, data);

  @override
  Future<void> close() async {}
}
