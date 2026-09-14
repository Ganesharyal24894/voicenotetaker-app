/// How a recorder in the scan list stands with THIS phone.
///
/// PURE: from the scan response, the OS bond state and what the app
/// remembers. The words on screen are the view's (`scan_view.dart`).
library;

import 'pairing_advert.dart';

enum RecorderPairing {
  /// Older firmware: no pairing at all. Shown as it always was.
  legacy,

  /// No owner yet: the first phone that pairs becomes it.
  readyToPair,

  /// This phone is the owner.
  yours,

  /// Another phone owns it and its pairing window is shut.
  pairedToAnother,

  /// Its pairing window is open: this phone can pair now.
  pairingMode;

  /// Resolves the state of one recorder.
  ///
  /// [bonded] is the OS bond (Android; null elsewhere), [remembered] whether
  /// the app recorded a successful encrypted connection to this id, and
  /// [refusedHere] whether the recorder refused this phone since the app
  /// started - which outranks a stale bond the OS still lists.
  static RecorderPairing resolve({
    required PairingAdvert? advert,
    bool? bonded,
    bool remembered = false,
    bool refusedHere = false,
  }) {
    if (advert == null) return RecorderPairing.legacy;
    final ours = (bonded ?? false) || remembered;
    if (advert.windowOpen) {
      return ours && advert.owned && !refusedHere
          ? RecorderPairing.yours
          : RecorderPairing.pairingMode;
    }
    if (!advert.owned) return RecorderPairing.readyToPair;
    if (refusedHere) return RecorderPairing.pairedToAnother;
    return ours ? RecorderPairing.yours : RecorderPairing.pairedToAnother;
  }
}
