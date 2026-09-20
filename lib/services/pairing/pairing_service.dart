import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../drivers/ble_pairing.dart';
import '../../model/device_state.dart';
import '../../model/pairing_flow.dart';
import '../../model/pairing_outcome.dart';
import '../../model/recorder_pairing.dart';
import 'pairing_store.dart';

/// Runs a [PairingFlow] against the [BlePairing] driver, and remembers which
/// recorders this phone owns.
///
/// The controller connects with the transport as always, then hands the link
/// to [PairingAttempt.afterConnect]: bond (Android), read `fe02` (the
/// encryption proof, and iOS's pairing trigger), then carry on with the usual
/// session setup. Recorders that say nothing about pairing skip straight
/// through.
class PairingService {
  PairingService({
    required this._driver,
    required this._store,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  /// Long enough for the Android pairing dialog or the iOS alert to be read
  /// and accepted; the firmware drops an unencrypted link at 45 s.
  static const Duration promptTimeout = Duration(seconds: 40);

  final BlePairing _driver;
  final PairingStore _store;
  final DateTime Function() _now;

  PairingRecord _record = const PairingRecord();
  bool _loaded = false;

  /// Whether the platform bonds explicitly (Android) - and so whether a scan
  /// result's bond state can be trusted.
  bool get systemBonds => _driver.systemBonds;

  Future<void> load() async {
    if (_loaded) return;
    _record = await _store.load();
    _loaded = true;
  }

  /// Whether the app remembers an encrypted connection to [deviceId].
  bool isOwner(String deviceId) =>
      _record.owners.containsKey(deviceId.toLowerCase());

  /// When this phone first paired with [deviceId], if known.
  DateTime? pairedSince(String deviceId) =>
      _record.owners[deviceId.toLowerCase()];

  /// How [device] stands with this phone; see [RecorderPairing.resolve].
  RecorderPairing stateOf(DiscoveredDevice device, {bool refusedHere = false}) =>
      RecorderPairing.resolve(
        advert: device.pairing,
        bonded: device.bonded,
        remembered: isOwner(device.id),
        refusedHere: refusedHere,
      );

  /// Starts an attempt on [device], before the transport connects.
  Future<PairingAttempt> begin(DiscoveredDevice device) async {
    await load();
    final remembered = isOwner(device.id);
    // Asked afresh rather than taken from the scan: the user may have just
    // removed the bond in Bluetooth settings.
    final bonded = await _driver.isBonded(device.id);
    return PairingAttempt._(
      this,
      device,
      PairingFlow(
        advert: device.pairing,
        systemBonds: _driver.systemBonds,
        // Without an OS answer (iOS) a remembered owner is the best stand-in.
        bondedBefore: bonded ?? remembered,
        rememberedOwner: remembered,
      ),
    );
  }

  /// The id to reconnect to [rememberedId] through.
  ///
  /// On Android a recorder this phone owns is reached by its bonded IDENTITY
  /// address: an address seen in a scan rotates every 15 minutes. Anything the
  /// app does not know as an owner is left alone.
  Future<String> reconnectId(String rememberedId) async {
    if (!_driver.systemBonds || !isOwner(rememberedId)) return rememberedId;
    final bonded = await _driver.bondedRecorderIds();
    if (bonded.any((id) => id.toLowerCase() == rememberedId.toLowerCase())) {
      return rememberedId;
    }
    return bonded.length == 1 ? bonded.single : rememberedId;
  }

  Future<void> _remember(Iterable<String> ids) async {
    final now = _now();
    final owners = Map<String, DateTime>.of(_record.owners);
    var changed = false;
    for (final id in ids) {
      final key = id.toLowerCase();
      if (owners.containsKey(key)) continue;
      owners[key] = now;
      changed = true;
    }
    if (!changed) return;
    _record = PairingRecord(owners: owners);
    await _save();
  }

  /// Drops [deviceId]: the recorder refused this phone, so it is no longer
  /// this phone's.
  Future<void> forget(String deviceId) async {
    final key = deviceId.toLowerCase();
    if (!_record.owners.containsKey(key)) return;
    _record = PairingRecord(
      owners: Map<String, DateTime>.of(_record.owners)..remove(key),
    );
    await _save();
  }

  Future<void> _save() async {
    try {
      await _store.save(_record);
    } on Object catch (error) {
      // Still known for this run; only forgotten across a restart.
      debugPrint('Could not save the pairing record: $error');
    }
  }
}

/// One connect attempt's pairing half. Made by [PairingService.begin].
class PairingAttempt {
  PairingAttempt._(this._service, this.device, this.flow);

  final PairingService _service;
  final DiscoveredDevice device;
  final PairingFlow flow;

  DateTime? _connectedAt;

  /// Where the remembered-device id should point after success: the bonded
  /// identity address on Android when it differs from [device]'s id.
  String? ownerId;

  BlePairing get _driver => _service._driver;

  /// The transport's connect threw [error]. A refusal forgets the recorder.
  Future<PairingOutcome> connectFailed(Object error) async {
    final outcome = flow.failed(_driver.describe(error, deviceId: device.id));
    if (outcome.needsCharger) await _service.forget(device.id);
    return outcome;
  }

  /// The link is up: bond and secure as this recorder needs. Never throws.
  Future<PairingOutcome> afterConnect() async {
    _connectedAt = _service._now();
    var step = flow.connected();
    try {
      if (step == PairingStep.bonding) {
        await _driver.bond(device.id, timeout: PairingService.promptTimeout);
        step = flow.bonded();
      }
      if (step == PairingStep.securing) {
        await _driver.secure(device.id, timeout: PairingService.promptTimeout);
        flow.secured();
      }
    } on Object catch (error) {
      final since = _service._now().difference(_connectedAt!);
      flow.failed(
        _driver.describe(error, deviceId: device.id),
        sinceConnected: since,
      );
    }
    final outcome = flow.outcome!;
    if (outcome == PairingOutcome.success && flow.recorderPairs) {
      final ids = <String>[device.id];
      if (_driver.systemBonds) {
        // The id connected through may be a private address; the bond is kept
        // under the identity address, which is what reconnects use.
        final bonded = await _driver.bondedRecorderIds();
        final same = bonded.any((id) => id.toLowerCase() == device.id.toLowerCase());
        if (!same && bonded.length == 1) {
          ownerId = bonded.single;
          ids.add(bonded.single);
        }
      }
      await _service._remember(ids);
    } else if (outcome.needsCharger) {
      await _service.forget(device.id);
    }
    return outcome;
  }
}
