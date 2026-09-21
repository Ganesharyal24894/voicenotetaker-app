import 'package:flutter/widgets.dart';

import '../../model/home_status.dart';
import '../theme.dart';

/// The ONE place a [HomeStatusTone] becomes a colour, so the header on Home
/// and the Always listening card cannot disagree.
///
/// Privacy mode is purple, not amber: it is the wearer's choice, and amber is
/// what "Not saving — recorder disconnected" wears.
abstract final class StatusToneColors {
  /// The dot before the status: green while saving, amber while not, purple
  /// in privacy mode, grey when nothing is wrong and nothing is happening.
  static Color dot(HomeStatusTone tone) => switch (tone) {
        HomeStatusTone.good => AppColors.connected,
        HomeStatusTone.warning => AppColors.warning,
        HomeStatusTone.privacy => AppColors.purple400,
        HomeStatusTone.idle => AppColors.disconnected,
      };

  /// The status line's words on Home. Only the two that need the wearer's
  /// eye leave the secondary grey.
  static Color label(HomeStatusTone tone) => switch (tone) {
        HomeStatusTone.warning => AppColors.warning,
        HomeStatusTone.privacy => AppColors.purple300,
        HomeStatusTone.good || HomeStatusTone.idle => AppColors.textSecondary,
      };
}
