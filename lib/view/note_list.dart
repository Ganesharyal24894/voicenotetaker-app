import '../model/note_search.dart';
import '../model/recording_info.dart';
import '../model/transcript.dart';
import '../model/transcript_paragraphs.dart';
import 'format.dart';

/// Wording shared by the note screen and the notes list.
///
/// Presentation only - these turn model values into the exact strings the
/// designs show - so they live in `view/`, next to [Fmt].
abstract final class NoteLabels {
  /// `12 min`. Never `0 min`: a note that exists lasted at least a moment.
  static String minutes(Duration length) {
    final minutes = (length.inSeconds / 60).round();
    return '${minutes < 1 ? 1 : minutes} min';
  }

  /// `09:14 · 12 min` - a note's title.
  static String title(RecordingInfo recording) =>
      '${Fmt.timeOfDay(recording.recordedAt)} · '
      '${minutes(recording.duration ?? Duration.zero)}';

  /// `1,450`.
  static String count(int value) {
    final digits = value.abs().toString();
    final buffer = StringBuffer(value < 0 ? '-' : '');
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }

  /// `2 speakers`, or null for fewer than two - one voice is not worth a word.
  static String? speakers(int count) =>
      count > 1 ? '$count speakers' : null;

  /// `Today · 2 speakers · 1,450 words`, leaving out whatever is not known.
  static String noteMeta({
    required DateTime recordedAt,
    required DateTime now,
    int speakerCount = 0,
    int? words,
  }) =>
      <String>[
        Fmt.day(recordedAt, now: now),
        ?speakers(speakerCount),
        if (words != null && words > 0)
          '${count(words)} ${words == 1 ? 'word' : 'words'}',
      ].join(' · ');

  /// `Audio deletes in 18 h`. Counted from when the note started, which is
  /// what the retention sweep counts from.
  static String audioDeletes({
    required DateTime recordedAt,
    required DateTime now,
    Duration maxAge = const Duration(hours: 24),
  }) {
    final left = recordedAt.add(maxAge).difference(now);
    if (left <= Duration.zero) return 'Audio deletes soon';
    if (left < const Duration(hours: 1)) {
      final minutes = (left.inSeconds / 60).ceil();
      return 'Audio deletes in $minutes min';
    }
    return 'Audio deletes in ${left.inHours} h';
  }

  /// A list section: `Today`, `Yesterday`, `Monday` within the week, then
  /// `12 Mar` - with the year once it is not this one.
  static String group(DateTime at, {required DateTime now}) {
    final day = Fmt.day(at, now: now);
    final today = DateTime(now.year, now.month, now.day);
    final then = DateTime(at.year, at.month, at.day);
    final days = today.difference(then).inDays;
    if (days > 1 && days < 7) return _weekdays[then.weekday - 1];
    if (days >= 7 && then.year != today.year) return '$day ${then.year}';
    return day;
  }

  static const List<String> _weekdays = <String>[
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
}

/// A small label after a row's meta line.
enum NoteBadgeKind {
  /// Purple: the user did something to this note.
  accent,

  /// Quiet outline.
  plain,
}

/// One row of the notes list: what it says, and what search looks through.
class NoteListItem {
  const NoteListItem({
    required this.recording,
    required this.title,
    required this.meta,
    this.titleIsState = false,
    this.badge,
    this.badgeKind = NoteBadgeKind.plain,
    this.transcriptText = '',
  });

