import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller/app_controller.dart';
import '../drivers/audio_player.dart';
import '../model/recording_info.dart';
import '../model/speaker_names.dart';
import '../model/transcript.dart';
import '../model/transcript_paragraphs.dart';
import 'note_audio_panel.dart';
import 'note_list.dart';
import 'theme.dart';
import 'widgets/app_icons.dart';
import 'widgets/common.dart';
import 'widgets/home_icons.dart';

/// One note: its transcript first, its audio one tap away.
///
/// `NoteDetail.dc.html` and `NoteAudio.dc.html`. Everything shown comes from
/// [AppController]: the transcript and its state, speaker names, the audio
/// retention setting, and - while the audio panel is open - the player's own
/// [PlaybackState]. The screen keeps only what is about the screen: whether
/// the panel is open, and whether the user scrolled recently.
class NoteView extends StatefulWidget {
  const NoteView({
    required this.controller,
    required this.recording,
    this.onBack,
    this.onDeleted,
    this.onSummarize,
    this.now,
    super.key,
  });

  final AppController controller;

  /// The note as it was when opened. The screen follows the library's newer
  /// copy of it (kept, audio removed) by path.
  final RecordingInfo recording;

  final VoidCallback? onBack;

  /// Called after the note was deleted; [onBack] when null.
  final VoidCallback? onDeleted;

  /// "Summarize with your AI". Null disables the button.
  final VoidCallback? onSummarize;

  /// "Today" and "Audio deletes in 18 h" are relative to this; the wall clock
  /// when null.
  final DateTime? now;

  /// How long after the user scrolls the transcript it is left alone, rather
  /// than following the playhead.
  static const Duration userScrollHold = Duration(seconds: 4);

  @override
  State<NoteView> createState() => _NoteViewState();
}

class _NoteViewState extends State<NoteView> {
  final ScrollController _scroll = ScrollController();
  List<GlobalKey> _paragraphKeys = <GlobalKey>[];

  bool _audioOpen = false;
  bool _busy = false;

  /// Running while the user's own scroll is recent.
  Timer? _userScrolled;

  /// The paragraph last scrolled to, so each one is scrolled to once.
  int? _followed;

  Transcript? _laidOutFrom;
  List<TranscriptParagraph> _paragraphs = const <TranscriptParagraph>[];

  AppController get _controller => widget.controller;

  /// The library's latest copy of this note - Keep and the retention sweep
  /// change it while the screen is open.
  RecordingInfo get _recording {
    final path = widget.recording.path;
    for (final recording in _controller.recordings) {
      if (recording.path == path) return recording;
    }
    return widget.recording;
  }

  DateTime get _now => widget.now ?? DateTime.now();

  bool get _canPlay => _controller.canPlay && _recording.hasAudio;

  bool get _isLoaded => _controller.nowPlaying?.path == widget.recording.path;

  PlaybackState get _playback => _controller.playbackState;

