import 'dart:async';

import 'package:flutter/material.dart';

import '../controller/app_controller.dart';
import '../model/device_test_aggregate.dart';
import '../model/device_test_result.dart';
import '../model/link_health.dart';
import 'format.dart';
import 'placeholder_data.dart';
import 'theme.dart';
import 'widgets/app_icons.dart';
import 'widgets/common.dart';

/// Device Diagnostics - what the recorder is doing, for anybody to look at.
///
/// THE SPLIT WITH DEVELOPER OPTIONS IS OBSERVE VERSUS MUTATE. Everything on this
/// screen is something a user can WATCH: the live link, a microphone check and
/// the history of its readings, the die temperature. Nothing here changes a
/// setting on the device, which is why it ships in release builds and needs no
/// warning badge. Auto-sleep and the codec - the two controls that write to the
/// recorder - are behind "Developer options" at the bottom, debug builds only.
///
/// NOTHING RUNS UNLESS REQUIRED, and this screen is the reason that rule needed
/// stating. Two subscriptions exist only for it:
///
///   * `fe01`, the audio stream, because the only way to count the frames the
///     phone received is to receive them, and
///   * `fe07`, the die temperature, because subscribing is what makes the
///     firmware sample the sensor at all.
///
/// Both cost the recorder power for as long as they are open, so both are tied to
/// this screen being VISIBLE rather than to it existing:
///
///   * [initState] opens them and [dispose] closes them, which covers every way
///     the route can go away - the back chevron, a system back gesture, the
///     route being replaced.
///   * [didChangeAppLifecycleState] closes them when the app is backgrounded and
///     opens them again on resume. This is the FIRST lifecycle observer in the
///     app: nothing else here watched `AppLifecycleState` before, so rather than
///     invent an app-wide mechanism, the one screen that has a reason to care
///     observes it, scoped to its own [State] and removed in [dispose].
///
/// `inactive` is deliberately NOT treated as "gone". It fires for a notification
/// shade being pulled down, an incoming call, the iOS app switcher preview - all
/// transient, and tearing the subscriptions down and back up on each of them
/// would thrash the radio for nothing. `hidden` and `paused` are the states that
/// mean the user has actually left.
class DiagnosticsView extends StatefulWidget {
  const DiagnosticsView({
    required this.controller,
    this.onBack,
    this.onOpenDeveloper,
    super.key,
  });

  final AppController controller;
  final VoidCallback? onBack;

  /// Non-null only in debug builds - see `developer_view.dart`.
  final VoidCallback? onOpenDeveloper;

  @override
  State<DiagnosticsView> createState() => _DiagnosticsViewState();
}

class _DiagnosticsViewState extends State<DiagnosticsView>
    with WidgetsBindingObserver {
  AppController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_controller.openDiagnostics());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onControllerChanged);
    // `dispose` is synchronous, so the teardown is started rather than awaited.
    // It does not need this widget alive: everything it stops belongs to the
    // controller.
    unawaited(_controller.closeDiagnostics());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(_controller.openDiagnostics());
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        unawaited(_controller.closeDiagnostics());
      case AppLifecycleState.inactive:
        // Transient - see the class comment. Nothing is torn down.
        break;
    }
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final onBack = widget.onBack;
    final onOpenDeveloper = widget.onOpenDeveloper;

    return ScreenScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              if (onBack != null) ...<Widget>[
                TapTarget(
                  onTap: onBack,
                  semanticLabel: 'Back',
                  child: const AppIcon(
                    AppGlyph.chevronLeft,
                    size: 20,
                    color: AppColors.textSecondary,
                    strokeWidth: 1.7,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              const Expanded(
                child: Text(
                  'Diagnostics',
                  style: AppText.title22,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'What the recorder is doing right now. Nothing here changes a '
            'setting on the device. The link and the die temperature are only '
            'measured while this screen is open.',
            style: AppText.footnote12,
          ),
          const SizedBox(height: 22),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: <Widget>[
                _LinkCard(controller: _controller),
                const SizedBox(height: 10),
                _MicCheckCard(controller: _controller),
                const SizedBox(height: 10),
                _DieTemperatureCard(controller: _controller),
              ],
            ),
          ),
          if (onOpenDeveloper != null) ...<Widget>[
            const SizedBox(height: 12),
            QuietButton(
              label: 'Developer options',
              onPressed: onOpenDeveloper,
            ),
          ],
        ],
      ),
    );
  }
}

