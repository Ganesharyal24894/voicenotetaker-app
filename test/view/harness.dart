import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:voicenotetaker_app/controller/app_controller.dart';
import 'package:voicenotetaker_app/drivers/audio_player.dart';
import 'package:voicenotetaker_app/drivers/ble_transport.dart';
import 'package:voicenotetaker_app/drivers/file_store.dart';
import 'package:voicenotetaker_app/drivers/platform_settings.dart';
import 'package:voicenotetaker_app/model/audio_codec.dart';
import 'package:voicenotetaker_app/model/battery_status.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/model/die_temperature.dart';
import 'package:voicenotetaker_app/model/stream_info.dart';
import 'package:voicenotetaker_app/services/device_test_service.dart';
import 'package:voicenotetaker_app/services/device_test_store.dart';
import 'package:voicenotetaker_app/services/library_service.dart';
import 'package:voicenotetaker_app/services/wav_writer.dart';
import 'package:voicenotetaker_app/view/theme.dart';

/// Fake radio. The view tests never touch real BLE - `universal_ble` is not
/// even importable from `view/`.
class MockBleTransport extends Mock implements BleTransport {}

/// Fake way into the OS settings pages. The view tests never open a real
/// Settings app; they check that the button ASKED to.
class MockPlatformSettings extends Mock implements PlatformSettings {}

/// Fake player. The view tests never touch `just_audio`, and never need audio
/// hardware: everything the playback screen renders arrives on [FakePlayback].
class MockAudioPlayer extends Mock implements AudioPlayer {}

/// mocktail needs a fallback for any non-primitive type used with `any()`.
void registerViewFallbacks() {
  registerFallbackValue(AudioCodec.imaAdpcm);
  registerFallbackValue(Duration.zero);
}

/// An [AudioPlayer] the tests drive by hand.
///
/// mocktail records the calls the screen makes - `load`, `play`, `seek` - and
/// [emit] pushes the [PlaybackState] the screen renders. Nothing is emitted on
/// its own: a fake that reported "playing" because `play()` was called would
/// hide exactly the bug these tests exist to catch.
class FakePlayback {
  FakePlayback() {
    when(() => player.state).thenAnswer((_) => _states.stream);
    when(() => player.load(any())).thenAnswer((_) async {});
    when(() => player.play()).thenAnswer((_) async {});
    when(() => player.pause()).thenAnswer((_) async {});
    when(() => player.stop()).thenAnswer((_) async {});
    when(() => player.seek(any())).thenAnswer((_) async {});
    when(() => player.setSpeed(any())).thenAnswer((_) async {});
    when(() => player.dispose()).thenAnswer((_) async {});
  }

  final MockAudioPlayer player = MockAudioPlayer();
  final StreamController<PlaybackState> _states =
      StreamController<PlaybackState>.broadcast();

  /// Reports a position, exactly as the driver's own stream would.
  void emit({
    required bool isPlaying,
    required Duration position,
    Duration? duration,
    String? path,
  }) =>
      _states.add(
        PlaybackState(
          isPlaying: isPlaying,
          position: position,
          duration: duration,
          path: path,
        ),
      );

  /// Fails the way the driver does when the platform reports an error.
  void fail(Object error) => _states.addError(error);