  /// Projects one saved note.
  ///
  /// [status] is null in a build without speech-to-text. [progress] is the
  /// running job's fraction, used only when this note is the one running.
  /// [quoteAs] is how a quoted transcript is turned into a row's title.
  /// `AssistantController.titleFor` is passed here, so a note that begins
  /// "Instinct," is listed by what was asked for rather than by who was being
  /// addressed. THE TRANSCRIPT ITSELF IS NOT TOUCHED - [transcriptText] below
  /// still holds every word, and so does the file on disk.
  factory NoteListItem.from(
    RecordingInfo recording, {
    required TranscriptStatus? status,
    Transcript? transcript,
    bool isWriting = false,
    double progress = 0,
    bool autoDeleteAudio = false,
    String Function(String)? quoteAs,
  }) {
    final time = Fmt.timeOfDay(recording.recordedAt);
    final spoken = transcript != null && transcript.hasSpeech;
    final speakerCount =
        spoken ? TranscriptLayout.speakers(transcript).length : 0;

    if (isWriting) {
      return NoteListItem(
        recording: recording,
        title: 'New note',
        titleIsState: true,
        meta: '$time · Writing…',
      );
    }

    final String title;
    var isState = true;
    switch (status) {
      case TranscriptStatus.done when spoken:
        final paragraphs = TranscriptLayout.paragraphs(transcript);
        final quoted =
            paragraphs.isEmpty ? transcript.text : paragraphs.first.text;
        title = quoteAs == null ? quoted : quoteAs(quoted);
        isState = false;
      case TranscriptStatus.done:
        // Listed as transcribed, not read yet.
        title = 'Loading…';
      case TranscriptStatus.noSpeech:
        title = 'No speech found';
      case TranscriptStatus.failed || TranscriptStatus.unsupported:
        title = "Couldn't transcribe";
      case TranscriptStatus.running ||
            TranscriptStatus.queued ||
            TranscriptStatus.none ||
            TranscriptStatus.checking ||
            TranscriptStatus.modelMissing:
        title = recording.hasAudio
            ? 'Waiting for transcript'
            : 'No transcript';
      case null:
        title = 'No transcript';
    }

    final String? badge;
    var kind = NoteBadgeKind.plain;
    if (status == TranscriptStatus.running) {
      badge = 'Transcribing ${(progress.clamp(0.0, 1.0) * 100).round()}%';
    } else if (!recording.hasAudio) {
      badge = 'Audio deleted';
    } else if (autoDeleteAudio && recording.keepAudio) {
      // "Kept" only means something while audio is being deleted.
      badge = 'Audio kept';
      kind = NoteBadgeKind.accent;
    } else {
      badge = null;
    }

    return NoteListItem(
      recording: recording,
      title: title,
      titleIsState: isState,
      meta: <String>[
        time,
        NoteLabels.minutes(recording.duration ?? Duration.zero),
        ?NoteLabels.speakers(speakerCount),
      ].join(' · '),
      badge: badge,
      badgeKind: kind,
      transcriptText: spoken ? transcript.text : '',
    );
  }

  final RecordingInfo recording;
  final String title;

  /// True when [title] describes the note's state rather than quoting it.
  final bool titleIsState;

  final String meta;
  final String? badge;
  final NoteBadgeKind badgeKind;

  /// Everything that was said, for search.
  final String transcriptText;

  /// `09:14`.
  String get timeLabel => Fmt.timeOfDay(recording.recordedAt);

  /// Whether search [query] finds this note: in what was said, or its time.
  bool matches(String query) =>
      NoteSearch.matches(query, <String>[transcriptText, timeLabel]);
}

/// A titled run of rows.
class NoteGroup {
  const NoteGroup(this.label, this.items);

  final String label;
  final List<NoteListItem> items;
}

abstract final class NoteList {
  /// [items] that match [query], newest first.
  static List<NoteListItem> filter(List<NoteListItem> items, String query) {
    final sorted = <NoteListItem>[...items]
      ..sort((a, b) => b.recording.recordedAt.compareTo(a.recording.recordedAt));
    return <NoteListItem>[
      for (final item in sorted)
        if (item.matches(query)) item,
    ];
  }

  /// [items], in the order given, under their day headings.
  static List<NoteGroup> group(List<NoteListItem> items, {required DateTime now}) {
    final groups = <NoteGroup>[];
    for (final item in items) {
      final label = NoteLabels.group(item.recording.recordedAt, now: now);
      if (groups.isEmpty || groups.last.label != label) {
        groups.add(NoteGroup(label, <NoteListItem>[item]));
      } else {
        groups.last.items.add(item);
      }
    }
    return groups;
  }
}
