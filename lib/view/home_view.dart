import 'dart:async';

import 'package:flutter/material.dart';

import '../controller/app_controller.dart';
import '../model/battery_bars.dart';
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

    // Scrollable ONLY when it has to be. At a normal portrait height the
    // minHeight equals the viewport, IntrinsicHeight resolves to exactly
    // that, and the Expanded below takes up the slack -- identical to a
    // plain Column. Turn the phone to landscape and the fixed rows (header,
    // "Recent", three entries) leave far less room than the record block
    // needs, so the intrinsic height exceeds the viewport and the page
    // scrolls instead of overflowing.
    //
    // The bug this fixes rendered as a black-and-yellow "BOTTOM OVERFLOWED
    // BY 201 PIXELS" banner across the record button in debug, and would
    // have silently CLIPPED the Disconnect button in release -- which is
    // worse, because nothing would have said so.
    return ScreenScaffold(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
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
                        // Charging is stated in WORDS here, so the battery
                        // readout's green tint is a reinforcement rather than
                        // the only way to tell 40% charging from 40% draining.
                        //
                        // It REPLACES "Connected" rather than being appended
                        // to it: "Connected · Charging" does not fit beside
                        // the name, the battery and the developer entry point
                        // at 390px, and the breathing green dot immediately to
                        // its left already says the link is up.
                        //
                        // Flexible, because a narrower phone or a longer
                        // device name must ellipsise rather than overflow.
                        Flexible(
                          child: Text(
                            connected
                                ? (controller.batteryCharging
                                    ? 'Charging'
                                    : 'Connected')
                                : 'Disconnected',
                            style: AppText.body13,
                            overflow: TextOverflow.ellipsis,
                          ),
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
              _BatteryReadout(controller: controller),
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
                  if (connected) ...<Widget>[
                    const SizedBox(height: 24),
                    _DisconnectChip(
                      onTap: () => unawaited(controller.disconnect()),
                    ),
                  ],
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
              ),
            ),
          );
        },
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

/// Battery charge and charging state, from the device's `fe05` characteristic.
///
/// FOUR BARS, NOT A FIGURE. The device derives its percentage from cell
/// voltage against an OCV curve, and across the middle of that curve about two
/// millivolts separate one point from the next - so a mid-range figure is
/// precise-looking and not reliable. [BatteryBars] explains the shape of the
/// error and why four buckets are what the measurement supports. The
/// percentage itself is not thrown away: the device still reports it, and the
/// developer screen still shows it, where precision is worth something.
///
/// NOTHING REPLACED THE FIGURE. No word stands where "87%" did, for two
/// reasons: the status line directly under the device name already says
/// "Charging" or "Connected" in words, so a second word here would either
/// repeat it or fight it; and every phone in the user's pocket shows this
/// state as a glyph alone. Dropping the reserved 34px also gives the device
/// name that much more room before it has to ellipsise, which matters at
/// 390px and in landscape.
///
/// THREE STATES, AND 0% IS NONE OF THEM:
///
///   * bars - the device measured a charge and said so;
///   * unknown because the device has no reading (`0xFF` on the wire);
///   * unknown because there is no `fe05` at all - older firmware, a failed
///     read, or nothing connected.
///
/// The last two draw an EMPTY SHELL with no slots in it at all, which is a
/// different picture from the four faint slots of a measured, flat cell. A
/// flat battery and an unanswered question look nothing alike here, which is
/// the whole point.
///
/// Charging is shown separately from the charge, and is knowable even when the
/// charge is not: the glyph carries a bolt, turns green, and the status line
/// says "Charging" in words, so the state never rests on colour alone.
class _BatteryReadout extends StatelessWidget {
  const _BatteryReadout({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    // The percentage is read for ONE purpose: telling a measured charge from
    // no measurement at all. `BatteryBars` reports zero bars for both a flat
    // cell and an unread one - deliberately, since they are both "no bars" -
    // and the glyph needs to draw them differently.
    final percent = controller.batteryPercent;
    final bars = controller.batteryBars;
    final charging = controller.batteryCharging;

    return Semantics(
      label: _semanticLabel(percent, bars, charging),
      container: true,
      excludeSemantics: true,
      // The glyph is a fixed 18px in every state, so the header cannot reflow
      // as the charge moves, as the link comes and goes, or when the reading
      // disappears entirely.
      child: BatteryIcon(
        bars: percent == null ? null : bars.bars,
        color: _tint(bars, charging),
        charging: charging,
      ),
    );
  }

  /// The tint, from the theme's existing tokens only.
  ///
  /// Charging outranks everything: the user has already done the thing a red
  /// shell would be asking for, so amber-thinking here would be nagging. Full
  /// and charging share the green - the BOLT is what separates them, which is
  /// why it is drawn as a shape rather than as a colour change.
  static Color _tint(BatteryBars bars, bool charging) {
    if (charging) return AppColors.connected;
    if (bars.isCritical) return AppColors.error;
    if (bars.isFull) return AppColors.connected;
    return AppColors.textTertiary;
  }

  /// Spelt out for a screen reader, where the colour means nothing and the
  /// bars cannot be counted.
  ///
  /// IN WORDS, AND STILL NOT AS A PERCENTAGE. A screen-reader user cannot see
  /// that the display only has four positions, so reading them "47 percent"
  /// would hand them a precision the measurement does not have AND hide the
  /// fact that it is an estimate - a worse deal than a sighted user gets, not
  /// an equal one. Full, empty and critically low are named outright, because
  /// those are the states a count of bars is worst at conveying.
  static String _semanticLabel(int? percent, BatteryBars bars, bool charging) {
    final String state;
    if (percent == null) {
      state = 'level unknown';
    } else if (bars.isFull) {
      state = 'full';
    } else if (bars.bars == 0) {
      // Already the emptiest thing the glyph can draw; ", critically low"
      // after "empty" would add nothing.
      state = 'empty';
    } else {
      state = '${bars.bars} of ${BatteryBars.maxBars} bars'
          '${bars.isCritical ? ', critically low' : ''}';
    }
    return charging ? 'Battery $state, charging' : 'Battery $state';
  }
}

/// Ends the link with the recorder.
///
/// Placed with the connection state rather than in the header: the header is
/// only 46px tall and already carries the logo, the device name, the battery
/// and (in debug) the developer entry point, and the sentence directly under
/// the record button - "Tap to record" / "Connect a recorder to start" - is
/// where this screen already talks about whether a recorder is attached.
///
/// The same quiet pill as the playback screen's speed and Transcribe chips, so
/// this introduces no new control idiom. It is shown ONLY while connected; it
/// is not confirmed, because disconnecting destroys nothing and reconnecting
/// is one tap on the screen it returns to.
class _DisconnectChip extends StatelessWidget {
  const _DisconnectChip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TapTarget(
      onTap: onTap,
      semanticLabel: 'Disconnect',
      // Red, because this is the one control on Home that takes something
      // away. It stays an outline rather than a filled button: destructive
      // AND quiet, so it reads as available without competing with the
      // record button it sits under.
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.errorBorder),
          borderRadius: AppShape.pill,
        ),
        child: Text(
          'Disconnect',
          style: AppText.label13.copyWith(color: AppColors.error),
        ),
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