  Future<void> close() => _states.close();
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
  ViewHarness({
    List<DiscoveredDevice> devices = const <DiscoveredDevice>[],
    AudioPlayer? audioPlayer,
    this.availability = BleAvailability.poweredOn,
    this.testWindow,
  }) : transport = MockBleTransport() {
    when(() => transport.currentAvailability())
        .thenAnswer((_) async => availability);
    when(() => transport.availability).thenAnswer((_) => adapter.stream);
    when(() => settings.openBluetoothSettings()).thenAnswer((_) async => true);
    when(() => settings.openAppSettings()).thenAnswer((_) async => true);
    when(() => transport.ensurePermissions()).thenAnswer((_) async => true);
    // A scan stream that STAYS OPEN, the way a real one does: the radio keeps
    // listening after it has reported a device. The stream closing means the
    // scan window ended (see `BleTransport.scan`), so it must not close on its
    // own here - `endScan` is what a test uses to end the window.
    when(() => transport.scan()).thenAnswer((_) {
      final scan = StreamController<DiscoveredDevice>.broadcast();
      _scan = scan;
      // After the caller has attached its listener, never before.
      scheduleMicrotask(() {
        for (final device in devices) {
          if (!scan.isClosed) scan.add(device);
        }
      });
      return scan.stream;
    });
    when(() => transport.stopScan()).thenAnswer((_) async {});
    when(() => transport.connect(any())).thenAnswer((_) async {});
    // An OPEN link stream, so a test can drop the link the way the radio does
    // - see [dropLink]. Nothing arrives unless a test sends it.
    when(() => transport.connectionState(any())).thenAnswer((_) => link.stream);
    when(() => transport.disconnect(any())).thenAnswer((_) async {});
    when(() => transport.selectCodec(any(), any())).thenAnswer((_) async {});
    // The device's own default: auto-sleep off. Tests that care re-stub this
    // - including with a throw, which is what firmware without `fe04` does.
    when(() => transport.readAutoSleep(any())).thenAnswer((_) async => false);
    when(() => transport.setAutoSleep(any(), any())).thenAnswer((_) async {});
    // A charged, discharging cell: the ordinary case. Tests that care
    // re-stub this - including with a throw, which is what firmware without
    // `fe05` does - or push values through [battery].
    when(() => transport.readBattery(any()))
        .thenAnswer((_) async => const BatteryStatus(percent: 76, charging: false));
    when(() => transport.subscribeBattery(any()))
        .thenAnswer((_) => battery.stream);
    when(() => transport.unsubscribeBattery(any())).thenAnswer((_) async {});
    // A die running warm, which is the ordinary case: the sensor shares a
    // package with the CPU and the radio. Tests that care re-stub this -
    // including with a throw, which is what firmware without `fe07` does - or
    // push values through [temperature].
    when(() => transport.readDieTemperature(any()))
        .thenAnswer((_) async => const DieTemperature(deciCelsius: 312));
    when(() => transport.subscribeDieTemperature(any()))
        .thenAnswer((_) => temperature.stream);
    when(() => transport.unsubscribeDieTemperature(any()))
        .thenAnswer((_) async {});
    // The live link's signal, which is NOT `knownDevice.rssi`: that one is a
    // single sample off an advertising packet, taken at scan time.
    when(() => transport.readRssi(any())).thenAnswer((_) async => -58);
    when(() => transport.readStreamInfo(any()))
        .thenAnswer((_) async => StreamInfo.fallback);
    when(() => transport.subscribeFrames(any()))
        .thenAnswer((_) => frames.stream);
    when(() => transport.unsubscribeFrames(any())).thenAnswer((_) async {});
    when(() => transport.dispose()).thenAnswer((_) async {});

    controller = AppController(
      transport: transport,
      fileStore: fileStore,
      audioPlayer: audioPlayer,
      platformSettings: settings,
      recordingsDirectory: recordingsDirectory,
      deviceTestService: testWindow == null
          ? null
          : DeviceTestService(
              transport: transport,
              store: DeviceTestStore(
                fileStore: fileStore,
                directory: recordingsDirectory,
              ),
              // Milliseconds instead of the ten seconds and three minutes the
              // real windows are, so a widget test can watch a test run
              // without the widget test taking three minutes.
              noiseFloorWindow: testWindow!,
              sensitivityWindow: testWindow!,
              linkSoakWindow: testWindow!,
              advertisingPollWindow: testWindow!,
              systemOffConfirm: testWindow!,
              systemOffTimeout: testWindow!,
              wakeTimeout: testWindow!,
              tick: const Duration(milliseconds: 20),
            ),
    );
  }

  /// Where the controller writes captures, and where the library reads them.
  static const String recordingsDirectory = '/tmp/voicenotetaker-test';

  final MockBleTransport transport;
  final MockPlatformSettings settings = MockPlatformSettings();
  final MemoryFileStore fileStore = MemoryFileStore();

  /// What `currentAvailability()` answers. [begin] is what makes the controller
  /// read it.
  final BleAvailability availability;

  /// When set, the device-test harness runs with windows this long instead of
  /// its real ones. Null leaves the controller building the real service, which
  /// is what every test that only RENDERS the card wants.
  final Duration? testWindow;

  /// Adapter state changes, pushed by hand.
  final StreamController<BleAvailability> adapter =
      StreamController<BleAvailability>.broadcast();

