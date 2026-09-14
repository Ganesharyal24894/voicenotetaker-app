import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller/app_controller.dart';
import '../drivers/audio_player.dart';
import '../model/recording_info.dart';
import '../model/transcript.dart';
import 'format.dart';
import 'recording_entry.dart';
import 'theme.dart';
import 'widgets/app_icons.dart';
import 'widgets/common.dart';
import 'widgets/waveform.dart';

/// Screen 5 - playback.
///
/// The transport is REAL: every value on this screen comes from
/// [AppController.playbackState], which is the driver's own
/// [PlaybackState] stream, and every control calls the controller. The screen
/// keeps no position or playing flag of its own, so it cannot show a playhead
/// moving while nothing is being played.
///
/// [recording] is the file [entry] describes. It is null for a row that has no
/// file behind it - a placeholder - and the transport is then visibly disabled
/// rather than silently dead. The same is true when the app was built without
/// a playback driver at all ([AppController.canPlay] false).
///
/// SCRUBBER ENVELOPE: still the fixed one in [ScrubWaveform]; nothing under
/// `view/` extracts amplitudes from a file yet. The PLAYHEAD and the seeking,
/// which are what this screen is about, are real.
class PlaybackView extends StatefulWidget {
  const PlaybackView({
    required this.controller,
    required this.entry,
    this.recording,
    this.onDeleted,
    this.onBack,
    super.key,
  });

  final AppController controller;
  final RecordingEntry entry;

  /// The saved file behind [entry], as the library service described it.
  ///
  /// Null when this entry has no file - the placeholder rows - in which case
  /// nothing can be loaded and the transport is disabled.
  final RecordingInfo? recording;

  /// Called after this recording has been deleted, so the caller can leave a
  /// screen that no longer has a file behind it.
  ///
  /// Null - or a [recording] of null - takes the delete action away entirely.
  final VoidCallback? onDeleted;

  final VoidCallback? onBack;

  @override
  State<PlaybackView> createState() => _PlaybackViewState();
}

class _PlaybackViewState extends State<PlaybackView> {
  /// Cycle order for the speed chip. The rate itself lives on the
  /// controller; this is only the order the chip walks through.
  static const List<double> _speeds = <double>[1.0, 1.5, 2.0, 0.5];

  /// True while a controller call is in flight, so the screen can say
  /// "Loading" instead of drawing a stopped transport over a file that is
  /// still opening.
  bool _busy = false;

  AppController get _controller => widget.controller;

  RecordingInfo? get _recording => widget.recording;

  /// Whether this screen can drive playback at all: there has to be a file,
  /// and the app has to have been built with a player.
  bool get _enabled => _recording != null && _controller.canPlay;

  PlaybackState get _playback => _controller.playbackState;

  /// Whether the loaded file is the one this screen is showing. The controller
  /// has exactly one player, so the state it publishes only describes this
  /// recording while this recording is the one that was opened.
  bool get _isLoaded =>
      _recording != null &&
      _controller.nowPlaying?.path == _recording!.path;

  bool get _loading => _busy && !_isLoaded;

  /// The player's duration once the file has been parsed, and the length the
  /// library read out of the WAV header until then.
  Duration get _duration {
    final reported = _isLoaded ? _playback.duration : null;
    final duration = reported ?? widget.entry.duration;
    return duration < Duration.zero ? Duration.zero : duration;
  }

  Duration get _position {
    if (!_isLoaded) return Duration.zero;
    final position = _playback.position;
    if (position < Duration.zero) return Duration.zero;
    final duration = _duration;
    return position > duration ? duration : position;
  }

  bool get _playing => _isLoaded && _playback.isPlaying;

  double get _progress => _duration.inMilliseconds == 0
      ? 0
      : _position.inMilliseconds / _duration.inMilliseconds;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
    final recording = _recording;
    if (recording != null && _controller.canPlay) {
      // Set directly rather than through setState: this runs inside the
      // element's own build.
      _busy = true;
      unawaited(_start(recording));
    }
    // Only LOOKS for a saved transcript - a stat and a small read. Nothing is
    // transcribed until the user asks.
    if (recording != null && _controller.transcriptionAvailable) {
      unawaited(_controller.loadTranscript(recording));
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    // Leaving the screen ends the playback it started. `stopPlayback` only
    // notifies after an await, so this cannot rebuild anything during the
    // teardown frame.
    if (_enabled) unawaited(_controller.stopPlayback());
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  /// Opening a recording loads it and starts it.
  Future<void> _start(RecordingInfo recording) =>
      _run(() => _controller.playRecording(recording));

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggle() async {
    final recording = _recording;
    if (recording == null || !_controller.canPlay || _busy) return;
    setState(() => _busy = true);
    await _run(() => _controller.togglePlayback(recording));
  }

  /// Seeks to [position], clamped into the recording.
  void _seekTo(Duration position) {
    if (!_enabled) return;
    final duration = _duration;
    var target = position;
    if (target < Duration.zero) target = Duration.zero;
    if (target > duration) target = duration;
    unawaited(_controller.seekPlayback(target));
  }

  /// Deletes the recording this screen is showing, after confirming.
  ///
  /// [AppController.deleteRecording] stops playback before unlinking the file
  /// - deleting one out from under an open player is a platform crash - and
  /// this screen then has nothing left to show, so it leaves.
  Future<void> _delete() async {
    final recording = _recording;
    if (recording == null) return;
    final confirmed = await confirmDeleteRecording(
      context,
      what: widget.entry.title,
      detail: '${widget.entry.dayLabel()}, ${widget.entry.durationLabel}',
    );
    if (!confirmed || !mounted) return;
    await _controller.deleteRecording(recording);
    if (!mounted) return;
    (widget.onDeleted ?? widget.onBack)?.call();
  }

  /// What the transcript area shows, or null when there is nothing to show
  /// it for: no file, or a build without speech-to-text.
  TranscriptStatus? get _transcriptStatus {
    final recording = _recording;
    if (recording == null || !_controller.transcriptionAvailable) return null;
    return _controller.transcriptStatusFor(recording);
  }

  void _transcribe() {
    final recording = _recording;
    if (recording == null || !_controller.transcriptionAvailable) {
      _notice('Transcription is not available yet.');
      return;
    }
    if (_controller.isTranscribing) {
      _notice('Another recording is being transcribed.');
      return;
    }
    unawaited(_controller.transcribe(recording));
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) _notice('Copied.');
  }

