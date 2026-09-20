import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller/app_controller.dart';
import '../model/audio_codec.dart';
import '../model/battery_bars.dart';
import '../model/device_test_aggregate.dart';
import '../model/device_test_result.dart';
import 'format.dart';
import 'placeholder_data.dart';
import 'theme.dart';
import 'widgets/app_icons.dart';
import 'widgets/common.dart';

/// The ONLY construction site of [DeveloperView].
///
/// [kDebugMode] is a compile-time constant, so in a release build the body of
/// the `if` below is dead code and the whole screen - along with everything it
/// pulls in - is tree-shaken out of the binary. Never construct
/// [DeveloperView] anywhere else, or that guarantee is lost.
Widget? debugOnlyDeveloperView({
  required AppController controller,
  VoidCallback? onBack,
}) {
  if (kDebugMode) {
    return DeveloperView(controller: controller, onBack: onBack);
  }
  return null;
}

/// Developer options. Debug builds only; reach it through
/// [debugOnlyDeveloperView], which is reached from the diagnostics screen.
///
/// WHAT LIVES HERE AND WHY. The split between this screen and Device
/// Diagnostics is observe versus mutate. Everything that CHANGES the recorder
/// is here - the codec it is asked for, the auto-sleep flag that is written into
/// its flash - because a wrong tap on either has consequences for the device
/// rather than for a number on a page. Everything a user can only WATCH is on
/// the diagnostics screen, which is in release builds too: the live link, the
/// mic check and its history, the die temperature.
///
/// The raw link and stream counters stay here rather than moving across, because
/// they are the same facts the diagnostics screen states in a readable form -
/// byte totals and malformed-frame counts belong in a report, not in front of
/// somebody asking whether their recorder is working.
///
/// Stateful for two reasons: this screen is PUSHED, so a `setState` in [AppRoot]
/// does not reach it - anything here that reflects live device state would
/// otherwise render once and go stale - and the diagnostics report quotes the
/// die temperature, which is read once on the way in. THAT READ IS A READ, not a
/// subscription: `fe07` notifications are what make the firmware sample the
/// sensor continuously, and they belong to the screen that draws a live figure.
class DeveloperView extends StatefulWidget {
  const DeveloperView({required this.controller, this.onBack, super.key});

  final AppController controller;
  final VoidCallback? onBack;

  @override
  State<DeveloperView> createState() => _DeveloperViewState();
}

class _DeveloperViewState extends State<DeveloperView> {
  AppController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
    // One read, no subscription - see the class comment. It costs the device a
    // single sample and it is what keeps the die line in the report from saying
    // "unavailable" on a perfectly healthy recorder.
    unawaited(_controller.refreshTemperature());
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  String _diagnostics() {
    final device = _controller.connectedDevice;
    final stats = _controller.stats;
    final info = _controller.streamInfo;
    final tests = _controller.deviceTests;
    return <String>[
      'voiceNotetaker diagnostics',
      'generated: ${DateTime.now().toIso8601String()}',
      'phase: ${_controller.phase.name}',
      'adapter: ${_controller.availability.name}',
      'address: ${device?.id ?? '—'}',
      'name: ${device?.name ?? '—'}',
      'rssi: ${Fmt.rssi(device?.rssi)}',
      'codec requested: ${_controller.preferredCodec.name}',
      // Reported as unknown when the device never told us, so a report from a
      // board that did not answer cannot be misread as "auto-sleep off".
      'auto-sleep: ${_controller.autoSleepAvailable ? (_controller.autoSleepEnabled ? 'on' : 'off') : 'unknown'}',
      // Same rule: "unknown" rather than a number, so a report from a board
      // that did not answer cannot be misread as a flat battery.
      'battery: ${_controller.batteryAvailable ? (_controller.batteryPercent == null ? 'unknown (0xFF)' : '${_controller.batteryPercent}%') : 'unavailable'}',
      // What Home was DRAWING at the time, beside the figure it came from:
      // a report that only carried the percentage could not explain a
      // complaint about the bars.
      'battery bars: ${_controller.batteryPercent == null ? 'none' : '${_controller.batteryBars.bars} of ${BatteryBars.maxBars}'}',
      'charging: ${_controller.batteryAvailable ? (_controller.batteryCharging ? 'yes' : 'no') : 'unknown'}',
      'stream: ${info == null ? '—' : info.toString()}',
      'frames received: ${stats.framesReceived}',
      'frames lost: ${stats.framesLost}',
      'malformed frames: ${stats.malformedFrames}',
      'wire bytes: ${stats.wireBytes}',
      'decoded bytes: ${stats.decodedBytes}',
      // Labelled DIE on purpose, wherever it appears. It is the chip's own
      // junction temperature and it reads above the room; a report that called
      // it "temperature" would be read as ambient by whoever receives it.
      'die temperature: ${_temperatureLine(_controller)}',
      'last file: ${_controller.lastRecording?.path ?? '—'}',
      'error: ${_controller.errorMessage ?? 'none'}',
      ..._retiredRunLines(_controller),
      ..._testAggregateLines(tests.history),
      ..._testHistoryLines(tests.history),
      ..._measurementNotes,
    ].join('\n');
  }