/// The live link: the signal, and what the stream actually delivered.
///
/// THIS REPLACED TWO SAVED TESTS - a stepped range walk and a three-minute soak.
/// Both measured these same two quantities and then froze them into a row in a
/// file; the device produces them continuously. So a soak is this card left
/// open, and a range walk is this card carried across a room.
///
/// RSSI ALONE MISLEADS, which is why the loss figures sit directly under it. A
/// link at a respectable -75 dBm can be shedding one frame in twenty, because
/// what costs a notify stream its packets is retries in a crowded band rather
/// than path loss. Either number on its own invites the wrong conclusion.
///
/// LOSS IS COUNTED FROM GAPS IN THE `fe01` SEQUENCE NUMBER, which is what makes
/// it the number worth having: it counts what the PHONE failed to receive, air
/// losses included. A byte counter kept by the firmware could only say what the
/// firmware believed it had sent.
///
/// It degrades honestly in three directions, and none of them is a zero: not
/// connected, a platform that will not report the signal, and the mic check
/// having taken the one frame subscription.
class _LinkCard extends StatelessWidget {
  const _LinkCard({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final health = controller.linkHealth;
    final connected = controller.isConnected;
    final failure = controller.linkFailure;
    final watching = health.watching;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SectionCaption('Link', small: true),
          const SizedBox(height: 12),
          KeyValueRow(
            label: 'Signal',
            value: Fmt.rssi(health.rssiDbm),
            valueColor: health.rssiDbm == null
                ? AppColors.textPrimary
                : AppColors.connected,
          ),
          const SizedBox(height: 10),
          _RssiMeter(fraction: health.rssiFraction),
          const SizedBox(height: 14),
          // "Streamed", not "received": the pair of numbers only means anything
          // together, and the word that pairs with "lost" is the one that says
          // these frames arrived.
          KeyValueRow(
            label: 'Frames streamed',
            value: watching ? '${health.framesReceived}' : _unknown,
          ),
          const SizedBox(height: 12),
          KeyValueRow(
            label: 'Frames lost',
            value: watching ? '${health.framesLost}' : _unknown,
            valueColor: !watching || health.framesLost == 0
                ? AppColors.textPrimary
                : AppColors.warning,
          ),
          const SizedBox(height: 12),
          // Null until something has arrived, and rendered as a dash. A loss
          // rate of 0.00% on a stream that has not started is a lie that reads
          // as a perfect link.
          KeyValueRow(
            label: 'Loss',
            value: watching && health.lossPercent != null
                ? Fmt.measurement(health.lossPercent, '%')
                : _unknown,
            valueColor: (health.lossPercent ?? 0) == 0
                ? AppColors.textPrimary
                : AppColors.warning,
          ),
          const SizedBox(height: 12),
          Text(
            _linkState(
              connected: connected,
              watching: watching,
              checkRunning: controller.deviceTests.isBatchActive,
              failure: failure,
            ),
            style: AppText.footnote11.copyWith(
              color: failure != null ? AppColors.warning : AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Counted from gaps in the fe01 sequence number, so a lost frame is '
            'one the recorder sent and this phone never got - the air included. '
            'The counters start from zero each time this screen opens: they '
            'describe this sitting, not the life of the link. Leaving the screen '
            'open IS the soak test.',
            style: AppText.footnote11,
          ),
        ],
      ),
    );
  }

  static const String _unknown = PlaceholderData.unknownValue;

  String _linkState({
    required bool connected,
    required bool watching,
    required bool checkRunning,
    required String? failure,
  }) {
    if (!connected) {
      return 'Not connected, so there is no link to measure. Nothing here is a '
          'reading.';
    }
    if (failure != null) return 'Not counting: $failure';
    if (checkRunning) {
      return 'Paused while the mic check runs - the audio stream takes one '
          'listener at a time. It comes back when the check finishes.';
    }
    if (!watching) return 'Not counting frames.';
    return 'Live. Walk away from the recorder and watch both halves move.';
  }
}

