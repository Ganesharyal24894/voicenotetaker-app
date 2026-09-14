import 'dart:async';

import 'package:flutter/material.dart';

import '../controller/app_controller.dart';
import '../controller/summary_controller.dart';
import '../model/battery_bars.dart';
import '../model/continuous_status.dart';
import '../model/device_profile.dart';
import '../model/home_status.dart';
import '../model/notes_overview.dart';
import '../model/recording_info.dart';
import 'home/notes_tab.dart';
import 'home/summarize_sheet.dart';
import 'home/today_tab.dart';
import 'recording_entry.dart';
import 'theme.dart';
import 'widgets/app_icons.dart';
import 'widgets/common.dart';
import 'widgets/home_widgets.dart';
import 'widgets/motion.dart';

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
    this.onOpenDiagnostics,
    this.onConnect,
    super.key,
  });

  final AppController controller;
  final SummaryController summaries;

  final VoidCallback onOpenLibrary;
  final ValueChanged<RecordingEntry> onOpenRecording;

  /// Opens Device Diagnostics - the header menu, for now. Non-null in RELEASE
  /// builds too: everything on that screen is something the user can only
  /// watch. The mutating controls live one more tap in, on Developer options.
  final VoidCallback? onOpenDiagnostics;

  /// Goes to the pairing screen. Offered in the recorder sheet while nothing
  /// is connected and always-listening is off; null hides it.
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
                onStatus: () => unawaited(
                  showRecorderSheet(context, controller: controller, onConnect: widget.onConnect),
                ),
                onRecord: _record,
                onMenu: widget.onOpenDiagnostics,
              ),
            ),
            const SizedBox(height: 14),
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
  final VoidCallback onStatus;
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
    );
    final canRecord = connected && !controller.continuousActive;
    final Color dot = switch (status.tone) {
      HomeStatusTone.good => AppColors.connected,
      HomeStatusTone.warning => AppColors.warning,
      HomeStatusTone.idle => AppColors.disconnected,
    };
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
              // The status line is the door to the recorder's settings - for
              // now the always-listening switch - so the whole line is the
              // target, chevron included.
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
                        BreathingDot(breathing: status.tone == HomeStatusTone.good, color: dot),
                        const SizedBox(width: 7),
                        Flexible(
                          child: Text(
                            status.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.body13.copyWith(
                              color: status.tone == HomeStatusTone.warning
                                  ? AppColors.warning
                                  : AppColors.textSecondary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        const AppIcon(AppGlyph.chevronRight, size: 13, color: AppColors.textTertiary, strokeWidth: 1.7),
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
              semanticLabel: 'Diagnostics',
              child: const AppIcon(AppGlyph.more, size: 19, color: AppColors.textSecondary, strokeWidth: 1.7),
            ),
          ),
      ],
    );
  }
}

/// The sheet the status line opens: always listening, and connect or
/// disconnect. The full recorder settings screen replaces it later.
Future<void> showRecorderSheet(
  BuildContext context, {
  required AppController controller,
  VoidCallback? onConnect,
}) =>
    showHomeSheet<void>(
      context,
      builder: (sheetContext) => ListenableBuilder(
        listenable: controller,
        builder: (sheetContext, _) {
          final connected = controller.isConnected && controller.connectedDevice != null;
          final status = HomeStatus.resolve(
            continuous: controller.continuousStatus,
            connected: connected,
            charging: controller.batteryCharging,
          );
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Text('Recorder', style: AppText.title21),
              const SizedBox(height: 6),
              Text(status.label, style: AppText.body13),
              const SizedBox(height: 16),
              AlwaysListeningCard(controller: controller),
              if (connected && !controller.continuousEnabled) ...<Widget>[
                const SizedBox(height: 16),
                Center(
                  child: _DisconnectChip(
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(controller.disconnect());
                    },
                  ),
                ),
              ],
              if (!connected && !controller.continuousEnabled && onConnect != null) ...<Widget>[
                const SizedBox(height: 16),
                PrimaryButton(
                  label: 'Connect a recorder',
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    onConnect();
                  },
                ),
              ],
            ],
          );
        },
      ),
    );

