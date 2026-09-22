import 'dart:async';

import 'package:flutter/material.dart';

import '../controller/app_controller.dart';
import '../controller/assistant_controller.dart';
import '../controller/summary_controller.dart';
import '../model/battery_bars.dart';
import '../model/device_profile.dart';
import '../model/home_status.dart';
import '../model/notes_overview.dart';
import '../model/recording_info.dart';
import 'assistant_view.dart';
import 'home/notes_tab.dart';
import 'home/summarize_sheet.dart';
import 'home/today_tab.dart';
import 'recording_entry.dart';
import 'theme.dart';
import 'widgets/app_icons.dart';
import 'widgets/common.dart';
import 'widgets/connect_banner.dart';
import 'widgets/home_widgets.dart';
import 'widgets/motion.dart';
import 'widgets/privacy_banner.dart';
import 'widgets/status_tone.dart';

/// Screen 2 - home: two tabs under one header.
///
/// TODAY (the default) is what your AI made of your day; NOTES is where the
/// transcripts stand. The header answers "are my notes being saved?" on both,
/// and holds the battery, manual recording and the menu. See
/// `doc/today-and-summaries.md`.
class HomeView extends StatefulWidget {
  const HomeView({
    required this.controller,
    required this.summaries,
    required this.onOpenLibrary,
    required this.onOpenRecording,
    this.assistant,
    this.onOpenSettings,
    this.onConnect,
    super.key,
  });

  final AppController controller;
  final SummaryController summaries;

  /// Only for the Undo banner above the tab bar. Null shows no banner, which
  /// is right for a build without the feature.
  final AssistantController? assistant;

  final VoidCallback onOpenLibrary;
  final ValueChanged<RecordingEntry> onOpenRecording;

  /// Opens Recorder settings - from the status line and from the menu. Non-null
  /// in RELEASE builds too; Diagnostics is one row further in. Null hides the
  /// menu and makes the status line plain text.
  final VoidCallback? onOpenSettings;

  /// Opens the scan screen over Home, from the card Today shows while always
  /// listening has no recorder. Null leaves the card out.
  final VoidCallback? onConnect;

  static const int todayTab = 0;
  static const int notesTab = 1;

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
  int _tab = HomeView.todayTab;

  AppController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    if (!widget.summaries.isLoaded) unawaited(widget.summaries.load());
  }

  void _openRecording(RecordingInfo info) {
    widget.onOpenRecording(
      RecordingEntry.fromInfo(
        info,
        isWriting: info.path == _controller.writingNotePath,
        transcript: _controller.transcriptionAvailable
            ? _controller.listTranscriptStatusFor(info)
            : null,
      ),
    );
  }

  Future<void> _paste() async {
    final result = await widget.summaries.pasteFromClipboard();
    if (!mounted) return;
    switch (result) {
      case PasteResult.saved:
        setState(() => _tab = HomeView.todayTab);
      case PasteResult.emptyClipboard:
        showHomeMessage(context, SummaryController.emptyClipboardMessage);
      case PasteResult.unreadable:
        showHomeMessage(context, SummaryController.unreadableMessage);
    }
  }

  void _summarize() => unawaited(
        showSummarizeSheet(
          context,
          summaries: widget.summaries,
          recordings: _controller.recordings,
        ),
      );

  void _record() {
    final connected = _controller.isConnected && _controller.connectedDevice != null;
    if (_controller.continuousActive) {
      showHomeMessage(context, 'Notes already save on their own while always listening is on.');
    } else if (!connected) {
      showHomeMessage(context, 'Connect your recorder to record.');
    } else {
      unawaited(_controller.startRecording());
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final viewPadding = MediaQuery.viewPaddingOf(context);
    final now = widget.summaries.now;
    return Scaffold(
      backgroundColor: AppColors.screen,
      body: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.fromLTRB(AppShape.gutter, viewPadding.top + 15, AppShape.gutter, 0),
              child: _HomeHeader(
                controller: controller,
                onStatus: widget.onOpenSettings,
                onRecord: _record,
                onMenu: widget.onOpenSettings,
              ),
            ),
            const SizedBox(height: 14),
            // One slot, two cards that never show together: privacy mode
            // needs a live link, and the connect card needs none.
            if (_tab == HomeView.todayTab) ...<Widget>[
              PrivacyBanner(controller: controller),
              ConnectBanner(controller: controller, onConnect: widget.onConnect),
            ],
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: <Widget>[
                  TodayTab(
                    summaries: widget.summaries,
                    recordings: controller.recordings,
                    onOpenRecording: _openRecording,
                    onSummarize: _summarize,
                    onPaste: () => unawaited(_paste()),
                  ),
                  NotesTab(
                    overview: NotesOverview.derive(
                      recordings: controller.recordings,
                      now: now,
                      statusOf: controller.listTranscriptStatusFor,
                      writingPath: controller.writingNotePath,
                      transcribingPath: controller.transcribingPath,
                      transcriptionDone: controller.transcriptionDone,
                      transcriptionTotal: controller.transcriptionTotal,
                      autoDeleteAudio: controller.autoDeleteAudio,
                    ),
                    now: now,
                    onOpenRecording: _openRecording,
                    onOpenLibrary: widget.onOpenLibrary,
                  ),
                ],
              ),
            ),
            // Above the tab bar, below whichever tab is up: an instruction
            // can be stopped from either one.
            if (widget.assistant != null)
              AssistantUndoBanner(assistant: widget.assistant!),
            HomeTabBar(index: _tab, onSelect: (index) => setState(() => _tab = index)),
          ],
        ),
      ),
    );
  }
}

