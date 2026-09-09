import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/controller/app_controller.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/drivers/file_store.dart';
import 'package:voicenotetaker_app/model/audio_codec.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/model/stream_info.dart';
import 'package:voicenotetaker_app/services/library_service.dart';
import 'package:voicenotetaker_app/services/wav_writer.dart';
import 'package:voicenotetaker_app/view/theme.dart';

/// Fake radio. The view tests never touch real BLE - `universal_ble` is not
/// even importable from `view/`.
class MockBleTransport extends Mock implements BleTransport {}

/// mocktail needs a fallback for any enum used with `any()`.
void registerViewFallbacks() {
  registerFallbackValue(AudioCodec.imaAdpcm);
}

/// The recorder as the scan screen sees it.
const DiscoveredDevice knownDevice = DiscoveredDevice(
  id: 'EB:6B:5E:4C:33:A3',
  name: 'voiceNotetaker',
  rssi: -54,
);

/// Something else in range: dimmed, not connectable.
const DiscoveredDevice unknownDevice = DiscoveredDevice(
  id: 'C2:1A:90:07:4E:B8',
  name: null,
  rssi: -88,
);

/// Everything a view test needs, wired together.
class ViewHarness {
  ViewHarness({List<DiscoveredDevice> devices = const <DiscoveredDevice>[]})
      : transport = MockBleTransport() {
    when(() => transport.currentAvailability())
        .thenAnswer((_) async => BleAvailability.poweredOn);
    when(() => transport.availability)
        .thenAnswer((_) => const Stream<BleAvailability>.empty());
    when(() => transport.ensurePermissions()).thenAnswer((_) async => true);
    when(() => transport.scan())
        .thenAnswer((_) => Stream<DiscoveredDevice>.fromIterable(devices));
    when(() => transport.stopScan()).thenAnswer((_) async {});
    when(() => transport.connect(any())).thenAnswer((_) async {});
    when(() => transport.connectionState(any()))
        .thenAnswer((_) => const Stream<BleConnectionStatus>.empty());
    when(() => transport.disconnect(any())).thenAnswer((_) async {});
    when(() => transport.selectCodec(any(), any())).thenAnswer((_) async {});
    when(() => transport.readStreamInfo(any()))
        .thenAnswer((_) async => StreamInfo.fallback);
    when(() => transport.subscribeFrames(any()))
        .thenAnswer((_) => frames.stream);
    when(() => transport.unsubscribeFrames(any())).thenAnswer((_) async {});
    when(() => transport.dispose()).thenAnswer((_) async {});

    controller = AppController(
      transport: transport,
      fileStore: fileStore,
      recordingsDirectory: recordingsDirectory,
    );
  }

  /// Where the controller writes captures, and where the library reads them.
  static const String recordingsDirectory = '/tmp/voicenotetaker-test';

  final MockBleTransport transport;
  final MemoryFileStore fileStore = MemoryFileStore();
  final StreamController<Uint8List> frames =
      StreamController<Uint8List>.broadcast();
  late final AppController controller;

  /// Writes a real WAV file into the store, exactly as a finished capture
  /// would, and makes the controller re-read the library.
  ///
  /// Returns the path written. The file carries a genuine 44-byte header, so
  /// the library reads its length out of the header rather than being told it.
  Future<String> seedRecording({
    DateTime? at,
    Duration length = const Duration(minutes: 4, seconds: 12),
    int sampleRateHz = 16000,
  }) async {
    final when = at ?? DateTime(2026, 9, 10, 9, 14);
    final path = fileStore.join(
      recordingsDirectory,
      RecordingNaming.fileName(when),
    );
    final samples = (length.inMilliseconds * sampleRateHz) ~/ 1000;
    await fileStore.writeBytes(
      path,
      WavWriter.wrapPcm(
        Uint8List(samples * 2),
        sampleRateHz: sampleRateHz,
        channels: 1,
        bitsPerSample: 16,
      ),
    );
    fileStore.modifiedTimes[path] = when;
    await controller.refreshLibrary();
    return path;
  }