  Duration get _duration {
    final reported = _isLoaded ? _playback.duration : null;
    final duration = reported ?? _recording.duration ?? Duration.zero;
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

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
    final recording = widget.recording;
    // Both only READ: a stat and a small file each.
    unawaited(_controller.loadTranscript(recording));
    unawaited(_controller.loadSpeakerNames(recording.path));
    // Waiting in the background queue? Then it goes next.
    if (_controller.transcriptionAvailable) {
      _controller.prioritiseTranscription(recording);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _userScrolled?.cancel();
    _scroll.dispose();
    // Leaving the note ends the playback it started.
    if (_isLoaded) unawaited(_controller.stopPlayback());
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  // ---------------------------------------------------------------- audio

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toggleAudio() {
    if (_audioOpen) {
      setState(() => _audioOpen = false);
      if (_playing) unawaited(_controller.pausePlayback());
      return;
    }
    setState(() => _audioOpen = true);
    // Opening the audio means "play it".
    if (_canPlay && !_playing) {
      unawaited(_run(() => _controller.playRecording(_recording)));
    }
  }

  Future<void> _togglePlay() async {
    if (!_canPlay || _busy) return;
    await _run(() => _controller.togglePlayback(_recording));
  }

  void _seekTo(Duration position) {
    if (!_canPlay || !_isLoaded) return;
    final duration = _duration;
    var target = position;
    if (target < Duration.zero) target = Duration.zero;
    if (target > duration) target = duration;
    unawaited(_controller.seekPlayback(target));
  }

  /// Tapping a paragraph plays the note from there.
  Future<void> _playFrom(Duration start) async {
    if (!_canPlay) return;
    _followed = null;
    if (!_audioOpen) setState(() => _audioOpen = true);
    if (!_isLoaded) {
      await _run(() => _controller.playRecording(_recording));
      if (!mounted || !_isLoaded) return;
    } else if (!_playing) {
      unawaited(_controller.resumePlayback());
    }
    _seekTo(start);
  }

  // ------------------------------------------------------------ transcript

  List<TranscriptParagraph> _paragraphsOf(Transcript transcript) {
    if (!identical(transcript, _laidOutFrom)) {
      _laidOutFrom = transcript;
      _paragraphs = TranscriptLayout.paragraphs(transcript);
      _paragraphKeys = <GlobalKey>[
        for (var i = 0; i < _paragraphs.length; i++) GlobalKey(),
      ];
      _followed = null;
    }
    return _paragraphs;
  }

  /// The user scrolled: leave the transcript where they put it for a while.
  bool _onScroll(ScrollNotification notification) {
    final byUser = switch (notification) {
      ScrollStartNotification(:final dragDetails) => dragDetails != null,
      ScrollUpdateNotification(:final dragDetails) => dragDetails != null,
      _ => false,
    };
    if (byUser) {
      _userScrolled?.cancel();
      _userScrolled = Timer(NoteView.userScrollHold, () {
        _userScrolled = null;
      });
    }
    return false;
  }

  /// Brings the paragraph being heard into view - gently, once per
  /// paragraph, and never while the user's own scroll is recent.
  void _follow(int? active) {
    if (active == null || active == _followed || !_playing) return;
    _followed = active;
    if (_userScrolled != null) return;
    final key = active < _paragraphKeys.length ? _paragraphKeys[active] : null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = key?.currentContext;
      if (!mounted || context == null) return;
      unawaited(
        Scrollable.ensureVisible(
          context,
          alignment: 0.25,
          duration: AppMotion.isReduced(this.context)
              ? Duration.zero
              : const Duration(milliseconds: 400),
          curve: Curves.easeInOut,
        ),
      );
    });
  }

  void _transcribe() {
    final recording = _recording;
    if (!_controller.transcriptionAvailable || !recording.hasAudio) return;
    if (recording.path == _controller.writingNotePath) {
      _notice('This note is still being written.');
      return;
    }
    if (_controller.isTranscribing) {
      _notice('Another note is being transcribed. Try again in a moment.');
      return;
    }
    unawaited(_controller.transcribe(recording));
  }

