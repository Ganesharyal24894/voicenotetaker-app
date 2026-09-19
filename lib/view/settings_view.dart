import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../controller/app_controller.dart';
import '../controller/assistant_controller.dart';
import '../controller/models_controller.dart';
import '../model/auto_sleep.dart';
import '../model/home_status.dart';
import '../model/model_download.dart';
import 'assistant_view.dart';
import 'format.dart';
import 'models_view.dart';
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
    this.assistant,
    this.onBack,
    this.onOpenDiagnostics,
    this.onConnect,
    this.onPairNewPhone,
    this.onOpenModels,
    this.onOpenInstinct,
    this.onExportNotes,
    super.key,
  });

  final AppController controller;

  /// "Send to Instinct". Null hides the row, which is the honest state for a
  /// build without the feature and for a screen pumped on its own in a test.
  final AssistantController? assistant;
  final VoidCallback? onBack;
  final VoidCallback? onOpenDiagnostics;

  /// Goes to pairing; offered while nothing is connected and listening is
  /// off. Null hides it.
  final VoidCallback? onConnect;

  /// Opens the "Pair a new phone" instructions. Null pushes them from here.
  final VoidCallback? onPairNewPhone;

  /// Opens "Speech models". Null pushes it from here.
  final VoidCallback? onOpenModels;

  /// Opens "Send to Instinct". Null pushes it from here.
  final VoidCallback? onOpenInstinct;

  /// Opens "Export notes" - one zip of the recordings and transcripts, handed
  /// to the share sheet. Null hides the row, which is what a build with no
  /// share sheet and a screen pumped on its own in a test both want.
  final VoidCallback? onExportNotes;

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
                  const SizedBox(height: 16),
                  const _Section(ModelsCopy.settingsTitle),
                  _ModelsCard(
                    controller: controller,
                    onTap: onOpenModels ?? () => _openModels(context),
                  ),
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
                  // Three plain rows at the bottom, no section caption
                  // between them: each is a door out of Settings rather than a
                  // setting, and each draws its own hairline so they stack.
                  if (assistant != null ||
                      onExportNotes != null ||
                      onOpenDiagnostics != null)
                    const SizedBox(height: 16),
                  if (assistant != null)
                    _InstinctRow(
                      assistant: assistant!,
                      onTap: onOpenInstinct ?? () => _openInstinct(context),
                    ),
                  if (onExportNotes != null)
                    _EndRow(
                      title: 'Export notes',
                      meta: 'One zip of your recordings and transcripts',
                      onTap: onExportNotes!,
                    ),
                  if (onOpenDiagnostics != null)
                    _EndRow(
                      title: 'Diagnostics',
                      meta: 'Battery, connection, mic check',
                      onTap: onOpenDiagnostics!,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Which speech-model screen the row opens.
  ///
  /// A PHONE WITH NOTHING INSTALLED HAS NOTHING TO MANAGE. There is one thing
  /// to do - pick the packs and start - so the row goes straight to the setup
  /// screen, with its ticks and its one-time total, rather than to a list of
  /// three rows that each say Download. Once a pack is here, the manage screen
  /// is the useful one.
  static bool opensSetup(List<ModelInstallStatus> statuses) =>
      statuses.isNotEmpty && !statuses.any((status) => status.isInstalled);

  /// Speech models is a page under this screen, the way Diagnostics is.
  void _openModels(BuildContext context) {
    final models = AppControllerModels(controller);
    final setup = opensSetup(controller.modelStatuses);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => setup
            ? ModelsSetupView(
                models: models,
                backLabel: SettingsView.title,
                onBack: () => Navigator.of(context).pop(),
              )
            : ModelsSettingsView(
                models: models,
                onBack: () => Navigator.of(context).pop(),
              ),
      ),
    );
  }

  /// "Send to Instinct" is a page under this screen, the way Diagnostics is.
  void _openInstinct(BuildContext context) {
    final assistant = this.assistant;
    if (assistant == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => AssistantView(
          assistant: assistant,
          onBack: () => Navigator.of(context).pop(),
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

/// "Speech models": how much is installed, and the way into the screen that
/// manages it.
///
/// THE SIZE IS THE POINT OF THE ROW. A pack is the largest thing this app ever
/// puts on somebody's phone, so the number is on the row itself rather than one
/// tap further in.
class _ModelsCard extends StatelessWidget {
  const _ModelsCard({required this.controller, required this.onTap});

  final AppController controller;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final statuses = controller.modelStatuses;
    final installed = statuses.where((status) => status.isInstalled).length;
    final busy = statuses.any((status) => status.isBusy);
    final String meta;
    if (busy) {
      meta = 'Downloading\u2026';
    } else if (installed == 0) {
      meta = 'Nothing downloaded yet';
    } else {
      meta = '$installed of ${statuses.length} downloaded \u00B7 '
          '${formatBytes(controller.installedModelBytes)}';
    }

    return Semantics(
      button: true,
      label: ModelsCopy.settingsTitle,
      container: true,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AppCard(
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(minHeight: AppShape.minTapTarget),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text(
                        ModelsCopy.settingsTitle,
                        style: AppText.rowTitle,
                      ),
                      const SizedBox(height: 4),
                      Text(meta, style: AppText.rowMeta),
                    ],
                  ),
                ),
                const AppIcon(
                  AppGlyph.chevronRight,
                  size: 17,
                  color: AppColors.textTertiary,
                  strokeWidth: 1.7,
                ),
              ],
            ),
          ),
        ),
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
///
/// On iPhone there is nothing to grant and nothing to ask, so the dialog never
/// appears - but the switch would then quietly promise Android's behaviour.
/// [iosNote] is the one line that says what actually happens instead, and it
/// shows on iOS only.
class AlwaysListeningCard extends StatelessWidget {
  const AlwaysListeningCard({required this.controller, super.key});