/// The always-listening switch and, while it is on, what it is doing.
///
/// A CARD, NOT A SETTINGS PAGE: it is the one mode the app has, and the status
/// line under it ("Hearing speech", "Muted on device") is something the wearer
/// glances at, so it lives on Home under the device it describes.
///
/// Turning it on asks for the background permissions first - with one sentence
/// on why - when the phone has not already granted them. Declining still turns
/// it on: it then works while the app is open, which is better than a switch
/// that refuses.
class AlwaysListeningCard extends StatelessWidget {
  const AlwaysListeningCard({required this.controller, super.key});

  final AppController controller;

  static const String title = 'Always listening';

  @override
  Widget build(BuildContext context) {
    final status = controller.continuousStatus;
    final enabled = controller.continuousEnabled;
    final available = enabled || controller.canUseContinuous;

    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(title, style: AppText.rowTitle),
                const SizedBox(height: 4),
                Row(
                  children: <Widget>[
                    if (enabled) ...<Widget>[
                      StatusDot(color: statusColor(status)),
                      const SizedBox(width: 7),
                    ],
                    Flexible(
                      child: Text(
                        enabled ? status.label : 'Notes save when you speak',
                        style: AppText.rowMeta,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Semantics(
            label: title,
            child: Switch(
              value: enabled,
              onChanged: available
                  ? (on) => unawaited(_toggle(context, on))
                  : null,
              thumbColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? AppColors.onPrimaryFill
                    : AppColors.textSecondary,
              ),
              trackColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? AppColors.primaryFill
                    : AppColors.raised,
              ),
              trackOutlineColor:
                  const WidgetStatePropertyAll<Color>(AppColors.border),
            ),
          ),
        ],
      ),
    );
  }

  /// The dot beside the status. Green while it works, rose while speech is
  /// being written - the recording colour - amber where the wearer or the
  /// firmware has to act, grey while there is no link.
  static Color statusColor(ContinuousStatus status) => switch (status) {
        ContinuousStatus.listening => AppColors.connected,
        ContinuousStatus.hearingSpeech => AppColors.recording,
        ContinuousStatus.muted ||
        ContinuousStatus.needsFirmwareUpdate =>
          AppColors.warning,
        ContinuousStatus.notConnected ||
        ContinuousStatus.off =>
          AppColors.disconnected,
      };

  Future<void> _toggle(BuildContext context, bool on) async {
    if (!on) {
      await controller.setContinuousEnabled(false);
      return;
    }
    if (!await controller.backgroundPermissionsGranted()) {
      final autostart = await controller.hasAutostartSettings();
      if (!context.mounted) return;
      final allow = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: AppColors.card,
          shape: const RoundedRectangleBorder(borderRadius: AppShape.card),
          title: const Text('Keep listening', style: AppText.title22),
          content: Text(
            'To save notes while your phone is locked, allow notifications '
            'and turn off battery limits for this app.'
            '${autostart ? '\n\nOn Xiaomi phones, also turn on Autostart.' : ''}',
            style: AppText.footnote12,
          ),
          actions: <Widget>[
            if (autostart)
              TextButton(
                onPressed: () => unawaited(controller.openAutostartSettings()),
                child: const Text('Autostart', style: AppText.label13),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Not now', style: AppText.label13),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(
                'Allow',
                style: AppText.label13.copyWith(color: AppColors.purpleText),
              ),
            ),
          ],
        ),
      );
      if (allow == true) await controller.requestBackgroundPermissions();
    }
    await controller.setContinuousEnabled(true);
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
/// and the diagnostics entry point, and the sentence directly under
/// the record button - "Tap to record" / "Connect a recorder to start" - is
/// where this screen already talks about whether a recorder is attached.
///
/// The same quiet pill as the note screen's speed and Transcribe chips, so
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

