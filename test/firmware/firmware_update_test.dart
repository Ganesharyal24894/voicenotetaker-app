import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/model/dfu_bootloader.dart';
import 'package:voicenotetaker_app/model/firmware_update.dart';

import 'firmware_fakes.dart';

FirmwareVersion v(String text) => FirmwareVersion.tryParse(text)!;

void main() {
  group('FirmwareVersion', () {
    test('parses what fe0a and a release tag carry', () {
      expect(v('0.1.0'), const FirmwareVersion(0, 1, 0));
      expect(v('v1.2.3'), const FirmwareVersion(1, 2, 3));
      expect(v('0.2.0-rc1').preRelease, 'rc1');
      expect('${v('0.2.0-rc.1')}', '0.2.0-rc.1');
    });

    test('refuses anything else rather than guessing', () {
      for (final bad in [
        '',
        '0.1',
        '0.1.0.0',
        '01.1.0',
        '0.1.0+build',
        '0.1.0-',
        '0.1.0-a..b',
        '0.1.0\u0000',
        'zero',
      ]) {
        expect(FirmwareVersion.tryParse(bad), isNull, reason: bad);
      }
    });

    test('compares numerically, not as text', () {
      expect(v('0.10.0') > v('0.9.0'), isTrue);
      expect(v('1.0.0') > v('0.99.99'), isTrue);
      expect(v('0.1.1') > v('0.1.0'), isTrue);
    });

    test('a pre-release sorts below its release', () {
      expect(v('0.2.0-rc1') < v('0.2.0'), isTrue);
      expect(v('0.2.0-rc1') > v('0.1.9'), isTrue);
      expect(v('0.2.0-rc.2') < v('0.2.0-rc.10'), isTrue);
      expect(v('0.2.0-1') < v('0.2.0-alpha'), isTrue);
      expect(v('0.2.0-alpha') < v('0.2.0-alpha.1'), isTrue);
    });
  });

  group('FirmwareRelease', () {
    test('survives a JSON round trip', () {
      final release = releaseOf('0.3.0');
      final back = FirmwareRelease.fromJson(release.toJson())!;
      expect(back.version, release.version);
      expect(back.sha256, release.sha256);
      expect(back.publishedAt, release.publishedAt);
    });

    test('anything else reads as no release', () {
      expect(FirmwareRelease.fromJson(null), isNull);
      expect(FirmwareRelease.fromJson(<String, Object?>{'version': '1'}),
          isNull);
    });
  });

  group('UpdateDecision', () {
    final latest = releaseOf('0.2.0');

    UpdateDecision decide({
      String? current = '0.1.0',
      FirmwareRelease? release,
      bool noRelease = false,
      bool charging = true,
      bool connected = true,
      int? percent = 60,
    }) =>
        UpdateDecision.evaluate(
          current: current == null ? null : v(current),
          latest: noRelease ? null : (release ?? latest),
          charging: charging,
          connected: connected,
          batteryPercent: percent,
        );

    test('a newer release on the charger is offered', () {
      expect(decide(), UpdateOffered(latest));
    });

    test('nothing is offered without a release', () {
      expect(decide(noRelease: true), const UpdateNone());
    });

    test('the same version is not offered', () {
      expect(decide(current: '0.2.0'), const UpdateNone());
    });

    test('a downgrade is never offered, whatever else is true', () {
      expect(decide(current: '0.3.0'), const UpdateNone());
      expect(decide(current: '0.2.1', connected: false), const UpdateNone());
      expect(decide(current: '1.0.0', charging: false), const UpdateNone());
    });

    test('a release build replaces its own pre-release', () {
      expect(decide(current: '0.2.0-rc1'), UpdateOffered(latest));
    });

    test('off the charger it is blocked, not hidden', () {
      expect(decide(charging: false),
          UpdateBlocked(latest, UpdateBlockReason.notOnCharger));
      expect(decide(charging: false, percent: null),
          UpdateBlocked(latest, UpdateBlockReason.notOnCharger));
    });

    test('a full cell may be on its cable, so the firmware decides', () {
      expect(decide(charging: false, percent: 100), UpdateOffered(latest));
    });

    test('disconnected it is blocked until the recorder is back', () {
      expect(decide(connected: false),
          UpdateBlocked(latest, UpdateBlockReason.notConnected));
    });

    test('connected with no readable version is blocked', () {
      expect(decide(current: null),
          UpdateBlocked(latest, UpdateBlockReason.unknownVersion));
    });

    test('never connected says nothing at all', () {
      expect(decide(current: null, connected: false), const UpdateNone());
    });
  });

  group('DfuBootloader', () {
    test('increments the least significant byte, last in the string', () {
      expect(DfuBootloader.incrementedAddress('C0:11:22:33:44:55'),
          'C0:11:22:33:44:56');
      expect(DfuBootloader.incrementedAddress('c0:11:22:33:44:0f'),
          'C0:11:22:33:44:10');
    });

    test('wraps without a carry, as a uint8_t does', () {
      expect(DfuBootloader.incrementedAddress('C0:11:22:33:44:FF'),
          'C0:11:22:33:44:00');
    });

    test('an iOS identifier has no address to increment', () {
      expect(
          DfuBootloader.incrementedAddress(
              '6E4E5C1A-8D2B-4C3F-9A1B-0C2D3E4F5A6B'),
          isNull);
      expect(DfuBootloader.incrementedAddress('C0:11:22:33:44'), isNull);
      expect(DfuBootloader.incrementedAddress('C0:11:22:33:44:GG'), isNull);
    });

    const ours = DiscoveredDevice(id: 'C0:11:22:33:44:56', rssi: -80);
    const louder = DiscoveredDevice(id: 'D0:00:00:00:00:01', rssi: -40);
    const quiet = DiscoveredDevice(id: 'D0:00:00:00:00:02', rssi: -90);

    test('the recorder\'s own address wins over a louder stranger', () {
      expect(
        DfuBootloader.pick([louder, ours],
            expectedAddress: 'c0:11:22:33:44:56'),
        ours,
      );
    });

    test('without a match the strongest AdaDFU is taken', () {
      expect(DfuBootloader.pick([quiet, louder], expectedAddress: null),
          louder);
      expect(
          DfuBootloader.pick([quiet, louder],
              expectedAddress: 'C0:11:22:33:44:56'),
          louder);
    });

    test('nothing seen is nothing picked', () {
      expect(DfuBootloader.pick(const [], expectedAddress: null), isNull);
    });
  });
}
