/// The speech-model downloader's screens - `ModelsSetup.dc.html`,
/// `ModelsDownloading.dc.html` and `ModelsSettings.dc.html`.
///
/// EVERYTHING HERE IS WRITTEN AGAINST [ModelsController], never against
/// `AppController`: the same discipline the Speakers sheet keeps, and the
/// reason these screens can be driven by a fake in a widget test without a
/// downloader, a file store or a network anywhere near them.
///
/// ONE STATUS PER FEATURE. The user picks "Hindi transcription", not
/// `encoder.int8.onnx`; a set is downloaded, removed and reported as one
/// thing, because half a set transcribes nothing.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../controller/models_controller.dart';
import '../model/model_download.dart';
import 'theme.dart';
import 'widgets/app_icons.dart';
import 'widgets/common.dart';
import 'widgets/home_widgets.dart';


/// Every word these screens say, in one place.
///
/// THE CANVAS'S COPY, NOT THE CATALOGUE'S. `ModelCatalogue` names a set
/// "Hindi speech" and explains it in a sentence written for a developer
/// reading the catalogue; the approved screens say "Hindi transcription" and
/// "Writes down Hindi and Hinglish". The screens are what a person reads, so
/// the screens' words win - and they live here rather than in the catalogue so
/// that publishing a new release tag never rewrites the UI.
abstract final class ModelsCopy {
  static const String setupTitle = 'Download the language pack';

  static const String setupBody =
      'Transcribing happens on your phone, so the language pack has to be '
      'downloaded once. After that it works offline.';

  static const String pick = 'Pick what you need';

  static const String oneTimeDownload = 'One-time download';

  /// The footnote under the total, which has to tell the truth about the
  /// setting rather than repeating a default.
  static const String wifiOnly =
      'Downloads on Wi-Fi only. You can change that in settings.';

  static const String mobileAllowed =
      'Downloads on Wi-Fi or mobile data, whichever you are on.';

  static const String download = 'Download';

  static const String downloadingTitle = 'Downloading';

  static const String languagePacks = 'Language packs';

  /// The one line about leaving the app. BOTH PLATFORMS IN ONE SENTENCE,
  /// because the app cannot know which phone is reading it at the moment the
  /// copy is written and a half-truth here is a support question later.
  static const String platformNote =
      'You can leave the app. On Android it keeps downloading; on iPhone it '
      'pauses and picks up when you come back.';

  static const String pause = 'Pause';
  static const String resume = 'Resume';
  static const String cancel = 'Cancel';
  static const String tryAgain = 'Try again';
  static const String done = 'Done';

  /// Shown once everything asked for is on the phone. Not in the artboards -
  /// they stop at the progress - but a screen that finishes has to say so and
  /// offer the way out.
  static const String ready = 'Everything is on this phone.';

  static const String settingsTitle = 'Speech models';

  static const String settingsBody =
      'Transcribing runs on this phone, so each pack is downloaded once and '
      'then works offline.';

  static const String onThisPhone = 'On this phone';
  static const String notDownloaded = 'Not downloaded';
  static const String downloadsSection = 'Downloads';
  static const String mobileDataSwitch = 'Download over mobile data';
  static const String mobileDataNote = 'Off means downloads wait for Wi-Fi.';
  static const String spaceUsed = 'Space used on this phone';
  static const String remove = 'Remove';
  static const String installedNote = 'On this phone';
  static const String checking = 'Checking…';
  static const String doneLabel = 'Done';

  /// The note screen when the pack it needs is not here.
  static const String blockedTitle = 'Nothing written down yet';

  /// The blocked note's one action, and the setup screen's title: the same
  /// words, so the tap is visibly the thing that opened.
  static const String blockedAction = setupTitle;

  static const String blockedBody =
      'Writing down Hindi needs a language pack on your phone. It downloads '
      'once, over Wi-Fi, and then works offline.';

  static String nameOf(ModelFeature feature) => switch (feature) {
        ModelFeature.hindiSpeech => 'Hindi transcription',
        ModelFeature.englishSpeech => 'English transcription',
        ModelFeature.speakerDetection => 'Speaker detection',
      };

  static String enablesOf(ModelFeature feature) => switch (feature) {
        ModelFeature.hindiSpeech => 'Writes down Hindi and Hinglish',
        ModelFeature.englishSpeech => 'Writes down English',
        ModelFeature.speakerDetection => 'Tells you who said what',
      };

