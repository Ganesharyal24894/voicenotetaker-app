import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/device_test_result.dart';
import 'package:voicenotetaker_app/services/device_test_store.dart';

import 'view/harness.dart' show MemoryFileStore;

/// The store is what turns "a number you watched" into "a number you can go
/// back to", which is the whole reason the harness exists. These tests pin down
/// that it survives a restart, that it stays newest-first, and - most
/// importantly - that a file it cannot fully understand costs it the rows it
/// cannot read and NOTHING ELSE.
void main() {
  DeviceTestStore storeOn(MemoryFileStore files, {int maxResults = 200}) =>
      DeviceTestStore(
        fileStore: files,
        directory: '/recordings',
        maxResults: maxResults,
      );

  DeviceTestResult result(
    DeviceTestKind kind,
    int minute, {
    DeviceTestOutcome outcome = DeviceTestOutcome.completed,
  }) =>
      DeviceTestResult(
        kind: kind,
        outcome: outcome,
        startedAt: DateTime.utc(2026, 9, 13, 14, minute),
        duration: const Duration(seconds: 10),
        readings: <DeviceTestReading>[
          DeviceTestReading(label: 'Stops', value: minute),
        ],
      );

  test('a fresh install has an empty history, not an error', () async {
    final store = storeOn(MemoryFileStore());
    await store.load();

    expect(store.isLoaded, isTrue);
    expect(store.results, isEmpty);
    expect(store.latestOf(DeviceTestKind.range), isNull);
  });

  test('until it is loaded it does not claim there is no history', () {
    final store = storeOn(MemoryFileStore());
    expect(store.isLoaded, isFalse);
  });

  test('a saved run is there after a restart', () async {
    final files = MemoryFileStore();
    final first = storeOn(files);
    await first.load();
    await first.append(result(DeviceTestKind.noiseFloor, 2));

    // A second store over the same files is exactly what the next launch is.
    final second = storeOn(files);
    await second.load();

    expect(second.results, hasLength(1));
    expect(second.results.single.kind, DeviceTestKind.noiseFloor);
    expect(second.latestOf(DeviceTestKind.noiseFloor)?.reading('Stops')?.value, 2);
  });

  test('the newest run comes first', () async {
    final store = storeOn(MemoryFileStore());
    await store.load();
    await store.append(result(DeviceTestKind.range, 1));
    await store.append(result(DeviceTestKind.range, 2));
    await store.append(result(DeviceTestKind.range, 3));

    expect(
      store.results.map((r) => r.reading('Stops')?.value).toList(),
      <int>[3, 2, 1],
    );
    // Which is what makes "latest" and "the one before it" - the comparison the
    // screen shows - a matter of taking the first two.
    expect(store.latestOf(DeviceTestKind.range)?.reading('Stops')?.value, 3);
  });

  test('latestOf answers per test, not across them', () async {
    final store = storeOn(MemoryFileStore());
    await store.load();
    await store.append(result(DeviceTestKind.range, 1));
    await store.append(result(DeviceTestKind.linkSoak, 2));

    expect(store.latestOf(DeviceTestKind.range)?.reading('Stops')?.value, 1);
    expect(store.latestOf(DeviceTestKind.linkSoak)?.reading('Stops')?.value, 2);
    expect(store.latestOf(DeviceTestKind.sensitivity), isNull);
  });

  test('the oldest runs fall off the end rather than growing without bound',
      () async {
    final store = storeOn(MemoryFileStore(), maxResults: 3);
    await store.load();
    for (var minute = 1; minute <= 5; minute++) {
      await store.append(result(DeviceTestKind.range, minute));
    }

    expect(store.results, hasLength(3));
    expect(
      store.results.map((r) => r.reading('Stops')?.value).toList(),
      <int>[5, 4, 3],
    );
  });

  test('an unavailable run is kept like any other', () async {
    final store = storeOn(MemoryFileStore());
    await store.load();
    await store.append(
      result(
        DeviceTestKind.wakeOnMotion,
        1,
        outcome: DeviceTestOutcome.unavailable,
      ),
    );

    expect(
      store.latestOf(DeviceTestKind.wakeOnMotion)?.outcome,
      DeviceTestOutcome.unavailable,
    );
  });

  test('one unreadable row costs that row and not the rest', () async {
    final files = MemoryFileStore();
    final store = storeOn(files);
    await store.load();
    await store.append(result(DeviceTestKind.range, 1));
    await store.append(result(DeviceTestKind.range, 2));

    // A row written by a build that knows a sixth test. The two rows this build
    // does understand must still be readable - refusing to show any history
    // because of one future row would be the worse failure.
    final decoded =
        jsonDecode(utf8.decode(files.files[store.path]!)) as Map<String, Object?>;
    (decoded['results']! as List).insert(1, <String, Object?>{
      'kind': 'thermal-cycling',
      'outcome': 'completed',
      'startedAt': '2026-09-13T14:01:00.000Z',
      'durationMs': 1000,
    });
    await files.writeBytes(store.path, utf8.encode(jsonEncode(decoded)));

    final reopened = storeOn(files);
    await reopened.load();
    expect(reopened.results, hasLength(2));
  });

  test('a corrupt file leaves an empty history and does not throw', () async {
    final files = MemoryFileStore();
    final store = storeOn(files);
    await files.writeBytes(store.path, utf8.encode('{not json at all'));

    await store.load();
    expect(store.results, isEmpty);
    // And new runs can still be recorded: losing old results is bad, refusing
    // to take new measurements would be worse.
    await store.append(result(DeviceTestKind.range, 1));
    expect(store.results, hasLength(1));
  });

  test('a file from a newer build is left alone, not reinterpreted', () async {
    final files = MemoryFileStore();
    final store = storeOn(files);
    await files.writeBytes(
      store.path,
      utf8.encode(
        jsonEncode(<String, Object?>{
          'version': DeviceTestStore.formatVersion + 1,
          'results': <Object?>[result(DeviceTestKind.range, 1).toJson()],
        }),
      ),
    );

    await store.load();
    // Not read - this build cannot know what those fields mean any more.
    expect(store.results, isEmpty);
  });

  test('a write failure is reported, not swallowed', () async {
    final files = _UnwritableStore();
    final store = storeOn(files);
    await store.load();

    // A result that was measured and not saved has failed at the one thing the
    // harness is for, so the caller must be told.
    await expectLater(
      store.append(result(DeviceTestKind.range, 1)),
      throwsA(isA<Exception>()),
    );
  });

  test('clear forgets every run', () async {
    final store = storeOn(MemoryFileStore());
    await store.load();
    await store.append(result(DeviceTestKind.range, 1));
    await store.clear();

    expect(store.results, isEmpty);
  });

  test('the file sits beside the recordings, not in a cache', () async {
    final store = storeOn(MemoryFileStore());
    expect(store.path, '/recordings/${DeviceTestStore.defaultFileName}');
  });
}

/// A store whose writes always fail, for the "the result was not saved" path.
class _UnwritableStore extends MemoryFileStore {
  @override
  Future<void> writeBytes(String path, List<int> bytes) async =>
      throw Exception('read-only filesystem');
}