  /// Link state for the connected device, pushed by hand.
  final StreamController<BleConnectionStatus> link =
      StreamController<BleConnectionStatus>.broadcast();
  final StreamController<Uint8List> frames =
      StreamController<Uint8List>.broadcast();

  /// `fe05` notifications, pushed by hand. Nothing arrives unless a test sends
  /// it, so a readout that moves on its own cannot pass unnoticed.
  final StreamController<BatteryStatus> battery =
      StreamController<BatteryStatus>.broadcast();

  /// `fe07` notifications, pushed by hand. Same rule as [battery].
  final StreamController<DieTemperature> temperature =
      StreamController<DieTemperature>.broadcast();

  /// The scan stream handed out by the most recent `scan()` call, so a test can
  /// end its window.
  StreamController<DiscoveredDevice>? _scan;

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

  /// Starts the controller, which is what makes it read the adapter state.
  ///
  /// Most view tests do not need this - they render a screen against state they
  /// set directly - but anything about [BleAvailability] does, because
  /// `initialise()` is where the adapter is first read.
  Future<void> begin(WidgetTester tester) async {
    final done = controller.initialise();
    await flush(tester);
    await done;
  }

  /// Pushes an adapter state change, exactly as the platform would.
  Future<void> notifyAvailability(
    WidgetTester tester,
    BleAvailability state,
  ) async {
    adapter.add(state);
    await flush(tester);
  }

  /// Drops the link WITHOUT the user asking - the radio reporting that the
  /// peripheral went away.
  Future<void> dropLink(WidgetTester tester) async {
    link.add(BleConnectionStatus.disconnected);
    await flush(tester);
  }

  /// Runs a scan to completion so [AppController.devices] is populated.
  Future<void> discover(WidgetTester tester) async {
    final done = controller.startScan();
    await flush(tester);
    await done;
  }

  /// Ends the scan window, exactly as the transport does when its ten seconds
  /// are up: the stream closes.
  ///
  /// This is the ONLY way a scan reports "finished", which is what separates a
  /// scan that found nothing from one that has not found anything yet.
  Future<void> endScanWindow(WidgetTester tester) async {
    await _scan?.close();
    _scan = null;
    await flush(tester);
  }

  /// Stops the scan the way the user does, by tapping the control again.
  ///
  /// Goes through [flush] rather than being awaited directly: cancelling a
  /// stream subscription needs the real event loop, not the tester's clock.
  Future<void> stopScan(WidgetTester tester) async {
    final done = controller.stopScan();
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

  /// Pushes a `fe05` notification, exactly as the device would.
  Future<void> notifyBattery(
    WidgetTester tester, {
    required int? percent,
    required bool charging,
  }) async {
    battery.add(BatteryStatus(percent: percent, charging: charging));
    await flush(tester);
  }

  /// Pushes a `fe07` notification, exactly as the device would.
  Future<void> notifyTemperature(
    WidgetTester tester, {
    required int? deciCelsius,
  }) async {
    temperature.add(DieTemperature(deciCelsius: deciCelsius));
    await flush(tester);
  }

  Future<void> dispose() async {
    final scan = _scan;
    _scan = null;
    if (scan != null && !scan.isClosed) await scan.close();
    if (!adapter.isClosed) await adapter.close();
    if (!link.isClosed) await link.close();
    await frames.close();
    if (!battery.isClosed) await battery.close();
    if (!temperature.isClosed) await temperature.close();
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

  /// Paths whose deletion must fail, for the "the unlink itself broke" case.
  final Set<String> undeletable = <String>{};

  /// When true every [writeBytes] fails, for the "the measurement happened and
  /// the record of it did not" case.
  bool readOnly = false;

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
  Future<void> writeBytes(String path, List<int> bytes) async {
    if (readOnly) {
      // A plain exception, not a `FileSystemException`: this store exists so the
      // domain layer can be tested with no `dart:io` anywhere near it.
      throw Exception('read-only filesystem: $path');
    }
    files[path] = <int>[...bytes];
  }

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<void> delete(String path) async {
    if (undeletable.contains(path)) {
      // A plain exception, not a `FileSystemException`: this store exists so
      // the domain layer can be tested with no `dart:io` anywhere near it.
      throw Exception('permission denied: $path');
    }
    files.remove(path);
  }

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
