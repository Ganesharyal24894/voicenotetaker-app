import 'package:flutter/material.dart';

import 'theme.dart';
import 'widgets/app_icons.dart';
import 'widgets/common.dart';
import 'widgets/edge_state.dart';

/// "Pair a new phone", from Settings - the charger instructions, told to the
/// phone that is ALREADY paired.
///
/// The pairing itself happens on the other phone, so this screen only says
/// what to do there, and what becomes of this phone. Nothing on the recorder
/// is erased until the new phone has actually paired.
class PairNewPhoneView extends StatelessWidget {
  const PairNewPhoneView({required this.onBack, super.key});

  final VoidCallback onBack;

  static const String headline = 'Pair a new phone';

  static const String body =
      'On the new phone, open voiceNotetaker. Put your recorder on its '
      'charger, then double-tap it. Its light blinks white for one minute '
      'while it’s ready to pair. After that, this phone stops connecting.';

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Transform.translate(
            offset: const Offset(-12, 0),
            child: TapTarget(
              onTap: onBack,
              semanticLabel: 'Back',
              child: const AppIcon(
                AppGlyph.chevronLeft,
                size: 20,
                color: AppColors.textSecondary,
                strokeWidth: 1.7,
              ),
            ),
          ),
          Expanded(
            child: EdgeState(
              glyph: AppGlyph.bluetooth,
              // Purple: nothing is wrong.
              tint: AppColors.purpleText,
              headline: headline,
              body: body,
              primaryLabel: 'Done',
              onPrimary: onBack,
            ),
          ),
        ],
      ),
    );
  }
}