  void _notice(String what) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          backgroundColor: AppColors.raised,
          content: Text(what, style: AppText.body13),
        ),
      );
  }

  /// The one line the design does not have: what is wrong, when something is.
  ///
  /// Null in the ordinary case, so the approved layout is untouched whenever
  /// there is nothing to say.
  Widget? _statusLine() {
    final error = _controller.playbackError;
    final String message;
    if (error != null) {
      message = 'Could not play this recording: $error';
    } else if (_loading) {
      message = 'Loading…';
    } else if (!_controller.canPlay) {
      message = 'Playback is unavailable on this build.';
    } else if (_recording == null) {
      message = 'This recording has no file to play.';
    } else {
      return null;
    }

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        message,
        style: AppText.meta13.copyWith(
          color: error != null ? AppColors.error : AppColors.textTertiary,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final position = _position;
    final remaining = _duration - position;
    final enabled = _enabled;
    final status = _statusLine();
    final transcriptStatus = _transcriptStatus;
    final recording = _recording;
    // The chip offers a transcript only where there is none yet; once one is
    // running or saved, the card is where it lives.
    final offerTranscribe = transcriptStatus == null ||
        transcriptStatus == TranscriptStatus.none;
    final showCard = recording != null &&
        transcriptStatus != null &&
        transcriptStatus != TranscriptStatus.none &&
        transcriptStatus != TranscriptStatus.checking;

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
              if (_recording == null)
                // Nothing to act on: a row with no file behind it cannot be
                // deleted, so the control says so rather than looking live.
                TapTarget(
                  onTap: () => _notice('No actions here yet.'),
                  semanticLabel: 'More',
                  child: const AppIcon(
                    AppGlyph.more,
                    size: 19,
                    color: AppColors.textSecondary,
                    strokeWidth: 1.7,
                  ),
                )
              else
                TapTarget(
                  onTap: () => unawaited(_delete()),
                  semanticLabel: 'Delete recording',
                  child: const AppIcon(
                    AppGlyph.trash,
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
          ?status,
          Expanded(
            // The transcript card and the transport share the space under the
            // title. The card is capped at half of it and scrolls inside
            // itself; the transport takes everything else, so the speed row
            // stays at the bottom however short the transcript is.
            child: LayoutBuilder(
              builder: (context, box) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (showCard) ...<Widget>[
                    const SizedBox(height: 22),
                    ConstrainedBox(
                      constraints:
                          BoxConstraints(maxHeight: box.maxHeight / 2),
                      child: _TranscriptCard(
                        status: transcriptStatus,
                        transcript: _controller.transcriptFor(recording),
                        done: _controller.transcriptionDone,
                        total: _controller.transcriptionTotal,
                        onCancel: () =>
                            unawaited(_controller.cancelTranscription()),
                        onRetry: _transcribe,
                        onCopy: (text) => unawaited(_copy(text)),
                      ),
                    ),
                  ],
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          ScrubWaveform(
                            progress: _progress,
                            onSeek: enabled
                                ? (fraction) => _seekTo(
                                      Duration(
                                        milliseconds:
                                            (_duration.inMilliseconds * fraction).round(),
                                      ),
                                    )
                                : null,
                          ),
                          const SizedBox(height: 14),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: <Widget>[
                              Text(Fmt.timer(position), style: AppText.scrubTime),
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
                                onTap: enabled
                                    ? () => _seekTo(
                                          _position - const Duration(seconds: 15),
                                        )
                                    : null,
                              ),
                              const SizedBox(width: 34),
                              _PlayPauseButton(
                                playing: _playing,
                                onTap: enabled ? _toggle : null,
                              ),
                              const SizedBox(width: 34),
                              _SkipButton(
                                glyph: AppGlyph.skipForward,
                                label: '30s',
                                semanticLabel: 'Skip forward 30 seconds',
                                onTap: enabled
                                    ? () => _seekTo(
                                          _position + const Duration(seconds: 30),
                                        )
                                    : null,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          Row(
            children: <Widget>[
              TapTarget(
                semanticLabel: 'Playback speed',
                onTap: () {
                  final current = _speeds.indexOf(widget.controller.playbackSpeed);
                  final next = _speeds[(current + 1) % _speeds.length];
                  unawaited(widget.controller.setPlaybackSpeed(next));
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.border),
                    borderRadius: AppShape.pill,
                  ),
                  child: Text(
                    '${widget.controller.playbackSpeed.toStringAsFixed(1)}×',
                    style: AppText.label13,
                  ),
                ),
              ),
              const Spacer(),
              if (offerTranscribe)
                TapTarget(
                  semanticLabel: 'Transcribe',
                  onTap: _transcribe,
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

/// The disabled transport's opacity - the same value [PrimaryButton] uses, so
/// "you cannot press this" looks the same everywhere in the app.
const double _disabledOpacity = 0.45;

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

  /// Null disables the control.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return TapTarget(
      onTap: onTap,
      semanticLabel: semanticLabel,
      child: Opacity(
        opacity: onTap == null ? _disabledOpacity : 1,
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
      ),
    );
  }
}

/// 82px purple disc. The glyph on it is LIGHT - the contrast rule.
class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({required this.playing, required this.onTap});

  final bool playing;

  /// Null disables the button.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: playing ? 'Pause' : 'Play',
      container: true,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Opacity(
          opacity: enabled ? 1 : _disabledOpacity,
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
      ),
    );
  }
}

/// The recording's Hindi transcript: being made, made, or why it could not be.
///
/// One card for every state, so the words, the progress and the problems all
/// appear in the same place. Problems use the playback screen's own status
/// colours: [AppColors.warning] for something that can be fixed on the phone,
/// [AppColors.error] for something that failed.
class _TranscriptCard extends StatelessWidget {
  const _TranscriptCard({
    required this.status,
    required this.transcript,
    required this.done,
    required this.total,
    required this.onCancel,
    required this.onRetry,
    required this.onCopy,
  });

  final TranscriptStatus status;
  final Transcript? transcript;
  final int done;
  final int total;
  final VoidCallback onCancel;
  final VoidCallback onRetry;
  final ValueChanged<String> onCopy;

  static const String caption = 'Hindi transcript';

  @override
  Widget build(BuildContext context) {
    final text = transcript?.text ?? '';
    final (String label, VoidCallback onTap)? action = switch (status) {
      TranscriptStatus.running => ('Cancel', onCancel),
      TranscriptStatus.done => ('Copy', () => onCopy(text)),
      TranscriptStatus.failed ||
      TranscriptStatus.modelMissing => ('Try again', onRetry),
      _ => null,
    };
    final body = Padding(
      padding: const EdgeInsets.only(right: 8),
      child: _body(text),
    );

    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Expanded(child: SectionCaption(caption)),
              if (action != null)
                TapTarget(
                  onTap: action.$2,
                  semanticLabel: action.$1,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      action.$1,
                      style: AppText.label13.copyWith(
                        color: AppColors.purpleText,
                      ),
                    ),
                  ),
                )
              else
                const SizedBox(height: AppShape.minTapTarget),
            ],
          ),
          if (status == TranscriptStatus.done) Flexible(child: body) else body,
        ],
      ),
    );
  }

  Widget _body(String text) {
    switch (status) {
      case TranscriptStatus.running:
        final fraction = total == 0 ? 0.0 : done / total;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Expanded(
                  child: Text('Transcribing…', style: AppText.meta13),
                ),
                Text('${(fraction * 100).round()}%', style: AppText.scrubTime),
              ],
            ),
            const SizedBox(height: 10),
            // Determinate from the first frame - 0% until the model is loaded
            // - so nothing animates on its own.
            ClipRRect(
              borderRadius: AppShape.pill,
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 3,
                color: AppColors.purpleText,
                backgroundColor: AppColors.raised,
              ),
            ),
          ],
        );
      case TranscriptStatus.done:
        return SingleChildScrollView(
          child: SelectableText(
            text,
            style: AppText.rowTitle.copyWith(height: 1.6),
          ),
        );
      case TranscriptStatus.noSpeech:
        return const Text('No speech found.', style: AppText.meta13);
      case TranscriptStatus.modelMissing:
        return Text(
          'The Hindi model is not on this phone.',
          style: AppText.meta13.copyWith(color: AppColors.warning),
        );
      case TranscriptStatus.unsupported:
        return Text(
          'This recording cannot be transcribed.',
          style: AppText.meta13.copyWith(color: AppColors.error),
        );
      case TranscriptStatus.failed:
        return Text(
          'Could not transcribe this recording.',
          style: AppText.meta13.copyWith(color: AppColors.error),
        );
      case TranscriptStatus.checking:
      case TranscriptStatus.none:
        return const SizedBox.shrink();
    }
  }
}