  Future<void> _export(BuildContext context) async {
    final text = _diagnostics();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: const RoundedRectangleBorder(borderRadius: AppShape.card),
        title: const Text('Diagnostics', style: AppText.title22),
        content: SingleChildScrollView(
          child: SelectableText(text, style: AppText.footnote12),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (context.mounted) Navigator.of(context).pop();
            },
            child: Text(
              'Copy',
              style: AppText.label13.copyWith(color: AppColors.purpleText),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close', style: AppText.label13),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final device = _controller.connectedDevice;
    final stats = _controller.stats;
    final lossPercent = (stats.lossRatio * 100).toStringAsFixed(2);
    final onBack = widget.onBack;

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
                  'Developer',
                  style: AppText.title22,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.warningBadgeFill,
                  border: Border.all(color: AppColors.warningBadgeBorder),
                  borderRadius: const BorderRadius.all(Radius.circular(6)),
                ),
                child: const Text('DEBUG ONLY', style: AppText.badge),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Compiled out of release builds. Everything here CHANGES the '
            'recorder; anything you can only watch is on Diagnostics, which '
            'ships in release builds too.',
            style: AppText.footnote12,
          ),
          const SizedBox(height: 22),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: <Widget>[
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const SectionCaption('Link', small: true),
                      const SizedBox(height: 12),
                      KeyValueRow(
                        label: 'Address',
                        value: device?.id ?? PlaceholderData.unknownValue,
                      ),
                      const SizedBox(height: 12),
                      // The advertising sample taken at scan time, NOT the live
                      // link - that one is the meter on the diagnostics screen,
                      // and the two are different numbers.
                      KeyValueRow(
                        label: 'RSSI at scan',
                        value: Fmt.rssi(device?.rssi),
                        valueColor: device?.rssi == null
                            ? AppColors.textPrimary
                            : AppColors.connected,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const SectionCaption('Stream', small: true),
                      const SizedBox(height: 12),
                      KeyValueRow(
                        label: 'Packets lost',
                        value: '${stats.framesLost} ($lossPercent%)',
                        valueColor: stats.framesLost == 0
                            ? AppColors.connected
                            : AppColors.warning,
                      ),
                      const SizedBox(height: 12),
                      KeyValueRow(
                        label: 'Frames received',
                        value: '${stats.framesReceived}',
                      ),
                      const SizedBox(height: 12),
                      KeyValueRow(
                        label: 'Decoded',
                        value: Fmt.bytes(stats.decodedBytes),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'The last capture, not the live link. Nothing here '
                        'moves unless a recording is running.',
                        style: AppText.footnote11,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const SectionCaption('Codec', small: true),
                      const SizedBox(height: 12),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: SegmentButton(
                              label: 'ADPCM',
                              selected: _controller.preferredCodec ==
                                  AudioCodec.imaAdpcm,
                              onTap: () => _controller.preferredCodec =
                                  AudioCodec.imaAdpcm,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: SegmentButton(
                              label: 'Raw PCM',
                              selected: _controller.preferredCodec ==
                                  AudioCodec.pcmS16le,
                              onTap: () => _controller.preferredCodec =
                                  AudioCodec.pcmS16le,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Raw PCM needs ATT MTU ≥ 247. iOS negotiates ~185, so '
                        'it is unavailable there.',
                        style: AppText.footnote11,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                _AutoSleepCard(controller: _controller),
                // Below auto-sleep: the two cards that talk about the cell
                // and its power belong together, and appending rather than
                // inserting leaves every card above exactly where the people
                // who use this screen already expect to find it.
                const SizedBox(height: 10),
                _BatteryCard(controller: _controller),
                if (_controller.transcriptionAvailable) ...<Widget>[
                  const SizedBox(height: 10),
                  _TranscriptionTimingCard(controller: _controller),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          QuietButton(
            label: 'Export diagnostics',
            onPressed: () => _export(context),
          ),
        ],
      ),
    );
  }
}

/// The battery reading in full - the figure the main screen no longer shows.
///
/// WHY THE PERCENTAGE LIVES HERE. Home shows four bars, because that is all
/// the measurement supports: the device derives its percentage from cell
/// voltage against an OCV curve, and across the middle of that curve about
/// 2 mV separate one point from the next, which an uncalibrated reference can
/// be well outside. The error is not uniform, though - near full it is about
/// 9 mV per point and near empty about 38, both sound - so the figure is worth
/// having, as long as the caveat travels with it. This screen is where a
/// caveat can be written down; a 12px figure in the header is not.
///
/// The device still reports the percentage and still logs it. Nothing was
/// discarded at the protocol layer: bucketing happens in the app, so a future
/// fuel-gauge IC can drive a finer display without the characteristic
/// changing.
class _BatteryCard extends StatelessWidget {
  const _BatteryCard({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final available = controller.batteryAvailable;
    final percent = controller.batteryPercent;
    final bars = controller.batteryBars;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SectionCaption('Battery', small: true),
          const SizedBox(height: 12),
          // Three outcomes, never collapsed into a number: a figure, a device
          // that has the characteristic but no reading, and firmware that
          // does not have it at all. The same rule the diagnostics report
          // follows, and for the same reason - a zero here would be read as a
          // flat cell.
          KeyValueRow(
            label: 'Charge',
            value: !available
                ? 'unavailable'
                : percent == null
                    ? 'unknown (0xFF)'
                    : '$percent%',
          ),
          const SizedBox(height: 12),
          // What Home is drawing from that figure, so the two can be compared
          // when a bucket boundary is in question.
          KeyValueRow(
            label: 'Bars',
            value: percent == null
                ? PlaceholderData.unknownValue
                : '${bars.bars} of ${BatteryBars.maxBars}'
                    '${bars.isFull ? ' (full)' : ''}'
                    '${bars.isCritical ? ' (critical)' : ''}',
          ),
          const SizedBox(height: 12),
          KeyValueRow(
            label: 'Charging',
            value: available
                ? (controller.batteryCharging ? 'yes' : 'no')
                : PlaceholderData.unknownValue,
            valueColor: available && controller.batteryCharging
                ? AppColors.connected
                : AppColors.textPrimary,
          ),
          const SizedBox(height: 12),
          // Millivolts belong beside the percentage, and `fe05` does not carry
          // them: two bytes, a percentage and a flags byte. Shown as unknown
          // rather than back-calculated from the percentage through the same
          // curve that produced it, which would be a circle dressed up as a
          // measurement.
          const KeyValueRow(
            label: 'Cell voltage',
            value: PlaceholderData.unknownValue,
          ),
          const SizedBox(height: 12),
          Text(
            'Home shows four bars, not this figure. Around the middle of the '
            'discharge curve about 2 mV separate one percentage point from '
            'the next, so a mid-range reading is precise-looking and not '
            'reliable; near full and near empty it is 9 and 38 mV per point, '
            'which is why the ends of the scale can be trusted. The device '
            'reports and logs the percentage either way - the bucketing is '
            "the app's.",
            style: AppText.footnote11,
          ),
        ],
      ),
    );
  }
}