  /// `70 of 197 MB` - the unit is said once when both numbers share it.
  ///
  /// Pure arithmetic on [formatBytes], so "does the total add up" is a unit
  /// test rather than a screenshot.
  static String progressLabel(int done, int total) {
    final doneText = formatBytes(done);
    final totalText = formatBytes(total);
    final unit = totalText.split(' ').last;
    if (doneText.endsWith(' $unit')) {
      return '${doneText.substring(0, doneText.length - unit.length - 1)} '
          'of $totalText';
    }
    return '$doneText of $totalText';
  }

  /// What removing a set costs, said in its own size.
  static String removeQuestion(ModelInstallStatus status) =>
      'Remove ${nameOf(status.feature)}?';

  static String removeDetail(ModelInstallStatus status) =>
      'It frees ${formatBytes(status.bytesTotal)}, and getting it back is the '
      'same download again. Transcripts already written are kept.';
}

/// "Download the language pack": pick the sets, see the one-time total, start.
///
/// The SAME screen becomes `ModelsDownloading.dc.html` once something is in
/// flight - it is one task with two faces, and pushing a second route for the
/// second face would leave a dead "pick what you need" behind the progress.
class ModelsSetupView extends StatefulWidget {
  const ModelsSetupView({
    required this.models,
    this.onBack,
    this.backLabel = 'Note',
    this.initialSelection = defaultSelection,
    super.key,
  });

  final ModelsController models;

  final VoidCallback? onBack;

  /// What Back goes to, in the header. The screen is reached from a note and
  /// from Recorder settings.
  final String backLabel;

  /// Ticked when the screen opens. Hindi and speaker detection: the two the
  /// app is useless without. English is a choice, so it starts off.
  final Set<ModelFeature> initialSelection;

  static const Set<ModelFeature> defaultSelection = <ModelFeature>{
    ModelFeature.hindiSpeech,
    ModelFeature.speakerDetection,
  };

  @override
  State<ModelsSetupView> createState() => _ModelsSetupViewState();
}

class _ModelsSetupViewState extends State<ModelsSetupView> {
  late final Set<ModelFeature> _selected = <ModelFeature>{
    ...widget.initialSelection,
  };

  /// True once Download was tapped, so the screen keeps showing progress
  /// through a pause and through a failure instead of snapping back to the
  /// picker the moment nothing is running.
  bool _started = false;

  ModelsController get _models => widget.models;

  @override
  void initState() {
    super.initState();
    // Cheap, and it is what makes a set deleted on another screen show as
    // missing here.
    unawaited(_models.refreshModels());
  }

  /// The sets the progress screen is about: what was ticked, and anything the
  /// app already had running when the screen opened.
  List<ModelInstallStatus> get _tracked => <ModelInstallStatus>[
        for (final status in _models.modelStatuses)
          if (_selected.contains(status.feature) || status.isBusy) status,
      ];

