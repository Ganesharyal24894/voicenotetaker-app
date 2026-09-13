import 'dart:async';
import 'dart:typed_data';

import '../drivers/ble_transport.dart';
import '../model/link_health.dart';
import 'frame_reassembler.dart';

/// Watches the live link: the signal, and the frames the phone actually got.
///
/// WHAT THIS REPLACED. A stepped range walk and a three-minute link soak, both
/// of which ended in a saved row. Both measured the same two quantities this
/// does, and the device produces both continuously - so a live readout answers
/// the same questions with nobody walking anywhere, and a soak becomes the
/// diagnostics screen left open. See [LinkHealth].
///
/// NOTHING RUNS UNLESS REQUIRED. This class does nothing at all until [start]
/// and stops completely on [stop]: the frame subscription is dropped, the
/// notifications are turned off at the device, and the poll timer is cancelled.
/// It is started when the diagnostics screen becomes visible and stopped when it
/// stops being visible - including on the app going to the background - because
/// subscribing to `fe01` is what makes the recorder stream, and a screen left
/// open must not leave the radio running for hours.
///
/// IT NEVER WRITES ANYTHING. No codec is selected, no flag is set: counting
/// frames works whatever format the device is streaming, because the sequence
/// header is in front of the payload and is not part of it. This is an observer,
/// and an observer that reconfigured the device would not be one.
///
/// THE FRAME SUBSCRIPTION IS EXCLUSIVE. `BleTransport.subscribeFrames` allows
/// one subscriber, so a recording or a mic check cannot have one while this
/// does. The caller is responsible for stopping this first; [start] reports a
/// failure rather than throwing if it is called anyway.
class LinkMonitor {
  /// A private initializing formal keeps the public parameter name
  /// (`transport:`) while assigning the private field - the same shape
  /// [DeviceTestService] uses.
  LinkMonitor({
    required this._transport,
    this.pollInterval = const Duration(seconds: 1),
  });

  final BleTransport _transport;

  /// How often the signal is re-read and the counters re-published.
  ///
  /// ONE SECOND, and the number is a compromise. `readRssi` is a round trip to
  /// the platform and on Android it is a GATT operation that queues behind the
  /// notify traffic this is measuring, so polling it at 10 Hz would both cost
  /// power and perturb the thing being observed. A second is fast enough that
  /// carrying the phone away from the device reads as a live meter.
  final Duration pollInterval;

  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// Fires whenever anything a screen renders changes.
  Stream<void> get changes => _changes.stream;

  final FrameReassembler _reassembler = FrameReassembler();

  StreamSubscription<Uint8List>? _frames;
  Timer? _poll;
  String? _deviceId;
  int? _rssiDbm;
  String? _failure;

  /// True while a poll is in flight, so a slow platform cannot queue a second.
  bool _reading = false;

  /// What the link is doing, as one value the screen renders directly.
  LinkHealth get health => LinkHealth(
        rssiDbm: _rssiDbm,
        stats: _reassembler.stats,
        watching: _frames != null,
      );

  /// True once [start] has opened the frame subscription.
  bool get isWatching => _frames != null;

  /// Why the counters are not running, or null when they are.
  ///
  /// Surfaced rather than swallowed: "no frames lost" and "nothing is counting"
  /// look identical in a counter and are not the same fact.
  String? get failure => _failure;

  /// Begins watching [deviceId]. Safe to call when already watching the same
  /// device - it does nothing rather than opening a second subscription.
  ///
  /// COUNTERS START FROM ZERO on every start, and that is the intended reading:
  /// the numbers describe this sitting in front of this screen, not the lifetime
  /// of the link. A counter that carried over from a previous visit would mix a
  /// walk down the corridor into a measurement taken at the desk.
  Future<void> start(String deviceId) async {
    if (_frames != null && _deviceId == deviceId) return;
    await stop();
    _deviceId = deviceId;
    _failure = null;
    _rssiDbm = null;
    _reassembler.reset();
    try {
      _frames = _transport.subscribeFrames(deviceId).listen(
            _reassembler.accept,
            // A stream that fails stops counting. Said out loud rather than
            // leaving the last counters on screen looking live.
            onError: (Object error) {
              _failure = 'the audio stream reported an error: $error';
              _notify();
            },
          );
    } on BleTransportException catch (e) {
      // Almost always the exclusive subscription: a capture or a mic check has
      // it. The signal is still worth reading, so the poll starts anyway.
      _failure = e.message;
    }
    _poll = Timer.periodic(pollInterval, (_) => _tick());
    // One reading immediately, so the meter is not empty for the first second.
    await _readRssi();
    _notify();
  }

  /// Stops watching and leaves nothing running.
  ///
  /// Best effort on the way out: whether or not the device agrees to stop
  /// notifying, this object is no longer listening and no longer polling.
  Future<void> stop() async {
    _poll?.cancel();
    _poll = null;
    final frames = _frames;
    final deviceId = _deviceId;
    _frames = null;
    _deviceId = null;
    _rssiDbm = null;
    _failure = null;
    if (frames != null) {
      await frames.cancel();
      if (deviceId != null) {
        try {
          await _transport.unsubscribeFrames(deviceId);
        } on BleTransportException {
          // The notifications have stopped either way.
        }
      }
    }
    _reassembler.reset();
    _notify();
  }

  void _tick() {
    // The counters have moved even if the signal read is still in flight, so
    // the frame figures are published on every tick regardless.
    _notify();
    unawaited(_readRssi());
  }

  Future<void> _readRssi() async {
    final deviceId = _deviceId;
    if (deviceId == null || _reading) return;
    _reading = true;
    try {
      final rssi = await _transport.readRssi(deviceId);
      // The device may have been let go while the read was in flight.
      if (_deviceId != deviceId) return;
      _rssiDbm = rssi;
    } on BleTransportException {
      // NO READING IS NOT A READING OF ZERO, and it is not the previous reading
      // either: a meter that froze at -58 dBm when the platform stopped
      // answering would be showing a measurement that is no longer being taken.
      if (_deviceId == deviceId) _rssiDbm = null;
    } finally {
      _reading = false;
      _notify();
    }
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> dispose() async {
    await stop();
    await _changes.close();
  }
}