/// A bar for the signal, from [LinkHealth.rssiFloorDbm] to
/// [LinkHealth.rssiCeilingDbm].
///
/// EMPTY IS NOT ZERO. With no reading the track is drawn and nothing fills it,
/// which reads as "no measurement" rather than as "no signal" - the same rule the
/// dash in the row above it follows. The endpoints are in the model, because
/// where a signal sits on a scale is a judgement about radios rather than about
/// pixels.
class _RssiMeter extends StatelessWidget {
  const _RssiMeter({required this.fraction});

  /// `0.0 .. 1.0`, or null when there is no reading to place.
  final double? fraction;

  @override
  Widget build(BuildContext context) {
    final value = fraction;
    return Semantics(
      // `container: true` because the bar has no semantics of its own for these
      // properties to merge into: without it the annotation has nothing to
      // attach to and the meter is invisible to a screen reader.
      container: true,
      label: 'Signal strength',
      value: value == null
          ? 'no reading'
          : '${(value * 100).round()} percent of scale',
      child: Container(
        height: 8,
        decoration: BoxDecoration(
          color: AppColors.raised,
          border: Border.all(color: AppColors.border),
          borderRadius: AppShape.pill,
        ),
        child: value == null
            ? null
            : FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: value,
                child: Container(
                  decoration: const BoxDecoration(
                    color: AppColors.purple400,
                    borderRadius: AppShape.pill,
                  ),
                ),
              ),
      ),
    );
  }
}

/// The microphone check, its controls, and the last two batches of each reading.
///
/// WHY THIS ONE SURVIVED AND THE LINK TESTS DID NOT. The enclosure puts plastic
/// between a voice and a MEMS microphone, and a bad port degrades a recording
/// SILENTLY: nothing fails, the words just get harder to make out. There is no
/// live readout that catches that, because the answer is a comparison against
/// how the bare board sounded - so this one has to be measured, saved and
/// compared by date.
///
/// WHY IT TAKES SEVERAL SAMPLES. Five runs on the bare board put the sensitivity
/// spread at 0.83 dB. That is what makes the batching worth its time: a change
/// caused by the enclosure will stand clear of a spread that narrow, and the
/// only reason anybody can say so is that the spread was measured.
///
/// A CHECK THAT CANNOT RUN IS NOT OFFERED. The same three-state rule the
/// auto-sleep control follows: no link, or a capture already holding the
/// exclusive frame subscription - each disables the control and says which it is.
/// Nothing here ever shows a default result.
class _MicCheckCard extends StatelessWidget {
  const _MicCheckCard({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final tests = controller.deviceTests;
    final blocker = controller.testBlocker;
    final saveFailure = tests.saveFailure;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SectionCaption('Mic check', small: true),
          const SizedBox(height: 8),
          const Text(
            'Enclosure before-and-after. Run it on the bare board, fit the '
            'case, run it again, and compare by date - the app cannot know '
            'whether the case is on, so it does not pretend to.',
            style: AppText.footnote11,
          ),
          if (blocker != null &&
              blocker != DeviceTestBlocker.testRunning) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              _blockerText(blocker),
              style: AppText.footnote11.copyWith(color: AppColors.warning),
            ),
          ],
          if (saveFailure != null) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              'The last result was measured but NOT saved: $saveFailure',
              style: AppText.footnote11.copyWith(color: AppColors.error),
            ),
          ],
          for (final kind in DeviceTestKind.values) ...<Widget>[
            const SizedBox(height: 16),
            _CheckRow(controller: controller, kind: kind),
          ],
          const SizedBox(height: 18),
          _SamplesPerCheck(controller: controller),
          const SizedBox(height: 14),
          Text(_historyLine(controller), style: AppText.footnote11),
        ],
      ),
    );
  }
}