  bool get _anyBusy => _models.modelStatuses.any((status) => status.isBusy);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _models,
      builder: (context, _) {
        final downloading = _started || _anyBusy;
        return ScreenScaffold(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _BackRow(label: widget.backLabel, onBack: widget.onBack),
              const SizedBox(height: 12),
              Expanded(
                child: downloading ? _downloadingBody() : _setupBody(),
              ),
            ],
          ),
        );
      },
    );
  }

  // --------------------------------------------------------------- setup

  Widget _setupBody() {
    final statuses = _models.modelStatuses;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text(ModelsCopy.setupTitle, style: AppText.title24),
        const SizedBox(height: 10),
        Text(
          ModelsCopy.setupBody,
          style: AppText.meta14
              .copyWith(color: AppColors.textSecondary, height: 1.55),
        ),
        const SizedBox(height: 14),
        const SizedBox(
          height: 36,
          child: Align(
            alignment: Alignment.centerLeft,
            child: SectionCaption(ModelsCopy.pick),
          ),
        ),
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: <Widget>[
              for (var i = 0; i < statuses.length; i++)
                _PickRow(
                  status: statuses[i],
                  selected: _selected.contains(statuses[i].feature),
                  divider: i > 0,
                  onChanged: (on) => setState(() {
                    if (on) {
                      _selected.add(statuses[i].feature);
                    } else {
                      _selected.remove(statuses[i].feature);
                    }
                  }),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.only(top: 14),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: AppColors.raised)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              const Expanded(
                child: Text(ModelsCopy.oneTimeDownload, style: AppText.body13),
              ),
              const SizedBox(width: 12),
              Text(
                formatBytes(_totalBytes),
                style: AppText.rowTitle.copyWith(fontSize: 16),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _Footnote(
          glyph: AppGlyph.wifi,
          text: _models.downloadOnMobileData
              ? ModelsCopy.mobileAllowed
              : ModelsCopy.wifiOnly,
        ),
        const SizedBox(height: 14),
        PrimaryButton(
          label: ModelsCopy.download,
          glyph: AppGlyph.download,
          height: 48,
          onPressed: _totalBytes == 0 ? null : _startDownloads,
        ),
      ],
    );
  }

  /// What the ticks add up to: the sets that are ticked and are NOT already on
  /// the phone, because a set that is here costs nothing to "download".
  int get _totalBytes {
    var total = 0;
    for (final status in _models.modelStatuses) {
      if (_selected.contains(status.feature) && !status.isInstalled) {
        total += status.bytesRemaining;
      }
    }
    return total;
  }

  void _startDownloads() {
    setState(() => _started = true);
    for (final status in _models.modelStatuses) {
      if (_selected.contains(status.feature) && !status.isInstalled) {
        unawaited(_models.downloadModel(status.feature));
      }
    }
  }

  // ---------------------------------------------------------- downloading

  Widget _downloadingBody() {
    final tracked = _tracked;
    var done = 0;
    var total = 0;
    for (final status in tracked) {
      done += status.isInstalled ? status.bytesTotal : status.bytesDone;
      total += status.bytesTotal;
    }
    final finished =
        tracked.isNotEmpty && tracked.every((status) => status.isInstalled);
    final failed = tracked.where((status) => status.failure != null).toList();
    final progress = total <= 0 ? 0.0 : done / total;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text(ModelsCopy.downloadingTitle, style: AppText.title24),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: <Widget>[
            Expanded(
              child: Text(
                ModelsCopy.progressLabel(done, total),
                style: AppText.scrubTime.copyWith(fontSize: 13),
              ),
            ),
            const SizedBox(width: 12),
            Text('${(progress * 100).round()}%', style: AppText.meta13),
          ],
        ),
        const SizedBox(height: 10),
        _Bar(value: progress, height: 6),
        const SizedBox(height: 18),
        const SizedBox(
          height: 36,
          child: Align(
            alignment: Alignment.centerLeft,
            child: SectionCaption(ModelsCopy.languagePacks),
          ),
        ),
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: <Widget>[
              for (var i = 0; i < tracked.length; i++)
                _ProgressRow(status: tracked[i], divider: i > 0),
            ],
          ),
        ),
        const SizedBox(height: 18),
        if (finished)
          Text(
            ModelsCopy.ready,
            style: AppText.body13.copyWith(color: AppColors.connected),
          )
        else
          _Footnote(glyph: AppGlyph.info, text: ModelsCopy.platformNote),
        const SizedBox(height: 14),
        if (finished)
          PrimaryButton(
            label: ModelsCopy.done,
            height: 48,
            onPressed: _leave,
          )
        else
          Row(
            children: <Widget>[
              Expanded(child: _primaryAction(failed)),
              const SizedBox(width: 10),
              Expanded(
                child: QuietButton(
                  label: ModelsCopy.cancel,
                  height: 48,
                  onPressed: _cancelAll,
                ),
              ),
            ],
          ),
      ],
    );
  }

  /// Pause while it runs, Resume when it is stopped with bytes on the phone,
  /// Try again when something failed. One button, and it always says what the
  /// tap will do.
  Widget _primaryAction(List<ModelInstallStatus> failed) {
    if (_anyBusy) {
      return QuietButton(
        label: ModelsCopy.pause,
        height: 48,
        onPressed: _pauseAll,
      );
    }
    return QuietButton(
      label: failed.isEmpty ? ModelsCopy.resume : ModelsCopy.tryAgain,
      height: 48,
      onPressed: _startDownloads,
    );
  }

  void _pauseAll() {
    for (final status in _models.modelStatuses) {
      if (status.isBusy) unawaited(_models.cancelModelDownload(status.feature));
    }
  }

  /// Stops everything and goes back to the picker. WHAT ARRIVED IS KEPT - the
  /// downloader resumes from it - so Cancel costs the user nothing but the
  /// wait, which is the only reason it is not a confirmed action.
  void _cancelAll() {
    _pauseAll();
    setState(() => _started = false);
  }

  void _leave() {
    final back = widget.onBack;
    if (back != null) {
      back();
      return;
    }
    Navigator.of(context).maybePop();
  }
}

