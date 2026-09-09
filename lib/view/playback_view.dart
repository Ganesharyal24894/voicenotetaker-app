import 'package:flutter/material.dart';

import 'format.dart';
import 'recording_entry.dart';
import 'theme.dart';
import 'widgets/app_icons.dart';
import 'widgets/common.dart';
import 'widgets/waveform.dart';

/// Screen 5 - playback.
///
/// PLACEHOLDER TRANSPORT: `lib/drivers/audio_player.dart` is interface-only -
/// no playback package has been chosen - so the scrubber, the play/pause state
/// and the speed chip move local state and nothing else. No `AudioPlayer` is
/// invented here; when one lands, replace [_PlaybackViewState] with the
/// driver's `PlaybackState` stream and the layout below is unchanged.
class PlaybackView extends StatefulWidget {
  const PlaybackView({required this.entry, this.onBack, super.key});

  final RecordingEntry entry;
  final VoidCallback? onBack;

  @override
  State<PlaybackView> createState() => _PlaybackViewState();
}

class _PlaybackViewState extends State<PlaybackView> {
  static const List<double> _speeds = <double>[1.0, 1.5, 2.0, 0.5];

  /// Starts at the mock's 01:52 of 04:12 so the scrubber shows a played and
  /// an unplayed half. Placeholder: nothing is actually playing.
  late Duration _position = Duration(
    seconds: (widget.entry.duration.inSeconds * 0.444).round(),
  );
  bool _playing = false;
  int _speedIndex = 0;

  Duration get _duration => widget.entry.duration;

  double get _progress => _duration.inMilliseconds == 0
      ? 0
      : _position.inMilliseconds / _duration.inMilliseconds;

  void _seekTo(Duration position) {
    setState(() {
      _position = Duration(
        milliseconds:
            position.inMilliseconds.clamp(0, _duration.inMilliseconds),
      );
    });
  }

  void _notWiredUp(String what) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          backgroundColor: AppColors.raised,
          content: Text(what, style: AppText.body13),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final remaining = _duration - _position;

    return ScreenScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              TapTarget(
                onTap: widget.onBack,
                semanticLabel: 'Back to recordings',
                child: const AppIcon(
                  AppGlyph.chevronLeft,
                  size: 20,
                  color: AppColors.textSecondary,
                  strokeWidth: 1.7,
                ),
              ),
              const SizedBox(width: 4),
              const Expanded(
                child: Text('Recordings', style: AppText.meta13),
              ),
              TapTarget(
                onTap: () => _notWiredUp('No actions here yet.'),
                semanticLabel: 'More',
                child: const AppIcon(
                  AppGlyph.more,
                  size: 19,
                  color: AppColors.textSecondary,
                  strokeWidth: 1.7,
                ),
              ),
            ],
          ),
          const SizedBox(height: 34),
          Text(widget.entry.title, style: AppText.title24),
          const SizedBox(height: 8),
          Text(widget.entry.playbackLabel(), style: AppText.meta13),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ScrubWaveform(
                  progress: _progress,
                  onSeek: (fraction) => _seekTo(
                    Duration(
                      milliseconds:
                          (_duration.inMilliseconds * fraction).round(),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: <Widget>[
                    Text(Fmt.timer(_position), style: AppText.scrubTime),
                    const Spacer(),
                    Text(
                      '−${Fmt.timer(remaining)}',
                      style: AppText.scrubTime
                          .copyWith(color: AppColors.textTertiary),
                    ),
                  ],
                ),
                const SizedBox(height: 34),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    _SkipButton(
                      glyph: AppGlyph.skipBack,
                      label: '15s',
                      semanticLabel: 'Skip back 15 seconds',
                      onTap: () => _seekTo(
                        _position - const Duration(seconds: 15),
                      ),
                    ),
                    const SizedBox(width: 34),
                    _PlayPauseButton(
                      playing: _playing,
                      onTap: () {
                        setState(() => _playing = !_playing);
                        _notWiredUp(
                          'Playback is not wired up yet — no audio player '
                          'driver has been chosen.',
                        );
                      },
                    ),
                    const SizedBox(width: 34),
                    _SkipButton(
                      glyph: AppGlyph.skipForward,
                      label: '30s',
                      semanticLabel: 'Skip forward 30 seconds',
                      onTap: () => _seekTo(
                        _position + const Duration(seconds: 30),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Row(
            children: <Widget>[
              TapTarget(
                semanticLabel: 'Playback speed',
                onTap: () => setState(
                  () => _speedIndex = (_speedIndex + 1) % _speeds.length,
                ),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.border),
                    borderRadius: AppShape.pill,
                  ),
                  child: Text(
                    '${_speeds[_speedIndex].toStringAsFixed(1)}×',
                    style: AppText.label13,
                  ),
                ),
              ),
              const Spacer(),
              TapTarget(
                semanticLabel: 'Transcribe',
                onTap: () => _notWiredUp(
                  'Transcription is not available yet.',
                ),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.purpleChipFill,
                    border: Border.all(color: AppColors.purpleChipBorder),
                    borderRadius: AppShape.pill,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const AppIcon(
                        AppGlyph.transcribe,
                        size: 15,
                        color: AppColors.purpleText,
                        strokeWidth: 1.7,
                      ),
                      const SizedBox(width: 9),
                      Text(
                        'Transcribe',
                        style: AppText.label13
                            .copyWith(color: AppColors.purpleText),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SkipButton extends StatelessWidget {
  const _SkipButton({
    required this.glyph,
    required this.label,
    required this.semanticLabel,
    required this.onTap,
  });

  final AppGlyph glyph;
  final String label;
  final String semanticLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TapTarget(
      onTap: onTap,
      semanticLabel: semanticLabel,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AppIcon(
            glyph,
            size: 26,
            color: AppColors.textSecondary,
            strokeWidth: 1.6,
          ),
          const SizedBox(height: 4),
          Text(label, style: AppText.micro10),
        ],
      ),
    );
  }
}

/// 82px purple disc. The glyph on it is LIGHT - the contrast rule.
class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({required this.playing, required this.onTap});

  final bool playing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: playing ? 'Pause' : 'Play',
      container: true,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 82,
          height: 82,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.primaryFill,
          ),
          alignment: Alignment.center,
          child: playing
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    for (var i = 0; i < 2; i++) ...<Widget>[
                      if (i > 0) const SizedBox(width: 7),
                      Container(
                        width: 6,
                        height: 27,
                        decoration: const BoxDecoration(
                          color: AppColors.onPrimaryFill,
                          borderRadius: BorderRadius.all(Radius.circular(2)),
                        ),
                      ),
                    ],
                  ],
                )
              : const Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: AppIcon(
                    AppGlyph.play,
                    size: 30,
                    color: AppColors.onPrimaryFill,
                  ),
                ),
        ),
      ),
    );
  }
}