/// How many runs are kept, and an account of the ones this build cannot read.
///
/// THE UNREAD ONES ARE SAID OUT LOUD. The file on this phone holds a bare-board
/// baseline, and some of those runs are of measurements that have since been
/// retired - the range walk, the link soak, wake-on-motion. They are kept in the
/// file and written back out untouched, but this build cannot interpret them, so
/// they are not in the history. Saying "12 runs kept, 3 more this build does not
/// read" is the difference between ignoring them and losing them.
String _historyLine(AppController controller) {
  final tests = controller.deviceTests;
  if (!tests.isLoaded) return 'Saved runs have not been read yet.';
  final kept = tests.history.length;
  final unread = controller.unreadDeviceTestRunCount;
  return <String>[
    '$kept run${kept == 1 ? '' : 's'} kept on this phone, newest first, in '
        '${tests.resultsFileName} beside the recordings.',
    if (unread > 0)
      '$unread more ${unread == 1 ? 'run is' : 'runs are'} in that file from '
          'a measurement this app no longer takes. They are kept, untouched, '
          'and not read.',
    'Every readable run is in Export diagnostics, readings and all.',
  ].join(' ');
}

/// One check: what it measures, its controls, and its last two batches.
class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.controller, required this.kind});

  final AppController controller;
  final DeviceTestKind kind;

  @override
  Widget build(BuildContext context) {
    final tests = controller.deviceTests;
    final isRunning = tests.running == kind;
    // A batch of this check is part-way through and waiting for the operator.
    // Nothing is streaming, but the check is very much in progress.
    final awaiting = tests.awaitingNextSample && tests.batchKind == kind;
    final active = isRunning || awaiting;
    final blocker = controller.testBlocker;
    final batches = tests.batchesOf(kind);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                _checkName(kind),
                style: AppText.devValue,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 96,
              child: SegmentButton(
                label: active ? 'Stop' : 'Run',
                semanticLabel:
                    '${active ? 'Stop' : 'Run'} the ${_checkName(kind).toLowerCase()} check',
                selected: active,
                // An active batch's own row is never disabled by the blocker it
                // is itself causing - see `AppController.testBlocker`.
                enabled: active || blocker == null,
                onTap: () => unawaited(
                  active ? _stop(controller) : _start(controller, kind),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(_checkBlurb(kind), style: AppText.footnote11),
        if (isRunning) ...<Widget>[
          if (tests.batchTarget > 1) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              'Sample ${tests.sampleNumber} of ${tests.batchTarget}',
              style: AppText.devValue,
            ),
          ],
          const SizedBox(height: 8),
          Text(
            _phasePrompt(tests.phase, kind),
            style: AppText.footnote11.copyWith(color: AppColors.purpleText),
          ),
          const SizedBox(height: 6),
          KeyValueRow(label: 'Elapsed', value: Fmt.timer(tests.elapsed)),
          const SizedBox(height: 6),
          KeyValueRow(
            label: 'Frames / lost',
            value: '${tests.liveStats.framesReceived} / '
                '${tests.liveStats.framesLost}',
            valueColor: tests.liveStats.framesLost == 0
                ? AppColors.connected
                : AppColors.warning,
          ),
        ],
        // BETWEEN SAMPLES of a batch that needs the operator. Nothing is
        // running, so none of the live readouts above are on screen - what is
        // needed here is how far through the batch they are, one control to take
        // the next sample and one to stop with what they have.
        if (awaiting) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            '${tests.samplesTaken} of ${tests.batchTarget} samples taken. '
            '${_nextSamplePrompt(kind)}',
            style: AppText.footnote11.copyWith(color: AppColors.purpleText),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: SegmentButton(
                  label: 'Next sample',
                  semanticLabel: 'Take the next sample of the '
                      '${_checkName(kind).toLowerCase()} check',
                  selected: false,
                  onTap: () => unawaited(controller.continueDeviceTestBatch()),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SegmentButton(
                  label: 'Keep ${tests.samplesTaken}',
                  semanticLabel: 'Stop the '
                      '${_checkName(kind).toLowerCase()} check and keep the '
                      '${tests.samplesTaken} sample'
                      '${tests.samplesTaken == 1 ? '' : 's'} already taken',
                  selected: false,
                  onTap: controller.endDeviceTestBatch,
                ),
              ),
            ],
          ),
        ],
        // The two BATCHES that make a comparison - never two single runs, which
        // is the whole point: these measurements are noisy enough that one
        // number against one number is a coin toss dressed up as a baseline.
        // Nothing is shown when there has never been a run: an empty row is
        // honest, an invented one is not.
        //
        // Wrapping lines rather than label/value rows: a timestamp, an n, a
        // median and a range do not fit a phone's width on one line, and a
        // clipped measurement is worse than a wrapped one.
        if (batches.isNotEmpty) ..._batchLines('Latest', batches.first),
        if (batches.length > 1) ..._batchLines('Before', batches[1]),
      ],
    );
  }

  /// Ends a running check from the row's own control.
  Future<void> _stop(AppController controller) async {
    // A batch waiting between samples has nothing streaming to cancel, and
    // cancelling is not what is wanted anyway: the samples already taken are
    // kept and aggregated.
    if (controller.deviceTests.awaitingNextSample) {
      controller.endDeviceTestBatch();
      return;
    }
    controller.cancelDeviceTest();
  }

  Future<void> _start(AppController controller, DeviceTestKind kind) =>
      switch (kind) {
        DeviceTestKind.noiseFloor => controller.runNoiseFloorTest(),
        DeviceTestKind.sensitivity => controller.runSensitivityTest(),
      };
}