  Future<void> _copy(Transcript transcript) async {
    final text = TranscriptLayout.plainText(
      transcript,
      _controller.speakerNamesFor(widget.recording.path),
    );
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) _notice('Copied');
  }

  Future<void> _rename(List<String> speakers) async {
    final path = widget.recording.path;
    final changes = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => _RenameSpeakersDialog(
        speakers: speakers,
        names: _controller.speakerNamesFor(path),
      ),
    );
    if (changes == null || !mounted) return;
    await _controller.renameSpeakers(path, changes);
  }

  Future<void> _delete() async {
    final recording = _recording;
    final confirmed = await confirmDeleteRecording(
      context,
      what: NoteLabels.title(recording),
      detail: NoteLabels.group(recording.recordedAt, now: _now),
    );
    if (!confirmed || !mounted) return;
    await _controller.deleteRecording(recording);
    if (!mounted) return;
    (widget.onDeleted ?? widget.onBack)?.call();
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

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final recording = _recording;
    final status = _controller.transcriptStatusFor(recording);
    final transcript = _controller.transcriptFor(recording);
    final spoken = transcript != null && transcript.hasSpeech;
    final showWords = spoken && status != TranscriptStatus.running;
    final speakers =
        spoken ? TranscriptLayout.speakers(transcript) : const <String>[];
    final names = _controller.speakerNamesFor(recording.path);
    final writing = recording.path == _controller.writingNotePath;
    final canTranscribeAgain = _controller.transcriptionAvailable &&
        recording.hasAudio &&
        !writing &&
        (status == TranscriptStatus.none ||
            status == TranscriptStatus.failed ||
            status == TranscriptStatus.unsupported ||
            status == TranscriptStatus.modelMissing);
    final viewPadding = MediaQuery.viewPaddingOf(context);

    final paragraphs = showWords
        ? _paragraphsOf(transcript)
        : const <TranscriptParagraph>[];
    final active = _isLoaded && paragraphs.isNotEmpty
        ? TranscriptLayout.paragraphAt(paragraphs, _position)
        : null;
    _follow(active);

    final audioRow = _audioRow(recording);

    return Scaffold(
      backgroundColor: AppColors.screen,
      body: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(top: viewPadding.top + 15),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppShape.gutter,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          _header(recording, canTranscribeAgain),
                          const SizedBox(height: 18),
                          Text(
                            NoteLabels.title(recording),
                            style: AppText.title24,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            NoteLabels.noteMeta(
                              recordedAt: recording.recordedAt,
                              now: _now,
                              speakerCount: speakers.length,
                              words: showWords
                                  ? TranscriptLayout.wordCount(transcript)
                                  : null,
                            ),
                            style: AppText.meta13,
                          ),
                          const SizedBox(height: 14),
                          if (speakers.length > 1)
                            _SpeakerChips(
                              speakers: speakers,
                              names: names,
                              onRename: () => unawaited(_rename(speakers)),
                            ),
                          ?audioRow,
                          if (audioRow != null || speakers.length > 1)
                            const SizedBox(height: 6),
                          Container(height: 1, color: AppColors.raised),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppShape.gutter - 12,
                        ),
                        child: paragraphs.isEmpty
                            ? _stateBody(recording, status, writing)
                            : _transcriptList(
                                paragraphs,
                                speakers,
                                names,
                                active,
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_audioOpen)
              _panel()
            else
              Padding(
                padding: EdgeInsets.fromLTRB(
                  AppShape.gutter,
                  12,
                  AppShape.gutter,
                  math.max(32, viewPadding.bottom),
                ),
                child: _bottomBar(recording, spoken ? transcript : null),
              ),
          ],
        ),
      ),
    );
  }

  Widget _header(RecordingInfo recording, bool canTranscribeAgain) {
    return Row(
      children: <Widget>[
        // The design pulls the back and menu glyphs 12px into the gutter, so
        // the glyphs - not their 44px hit areas - line up with the title.
        Transform.translate(
          offset: const Offset(-12, 0),
          child: TapTarget(
            onTap: widget.onBack,
            semanticLabel: 'Back',
            child: const AppIcon(
              AppGlyph.chevronLeft,
              size: 20,
              color: AppColors.textSecondary,
              strokeWidth: 1.7,
            ),
          ),
        ),
        Expanded(
          child: Transform.translate(
            offset: const Offset(-8, 0),
            child: Text(
              NoteLabels.group(recording.recordedAt, now: _now),
              style: AppText.meta13,
            ),
          ),
        ),
        Transform.translate(
          offset: const Offset(12, 0),
          child: PopupMenuButton<_NoteAction>(
            tooltip: '',
            color: AppColors.card,
            shape: const RoundedRectangleBorder(
              borderRadius: AppShape.control,
              side: BorderSide(color: AppColors.raised),
            ),
            onSelected: (action) {
              switch (action) {
                case _NoteAction.transcribe:
                  _transcribe();
                case _NoteAction.delete:
                  unawaited(_delete());
              }
            },
            itemBuilder: (context) => <PopupMenuEntry<_NoteAction>>[
              if (canTranscribeAgain)
                const PopupMenuItem<_NoteAction>(
                  value: _NoteAction.transcribe,
                  child: Text('Transcribe again', style: AppText.label13),
                ),
              PopupMenuItem<_NoteAction>(
                value: _NoteAction.delete,
                child: Text(
                  'Delete note',
                  style: AppText.label13.copyWith(color: AppColors.error),
                ),
              ),
            ],
            child: Semantics(
              button: true,
              label: 'More',
              excludeSemantics: true,
              child: const SizedBox.square(
                dimension: AppShape.minTapTarget,
                child: Center(
                  child: AppIcon(
                    AppGlyph.more,
                    size: 19,
                    color: AppColors.textSecondary,
                    strokeWidth: 1.7,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// "Audio deletes in 18 h · Keep", only while audio is being deleted - or
  /// "Audio deleted", once it has been.
  Widget? _audioRow(RecordingInfo recording) {
    final String text;
    Widget? action;
    if (!recording.hasAudio) {
      text = 'Audio deleted · transcript kept';
    } else if (!_controller.autoDeleteAudio) {
      return null;
    } else if (recording.keepAudio) {
      text = 'Audio kept';
      action = _Pill(
        label: "Don't keep",
        onTap: () =>
            unawaited(_controller.setKeepAudio(recording.path, false)),
      );
    } else {
      text = NoteLabels.audioDeletes(
        recordedAt: recording.recordedAt,
        now: _now,
      );
      action = _Pill(
        label: 'Keep',
        onTap: () => unawaited(_controller.setKeepAudio(recording.path, true)),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppShape.minTapTarget),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(text, style: AppText.meta12)),
          ?action,
        ],
      ),
    );
  }

  Widget _transcriptList(
    List<TranscriptParagraph> paragraphs,
    List<String> speakers,
    SpeakerNames names,
    int? active,
  ) {
    return Stack(
      children: <Widget>[
        NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: SingleChildScrollView(
            controller: _scroll,
            padding: const EdgeInsets.only(top: 7, bottom: 56),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (var i = 0; i < paragraphs.length; i++)
                  _ParagraphTile(
                    key: _paragraphKeys[i],
                    paragraph: paragraphs[i],
                    speakerLabel: paragraphs[i].speaker == null
                        ? null
                        : names.labelFor(paragraphs[i].speaker!, speakers),
                    speakerColor: paragraphs[i].speaker == null
                        ? null
                        : _speakerColor(
                            speakers.indexOf(paragraphs[i].speaker!),
                          ),
                    active: i == active,
                    playing: i == active && _playing,
                    onTap: _canPlay
                        ? () => unawaited(_playFrom(paragraphs[i].start))
                        : null,
                  ),
              ],
            ),
          ),
        ),
        // The fade into the bottom bar.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 64,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    AppColors.screen.withValues(alpha: 0),
                    AppColors.screen,
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Every transcript state that is not words, as the whole body: one short
  /// line, and the one thing to do about it when there is one.
  Widget _stateBody(
    RecordingInfo recording,
    TranscriptStatus status,
    bool writing,
  ) {
    final available = _controller.transcriptionAvailable;
    String? line;
    Color? color;
    double? progress;
    (String, VoidCallback)? action;

    if (writing) {
      line = 'This note is still being written.';
    } else {
      switch (status) {
        case TranscriptStatus.checking:
          line = null;
        case TranscriptStatus.running:
          final total = _controller.transcriptionTotal;
          progress = total == 0 ? 0.0 : _controller.transcriptionDone / total;
          line = 'Transcribing ${(progress * 100).round()}%';
        case TranscriptStatus.queued:
          line = 'Waiting to transcribe…';
        case TranscriptStatus.done || TranscriptStatus.noSpeech:
          line = 'No speech found.';
        case TranscriptStatus.none:
          if (!recording.hasAudio) {
            line = 'No transcript.';
          } else if (!available) {
            line = "Transcription isn't available on this phone.";
          } else {
            line = 'Not transcribed yet.';
            action = ('Transcribe', _transcribe);
          }
        case TranscriptStatus.modelMissing:
          line = "The Hindi speech model isn't on this phone.";
          color = AppColors.warning;
          action = ('Try again', _transcribe);
        case TranscriptStatus.unsupported:
          line = "This audio can't be transcribed.";
          color = AppColors.error;
        case TranscriptStatus.failed:
          line = "Couldn't transcribe this note.";
          color = AppColors.error;
          if (recording.hasAudio) action = ('Try again', _transcribe);
      }
    }
    if (line == null) return const SizedBox.shrink();

    return Center(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              line,
              textAlign: TextAlign.center,
              style: AppText.rowTitle.copyWith(
                color: color ?? AppColors.textSecondary,
              ),
            ),
            if (progress != null) ...<Widget>[
              const SizedBox(height: 14),
              SizedBox(
                width: 180,
                // Determinate from the first frame, so nothing animates on
                // its own.
                child: ClipRRect(
                  borderRadius: AppShape.pill,
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 3,
                    color: AppColors.purpleText,
                    backgroundColor: AppColors.raised,
                  ),
                ),
              ),
            ],
            if (action != null) ...<Widget>[
              const SizedBox(height: 10),
              _Pill(label: action.$1, onTap: action.$2, accent: true),
            ],
          ],
        ),
      ),
    );
  }

  Widget _bottomBar(RecordingInfo recording, Transcript? spoken) {
    return Row(
      children: <Widget>[
        Expanded(
          child: PrimaryButton(
            label: 'Summarize with your AI',
            glyph: AppGlyph.transcribe,
            onPressed: spoken == null ? null : widget.onSummarize,
          ),
        ),
        const SizedBox(width: 10),
        _SquareButton(
          semanticLabel: 'Copy transcript',
          onTap: spoken == null ? null : () => unawaited(_copy(spoken)),
          child: const HomeIcon(
            HomeGlyph.copy,
            size: 18,
            color: AppColors.textSecondary,
            strokeWidth: 1.6,
          ),
        ),
        if (_canPlay) ...<Widget>[
          const SizedBox(width: 10),
          _SquareButton(
            semanticLabel: 'Show audio',
            onTap: _toggleAudio,
            child: const AppIcon(
              AppGlyph.play,
              size: 16,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ],
    );
  }

  Widget _panel() {
    final enabled = _canPlay;
    final error = _controller.playbackError;
    final String? message;
    if (error != null) {
      message = "Couldn't play this audio.";
    } else if (_busy && !_isLoaded) {
      message = 'Loading…';
    } else {
      message = null;
    }
    return NoteAudioPanel(
      position: _position,
      duration: _duration,
      playing: _playing,
      speed: _controller.playbackSpeed,
      message: message,
      messageIsError: error != null,
      onClose: _toggleAudio,
      onToggle: enabled ? () => unawaited(_togglePlay()) : null,
      onSkip: enabled ? (delta) => _seekTo(_position + delta) : null,
      onSeek: enabled
          ? (fraction) => _seekTo(
                Duration(
                  milliseconds: (_duration.inMilliseconds * fraction).round(),
                ),
              )
          : null,
      onSpeed: (speed) => unawaited(_controller.setPlaybackSpeed(speed)),
    );
  }
}

enum _NoteAction { transcribe, delete }

/// Speaker colours, in the order speakers first talk. Text-safe colours on
/// the dark background - see the contrast rule in `theme.dart`.
const List<Color> _speakerColors = <Color>[
  AppColors.purpleText,
  AppColors.connected,
  AppColors.warning,
  AppColors.recording,
  AppColors.purple300,
];

Color _speakerColor(int index) =>
    _speakerColors[(index < 0 ? 0 : index) % _speakerColors.length];

class _SpeakerChips extends StatelessWidget {
  const _SpeakerChips({
    required this.speakers,
    required this.names,
    required this.onRename,
  });

  final List<String> speakers;
  final SpeakerNames names;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppShape.minTapTarget),
      child: Row(
        children: <Widget>[
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  for (var i = 0; i < speakers.length; i++) ...<Widget>[
                    if (i > 0) const SizedBox(width: 8),
                    _chip(i),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          TapTarget(
            onTap: onRename,
            semanticLabel: 'Rename speakers',
            child: Text(
              'Rename',
              style: AppText.label13.copyWith(color: AppColors.purpleText),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(int index) {
    final color = _speakerColor(index);
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.30)),
        borderRadius: AppShape.pill,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          StatusDot(color: color),
          const SizedBox(width: 7),
          Text(
            names.labelFor(speakers[index], speakers),
            style: AppText.label13.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

class _ParagraphTile extends StatelessWidget {
  const _ParagraphTile({
    required this.paragraph,
    required this.active,
    required this.playing,
    this.speakerLabel,
    this.speakerColor,
    this.onTap,
    super.key,
  });

  final TranscriptParagraph paragraph;
  final String? speakerLabel;
  final Color? speakerColor;
  final bool active;
  final bool playing;

  /// Plays from this paragraph; null when there is no audio to play.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final time = TranscriptLayout.timestamp(paragraph.start);
    final tile = Container(
      // The same padding lit or not, so the highlight moving never shifts
      // the text under the reader's eye.
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: active ? AppColors.raised : null,
        borderRadius: AppShape.control,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              if (speakerLabel != null) ...<Widget>[
                Text(
                  speakerLabel!,
                  style: AppText.meta12.copyWith(
                    fontWeight: FontWeight.w500,
                    color: speakerColor,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  time,
                  style: AppText.batteryValue,
                ),
              ),
              if (playing)
                Text(
                  'Playing',
                  style: AppText.footnote11.copyWith(
                    fontWeight: FontWeight.w400,
                    color: AppColors.purpleText,
                    height: 1.2,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            paragraph.text,
            style: AppText.rowTitle.copyWith(height: 1.6),
          ),
        ],
      ),
    );
    if (onTap == null) return tile;
    return Semantics(
      button: true,
      hint: 'Play from $time',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: tile,
      ),
    );
  }
}

/// A 30px outlined pill with a 44px hit area - "Keep", "Try again".
class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.onTap, this.accent = false});

  final String label;
  final VoidCallback onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return TapTarget(
      onTap: onTap,
      semanticLabel: label,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: accent ? AppColors.purpleChipFill : null,
          border: Border.all(
            color: accent ? AppColors.purpleChipBorder : AppColors.border,
          ),
          borderRadius: AppShape.pill,
        ),
        child: Text(
          label,
          style: AppText.label13.copyWith(
            color: accent ? AppColors.purpleText : null,
          ),
        ),
      ),
    );
  }
}

