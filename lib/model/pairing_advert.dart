/// The recorder's pairing status, read from its scan response.
///
/// Firmware that pairs to one phone puts one manufacturer-specific field in
/// its SCAN RESPONSE (not the advertising packet, so idle advertising costs
/// nothing more):
///
/// | Bytes  | Value                                                    |
/// |--------|----------------------------------------------------------|
/// | `[0]`  | AD length `0x05`                                         |
/// | `[1]`  | AD type `0xFF`, manufacturer-specific data               |
/// | `[2..3]` | company id `0xFFFF`, little-endian                     |
/// | `[4]`  | format `0x01`                                            |
/// | `[5]`  | flags: bit 0 has an owner, bit 1 pairing window open     |
///
/// Reserved flag bits are ignored. NO FIELD, or a format other than 1, is
/// older firmware with no pairing at all: [parse] answers null and the app
/// connects exactly as it always did.
///
/// See the firmware's `doc/pairing.md` and `model/pairing_model.h`.
class PairingAdvert {
  const PairingAdvert({required this.owned, required this.windowOpen});

  /// "No registered company" - matched together with the advertised name.
  static const int companyId = 0xFFFF;

  /// Layout version of the payload after the company id.
  static const int format = 1;

  static const int flagOwned = 0x01;
  static const int flagWindowOpen = 0x02;

  /// The recorder has an owner phone.
  final bool owned;

  /// The owner opened a pairing window (charger + double-tap): a new phone may
  /// pair now.
  final bool windowOpen;

  /// The flags byte as the firmware sends it, reserved bits clear.
  int get flags => (owned ? flagOwned : 0) | (windowOpen ? flagWindowOpen : 0);

  /// The status in one manufacturer field, given as its company id and the
  /// bytes after it. Null when the field is not the recorder's, or is a layout
  /// this build does not know.
  static PairingAdvert? fromManufacturer(int company, List<int> payload) {
    if (company != companyId) return null;
    if (payload.length < 2 || payload[0] != format) return null;
    final flags = payload[1];
    return PairingAdvert(
      owned: flags & flagOwned != 0,
      windowOpen: flags & flagWindowOpen != 0,
    );
  }

  /// The first recognisable status among all manufacturer fields a scan
  /// result carried, or null (older firmware).
  static PairingAdvert? parse(Iterable<(int, List<int>)> manufacturerData) {
    for (final (company, payload) in manufacturerData) {
      final advert = fromManufacturer(company, payload);
      if (advert != null) return advert;
    }
    return null;
  }

  /// The status in a raw AD structure - `05 FF FF FF 01 <flags>` - as a
  /// sniffer or the firmware doc shows it. Null for anything else.
  static PairingAdvert? fromAdStructure(List<int> bytes) {
    if (bytes.length < 2) return null;
    final length = bytes[0];
    if (bytes[1] != 0xFF || length < 3 || bytes.length < length + 1) {
      return null;
    }
    final company = bytes[2] | (bytes[3] << 8);
    return fromManufacturer(company, bytes.sublist(4, length + 1));
  }

  @override
  bool operator ==(Object other) =>
      other is PairingAdvert &&
      other.owned == owned &&
      other.windowOpen == windowOpen;

  @override
  int get hashCode => Object.hash(owned, windowOpen);

  @override
  String toString() => 'PairingAdvert(flags: 0x${flags.toRadixString(16).padLeft(2, '0')})';
}