/// The auto-sleep toggle - the `fe04` flag the device keeps in flash.
///
/// THE CLEAREST CASE OF A MUTATING CONTROL, which is why it is on this screen
/// and not on Diagnostics: a tap here writes a byte into the recorder's flash
/// that decides whether it puts itself to sleep.
///
/// UNAVAILABLE IS A REAL STATE, NOT A DEFAULT. When the device has not
/// reported the flag - nothing is connected, the read failed, or the firmware
/// did not answer `fe04` - NEITHER segment is selected and neither is
/// tappable.
/// Showing "Off" there would be a claim about a setting that can put the
/// recorder to sleep, made without having read it.
class _AutoSleepCard extends StatelessWidget {
  const _AutoSleepCard({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final available = controller.autoSleepAvailable;
    final enabled = available && controller.autoSleepEnabled;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SectionCaption('Auto-sleep', small: true),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: SegmentButton(
                  label: 'Off',
                  semanticLabel: 'Auto-sleep off',
                  selected: available && !enabled,
                  enabled: available,
                  onTap: () => unawaited(controller.setAutoSleep(false)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SegmentButton(
                  label: 'On',
                  semanticLabel: 'Auto-sleep on',
                  selected: enabled,
                  enabled: available,
                  onTap: () => unawaited(controller.setAutoSleep(true)),
                ),
              ),
            ],
          ),
          if (!available) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              controller.isConnected
                  ? 'This recorder did not report the setting, so nothing is '
                      'shown and nothing is written. Firmware without the '
                      'auto-sleep characteristic looks like this.'
                  : 'Connect to the recorder to read this setting. It is kept '
                      'on the device, not in the app.',
              style: AppText.footnote11,
            ),
          ],
          const SizedBox(height: 12),
          const Text(
            'The device sleeps after about 10 seconds without motion. It will '
            'not sleep while recording, or while the app is connected.',
            style: AppText.footnote11,
          ),
        ],
      ),
    );
  }
}

