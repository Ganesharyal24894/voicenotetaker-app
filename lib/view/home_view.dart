import 'package:flutter/material.dart';

import '../controller/app_controller.dart';
import '../model/device_profile.dart';
import 'placeholder_data.dart';
import 'recording_entry.dart';
import 'scan_view.dart';
import 'theme.dart';
import 'widgets/app_icons.dart';
import 'widgets/common.dart';
import 'widgets/device_mark.dart';
import 'widgets/motion.dart';

/// Screen 2 - home.
class HomeView extends StatelessWidget {
  const HomeView({
    required this.controller,
    required this.recents,
    required this.onOpenLibrary,
    required this.onOpenRecording,
    this.onOpenDeveloper,
    this.now,
    super.key,
  });

  final AppController controller;

  /// The three most recent recordings. Real once a library service exists;
  /// [PlaceholderData.library] until then.
  final List<RecordingEntry> recents;

  final VoidCallback onOpenLibrary;
  final ValueChanged<RecordingEntry> onOpenRecording;

  /// Non-null only in debug builds - see `developer_view.dart`.
  final VoidCallback? onOpenDeveloper;

  /// See [LibraryView.now]: the day labels are relative to this.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final device = controller.connectedDevice;
    final connected = controller.isConnected && device != null;
    final shown = recents.take(3).toList();

    return ScreenScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              // The 38x46 logo slot. It is present in BOTH states - dimmed
              // when disconnected rather than removed - so the header does
              // not jump as the link comes and goes. It is also the landing
              // pad for the board flying in from the scan screen.
              Hero(
                tag: ScanView.deviceMarkHeroTag,
                child: DeviceMark(
                  dimmed: !connected,
                  semanticLabel: 'voiceNotetaker recorder',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      device?.name ?? DeviceProfile.advertisedName,
                      style: AppText.title21,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: <Widget>[
                        // Breathes only while the link is up: a live
                        // condition, not decoration.
                        BreathingDot(
                          breathing: connected,
                          color: connected
                              ? AppColors.connected
                              : AppColors.disconnected,
                        ),
                        const SizedBox(width: 7),
                        Text(
                          connected ? 'Connected' : 'Disconnected',
                          style: AppText.body13,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (onOpenDeveloper != null)
                TapTarget(
                  onTap: onOpenDeveloper,
                  semanticLabel: 'Developer',
                  child: const AppIcon(
                    AppGlyph.more,
                    size: 19,
                    color: AppColors.textSecondary,
                    strokeWidth: 1.7,
                  ),
                ),
              const _BatteryReadout(),
            ],
          ),
          Expanded(
            // Center, not just a centred Column: the surrounding Column aligns
            // to the start, so without this the record button hugs the left
            // gutter instead of sitting on the screen's axis.
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _RecordButton(
                    onTap: connected ? controller.startRecording : null,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    connected ? 'Tap to record' : 'Connect a recorder to start',
                    style: AppText.meta14,
                  ),
                ],
              ),
            ),
          ),
          Row(
            children: <Widget>[
              const SectionCaption('Recent'),
              const Spacer(),
              TapTarget(
                onTap: onOpenLibrary,
                semanticLabel: 'All recordings',
                minSize: AppShape.minTapTarget,
                child: Text(
                  'All',
                  style: AppText.label13.copyWith(color: AppColors.purpleText),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < shown.length; i++)
            _RecentRow(
              entry: shown[i],
              lastInList: i == shown.length - 1,
              onTap: () => onOpenRecording(shown[i]),
              now: now,
            ),
        ],
      ),
    );
  }
}

/// 110px ring, 86px purple disc, a LIGHT mic glyph on the fill.
///
/// A press scales it to 0.93 and back - 120 ms down, 180 ms up.
class _RecordButton extends StatelessWidget {
  const _RecordButton({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: 'Record',
      container: true,
      excludeSemantics: true,
      child: PressScale(
        onTap: onTap,
        child: Opacity(
          opacity: onTap == null ? 0.45 : 1,
          child: Container(
            width: 110,
            height: 110,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.border),
            ),
            alignment: Alignment.center,
            child: Container(
              width: 86,
              height: 86,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primaryFill,
              ),
              alignment: Alignment.center,
              child: const AppIcon(
                AppGlyph.mic,
                size: 31,
                color: AppColors.onPrimaryFill,
                strokeWidth: 1.7,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Battery charge. There is no battery service on the device and no method for
/// one on `BleTransport`, so this renders the unknown state.
class _BatteryReadout extends StatelessWidget {
  const _BatteryReadout();

  @override
  Widget build(BuildContext context) {
    const level = PlaceholderData.batteryLevel;
    return Semantics(
      label: 'Battery',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const BatteryIcon(level: level),
          const SizedBox(width: 6),
          Text(
            level == null ? '—' : '${(level * 100).round()}%',
            style: AppText.meta12,
          ),
        ],
      ),
    );
  }
}

/// `.row` - a 1px top rule, 14px of padding, a play glyph and two lines.
class _RecentRow extends StatelessWidget {
  const _RecentRow({
    required this.entry,
    required this.lastInList,
    required this.onTap,
    this.now,
  });

  final RecordingEntry entry;
  final bool lastInList;
  final VoidCallback onTap;

  /// See [HomeView.now]: threaded down so the day label is pinnable.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: AppShape.minTapTarget),
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          border: Border(
            top: const BorderSide(color: AppColors.raised),
            bottom: lastInList
                ? const BorderSide(color: AppColors.raised)
                : BorderSide.none,
          ),
        ),
        child: Row(
          children: <Widget>[
            const AppIcon(
              AppGlyph.play,
              size: 17,
              color: AppColors.purpleText,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(entry.title, style: AppText.rowTitle),
                  const SizedBox(height: 3),
                  Text(entry.recentLabel(now: now), style: AppText.rowMeta),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
