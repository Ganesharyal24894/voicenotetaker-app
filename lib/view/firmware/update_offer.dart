import 'package:flutter/widgets.dart';

import '../../model/firmware_update.dart';
import '../widgets/common.dart';
import 'update_copy.dart';
import 'update_widgets.dart';

/// "Recorder update", ready or blocked - `UpdateReady.dc.html` and
/// `UpdateBlocked.dc.html`: what's new, the two checks, Update now.
///
/// UPDATE NOW IS ONLY LIVE WHEN [decision] OFFERS THE UPDATE: the recorder is
/// connected (the phone is next to it) and on external power. The firmware
/// refuses `OTA!` off the charger anyway; the button saying so first is
/// kinder than a failure.
class UpdateOffer extends StatelessWidget {
  const UpdateOffer({
    required this.release,
    required this.decision,
    required this.onUpdate,
    required this.onNotNow,
    super.key,
  });

  final FirmwareRelease release;
  final UpdateDecision decision;
  final VoidCallback onUpdate;
  final VoidCallback onNotNow;

  @override
  Widget build(BuildContext context) {
    final reason = switch (decision) {
      UpdateBlocked(:final reason) => reason,
      _ => null,
    };
    final ready = decision is UpdateOffered;
    final cableOnly = reason == UpdateBlockReason.unknownVersion;
    final phoneMet = reason != UpdateBlockReason.notConnected;
    // Off the link the charger cannot be known, so it is asked for.
    final chargerMet = ready;
    final notes = release.notes.trim();

    return ScreenScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          UpdateHeader(
            title: UpdateCopy.title,
            subtitle: UpdateCopy.published(release),
            onBack: onNotNow,
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: <Widget>[
                if (notes.isNotEmpty) _WhatsNew(notes: notes),
                if (!cableOnly) ...<Widget>[
                  Padding(
                    padding: EdgeInsets.only(top: notes.isEmpty ? 0 : 24, bottom: 8),
                    child: const SectionCaption(UpdateCopy.beforeYouStart),
                  ),
                  CheckRow(
                    met: chargerMet,
                    title: chargerMet ? UpdateCopy.onCharger : UpdateCopy.putOnCharger,
                    why: UpdateCopy.putOnChargerWhy,
                  ),
                  const SizedBox(height: 8),
                  CheckRow(
                    met: phoneMet,
                    title: phoneMet ? UpdateCopy.phoneNearby : UpdateCopy.bringPhone,
                    why: UpdateCopy.bringPhoneWhy,
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 20, 4, 0),
                  child: Text(
                    cableOnly ? UpdateCopy.cableOnly : UpdateCopy.takesAbout,
                    style: UpdateText.paragraph,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          UpdateButton(label: UpdateCopy.updateNow, onPressed: ready ? onUpdate : null),
          UpdateTextButton(label: UpdateCopy.notNow, onPressed: onNotNow),
        ],
      ),
    );
  }
}

class _WhatsNew extends StatelessWidget {
  const _WhatsNew({required this.notes});

  final String notes;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SectionCaption(UpdateCopy.whatsNew),
          const SizedBox(height: 10),
          Text(notes, style: UpdateText.notes),
        ],
      ),
    );
  }
}