/// How every figure on the diagnostics screen is actually arrived at.
///
/// THIS IS WHERE THE PRECISE WORDING LIVES NOW. The diagnostics screen used to
/// carry these paragraphs itself, in this register, and it was the wrong screen
/// for them: somebody opening Diagnostics wants to know whether their recorder
/// is working, not which characteristic a counter is derived from. The screen now
/// says the same things in plain language, and nothing was deleted - it moved
/// here, into the report an engineer reads when a plain-language sentence turns
/// out not to be enough.
///
/// PART OF THE EXPORT RATHER THAN A CARD, because this is the text that has to
/// travel. A bug report is pasted somewhere else entirely, and a caveat that
/// stayed on this screen would not go with it.
const List<String> _measurementNotes = <String>[
  '',
  '--- how the diagnostics screen measures things ---',
  '',
  'signal: the live connection RSSI in dBm, polled while the diagnostics '
      'screen is open. NOT the advertising sample under "RSSI at scan" above; '
      'the two are different numbers taken at different times. RSSI alone '
      'misleads - a link at a respectable -75 dBm can be shedding one frame in '
      'twenty, because what costs a notify stream its packets is retries in a '
      'crowded band rather than path loss - which is why the loss figures sit '
      'directly under it on the screen.',
  '',
  'audio received / audio lost / percent lost: frames, counted from gaps in the '
      'fe01 sequence number. That is what makes them the numbers worth having: '
      'they count what the PHONE failed to receive, air losses included, where '
      'a byte counter kept by the firmware could only say what the firmware '
      'believed it had sent. The counters start from zero each time the '
      'diagnostics screen opens, so they describe one sitting and not the life '
      'of the link. Leaving that screen open IS the soak test; carrying it '
      'across a room is the range walk. Both stand down while a mic check runs, '
      'because the fe01 subscription takes one listener at a time.',
  '',
  'temperature: the nRF52840 DIE temperature from fe07, NOT ambient. The sensor '
      'shares a package with the CPU and the radio, so it self-heats and reads '
      'well above the room even on an open bench, higher again inside the '
      'enclosure with the cell underneath. 0x8000 means the characteristic '
      'exists and has no reading; firmware without fe07 at all reads as '
      'unavailable. Subscribing is what makes the firmware sample the sensor, '
      'so it is sampled only while the diagnostics screen is visible.',
  '',
  'noise floor: a ten-second window of a quiet room, reported as RMS dBFS and '
      'labelled "Noise floor (RMS)" in the readings above. Measured over the '
      'whole window in the linear domain - see services/level_meter.dart for '
      'why averaging dBFS would under-report a transient. A floor that rose '
      'after the enclosure went on is the case itself: a rattle, a resonance, '
      'or vibration coupling into the MEMS microphone.',
  '',
  'sensitivity: a voice at ${DeviceTestReadings.sensitivityDistanceCm} cm from '
      'the microphone port at a normal speaking level, reported as peak and RMS '
      'dBFS ("Loudest" and "Average" on the screen). Comparable between runs '
      'only because the distance is fixed; move it and the numbers mean '
      'nothing. What it catches is what the enclosure\u2019s port costs a '
      'voice.',
  '',
  'batches: a median and the full min-to-max range, never a mean and never a '
      'standard deviation - see model/device_test_aggregate.dart for the '
      'reasoning, including why an inter-quartile range would discard exactly '
      'the extreme sample worth looking at. Nothing is excluded from a median '
      'except a sample that produced no reading at all, which is counted out '
      'loud. The expected range grows with n, so a range is only comparable '
      'against another range of similar size; the counts are fixed per check in '
      'DeviceTestSampling and every batch above prints its own n.',
];