/// "Speech models" under Recorder settings - `ModelsSettings.dc.html`.
class ModelsSettingsView extends StatefulWidget {
  const ModelsSettingsView({
    required this.models,
    this.onBack,
    this.backLabel = 'Recorder settings',
    super.key,
  });

  final ModelsController models;
  final VoidCallback? onBack;
  final String backLabel;

  @override
  State<ModelsSettingsView> createState() => _ModelsSettingsViewState();
}

class _ModelsSettingsViewState extends State<ModelsSettingsView> {
  ModelsController get _models => widget.models;

  @override
  void initState() {
    super.initState();
    unawaited(_models.refreshModels());
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _models,
      builder: (context, _) {
        final statuses = _models.modelStatuses;
        final installed = <ModelInstallStatus>[
          for (final status in statuses)
            if (status.isInstalled) status,
        ];
        final busy = <ModelInstallStatus>[
          for (final status in statuses)
            if (status.isBusy) status,
        ];
        final missing = <ModelInstallStatus>[
          for (final status in statuses)
            if (!status.isInstalled && !status.isBusy) status,
        ];

        return ScreenScaffold(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _BackRow(label: widget.backLabel, onBack: widget.onBack),
              Transform.translate(
                offset: const Offset(0, -2),
                child: const Text(
                  ModelsCopy.settingsTitle,
                  style: AppText.title22,
                ),
              ),
              const SizedBox(height: 8),
              const Text(ModelsCopy.settingsBody, style: AppText.footnote12),
              const SizedBox(height: 20),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: <Widget>[
                    if (installed.isNotEmpty)
                      _SettingsGroup(
                        caption: ModelsCopy.onThisPhone,
                        children: <Widget>[
                          for (var i = 0; i < installed.length; i++)
                            _InstalledRow(
                              status: installed[i],
                              divider: i > 0,
                              onRemove: () =>
                                  unawaited(_remove(installed[i])),
                            ),
                        ],
                      ),
                    if (busy.isNotEmpty)
                      _SettingsGroup(
                        caption: ModelsCopy.downloadingTitle,
                        children: <Widget>[
                          for (var i = 0; i < busy.length; i++)
                            _BusySettingsRow(
                              status: busy[i],
                              divider: i > 0,
                              onCancel: () => unawaited(
                                _models.cancelModelDownload(busy[i].feature),
                              ),
                            ),
                        ],
                      ),
                    if (missing.isNotEmpty)
                      _SettingsGroup(
                        caption: ModelsCopy.notDownloaded,
                        children: <Widget>[
                          for (var i = 0; i < missing.length; i++)
                            _MissingRow(
                              status: missing[i],
                              divider: i > 0,
                              onDownload: () => unawaited(
                                _models.downloadModel(missing[i].feature),
                              ),
                            ),
                        ],
                      ),
                    _SettingsGroup(
                      caption: ModelsCopy.downloadsSection,
                      padding: const EdgeInsets.fromLTRB(16, 10, 10, 12),
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            const Expanded(
                              child: Text(
                                ModelsCopy.mobileDataSwitch,
                                style: AppText.rowTitle,
                              ),
                            ),
                            HomeSwitch(
                              label: ModelsCopy.mobileDataSwitch,
                              value: _models.downloadOnMobileData,
                              onChanged: (on) => unawaited(
                                _models.setDownloadOnMobileData(on),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        const Padding(
                          padding: EdgeInsets.only(right: 6),
                          child: Text(
                            ModelsCopy.mobileDataNote,
                            style: AppText.footnote12,
                          ),
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.only(top: 14),
                      decoration: const BoxDecoration(
                        border:
                            Border(top: BorderSide(color: AppColors.raised)),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: <Widget>[
                          const Expanded(
                            child: Text(
                              ModelsCopy.spaceUsed,
                              style: AppText.body13,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            formatBytes(_models.installedModelBytes),
                            style: AppText.devValue,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// CONFIRMED, because the undo is a 197 MB download on somebody's data.
  Future<void> _remove(ModelInstallStatus status) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: const RoundedRectangleBorder(borderRadius: AppShape.card),
        title: Text(
          ModelsCopy.removeQuestion(status),
          style: AppText.title22,
        ),
        content: Text(
          ModelsCopy.removeDetail(status),
          style: AppText.footnote12,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(ModelsCopy.cancel, style: AppText.label13),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              ModelsCopy.remove,
              style: AppText.label13.copyWith(color: AppColors.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) await _models.deleteModel(status.feature);
  }
}

// ---------------------------------------------------------------- pieces

/// The header's back chevron and the name of what it goes to.
class _BackRow extends StatelessWidget {
  const _BackRow({required this.label, this.onBack});

  final String label;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: const Offset(-12, 0),
      child: Row(
        children: <Widget>[
          TapTarget(
            onTap: onBack ?? () => Navigator.of(context).maybePop(),
            semanticLabel: 'Back',
            child: const AppIcon(
              AppGlyph.chevronLeft,
              size: 20,
              color: AppColors.textSecondary,
              strokeWidth: 1.7,
            ),
          ),
          Expanded(
            child: Text(
              label,
              style: AppText.meta13,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// A tickable set on the setup screen: what it does, what it costs.
///
/// A set already on the phone has no tick - there is nothing to decide - and
/// says so where its size would be.
class _PickRow extends StatelessWidget {
  const _PickRow({
    required this.status,
    required this.selected,
    required this.divider,
    required this.onChanged,
  });

  final ModelInstallStatus status;
  final bool selected;
  final bool divider;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final installed = status.isInstalled;
    final name = ModelsCopy.nameOf(status.feature);
    return Container(
      constraints: const BoxConstraints(minHeight: AppShape.minTapTarget),
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: divider
          ? const BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.raised)),
            )
          : null,
      child: Row(
        children: <Widget>[
          Transform.translate(
            offset: const Offset(-12, 0),
            child: installed
                ? const SizedBox.square(dimension: AppShape.minTapTarget)
                : TodoCheckbox(
                    checked: selected,
                    // "Include", because the row's own title already says the
                    // name and a screen reader would otherwise meet the same
                    // three words twice with no hint which one is the tick.
                    semanticLabel: 'Include $name',
                    onChanged: onChanged,
                  ),
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(name, style: AppText.rowTitle),
                const SizedBox(height: 3),
                Text(
                  ModelsCopy.enablesOf(status.feature),
                  style: AppText.rowMeta,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            installed
                ? ModelsCopy.installedNote
                : formatBytes(status.bytesTotal),
            style: installed
                ? AppText.body13.copyWith(color: AppColors.connected)
                : AppText.body13,
          ),
        ],
      ),
    );
  }
}

/// One set on the progress screen: its name, where it has got to, its bar.
class _ProgressRow extends StatelessWidget {
  const _ProgressRow({required this.status, required this.divider});

  final ModelInstallStatus status;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final failure = status.failure;
    final (String right, Color color) = switch (status.state) {
      ModelInstallState.installed => (
          ModelsCopy.doneLabel,
          AppColors.connected,
        ),
      ModelInstallState.verifying => (ModelsCopy.checking, AppColors.purpleText),
      ModelInstallState.failed => ('', AppColors.error),
      _ => (
          ModelsCopy.progressLabel(status.bytesDone, status.bytesTotal),
          AppColors.textSecondary,
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: divider
          ? const BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.raised)),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Expanded(
                child: Text(
                  ModelsCopy.nameOf(status.feature),
                  style: AppText.rowTitle,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (right.isNotEmpty) ...<Widget>[
                const SizedBox(width: 12),
                Text(right, style: AppText.rowMeta.copyWith(color: color)),
              ],
            ],
          ),
          const SizedBox(height: 9),
          _Bar(
            value: status.progress,
            height: 4,
            color: switch (status.state) {
              ModelInstallState.installed => AppColors.connected,
              ModelInstallState.failed => AppColors.error,
              _ => AppColors.purpleText,
            },
          ),
          // THE FAILURE IS PRINTED, NOT COMPOSED: `ModelDownloadFailure`
          // already writes one plain line that says what happened and what to
          // do about it, and two places writing that sentence is two places to
          // get it wrong.
          if (failure != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              failure.message,
              style: AppText.footnote12.copyWith(color: AppColors.error),
            ),
          ],
          if (status.paused) ...<Widget>[
            const SizedBox(height: 8),
            const Text('Paused. It carries on when you come back.',
                style: AppText.footnote12),
          ],
        ],
      ),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({
    required this.caption,
    required this.children,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
  });

  final String caption;
  final List<Widget> children;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SectionCaption(caption),
          const SizedBox(height: 8),
          AppCard(
            padding: padding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ],
      ),
    );
  }
}

/// A settings row: name, a line under it, and one word on the right.
class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.name,
    required this.meta,
    required this.action,
    required this.actionLabel,
    required this.divider,
    this.metaColor = AppColors.textTertiary,
  });

  final String name;
  final String meta;
  final VoidCallback action;
  final String actionLabel;
  final bool divider;
  final Color metaColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: AppShape.minTapTarget),
      padding: const EdgeInsets.symmetric(vertical: 2),
      decoration: divider
          ? const BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.raised)),
            )
          : null,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(name, style: AppText.rowTitle),
                const SizedBox(height: 3),
                Text(meta, style: AppText.rowMeta.copyWith(color: metaColor)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Transform.translate(
            offset: const Offset(4, 0),
            child: TapTarget(
              onTap: action,
              semanticLabel: '$actionLabel $name',
              child: Text(
                actionLabel,
                style: AppText.label13.copyWith(color: AppColors.purpleText),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InstalledRow extends StatelessWidget {
  const _InstalledRow({
    required this.status,
    required this.divider,
    required this.onRemove,
  });

  final ModelInstallStatus status;
  final bool divider;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => _SettingsRow(
        name: ModelsCopy.nameOf(status.feature),
        meta: formatBytes(status.bytesTotal),
        action: onRemove,
        actionLabel: ModelsCopy.remove,
        divider: divider,
      );
}

class _MissingRow extends StatelessWidget {
  const _MissingRow({
    required this.status,
    required this.divider,
    required this.onDownload,
  });

  final ModelInstallStatus status;
  final bool divider;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final failure = status.failure;
    return _SettingsRow(
      name: ModelsCopy.nameOf(status.feature),
      // A part-downloaded set says what is LEFT, because that is what tapping
      // Download will actually cost.
      meta: failure?.message ??
          (status.bytesDone > 0
              ? '${formatBytes(status.bytesRemaining)} left'
              : formatBytes(status.bytesTotal)),
      metaColor: failure == null ? AppColors.textTertiary : AppColors.error,
      action: onDownload,
      actionLabel: ModelsCopy.download,
      divider: divider,
    );
  }
}

class _BusySettingsRow extends StatelessWidget {
  const _BusySettingsRow({
    required this.status,
    required this.divider,
    required this.onCancel,
  });

  final ModelInstallStatus status;
  final bool divider;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: AppShape.minTapTarget),
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: divider
          ? const BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.raised)),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  ModelsCopy.nameOf(status.feature),
                  style: AppText.rowTitle,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 10),
              Transform.translate(
                offset: const Offset(4, 0),
                child: TapTarget(
                  onTap: onCancel,
                  semanticLabel:
                      '${ModelsCopy.cancel} ${ModelsCopy.nameOf(status.feature)}',
                  child: Text(
                    ModelsCopy.cancel,
                    style:
                        AppText.label13.copyWith(color: AppColors.purpleText),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            status.state == ModelInstallState.verifying
                ? ModelsCopy.checking
                : ModelsCopy.progressLabel(status.bytesDone, status.bytesTotal),
            style: AppText.rowMeta,
          ),
          const SizedBox(height: 8),
          _Bar(value: status.progress, height: 4),
        ],
      ),
    );
  }
}

/// A rounded progress bar. Determinate from the first frame - nothing in this
/// app animates on its own.
class _Bar extends StatelessWidget {
  const _Bar({
    required this.value,
    required this.height,
    this.color = AppColors.purpleText,
  });

  final double value;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: AppShape.pill,
      child: LinearProgressIndicator(
        value: value.clamp(0.0, 1.0),
        minHeight: height,
        color: color,
        backgroundColor: AppColors.raised,
      ),
    );
  }
}

/// A small glyph and a quiet line beside it.
class _Footnote extends StatelessWidget {
  const _Footnote({required this.glyph, required this.text});

  final AppGlyph glyph;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: AppIcon(
            glyph,
            size: 14,
            color: AppColors.textTertiary,
            strokeWidth: 1.7,
          ),
        ),
        const SizedBox(width: 9),
        Expanded(child: Text(text, style: AppText.footnote12)),
      ],
    );
  }
}
