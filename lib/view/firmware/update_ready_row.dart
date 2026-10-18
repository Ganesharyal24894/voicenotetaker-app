import 'package:flutter/widgets.dart';

import '../../model/firmware_update.dart';
import '../../model/firmware_update_state.dart';
import '../../services/firmware/firmware_update_service.dart';
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';
import 'update_copy.dart';
import 'update_widgets.dart';

/// Today's quiet "A recorder update is ready" row, under the header -
/// `canvas-update/project/Main.dc.html`.
///
/// Only while the update can actually be installed now ([UpdateOffered]: the
/// recorder is connected and on its charger) and no run is under way. Nothing
/// happens until the row is tapped and Update now is pressed.
class UpdateReadyRow extends StatelessWidget {
  const UpdateReadyRow({required this.updates, required this.onOpen, super.key});

  /// Null - a build or a test without the service - shows nothing.
  final FirmwareUpdateService? updates;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final updates = this.updates;
    if (updates == null) return const SizedBox.shrink();
    return ValueListenableBuilder<UpdateState>(
      valueListenable: updates.state,
      builder: (context, state, _) {
        final resting = state is UpdateIdle ||
            state is UpdateChecking ||
            state is UpdateAvailable ||
            state is UpdateReadyToInstall;
        final decision = updates.decision;
        if (!resting || decision is! UpdateOffered) {
          return const SizedBox.shrink();
        }
        return _Row(
          meta: UpdateCopy.todayMeta(decision.release.version),
          onTap: onOpen,
        );
      },
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.meta, required this.onTap});

  final String meta;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppShape.gutter, 0, AppShape.gutter, 14),
      child: Semantics(
        button: true,
        label: UpdateCopy.todayTitle,
        value: meta,
        container: true,
        excludeSemantics: true,
        onTap: onTap,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AppCard(
            borderColor: AppColors.purpleChipBorder,
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
            child: Row(
              children: <Widget>[
                const StrokeGlyph(
                  size: 22,
                  color: AppColors.purpleText,
                  paths: updateGlyph,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text(UpdateCopy.todayTitle, style: AppText.rowTitle),
                      const SizedBox(height: 3),
                      Text(
                        meta,
                        style: AppText.rowMeta.copyWith(color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                const AppIcon(AppGlyph.chevronRight,
                    size: 13, color: AppColors.textTertiary, strokeWidth: 1.7),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
