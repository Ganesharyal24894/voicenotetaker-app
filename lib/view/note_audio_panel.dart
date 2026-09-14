import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'format.dart';
import 'theme.dart';
import 'widgets/app_icons.dart';
import 'widgets/common.dart';
import 'widgets/transport.dart';
import 'widgets/waveform.dart';

/// The note's audio, on demand: a panel at the bottom of the note screen.
///
/// Stateless on purpose. Every value comes from the note screen, which reads
/// it from `AppController`'s playback state - so the panel cannot show a
/// playhead moving while nothing is playing.
class NoteAudioPanel extends StatelessWidget {
  const NoteAudioPanel({
    required this.position,
    required this.duration,
    required this.playing,
    required this.speed,
    required this.onClose,
    this.message,
    this.messageIsError = false,
    this.onSeek,
    this.onSkip,
    this.onToggle,
    this.onSpeed,
    super.key,
  });

  /// Compact waveform band.
  static const double waveHeight = 60;

  final Duration position;
  final Duration duration;
  final bool playing;
  final double speed;

  /// One short line when something needs saying - loading, or a problem.
  final String? message;
  final bool messageIsError;

  /// Null disables that control.
  final ValueChanged<double>? onSeek;
  final ValueChanged<Duration>? onSkip;
  final VoidCallback? onToggle;
  final ValueChanged<double>? onSpeed;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final bottom = math.max(30.0, MediaQuery.viewPaddingOf(context).bottom);
    final progress = duration.inMilliseconds == 0
        ? 0.0
        : position.inMilliseconds / duration.inMilliseconds;
    final remaining = duration - position;

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.card,
        border: Border(top: BorderSide(color: AppColors.raised)),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      padding: EdgeInsets.fromLTRB(AppShape.gutter, 4, AppShape.gutter, bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const SectionCaption('Audio'),
              const Spacer(),
              if (onSpeed != null)
                SpeedChip(speed: speed, onChanged: onSpeed!),
              Transform.translate(
                offset: const Offset(12, 0),
                child: TapTarget(
                  onTap: onClose,
                  semanticLabel: 'Hide audio',
                  child: Transform.rotate(
                    angle: math.pi / 2,
                    child: const AppIcon(
                      AppGlyph.chevronRight,
                      size: 20,
                      color: AppColors.textSecondary,
                      strokeWidth: 1.7,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                message!,
                style: AppText.meta13.copyWith(
                  color: messageIsError ? AppColors.error : null,
                ),
              ),
            ),
          ScrubWaveform(
            progress: progress,
            height: waveHeight,
            onSeek: onSeek,
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Text(Fmt.timer(position), style: AppText.scrubTime),
              const Spacer(),
              Text(
                '−${Fmt.timer(remaining)}',
                style:
                    AppText.scrubTime.copyWith(color: AppColors.textTertiary),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              SkipButton(
                glyph: AppGlyph.skipBack,
                label: '15s',
                semanticLabel: 'Skip back 15 seconds',
                onTap: onSkip == null
                    ? null
                    : () => onSkip!(const Duration(seconds: -15)),
              ),
              const SizedBox(width: 34),
              PlayPauseButton(playing: playing, onTap: onToggle),
              const SizedBox(width: 34),
              SkipButton(
                glyph: AppGlyph.skipForward,
                label: '30s',
                semanticLabel: 'Skip forward 30 seconds',
                onTap: onSkip == null
                    ? null
                    : () => onSkip!(const Duration(seconds: 30)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
