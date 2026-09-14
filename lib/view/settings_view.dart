import 'dart:async';

import 'package:flutter/material.dart';

import '../controller/app_controller.dart';
import '../model/auto_sleep.dart';
import '../model/home_status.dart';
import 'format.dart';
import 'pair_new_phone_view.dart';
import 'theme.dart';
import 'widgets/app_icons.dart';
import 'widgets/common.dart';
import 'widgets/home_widgets.dart';
import 'widgets/motion.dart';

/// Recorder settings - `Settings.dc.html`.
///
/// Reached from Home's status line and its menu, in every build. Sections -
/// Listening, Auto-sleep, Audio, and Pairing once this phone is known to be
/// the recorder's owner - and a row into Diagnostics.
///
/// PAIRING IS HIDDEN UNTIL IT MEANS SOMETHING: a recorder that does not pair
/// (older firmware), or one this phone has not paired with, has nothing to
/// show there.
///
/// CONNECT AND DISCONNECT live under the Listening card, and only while
/// always-listening is off - the one place the old recorder sheet offered
/// them. With it on, the link is the app's to keep.
class SettingsView extends StatelessWidget {
  const SettingsView({
    required this.controller,
    this.onBack,
    this.onOpenDiagnostics,
    this.onConnect,
    this.onPairNewPhone,
    super.key,
  });

  final AppController controller;
  final VoidCallback? onBack;
  final VoidCallback? onOpenDiagnostics;

  /// Goes to pairing; offered while nothing is connected and listening is
  /// off. Null hides it.
  final VoidCallback? onConnect;

  /// Opens the "Pair a new phone" instructions. Null pushes them from here.
  final VoidCallback? onPairNewPhone;

  static const String title = 'Recorder settings';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => ScreenScaffold(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (onBack != null)
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
            const Text(title, style: AppText.title22),
            const SizedBox(height: 18),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: <Widget>[
                  const _Section('Listening'),
                  AlwaysListeningCard(controller: controller),
                  ..._linkAction(context),
                  const SizedBox(height: 16),
                  const _Section('Auto-sleep'),
                  AutoSleepCard(controller: controller),
                  const SizedBox(height: 16),
                  const _Section('Audio'),
                  _AudioCard(controller: controller),
                  if (controller.pairedToThisPhone) ...<Widget>[
                    const SizedBox(height: 16),
                    const _Section('Pairing'),
                    PairingCard(
                      since: controller.pairedSince,
                      onPairNewPhone: onPairNewPhone ??
                          () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (context) => PairNewPhoneView(
                                    onBack: () => Navigator.of(context).pop(),
                                  ),
                                ),
                              ),
                    ),
                  ],
                  if (onOpenDiagnostics != null) ...<Widget>[
                    const SizedBox(height: 16),
                    _DiagnosticsRow(onTap: onOpenDiagnostics!),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _linkAction(BuildContext context) {
    if (controller.continuousEnabled) return const <Widget>[];
    final connected =
        controller.isConnected && controller.connectedDevice != null;
    if (connected) {
      return <Widget>[
        const SizedBox(height: 8),
        Center(
          child: _DisconnectChip(
            onTap: () => unawaited(controller.disconnect()),
          ),
        ),
      ];
    }
    final connect = onConnect;
    if (connect == null) return const <Widget>[];
    return <Widget>[
      const SizedBox(height: 12),
      SheetButton(
        label: 'Connect a recorder',
        filled: false,
        onPressed: () {
          // Pairing is a page under this screen's navigator; leave first so
          // Back from pairing lands on Home.
          Navigator.of(context).maybePop();
          connect();
        },
      ),
    ];
  }
}

/// "Paired to this phone", since when, and a quiet way to pair a new one.
class PairingCard extends StatelessWidget {
  const PairingCard({required this.onPairNewPhone, this.since, super.key});

  final DateTime? since;
  final VoidCallback onPairNewPhone;

  static const String title = 'Paired to this phone';

