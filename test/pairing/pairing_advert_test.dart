import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/model/pairing_advert.dart';

/// The scan-response flags - firmware `doc/pairing.md`, "Advertised status".
void main() {
  group('the AD structure the firmware sends', () {
    test('05 FF FF FF 01 00: ready to pair', () {
      expect(
        PairingAdvert.fromAdStructure(<int>[0x05, 0xFF, 0xFF, 0xFF, 0x01, 0x00]),
        const PairingAdvert(owned: false, windowOpen: false),
      );
    });

    test('01: paired to another phone', () {
      expect(
        PairingAdvert.fromAdStructure(<int>[0x05, 0xFF, 0xFF, 0xFF, 0x01, 0x01]),
        const PairingAdvert(owned: true, windowOpen: false),
      );
    });

    test('02 and 03: pairing window open', () {
      expect(
        PairingAdvert.fromAdStructure(<int>[0x05, 0xFF, 0xFF, 0xFF, 0x01, 0x02]),
        const PairingAdvert(owned: false, windowOpen: true),
      );
      expect(
        PairingAdvert.fromAdStructure(<int>[0x05, 0xFF, 0xFF, 0xFF, 0x01, 0x03]),
        const PairingAdvert(owned: true, windowOpen: true),
      );
    });

    test('reserved bits are ignored', () {
      final advert = PairingAdvert.fromAdStructure(
        <int>[0x05, 0xFF, 0xFF, 0xFF, 0x01, 0xFD],
      );
      expect(advert, const PairingAdvert(owned: true, windowOpen: false));
      expect(advert!.flags, 0x01);
    });

    test('anything else is not a status', () {
      expect(PairingAdvert.fromAdStructure(<int>[]), isNull);
      expect(PairingAdvert.fromAdStructure(<int>[0x05, 0x09, 0x76, 0x6F, 0x69, 0x63]),
          isNull, reason: 'a name field');
      expect(PairingAdvert.fromAdStructure(<int>[0x05, 0xFF, 0x59, 0x00, 0x01, 0x01]),
          isNull, reason: 'another company id');
      expect(PairingAdvert.fromAdStructure(<int>[0x05, 0xFF, 0xFF, 0xFF]), isNull,
          reason: 'truncated');
    });
  });

  group('manufacturer data as the platform reports it', () {
    test('company 0xFFFF, format 1', () {
      expect(
        PairingAdvert.fromManufacturer(0xFFFF, <int>[0x01, 0x01]),
        const PairingAdvert(owned: true, windowOpen: false),
      );
    });

    test('an unknown format or a short payload is older firmware', () {
      expect(PairingAdvert.fromManufacturer(0xFFFF, <int>[0x02, 0x01]), isNull);
      expect(PairingAdvert.fromManufacturer(0xFFFF, <int>[0x01]), isNull);
      expect(PairingAdvert.fromManufacturer(0xFFFF, <int>[]), isNull);
    });

    test('a longer payload of format 1 still reads its flags', () {
      expect(
        PairingAdvert.fromManufacturer(0xFFFF, <int>[0x01, 0x02, 0x00, 0x00]),
        const PairingAdvert(owned: false, windowOpen: true),
      );
    });

    test('no field at all - older firmware - is null', () {
      expect(PairingAdvert.parse(const <(int, List<int>)>[]), isNull);
    });

    test('the recorder field is found among others', () {
      expect(
        PairingAdvert.parse(<(int, List<int>)>[
          (0x004C, <int>[0x02, 0x15]),
          (0xFFFF, <int>[0x01, 0x03]),
        ]),
        const PairingAdvert(owned: true, windowOpen: true),
      );
    });
  });

  group('DiscoveredDevice across scan results', () {
    const bare = DiscoveredDevice(id: 'A', name: 'voiceNotetaker', rssi: -60);
    const withStatus = DiscoveredDevice(
      id: 'A',
      rssi: -55,
      pairing: PairingAdvert(owned: true, windowOpen: false),
      bonded: false,
    );

    test('a scan response adds the status', () {
      final merged = bare.mergedWith(withStatus);
      expect(merged.pairing, withStatus.pairing);
      expect(merged.name, 'voiceNotetaker');
      expect(merged.bonded, isFalse);
      expect(merged.differsFrom(bare), isTrue);
    });

    test('a result without one does not erase it', () {
      final merged = withStatus.mergedWith(bare);
      expect(merged.pairing, withStatus.pairing);
    });

    test('the window opening is a change worth redrawing', () {
      final open = withStatus.mergedWith(
        const DiscoveredDevice(
          id: 'A',
          pairing: PairingAdvert(owned: true, windowOpen: true),
        ),
      );
      expect(open.differsFrom(withStatus), isTrue);
      expect(withStatus.mergedWith(withStatus).differsFrom(withStatus), isFalse);
    });
  });
}