/// The 46px outlined square buttons beside Summarize.
class _SquareButton extends StatelessWidget {
  const _SquareButton({
    required this.semanticLabel,
    required this.onTap,
    required this.child,
  });

  final String semanticLabel;
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TapTarget(
      onTap: onTap,
      semanticLabel: semanticLabel,
      child: Opacity(
        opacity: onTap == null ? 0.45 : 1,
        child: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border),
            borderRadius: AppShape.control,
          ),
          alignment: Alignment.center,
          child: child,
        ),
      ),
    );
  }
}

/// Names for a note's speakers. Returns label -> name for every speaker (a
/// blank name clears it), or null when cancelled.
class _RenameSpeakersDialog extends StatefulWidget {
  const _RenameSpeakersDialog({required this.speakers, required this.names});

  final List<String> speakers;
  final SpeakerNames names;

  @override
  State<_RenameSpeakersDialog> createState() => _RenameSpeakersDialogState();
}

class _RenameSpeakersDialogState extends State<_RenameSpeakersDialog> {
  late final List<TextEditingController> _fields = <TextEditingController>[
    for (final speaker in widget.speakers)
      TextEditingController(text: widget.names.customName(speaker) ?? ''),
  ];

  @override
  void dispose() {
    for (final field in _fields) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(borderRadius: AppShape.card),
      title: const Text('Rename speakers', style: AppText.title22),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (var i = 0; i < widget.speakers.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextField(
                  controller: _fields[i],
                  cursorColor: AppColors.purpleText,
                  textCapitalization: TextCapitalization.words,
                  style: AppText.meta14.copyWith(color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'Speaker ${i + 1}',
                    hintStyle: AppText.meta14,
                    prefixIcon: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: StatusDot(color: _speakerColor(i)),
                    ),
                    prefixIconConstraints:
                        const BoxConstraints(minWidth: 30, minHeight: 6),
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel', style: AppText.label13),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(<String, String>{
            for (var i = 0; i < widget.speakers.length; i++)
              widget.speakers[i]: _fields[i].text,
          }),
          child: Text(
            'Save',
            style: AppText.label13.copyWith(color: AppColors.purpleText),
          ),
        ),
      ],
    );
  }
}