/// How many samples each check takes, and why it takes more than one.
///
/// BELOW THE ROWS, not above them. It applies to both of them, but the rows are
/// what people come to this card for and a control inserted above them pushes
/// every one of them down the screen.
class _SamplesPerCheck extends StatelessWidget {
  const _SamplesPerCheck({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final tests = controller.deviceTests;
    // Mid-batch the count is fixed: a batch carries the number it was started
    // with, or the n on the card would not be the n that was measured.
    final locked = tests.isRunning || tests.isBatchActive;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Samples per check · ${controller.samplesPerTest}',
          style: AppText.devValue,
        ),
        const SizedBox(height: 4),
        const Text(
          'Both measurements are noisy, so one reading before the case and one '
          'after cannot be compared - the difference would be noise as often '
          'as not. Each check is taken this many times and reported as a '
          'median with the full range across the samples, so the spread is on '
          'the screen next to the figure.',
          style: AppText.footnote11,
        ),
        const SizedBox(height: 4),
        const Text(
          'The noise floor repeats on its own. The voice asks you between '
          'samples - and you can stop early at any point, which keeps every '
          'sample already taken.',
          style: AppText.footnote11,
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            for (final count in DeviceTestSampling.choices) ...<Widget>[
              if (count != DeviceTestSampling.choices.first)
                const SizedBox(width: 8),
              Expanded(
                child: SegmentButton(
                  label: '$count',
                  semanticLabel: count == 1
                      ? 'Take a single sample per check'
                      : 'Take $count samples per check',
                  selected: count == controller.samplesPerTest,
                  enabled: !locked,
                  onTap: () => controller.samplesPerTest = count,
                ),
              ),
            ],
          ],
        ),
        if (locked) ...<Widget>[
          const SizedBox(height: 4),
          const Text(
            'Fixed while a batch is in progress. The next one can differ.',
            style: AppText.footnote11,
          ),
        ],
      ],
    );
  }
}