/// The die temperature as the export states it - three outcomes, and the word
/// "die" in every one of them.
String _temperatureLine(AppController controller) {
  if (!controller.temperatureAvailable) return 'unavailable';
  final celsius = controller.dieTemperatureCelsius;
  if (celsius == null) return 'unknown (0x8000)';
  return '${celsius.toStringAsFixed(1)} °C die '
      '(${controller.dieTemperature!.deciCelsius} decidegrees, NOT ambient)';
}

/// Runs in the saved file that this build does not read, accounted for out loud.
///
/// WHY THE EXPORT SAYS THIS. The file on the owner's phone holds a bare-board
/// baseline, and some of those runs are of measurements that have since been
/// retired. They are KEPT IN THE FILE and written back out untouched, but this
/// build cannot interpret them, so they are not in the history below. A report
/// that silently listed twelve of fifteen runs would look like data loss.
List<String> _retiredRunLines(AppController controller) {
  final unread = controller.unreadDeviceTestRunCount;
  if (unread == 0) return const <String>[];
  return <String>[
    '',
    'saved runs this build does not read: $unread. '
        'They are kept in the file untouched.',
  ];
}

/// Every saved batch reduced to its medians and ranges, for the export.
///
/// BEFORE the run-by-run list and not instead of it. This section is what
/// somebody reading the report actually compares; the individual samples below
/// it are what lets them check that the aggregate is not hiding an outlier.
///
/// Every reading is aggregated here, not just the headline ones the card has
/// room for.
List<String> _testAggregateLines(List<DeviceTestResult> history) {
  final batches = DeviceTestBatch.group(history);
  if (batches.isEmpty) return const <String>[];
  return <String>[
    '',
    '--- device test batches (median and full range per batch) ---',
    for (final batch in batches) ...<String>[
      '',
      '${batch.startedAt.toIso8601String()}  ${batch.kind.wireName}  '
          'n=${batch.sampleCount} of ${batch.requested}'
          '${batch.isPartial ? '  (stopped early)' : ''}',
      for (final label in _labelsIn(batch))
        '  ${_aggregateLine(batch.spreadOf(label))}',
    ],
  ];
}

