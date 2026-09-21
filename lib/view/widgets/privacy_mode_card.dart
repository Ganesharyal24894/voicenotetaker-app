import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../controller/app_controller.dart';
import '../../model/notes_saving.dart';
import '../theme.dart';
import 'common.dart';
import 'home_widgets.dart';

/// Recorder settings → Listening: the Privacy mode switch, directly under
/// Always listening and built the same way. From
/// `canvas-privacy/Settings{Off,On,Disconnected}.dc.html`.
///
/// THE SWITCH IS THE RECORDER'S STATE, NOT THE TAP. A tap asks the recorder;
/// the switch moves when the recorder reports privacy mode on `fe08`. It can
/// only be used while always listening runs on a live link - the only time
/// that answer is heard - and is disabled otherwise.
class PrivacyModeCard extends StatelessWidget {
  const PrivacyModeCard({required this.controller, super.key});

  final AppController controller;

  static const String title = 'Privacy mode';
  static const String metaOff = 'Pause listening for a while';
  static const String metaOn = "Your recorder isn't listening";
  static const String metaUnavailable = 'Connect your recorder to use privacy mode';
  static const String footnote =
      'You can also double-tap your recorder. Its light turns red while '
      'privacy mode is on.';

  @override
  Widget build(BuildContext context) {
    final on = controller.notesSaving == NotesSaving.privacyMode;
    final available = controller.canSetPrivacyMode;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AppCard(
            padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text(title, style: AppText.rowTitle),
                      const SizedBox(height: 4),
                      Text(
                        !available ? metaUnavailable : (on ? metaOn : metaOff),
                        style: AppText.rowMeta,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                HomeSwitch(
                  label: title,
                  value: on,
                  onChanged: available
                      ? (wanted) => unawaited(
                            wanted
                                ? controller.turnPrivacyModeOn()
                                : controller.turnPrivacyModeOff(),
                          )
                      : null,
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(footnote, style: AppText.footnote12),
          ),
        ],
      ),
    );
  }
}