/// The nRF52840's own junction temperature - the `fe07` characteristic.
///
/// A PASSIVE READING. Nothing on this card does anything; it is here because a
/// plastic case with a LiPo cell under the board will move this figure, and a
/// noise floor that got worse is worth a great deal more when the temperature it
/// was taken at is written next to it.
///
/// THE LABEL IS THE POINT. This is a DIE temperature: the sensor is inside the
/// same package as the CPU and the radio, so it reads well above the room even
/// on an open bench. A figure like "31.2" next to the word "temperature" will be
/// read as the room by anyone who did not write this file, so every place it
/// appears - here, the export, the card's own caption - says "die".
///
/// Three outcomes, never collapsed: a figure, a device that has the
/// characteristic but no reading (`0x8000`), and firmware that does not have
/// `fe07` at all. Zero would read as a freezing room, which is why the
/// controller's getter is nullable.
class _DieTemperatureCard extends StatelessWidget {
  const _DieTemperatureCard({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final available = controller.temperatureAvailable;
    final celsius = controller.dieTemperatureCelsius;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SectionCaption('Die temperature', small: true),
          const SizedBox(height: 12),
          KeyValueRow(
            label: 'Die',
            value: !available
                ? 'unavailable'
                : celsius == null
                    ? 'unknown (0x8000)'
                    : '${celsius.toStringAsFixed(1)} °C',
          ),
          const SizedBox(height: 12),
          Text(
            available
                ? 'The chip’s own junction temperature, NOT the room. The '
                    'sensor shares a package with the CPU and the radio, so it '
                    'self-heats - and it will read higher again inside the '
                    'enclosure with the cell underneath it. It is captured on '
                    'every mic check above, and the device only samples it while '
                    'this screen is open.'
                : controller.isConnected
                    ? 'This recorder did not report a die temperature, so '
                        'nothing is shown. Firmware without the fe07 '
                        'characteristic looks like this.'
                    : 'Connect to the recorder to read this. It is measured on '
                        'the device, not in the app.',
            style: AppText.footnote11,
          ),
        ],
      ),
    );
  }
}

/// One saved BATCH as the comparison reads it: when, how many samples, the
/// median of each headline reading, the range those samples spanned, and the
/// samples themselves.
///
/// THE SPREAD IS NOT A FOOTNOTE HERE. A three-decibel change after the
/// enclosure means nothing if the five samples before it spanned ten, and the
/// only way somebody reads that off the screen instead of deducing it is for the
/// range to sit on the line under the median.
///
/// THE SAMPLES ARE PRINTED IN FULL, and no reading is ever dropped for being
/// extreme. A single wild value is frequently the most interesting thing the
/// batch found - a resonance, a door - and a median that quietly excluded it
/// would hide exactly that. Nothing is excluded, so there is nothing to declare;
/// what IS declared is the opposite case, a sample that produced no reading at
/// all, which cannot enter a median and is counted out loud.
List<Widget> _batchLines(String when, DeviceTestBatch batch) {
  final colour = _batchColour(batch);
  return <Widget>[
    const SizedBox(height: 6),
    Text(
      '$when · ${Fmt.dayAndTime(batch.startedAt)} · ${_batchCount(batch)}',
      style: AppText.devLabel.copyWith(color: colour),
    ),
    for (final label in _headlineLabels(batch.kind))
      ..._spreadLines(batch.spreadOf(label), colour),
  ];
}

List<Widget> _spreadLines(ReadingSpread spread, Color colour) {
  final missing = spread.missing == 0
      ? ''
      : ' · ${spread.missing} of ${spread.sampleCount} had no reading';
  return <Widget>[
    const SizedBox(height: 2),
    Text(
      spread.hasSpread
          ? '${spread.label}: median '
              '${Fmt.measurement(spread.median, spread.unit)} · '
              '${Fmt.measurement(spread.min, spread.unit)} to '
              '${Fmt.measurement(spread.max, spread.unit)} · spread '
              '${Fmt.measurement(spread.spread, spread.unit)}$missing'
          : '${spread.label}: '
              '${Fmt.measurement(spread.median, spread.unit)}$missing',
      style: AppText.footnote11.copyWith(color: colour),
    ),
    // Every sample, so an outlier is visible rather than inferred.
    if (spread.hasSpread) ...<Widget>[
      const SizedBox(height: 2),
      Text(
        'samples: ${spread.values.map(
              (value) => Fmt.measurement(value, spread.unit),
            ).join(' · ')}',
        style: AppText.footnote11,
      ),
    ],
  ];
}