/// Every reading label the batch produced, in the order the samples list them.
List<String> _labelsIn(DeviceTestBatch batch) {
  final labels = <String>[];
  for (final run in batch.runs) {
    for (final reading in run.readings) {
      if (!labels.contains(reading.label)) labels.add(reading.label);
    }
  }
  return labels;
}

String _aggregateLine(ReadingSpread spread) {
  final missing = spread.missing == 0
      ? ''
      : ', ${spread.missing} of ${spread.sampleCount} had no reading';
  if (!spread.hasSpread) {
    return '${spread.label}: '
        '${Fmt.measurement(spread.median, spread.unit)} '
        '(n=${spread.n}, no spread)$missing';
  }
  return '${spread.label}: median '
      '${Fmt.measurement(spread.median, spread.unit)}, range '
      '${Fmt.measurement(spread.min, spread.unit)} to '
      '${Fmt.measurement(spread.max, spread.unit)}, spread '
      '${Fmt.measurement(spread.spread, spread.unit)} (n=${spread.n})$missing';
}

/// The whole saved history, for the export.
///
/// Not truncated. A report that drops the run you wanted to compare against is
/// not a report.
List<String> _testHistoryLines(List<DeviceTestResult> history) {
  return <String>[
    '',
    '--- device tests (${history.length} run'
        '${history.length == 1 ? '' : 's'} kept) ---',
    if (history.isEmpty) 'nothing has been run on this phone yet',
    for (final result in history) ...<String>[
      '',
      '${result.startedAt.toIso8601String()}  ${result.kind.wireName}  '
          '${result.outcome.wireName}  '
          '${(result.duration.inMilliseconds / 1000).toStringAsFixed(1)}s',
      for (final reading in result.readings)
        '  ${reading.label}: ${Fmt.measurement(reading.value, reading.unit)}',
      if (result.note != null) '  note: ${result.note}',
    ],
  ];
}

/// The last transcription's cost - a small readout, not a control.
///
/// Transcribing is done from a note's screen now. What is left
/// here is the part only a developer wants: how long the model took to load
/// and decode, and what it did to the app's memory. Nothing runs from this
/// card.
class _TranscriptionTimingCard extends StatelessWidget {
  const _TranscriptionTimingCard({required this.controller});

  final AppController controller;

  static String _ms(Duration d) => '${d.inMilliseconds} ms';

  static String _mb(int? kb) =>
      kb == null ? PlaceholderData.unknownValue : '${(kb / 1024).round()} MB';

  @override
  Widget build(BuildContext context) {
    final result = controller.lastTranscription;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SectionCaption('Last transcript', small: true),
          const SizedBox(height: 12),
          if (result == null)
            const Text(
              'Transcribe a recording to see its timings.',
              style: AppText.footnote12,
            )
          else ...<Widget>[
            KeyValueRow(label: 'Audio', value: _ms(result.audioDuration)),
            const SizedBox(height: 8),
            KeyValueRow(label: 'Load', value: _ms(result.loadTime)),
            const SizedBox(height: 8),
            KeyValueRow(label: 'Decode', value: _ms(result.decodeTime)),
            const SizedBox(height: 8),
            KeyValueRow(
              label: 'Real-time factor',
              value: result.realTimeFactor == null
                  ? PlaceholderData.unknownValue
                  : result.realTimeFactor!.toStringAsFixed(3),
            ),
            const SizedBox(height: 8),
            KeyValueRow(
              label: 'Memory before',
              value: _mb(result.rssBeforeLoadKb),
            ),
            const SizedBox(height: 8),
            KeyValueRow(label: 'Memory peak', value: _mb(result.peakRssKb)),
            const SizedBox(height: 8),
            KeyValueRow(
              label: 'Memory after',
              value: _mb(result.rssAfterReleaseKb),
            ),
            const SizedBox(height: 12),
            const Text(
              'Memory is the whole app.',
              style: AppText.footnote11,
            ),
          ],
        ],
      ),
    );
  }
}
