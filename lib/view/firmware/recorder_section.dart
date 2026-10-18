import 'package:flutter/widgets.dart';

import '../../model/firmware_update.dart';
import '../../model/firmware_update_state.dart';
import '../../services/firmware/firmware_update_service.dart';
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';
import 'update_copy.dart';

/// Recorder settings' RECORDER section - `canvas-update/project/Settings.dc.html`:
/// the Software row, and Diagnostics under it.
///
/// It owns the gap above itself and draws nothing when it has no rows, so
/// either row can go without touching the screen around it.
class RecorderSection extends StatelessWidget {
  const RecorderSection({
    this.updates,
    this.onOpenUpdate,
    this.onOpenDiagnostics,
    super.key,
  });

  /// Null hides the Software row.
  final FirmwareUpdateService? updates;
  final VoidCallback? onOpenUpdate;

  /// Null hides the Diagnostics row.
  final VoidCallback? onOpenDiagnostics;

  @override
  Widget build(BuildContext context) {
    final updates = this.updates;
    final rows = <Widget>[
      if (updates != null)
        ValueListenableBuilder<UpdateState>(
          valueListenable: updates.state,
          builder: (context, state, _) {
            final row = SoftwareLine.of(
              state: state,
              decision: updates.decision,
              installed: updates.installedVersion,
              latestKnown: updates.latestRelease != null,
            );
            return SettingsLinkCard(
              title: UpdateCopy.softwareTitle,
              meta: row.meta,
              dot: row.dot,
              onTap: row.opens ? onOpenUpdate : null,
            );
          },
        ),
      if (onOpenDiagnostics != null)
        SettingsLinkCard(
          title: 'Diagnostics',
          meta: 'Battery, connection, mic check',
          onTap: onOpenDiagnostics,
        ),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: 16),
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: SectionCaption(UpdateCopy.section),
        ),
        for (var i = 0; i < rows.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: 8),
          rows[i],
        ],
      ],
    );
  }
}

/// What the Software row says, and whether it leads anywhere. Pure.
class SoftwareLine {
  const SoftwareLine(this.meta, {this.dot, this.opens = false});

  final String meta;
  final Color? dot;
  final bool opens;

  static SoftwareLine of({
    required UpdateState state,
    required UpdateDecision decision,
    required FirmwareVersion? installed,
    required bool latestKnown,
  }) {
    switch (state) {
      case UpdateChecking():
        return const SoftwareLine(UpdateCopy.checking);
      case UpdateDownloading(:final release) ||
            UpdateWaitingForBootloader(:final release) ||
            UpdateTransferring(:final release) ||
            UpdateConfirming(:final release):
        return SoftwareLine(UpdateCopy.updating(release.version),
            dot: AppColors.purpleText, opens: true);
      case UpdateFailed():
        return const SoftwareLine(UpdateCopy.didNotFinishShort,
            dot: AppColors.warning, opens: true);
      case UpdateDone(:final version):
        return SoftwareLine(UpdateCopy.upToDate(version), opens: true);
      default:
        break;
    }
    switch (decision) {
      case UpdateBlocked(reason: UpdateBlockReason.unknownVersion):
        return const SoftwareLine(UpdateCopy.versionUnreadable, opens: true);
      case UpdateOffered(:final release) || UpdateBlocked(:final release):
        if (installed != null) {
          return SoftwareLine(UpdateCopy.updateReady(installed, release.version),
              dot: AppColors.purpleText, opens: true);
        }
      case UpdateNone():
        break;
    }
    if (installed == null) return const SoftwareLine(UpdateCopy.versionUnknown);
    // Never "up to date" before any release has been looked at.
    return SoftwareLine(latestKnown
        ? UpdateCopy.upToDate(installed)
        : UpdateCopy.versionLine(installed));
  }
}

/// A Recorder-section row: a title, a line of meta with an optional dot, and
/// a chevron when it leads somewhere.
class SettingsLinkCard extends StatelessWidget {
  const SettingsLinkCard({
    required this.title,
    required this.meta,
    this.dot,
    this.onTap,
    super.key,
  });

  final String title;
  final String meta;
  final Color? dot;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onTap != null,
      label: title,
      value: meta,
      container: true,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AppCard(
          borderColor: dot == AppColors.purpleText
              ? AppColors.purpleChipBorder
              : AppColors.raised,
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(title, style: AppText.rowTitle),
                    const SizedBox(height: 4),
                    Row(
                      children: <Widget>[
                        if (dot != null) ...<Widget>[
                          StatusDot(color: dot!),
                          const SizedBox(width: 7),
                        ],
                        Flexible(
                          child: Text(
                            meta,
                            style: dot == null
                                ? AppText.rowMeta
                                : AppText.rowMeta.copyWith(color: AppColors.textSecondary),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (onTap != null)
                const AppIcon(AppGlyph.chevronRight,
                    size: 13, color: AppColors.textTertiary, strokeWidth: 1.7),
            ],
          ),
        ),
      ),
    );
  }
}
