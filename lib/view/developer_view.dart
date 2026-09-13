import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller/app_controller.dart';
import '../model/audio_codec.dart';
import '../model/battery_bars.dart';
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

/// Screen 6 - developer diagnostics. Debug builds only; reach it through
/// [debugOnlyDeveloperView].
///
/// Stateful for one reason: this screen is PUSHED, so a `setState` in
/// [AppRoot] does not reach it. Anything here that reflects live device state
/// - the codec selection, the auto-sleep flag the device reported - would
/// otherwise render once and then go stale. It listens the same way the
/// playback and recording screens do.
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
      // board running older firmware cannot be misread as "auto-sleep off".
      'auto-sleep: ${_controller.autoSleepAvailable ? (_controller.autoSleepEnabled ? 'on' : 'off') : 'unknown'}',
      // Same rule: "unknown" rather than a number, so a report from a board
      // running older firmware cannot be misread as a flat battery.
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
      ..._testHistoryLines(_controller.deviceTests.history),
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
            'Compiled out of release builds. Everything the technical '
            'direction put on the main screen lives here instead.',
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
                      // ATT MTU, interval and PHY are not exposed by
                      // `BleTransport`; adding them is a driver change, not a
                      // view one, so they read as unknown until it happens.
                      const KeyValueRow(
                        label: 'ATT MTU',
                        value: PlaceholderData.unknownValue,
                      ),
                      const SizedBox(height: 12),
                      const KeyValueRow(
                        label: 'Interval',
                        value: PlaceholderData.unknownValue,
                      ),
                      const SizedBox(height: 12),
                      const KeyValueRow(
                        label: 'PHY',
                        value: PlaceholderData.unknownValue,
                      ),
                      const SizedBox(height: 12),
                      KeyValueRow(
                        label: 'RSSI',
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
                      // Throughput needs a capture clock, which no layer
                      // publishes yet; the byte counters below are real.
                      const KeyValueRow(
                        label: 'Throughput',
                        value: PlaceholderData.unknownValue,
                      ),
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
                      const KeyValueRow(
                        label: 'Jitter buffer',
                        value: PlaceholderData.unknownValue,
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
                            child: _Segment(
                              label: 'ADPCM',
                              selected: _controller.preferredCodec ==
                                  AudioCodec.imaAdpcm,
                              onTap: () => _controller.preferredCodec =
                                  AudioCodec.imaAdpcm,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _Segment(
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
                // Appended below the battery, never inserted above it. Every
                // card on this screen is somewhere the people who use it
                // already know to look, and a card pushed down the list is a
                // card they have to hunt for.
                const SizedBox(height: 10),
                _TemperatureCard(controller: _controller),
                const SizedBox(height: 10),
                _DeviceTestsCard(controller: _controller),
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
          // measurement. Same rule as ATT MTU above.
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
/// UNAVAILABLE IS A REAL STATE, NOT A DEFAULT. When the device has not
/// reported the flag - nothing is connected, the read failed, or the firmware
/// predates `fe04` - NEITHER segment is selected and neither is tappable.
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
                child: _Segment(
                  label: 'Off',
                  semanticLabel: 'Auto-sleep off',
                  selected: available && !enabled,
                  enabled: available,
                  onTap: () => unawaited(controller.setAutoSleep(false)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _Segment(
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

/// One segment of a two-way selector - the codec pick, the auto-sleep flag.
/// Selected: purple fill with LIGHT text, per the contrast rule in `theme.dart`.
///
/// [enabled] false dims the segment and takes its tap away, which is how a
/// setting the device has not reported is shown: present, and visibly not
/// answerable.
class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.onTap,
    this.semanticLabel,
    this.enabled = true,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// Read out instead of [label] when the visible word is too short to say
  /// what it does on its own - "On" means nothing without "Auto-sleep".
  final String? semanticLabel;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: enabled,
      selected: selected,
      label: semanticLabel ?? label,
      container: true,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: SizedBox(
            height: AppShape.minTapTarget,
            child: Center(
              child: Container(
                height: 38,
                decoration: BoxDecoration(
                  color: selected ? AppColors.primaryFill : null,
                  border: selected
                      ? null
                      : Border.all(color: AppColors.border),
                  borderRadius: AppShape.segment,
                ),
                alignment: Alignment.center,
                child: Text(
                  label,
                  style: selected
                      ? AppText.devValue.copyWith(
                          fontWeight: FontWeight.w500,
                          color: AppColors.onPrimaryFill,
                        )
                      : AppText.devLabel.copyWith(
                          fontWeight: FontWeight.w400,
                          color: AppColors.textSecondary,
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The nRF52840's own junction temperature - the `fe07` characteristic.
///
/// THE LABEL IS THE POINT. This is a DIE temperature: the sensor is inside the
/// same package as the CPU and the radio, so it reads well above the room even
/// on an open bench, and it reads higher again inside a plastic case with a LiPo
/// cell underneath. A figure like "31.2" next to the word "temperature" will be
/// read as the room by anyone who did not write this file, so every place it
/// appears - here, the export, the card's own caption - says "die".
///
/// Three outcomes, never collapsed: a figure, a device that has the
/// characteristic but no reading (`0x8000`), and firmware that does not have
/// `fe07` at all. Zero would read as a freezing room, which is why the
/// controller's getter is nullable.
class _TemperatureCard extends StatelessWidget {
  const _TemperatureCard({required this.controller});

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
          // The raw wire value beside the figure, for the same reason the
          // battery card shows the bars beside the percentage: a report of a
          // decoding complaint is unanswerable without it.
          KeyValueRow(
            label: 'Decidegrees',
            value: controller.dieTemperature?.deciCelsius?.toString() ??
                PlaceholderData.unknownValue,
          ),
          const SizedBox(height: 12),
          Text(
            available
                ? 'The chip’s own junction temperature, NOT the room. The '
                    'sensor shares a package with the CPU and the radio, so it '
                    'self-heats - and it will read higher again inside the '
                    'enclosure with the cell underneath it, which is exactly '
                    'why it is worth a figure before and after. It is captured '
                    'on every test run below.'
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

/// The five enclosure tests, their controls, and the last two runs of each.
///
/// WHY THE LAST TWO RUNS ARE ON SCREEN. The recorder is going into a plastic
/// case with a cell under the board, and the only question worth asking is
/// whether that made things worse. One number cannot answer it. So each row
/// carries the most recent run AND the one before, side by side, which is the
/// before-and-after comparison the harness exists for; the full history, every
/// reading and every stop of every walk, is in Export diagnostics.
///
/// A TEST THAT CANNOT RUN IS NOT OFFERED. The same three-state rule the
/// auto-sleep card follows: no link, a capture already holding the exclusive
/// frame subscription, no `fe04` for the wake test, a denied scan permission -
/// each disables the control and says which it is. Nothing here ever shows a
/// default result.
class _DeviceTestsCard extends StatelessWidget {
  const _DeviceTestsCard({required this.controller});

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
          const SectionCaption('Device tests', small: true),
          const SizedBox(height: 8),
          const Text(
            'Enclosure before-and-after. Run the suite on the bare board, fit '
            'the case, run it again, and compare by date - the app cannot know '
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
            _TestRow(controller: controller, kind: kind),
          ],
          const SizedBox(height: 14),
          Text(
            tests.isLoaded
                ? '${tests.history.length} run'
                    '${tests.history.length == 1 ? '' : 's'} kept on this '
                    'phone, newest first, in ${tests.resultsFileName} '
                    'beside the recordings. Every one of them is in Export '
                    'diagnostics, readings and all.'
                : 'Saved runs have not been read yet.',
            style: AppText.footnote11,
          ),
        ],
      ),
    );
  }
}

/// One test: what it measures, its controls, and its last two results.
class _TestRow extends StatelessWidget {
  const _TestRow({required this.controller, required this.kind});

  final AppController controller;
  final DeviceTestKind kind;

  @override
  Widget build(BuildContext context) {
    final tests = controller.deviceTests;
    final isRunning = tests.running == kind;
    final blocker = kind == DeviceTestKind.wakeOnMotion
        ? controller.wakeTestBlocker
        : controller.testBlocker;
    final runs = tests.history.where((r) => r.kind == kind).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                _testName(kind),
                style: AppText.devValue,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 96,
              child: _Segment(
                label: isRunning ? 'Stop' : 'Run',
                semanticLabel:
                    '${isRunning ? 'Stop' : 'Run'} the ${_testName(kind).toLowerCase()} test',
                selected: isRunning,
                enabled: isRunning || blocker == null,
                onTap: () => unawaited(
                  isRunning ? _stop(controller, kind) : _start(controller, kind),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(_testBlurb(kind), style: AppText.footnote11),
        // A reason this test alone cannot run - no `fe04`, no scan permission.
        // The card already states whatever blocks every test; repeating it on
        // each of five rows would bury the one that is specific to this one.
        if (blocker != null &&
            blocker != DeviceTestBlocker.testRunning &&
            blocker != controller.testBlocker) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            _blockerText(blocker),
            style: AppText.footnote11.copyWith(color: AppColors.warning),
          ),
        ],
        if (isRunning) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            _phasePrompt(tests.phase, kind),
            style: AppText.footnote11.copyWith(color: AppColors.purpleText),
          ),
          const SizedBox(height: 6),
          KeyValueRow(
            label: 'Elapsed',
            value: Fmt.timer(tests.elapsed),
          ),
          // Frames while it runs, because a soak that is already shedding
          // packets is worth seeing before its three minutes are up.
          if (kind != DeviceTestKind.wakeOnMotion) ...<Widget>[
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
          if (kind == DeviceTestKind.range) ...<Widget>[
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: _Segment(
                    label: 'Mark step',
                    semanticLabel: 'Mark a range step',
                    selected: false,
                    onTap: () => unawaited(controller.markRangeStep()),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _Segment(
                    label: 'Finish',
                    semanticLabel: 'Finish the range walk',
                    selected: false,
                    onTap: () => unawaited(controller.finishRangeWalk()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // One wrapping line per stop rather than a label/value row: the
            // signal and both frame counts do not fit a phone's width side by
            // side, and a stop that is clipped is a stop the operator cannot
            // tell was recorded.
            for (final step in tests.steps)
              Text(
                'Stop ${step.index} · '
                '${Fmt.measurement(step.rssiDbm, 'dBm')} · '
                '${step.framesReceived} frames, ${step.framesLost} lost',
                style: AppText.footnote11.copyWith(
                  color: step.dropped
                      ? AppColors.warning
                      : AppColors.textSecondary,
                ),
              ),
          ],
          if (tests.phase == DeviceTestPhase.waitingForShake) ...<Widget>[
            const SizedBox(height: 8),
            _Segment(
              label: 'Shaken now',
              semanticLabel: 'I have shaken the device',
              selected: false,
              onTap: controller.confirmShaken,
            ),
          ],
        ],
        // The two runs that make a comparison. Nothing is shown when there has
        // never been a run - an empty row is honest, an invented one is not.
        //
        // A wrapping line rather than a label/value row for the same reason the
        // stops are: a timestamp plus two readings does not fit a phone's width
        // on one line, and a clipped measurement is worse than a wrapped one.
        if (runs.isNotEmpty) ...<Widget>[
          const SizedBox(height: 6),
          _RunLine(when: 'Latest', result: runs.first),
        ],
        if (runs.length > 1) ...<Widget>[
          const SizedBox(height: 3),
          _RunLine(when: 'Before', result: runs[1]),
        ],
      ],
    );
  }

  /// Ends a running test from the row's own control.
  ///
  /// The range walk needs BOTH halves: cancelling marks it abandoned, and only
  /// [AppController.finishRangeWalk] closes the stream and saves what the stops
  /// recorded. Cancelling alone would leave the walk running with its Stop
  /// button already pressed - which is the bug this method exists to prevent.
  Future<void> _stop(AppController controller, DeviceTestKind kind) async {
    controller.cancelDeviceTest();
    if (kind == DeviceTestKind.range) await controller.finishRangeWalk();
  }

  Future<void> _start(AppController controller, DeviceTestKind kind) =>
      switch (kind) {
        DeviceTestKind.range => controller.beginRangeWalk(),
        DeviceTestKind.noiseFloor => controller.runNoiseFloorTest(),
        DeviceTestKind.sensitivity => controller.runSensitivityTest(),
        DeviceTestKind.linkSoak => controller.runLinkSoakTest(),
        DeviceTestKind.wakeOnMotion => controller.runWakeOnMotionTest(),
      };
}

/// One saved run on one line: when it was taken, and what it measured.
class _RunLine extends StatelessWidget {
  const _RunLine({required this.when, required this.result});

  /// `Latest` or `Before` - which half of the comparison this is.
  final String when;
  final DeviceTestResult result;

  @override
  Widget build(BuildContext context) {
    return Text(
      '$when · ${Fmt.dayAndTime(result.startedAt)} · '
      '${_resultSummary(result)}',
      style: AppText.devLabel.copyWith(color: _outcomeColor(result.outcome)),
    );
  }
}

String _testName(DeviceTestKind kind) => switch (kind) {
      DeviceTestKind.range => 'Range',
      DeviceTestKind.noiseFloor => 'Noise floor',
      DeviceTestKind.sensitivity => 'Sensitivity',
      DeviceTestKind.linkSoak => 'Link soak',
      DeviceTestKind.wakeOnMotion => 'Wake on motion',
    };

String _testBlurb(DeviceTestKind kind) => switch (kind) {
      // The dropped-frame half is said out loud, because a reading of "RSSI
      // fine" on a link that is shedding packets is the exact mistake this
      // test exists to prevent.
      DeviceTestKind.range =>
        'Walk away in steps. Records the live link RSSI and the frames lost on '
            'each leg, because an acceptable RSSI can still be dropping frames.',
      DeviceTestKind.noiseFloor =>
        'Ten seconds of a quiet room, as RMS dBFS. Catches a rattle, a '
            'resonance, or case vibration coupling into the microphone.',
      DeviceTestKind.sensitivity =>
        'Speak at ${DeviceTestReadings.sensitivityDistanceCm} cm. Peak and RMS '
            'dBFS - what the enclosure’s port costs a voice.',
      DeviceTestKind.linkSoak =>
        'Streams for minutes and counts dropped frames and disconnections. '
            'Enclosure RF faults are usually intermittent, not absolute.',
      DeviceTestKind.wakeOnMotion =>
        'Enables auto-sleep, ends the link, waits for it to stop advertising, '
            'then times a shake. The case adds mass and damping.',
    };

String _blockerText(DeviceTestBlocker blocker) => switch (blocker) {
      DeviceTestBlocker.notConnected =>
        'Connect to the recorder first. Every test measures its link or its '
            'microphone, and neither exists without one.',
      DeviceTestBlocker.recording =>
        'A recording is in progress. The audio notify stream takes one '
            'subscriber, so no test can have it until the capture stops.',
      DeviceTestBlocker.testRunning => 'Another test is running.',
      DeviceTestBlocker.noAutoSleep =>
        'This firmware has no auto-sleep characteristic, so the device cannot '
            'be put to sleep on purpose and there is nothing to wake.',
      DeviceTestBlocker.scanPermissionDenied =>
        'Bluetooth permission was denied, and this test can only watch the '
            'device advertise by scanning.',
    };

String _phasePrompt(DeviceTestPhase phase, DeviceTestKind kind) =>
    switch (phase) {
      DeviceTestPhase.idle => '',
      DeviceTestPhase.walking =>
        'Walk away from the device in steps. Tap Mark step at each stop, then '
            'Finish.',
      DeviceTestPhase.measuring => switch (kind) {
          DeviceTestKind.noiseFloor =>
            'Quiet room, hands off the device. Measuring…',
          DeviceTestKind.sensitivity =>
            'Speak now, at ${DeviceTestReadings.sensitivityDistanceCm} cm from '
                'the microphone port.',
          _ => 'Streaming. Leave the device where it will actually live.',
        },
      DeviceTestPhase.waitingForSystemOff =>
        'Put the device down and do not touch it. Waiting for it to stop '
            'advertising, which is System OFF.',
      DeviceTestPhase.waitingForShake =>
        'It is asleep. Shake it, then tap Shaken now - the clock starts on the '
            'tap, not on this prompt.',
      DeviceTestPhase.waitingForWake => 'Waiting for it to advertise again…',
      DeviceTestPhase.saving => 'Saving the result…',
    };

/// The readings worth putting on the card, per test. Everything else is in the
/// export.
List<String> _headlineLabels(DeviceTestKind kind) => switch (kind) {
      DeviceTestKind.range => const <String>[
          DeviceTestReadings.rssiAtFirstDrop,
          DeviceTestReadings.lossPercent,
        ],
      DeviceTestKind.noiseFloor => const <String>[
          DeviceTestReadings.noiseFloorRms,
        ],
      DeviceTestKind.sensitivity => const <String>[
          DeviceTestReadings.peak,
          DeviceTestReadings.rms,
        ],
      DeviceTestKind.linkSoak => const <String>[
          DeviceTestReadings.framesLost,
          DeviceTestReadings.disconnections,
        ],
      DeviceTestKind.wakeOnMotion => const <String>[
          DeviceTestReadings.wakeDelay,
        ],
    };

/// One run in a line. An outcome that is not `completed` is NAMED, so a
/// cancelled run's partial numbers cannot be mistaken for a finished run's.
String _resultSummary(DeviceTestResult result) {
  final parts = <String>[
    for (final label in _headlineLabels(result.kind))
      if (result.reading(label) case final reading?)
        Fmt.measurement(reading.value, reading.unit),
  ];
  final word = result.outcome == DeviceTestOutcome.completed
      ? ''
      : '${result.outcome.wireName} · ';
  if (parts.isEmpty) {
    return result.outcome == DeviceTestOutcome.completed
        ? PlaceholderData.unknownValue
        : result.outcome.wireName;
  }
  return '$word${parts.join(' · ')}';
}

Color _outcomeColor(DeviceTestOutcome outcome) => switch (outcome) {
      DeviceTestOutcome.completed => AppColors.textPrimary,
      DeviceTestOutcome.cancelled => AppColors.textSecondary,
      DeviceTestOutcome.unavailable => AppColors.textSecondary,
      DeviceTestOutcome.failed => AppColors.warning,
    };

/// The die temperature as the export states it - three outcomes, and the word
/// "die" in every one of them.
String _temperatureLine(AppController controller) {
  if (!controller.temperatureAvailable) return 'unavailable';
  final celsius = controller.dieTemperatureCelsius;
  if (celsius == null) return 'unknown (0x8000)';
  return '${celsius.toStringAsFixed(1)} °C die '
      '(${controller.dieTemperature!.deciCelsius} decidegrees, NOT ambient)';
}

/// The whole saved history, for the export.
///
/// Not truncated. A harness whose export drops the run you wanted to compare
/// against is not an export.
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
      for (final step in result.steps)
        '  stop ${step.index}: ${Fmt.measurement(step.rssiDbm, 'dBm')}, '
            '${step.framesReceived} frames, ${step.framesLost} lost',
      if (result.note != null) '  note: ${result.note}',
    ],
  ];
}
