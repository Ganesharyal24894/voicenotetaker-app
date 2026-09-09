import 'dart:async';

import 'package:flutter/material.dart';

import '../controller/app_controller.dart';
import 'format.dart';
import 'placeholder_data.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/waveform.dart';

/// Screen 3 - capture in progress.
class RecordingView extends StatefulWidget {
  const RecordingView({required this.controller, this.clock, super.key});

  final AppController controller;

  /// Wall clock, injectable for tests - the same seam `RecordingService`
  /// uses. Defaults to [DateTime.now].
  final DateTime Function()? clock;

  @override
  State<RecordingView> createState() => _RecordingViewState();
}

class _RecordingViewState extends State<RecordingView> {
  /// Wall-clock start of the capture. Nothing below `view/` publishes an
  /// elapsed time - `CaptureStats` counts packets - so the screen keeps its
  /// own clock, started when it is first shown.
  DateTime Function() get _clock => widget.clock ?? DateTime.now;

  late final DateTime _startedAt;
  late final Timer _tick;

  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _startedAt = _clock();
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      setState(() => _elapsed = _clock().difference(_startedAt));
    });
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.controller.streamInfo;
    final stats = widget.controller.stats;
    final stopping = widget.controller.phase == AppPhase.stopping;

    return ScreenScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const StatusDot(color: AppColors.recording, size: 7),
              const SizedBox(width: 8),
              Text(
                'Recording',
                style: AppText.label13.copyWith(color: AppColors.recording),
              ),
              const Spacer(),
              Text(
                info == null
                    ? '—'
                    : Fmt.streamSummary(info.sampleRateHz, info.channels),
                style: AppText.meta12,
              ),
            ],
          ),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(Fmt.timer(_elapsed), style: AppText.timer),
                const SizedBox(height: 42),
                LiveWaveform(advance: stats.framesReceived),
                const SizedBox(height: 42),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: <Widget>[
                    const Text('peak', style: AppText.meta13),
                    const SizedBox(width: 8),
                    Text(
                      PlaceholderData.peakDbfs == null
                          ? '— dBFS'
                          : '−${PlaceholderData.peakDbfs!.abs()} dBFS',
                      style: AppText.peakValue,
                    ),
                  ],
                ),
              ],
            ),
          ),
          Center(
            child: Column(
              children: <Widget>[
                _StopButton(
                  onTap: stopping ? null : widget.controller.stopRecording,
                ),
                const SizedBox(height: 20),
                Text(
                  stopping ? 'Saving…' : 'Saving to your phone',
                  style: AppText.meta12,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 78px rose ring around a 26px rose square.
class _StopButton extends StatelessWidget {
  const _StopButton({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: 'Stop recording',
      container: true,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 78,
          height: 78,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.recording, width: 1.5),
          ),
          alignment: Alignment.center,
          child: Container(
            width: 26,
            height: 26,
            decoration: const BoxDecoration(
              color: AppColors.recording,
              borderRadius: BorderRadius.all(Radius.circular(5)),
            ),
          ),
        ),
      ),
    );
  }
}