  @override
  Widget build(BuildContext context) {
    final since = this.since;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ConstrainedBox(
            constraints:
                const BoxConstraints(minHeight: AppShape.minTapTarget),
            child: Row(
              children: <Widget>[
                const AppIcon(
                  AppGlyph.bluetooth,
                  size: 18,
                  color: AppColors.purpleText,
                  strokeWidth: 1.7,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text(title, style: AppText.rowTitle),
                      if (since != null) ...<Widget>[
                        const SizedBox(height: 4),
                        Text('Since ${Fmt.dayMonth(since)}', style: AppText.rowMeta),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SheetButton(
            label: 'Pair a new phone',
            filled: false,
            onPressed: onPairNewPhone,
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: SectionCaption(text),
      );
}

/// The always-listening switch and whether notes are being saved.
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
    final enabled = controller.continuousEnabled;
    final available = enabled || controller.canUseContinuous;
    final status = HomeStatus.resolve(
      continuous: controller.continuousStatus,
      connected: controller.isConnected,
      charging: controller.batteryCharging,
      storage: controller.recorderStorage,
    );

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
                      BreathingDot(
                        color: toneColor(status.tone),
                        breathing: status.tone == HomeStatusTone.good,
                      ),
                      const SizedBox(width: 7),
                    ],
                    Flexible(
                      child: Text(
                        enabled
                            ? status.label
                            : available
                                ? 'Notes save when you speak'
                                : 'Connect a recorder first',
                        style: AppText.rowMeta,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          HomeSwitch(
            label: title,
            value: enabled,
            onChanged:
                available ? (on) => unawaited(_toggle(context, on)) : null,
          ),
        ],
      ),
    );
  }

  /// The dot beside the status: green while saving, amber while not, grey
  /// when nothing is wrong and nothing is happening.
  static Color toneColor(HomeStatusTone tone) => switch (tone) {
        HomeStatusTone.good => AppColors.connected,
        HomeStatusTone.warning => AppColors.warning,
        HomeStatusTone.idle => AppColors.disconnected,
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

/// "Sleep when still for": 30 s, 1 min, 2 min, 5 min, Never.
///
/// The choice is the recorder's, kept in its flash, so it is READ, never
/// assumed: with no link, or firmware that cannot take a duration, nothing is
/// selected, nothing can be tapped, and one plain line says why.
///
/// A tap shows at once; if the recorder refuses, the old choice comes back and
/// a short message says so.
class AutoSleepCard extends StatelessWidget {
  const AutoSleepCard({required this.controller, super.key});

  final AppController controller;

  static const String couldNotChange = "Couldn't change auto-sleep. Try again.";

  /// The five options, in the canvas's order.
  static const List<(AutoSleepDuration, String)> options =
      <(AutoSleepDuration, String)>[
    (AutoSleepDuration.seconds30, '30 s'),
    (AutoSleepDuration.minute1, '1 min'),
    (AutoSleepDuration.minutes2, '2 min'),
    (AutoSleepDuration.minutes5, '5 min'),
    (AutoSleepDuration.off, 'Never'),
  ];

  @override
  Widget build(BuildContext context) {
    final usable = controller.isConnected && controller.autoSleepDurationSupported;
    final current = usable ? controller.autoSleepDuration : null;
    final String note;
    if (!controller.isConnected) {
      note = 'Connect your recorder to change this.';
    } else if (!usable) {
      note = 'Update your recorder to change this.';
    } else {
      note = 'Wakes when you move. Longer uses more battery.';
    }

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('Sleep when still for', style: AppText.devLabel),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              for (var i = 0; i < options.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(width: 6),
                Expanded(
                  child: SegmentButton(
                    label: options[i].$2,
                    semanticLabel: options[i].$1 == AutoSleepDuration.off
                        ? 'Never sleep'
                        : 'Sleep after ${options[i].$2}',
                    selected: current == options[i].$1,
                    enabled: usable,
                    onTap: () => unawaited(_choose(context, options[i].$1)),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Text(note, style: AppText.footnote12),
        ],
      ),
    );
  }

  Future<void> _choose(BuildContext context, AutoSleepDuration duration) async {
    final changed = await controller.setAutoSleepDuration(duration);
    if (!changed && context.mounted) showHomeMessage(context, couldNotChange);
  }
}

class _AudioCard extends StatelessWidget {
  const _AudioCard({required this.controller});

  final AppController controller;

  static const String label = 'Delete audio after 24 h';

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Expanded(child: Text(label, style: AppText.rowTitle)),
              HomeSwitch(
                label: label,
                value: controller.autoDeleteAudio,
                onChanged: (on) => unawaited(controller.setAutoDeleteAudio(on)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Padding(
            padding: EdgeInsets.only(right: 6),
            child: Text(
              'Transcripts are kept. Notes you mark Keep are never deleted.',
              style: AppText.footnote12,
            ),
          ),
        ],
      ),
    );
  }
}

class _DiagnosticsRow extends StatelessWidget {
  const _DiagnosticsRow({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Diagnostics',
      container: true,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: AppShape.minTapTarget),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: AppColors.raised)),
          ),
          child: const Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('Diagnostics', style: AppText.rowTitle),
                    SizedBox(height: 4),
                    Text('Battery, connection, mic check', style: AppText.rowMeta),
                  ],
                ),
              ),
              AppIcon(
                AppGlyph.chevronRight,
                size: 17,
                color: AppColors.textTertiary,
                strokeWidth: 1.7,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ends the link with the recorder. Red, because it takes something away; an
/// outline rather than a fill, because it is not what this screen is for. Not
/// confirmed: disconnecting destroys nothing and reconnecting is one tap.
class _DisconnectChip extends StatelessWidget {
  const _DisconnectChip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TapTarget(
      onTap: onTap,
      semanticLabel: 'Disconnect',
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