  /// Runs a scan to completion so [AppController.devices] is populated.
  Future<void> discover(WidgetTester tester) async {
    final done = controller.startScan();
    await flush(tester);
    await done;
  }

  /// Puts the controller in the connected state.
  Future<void> connect(WidgetTester tester) async {
    final done = controller.connect(knownDevice);
    await flush(tester);
    await done;
  }

  /// Starts a capture; the frame stream stays open and silent.
  Future<void> record(WidgetTester tester) async {
    final done = controller.startRecording();
    await flush(tester);
    await done;
  }

  /// Stops the capture in progress.
  Future<void> stop(WidgetTester tester) async {
    final done = controller.stopRecording();
    await flush(tester);
    await done;
  }

  Future<void> dispose() async {
    await frames.close();
    await controller.teardown();
  }
}

/// Lets the controller's async chains run, then rebuilds.
///
/// Controller actions are chains of awaits, some of which (cancelling a stream
/// subscription) need the real event loop rather than the widget tester's fake
/// clock - hence [WidgetTester.runAsync]. `pumpAndSettle()` is not an option
/// on these screens: the scan indicator animates forever by design.
Future<void> flush(WidgetTester tester, {int rounds = 3}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    await tester.pump();
  }
}

/// Pumps past the dock transition between two of the state-driven screens.
///
/// `AppRoot` moves between the scan screen, Home and the recording screen with
/// real route transitions, so that the board docking into the Home header can
/// be a `Hero`. `pumpAndSettle` is not an option - the scan ripple loops by
/// design - so the transition is pumped by hand.
Future<void> settleDock(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 800));
}

/// Pumps [child] at the mock's 390x844 frame with the real app theme.
Future<void> pumpScreen(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(390, 844),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(),
      debugShowCheckedModeBanner: false,
      home: child,
    ),
  );
  await tester.pump();
}

/// Minimal in-memory [FileStore]; the view tests only need `openWrite` to
/// succeed so a capture can start.
class MemoryFileStore implements FileStore {
  final Map<String, List<int>> files = <String, List<int>>{};

  /// Modification times for [stat], for tests that seed files directly.
  final Map<String, DateTime> modifiedTimes = <String, DateTime>{};

  @override
  Future<FileSink> openWrite(String path) async {
    final bytes = <int>[];
    files[path] = bytes;
    return _MemorySink(bytes);
  }

  @override
  Future<Uint8List> read(String path) async =>
      Uint8List.fromList(files[path] ?? const <int>[]);

  @override
  Future<Uint8List> readRange(String path, int start, int end) async {
    final bytes = await read(path);
    final from = start.clamp(0, bytes.length);
    final to = end.clamp(from, bytes.length);
    return Uint8List.sublistView(bytes, from, to);
  }

  @override
  Future<FileInfo?> stat(String path) async {
    final bytes = files[path];
    if (bytes == null) return null;
    return FileInfo(
      path: path,
      sizeBytes: bytes.length,
      modifiedAt: modifiedTimes[path] ?? DateTime(2026, 9, 10, 14, 30),
    );
  }

  @override
  Future<void> writeBytes(String path, List<int> bytes) async =>
      files[path] = <int>[...bytes];

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<void> delete(String path) async => files.remove(path);

  @override
  Future<List<String>> list(String directory) async => files.keys
      .where((p) => p.startsWith('$directory/'))
      .toList()
    ..sort();

  @override
  String join(String directory, String name) => '$directory/$name';
}

class _MemorySink implements FileSink {
  _MemorySink(this._bytes);

  final List<int> _bytes;

  @override
  int get bytesWritten => _bytes.length;

  @override
  Future<void> add(List<int> bytes) async => _bytes.addAll(bytes);

  @override
  Future<void> patch(int offset, List<int> bytes) async {
    while (_bytes.length < offset + bytes.length) {
      _bytes.add(0);
    }
    for (var i = 0; i < bytes.length; i++) {
      _bytes[offset + i] = bytes[i];
    }
  }

  @override
  Future<void> close() async {}
}
