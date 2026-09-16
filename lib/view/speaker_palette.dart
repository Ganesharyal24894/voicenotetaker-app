import 'package:flutter/painting.dart';

import 'theme.dart';

/// The colours that tell one speaker from another, inside one note.
///
/// STABLE PER LABEL, NOT PER ROW. A speaker's colour comes from where that
/// label first speaks, so the dot beside "Priya" in the Speakers sheet, her
/// chip under the title and her name above each of her paragraphs are the
/// same colour - and stay that colour when another speaker is renamed or a
/// row moves. Merging two speakers does change the order, and so may change a
/// colour; that is the transcript changing, not the palette drifting.
///
/// ALL TEXT-SAFE ON THE DARK BACKGROUND. Each is a token from `theme.dart`
/// that already clears 4.5:1 against [AppColors.screen], because these are
/// drawn as small text as well as dots - see the contrast rule in
/// `theme.dart`. [AppColors.primaryFill] is deliberately NOT here: it is a
/// fill colour and measures 2.78:1.
abstract final class SpeakerPalette {
  /// The canvas uses purple, green and amber for the three speakers it shows;
  /// the last two carry a fourth and fifth voice.
  static const List<Color> colors = <Color>[
    AppColors.purpleText,
    AppColors.connected,
    AppColors.warning,
    AppColors.recording,
    AppColors.purple300,
  ];

  /// The colour of the speaker in position [index]. Wraps past the end of
  /// [colors], and treats "not found" (-1) as the first.
  static Color at(int index) =>
      colors[(index < 0 ? 0 : index) % colors.length];

  /// The colour of [label] in a note whose speakers first speak in the order
  /// [order]. A label that is not in [order] gets the first colour.
  static Color of(String label, List<String> order) => at(order.indexOf(label));
}