/// `n=5 of 5`, plus every caveat that belongs beside an n.
String _batchCount(DeviceTestBatch batch) {
  final parts = <String>[
    'n=${batch.sampleCount}'
        '${batch.requested > 1 ? ' of ${batch.requested}' : ''}',
    if (batch.isPartial) 'stopped early',
    // A COMPARISON AGAINST ONE RUN SAYS SO. It is not a baseline; it is a
    // single draw from a noisy process, and it cannot show its own spread.
    if (batch.isSingle) 'one run only, no spread to judge it by',
    ..._batchOutcomes(batch),
  ];
  return parts.join(' · ');
}

/// The outcomes that were not `completed`, counted. Nothing is said about the
/// ones that were: that is what a batch is supposed to look like.
List<String> _batchOutcomes(DeviceTestBatch batch) => <String>[
      for (final outcome in DeviceTestOutcome.values)
        if (outcome != DeviceTestOutcome.completed &&
            batch.countOf(outcome) > 0)
          batch.isSingle
              ? outcome.wireName
              : '${batch.countOf(outcome)} ${outcome.wireName}',
    ];

Color _batchColour(DeviceTestBatch batch) {
  if (batch.countOf(DeviceTestOutcome.failed) > 0) return AppColors.warning;
  if (batch.countOf(DeviceTestOutcome.completed) == batch.sampleCount) {
    return AppColors.textPrimary;
  }
  return AppColors.textSecondary;
}

/// What the operator has to do before the next sample can be taken.
String _nextSamplePrompt(DeviceTestKind kind) => switch (kind) {
      DeviceTestKind.sensitivity =>
        'Get back to ${DeviceTestReadings.sensitivityDistanceCm} cm and speak '
            'again when the next sample starts.',
      // The noise floor repeats unattended and never waits, so this is
      // unreachable.
      DeviceTestKind.noiseFloor => '',
    };

/// The readings worth putting on the card, per check. Everything else - the
/// frames lost during the window, the seconds of audio actually measured, the
/// die temperature - is in Export diagnostics.
List<String> _headlineLabels(DeviceTestKind kind) => switch (kind) {
      DeviceTestKind.noiseFloor => const <String>[
          DeviceTestReadings.noiseFloorRms,
        ],
      DeviceTestKind.sensitivity => const <String>[
          DeviceTestReadings.peak,
          DeviceTestReadings.rms,
        ],
    };

String _checkName(DeviceTestKind kind) => switch (kind) {
      DeviceTestKind.noiseFloor => 'Noise floor',
      DeviceTestKind.sensitivity => 'Sensitivity',
    };

String _checkBlurb(DeviceTestKind kind) => switch (kind) {
      DeviceTestKind.noiseFloor =>
        'Ten seconds of a quiet room, as RMS dBFS. Catches a rattle, a '
            'resonance, or case vibration coupling into the microphone.',
      DeviceTestKind.sensitivity =>
        'Speak at ${DeviceTestReadings.sensitivityDistanceCm} cm. Peak and RMS '
            'dBFS - what the enclosure’s port costs a voice.',
    };

String _blockerText(DeviceTestBlocker blocker) => switch (blocker) {
      DeviceTestBlocker.notConnected =>
        'Connect to the recorder first. The check measures its microphone, '
            'which needs its audio stream.',
      DeviceTestBlocker.recording =>
        'A recording is in progress. The audio notify stream takes one '
            'subscriber, so no check can have it until the capture stops.',
      DeviceTestBlocker.testRunning => 'Another check is running.',
    };

String _phasePrompt(DeviceTestPhase phase, DeviceTestKind kind) =>
    switch (phase) {
      DeviceTestPhase.idle => '',
      DeviceTestPhase.measuring => switch (kind) {
          DeviceTestKind.noiseFloor =>
            'Quiet room, hands off the device. Measuring…',
          DeviceTestKind.sensitivity =>
            'Speak now, at ${DeviceTestReadings.sensitivityDistanceCm} cm from '
                'the microphone port.',
        },
      DeviceTestPhase.saving => 'Saving the result…',
      // Nothing is running between samples, so the row draws its own prompt -
      // see [_nextSamplePrompt].
      DeviceTestPhase.awaitingNextSample => '',
    };
