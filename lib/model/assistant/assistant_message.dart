/// The one email this app ever sends, as plain data.
///
/// PURE: no sockets, no clock of its own. [AssistantMessage.forInstruction]
/// is the only thing that decides what goes on the wire, which is what makes
/// "the instruction text and nothing else leaves the phone" a claim a test can
/// check rather than a promise in a document.
library;

/// One outbound email: who it is for, who it is from, and the two strings a
/// reader sees.
class AssistantMessage {
  const AssistantMessage({
    required this.from,
    required this.to,
    required this.subject,
    required this.body,
  });

  /// Builds the message for one spoken instruction.
  ///
  /// [instruction] is the transcript with the wake phrase already stripped. It
  /// is the WHOLE body: no signature, no note id, no device name, no other
  /// note, no audio. The assistant reads the body as if it had been typed.
  ///
  /// The subject is the note's time. The assistant answers on the body, so the
  /// subject is only there for the user scrolling their own Sent folder - and
  /// a time is what they will be looking for. It deliberately does not repeat
  /// the instruction: a subject line is the part of an email most likely to be
  /// shown on a lock screen.
  factory AssistantMessage.forInstruction({
    required String instruction,
    required DateTime spokenAt,
    required String from,
    required String to,
  }) =>
      AssistantMessage(
        from: from,
        to: to,
        subject: subjectFor(spokenAt),
        body: instruction.trim(),
      );

  final String from;
  final String to;
  final String subject;

  /// Plain text. No attachments in v1, and no HTML: the assistant reads text,
  /// and an HTML part would only be another place for something to leak into.
  final String body;

  /// "Voice note - 18 Sep 2026, 14:32".
  ///
  /// 24-hour and day-month-year, matching what the rest of the app shows, and
  /// built here rather than with `intl` so it does not depend on which locale
  /// the phone happens to be in when a note is queued.
  static String subjectFor(DateTime at) {
    final local = at.toLocal();
    final day = local.day.toString();
    final month = _months[local.month - 1];
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return 'Voice note - $day $month ${local.year}, $hour:$minute';
  }

  static const List<String> _months = <String>[
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  @override
  bool operator ==(Object other) =>
      other is AssistantMessage &&
      other.from == from &&
      other.to == to &&
      other.subject == subject &&
      other.body == body;

  @override
  int get hashCode => Object.hash(from, to, subject, body);

  /// Never prints [body]: what the user said is not log material.
  @override
  String toString() => 'AssistantMessage(to: $to, subject: $subject, '
      '${body.length} chars)';
}