/// The header both tabs share: name, saving status, battery, record, menu.
class _HomeHeader extends StatelessWidget {
  const _HomeHeader({
    required this.controller,
    required this.onStatus,
    required this.onRecord,
    required this.onMenu,
  });

  final AppController controller;
  final VoidCallback? onStatus;
  final VoidCallback onRecord;
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) {
    final device = controller.connectedDevice;
    final connected = controller.isConnected && device != null;
    final status = HomeStatus.resolve(
      continuous: controller.continuousStatus,
      connected: connected,
      charging: controller.batteryCharging,
      storage: controller.recorderStorage,
    );
    final canRecord = connected && !controller.continuousActive;
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                device?.name ?? DeviceProfile.advertisedName,
                style: AppText.title21,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              // The status line is the door to Recorder settings, so the whole
              // line is the target, chevron included.
              Semantics(
                button: true,
                label: status.label,
                hint: 'Recorder settings',
                container: true,
                excludeSemantics: true,
                onTap: onStatus,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onStatus,
                  child: SizedBox(
                    height: AppShape.minTapTarget,
                    child: Row(
                      children: <Widget>[
                        BreathingDot(
                          breathing: status.tone == HomeStatusTone.good,
                          color: StatusToneColors.dot(status.tone),
                        ),
                        const SizedBox(width: 7),
                        Flexible(
                          child: Text(
                            status.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.body13.copyWith(color: StatusToneColors.label(status.tone)),
                          ),
                        ),
                        if (onStatus != null) ...<Widget>[
                          const SizedBox(width: 4),
                          const AppIcon(AppGlyph.chevronRight, size: 13, color: AppColors.textTertiary, strokeWidth: 1.7),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 6),
          child: _BatteryReadout(controller: controller),
        ),
        Semantics(
          enabled: canRecord,
          child: TapTarget(
            onTap: onRecord,
            semanticLabel: 'Record',
            child: Opacity(
              opacity: canRecord ? 1 : 0.45,
              child: const AppIcon(AppGlyph.mic, size: 19, color: AppColors.textSecondary, strokeWidth: 1.7),
            ),
          ),
        ),
        if (onMenu != null)
          Transform.translate(
            offset: const Offset(12, 0),
            child: TapTarget(
              onTap: onMenu,
              semanticLabel: 'Settings',
              child: const AppIcon(AppGlyph.more, size: 19, color: AppColors.textSecondary, strokeWidth: 1.7),
            ),
          ),
      ],
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
///   * unknown because there is no `fe05` at all - a board not running this
///     firmware, a failed
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