  final AppController controller;

  static const String title = 'Always listening';

  /// What iPhone does differently, in the two ways a person would notice:
  /// transcripts wait, and a problem waits to be seen rather than buzzing.
  static const String iosNote =
      'On iPhone, notes keep saving while the recorder is linked, but '
      'transcripts finish when you open the app - and you will see any '
      'problem here rather than as an alert.';

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

    final card = AppCard(
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

    if (defaultTargetPlatform != TargetPlatform.iOS) return card;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        card,
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: Text(iosNote, style: AppText.footnote12),
        ),
      ],
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

/// "Send to Instinct", as a row at the foot of Recorder settings: not set up,
/// off, or on.
///
/// It follows the controller, because turning the feature on lives one screen
/// further in and the row must not still say "Not set up" when the user comes
/// back.
class _InstinctRow extends StatelessWidget {
  const _InstinctRow({required this.assistant, required this.onTap});

  final AssistantController assistant;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: assistant,
      builder: (context, _) => _EndRow(
        title: AssistantCopy.title,
        meta: !assistant.hasAccount
            ? AssistantCopy.rowNotSetUp
            : assistant.enabled
                ? AssistantCopy.rowOn
                : AssistantCopy.rowOff,
        onTap: onTap,
      ),
    );
  }
}

/// A plain row at the foot of the screen: a title, a line of meta, a chevron
/// and a hairline above it. Export notes and Diagnostics are both one of
/// these, which is what makes them read as a pair rather than as two
/// unrelated buttons that happen to be adjacent.
class _EndRow extends StatelessWidget {
  const _EndRow({
    required this.title,
    required this.meta,
    required this.onTap,
  });

  final String title;
  final String meta;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: title,
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
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(title, style: AppText.rowTitle),
                    const SizedBox(height: 4),
                    Text(meta, style: AppText.rowMeta),
                  ],
                ),
              ),
              const AppIcon(
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
