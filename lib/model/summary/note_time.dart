/// A note time as an AI reply quotes it: `09:14`, `Mon 09:14`, `14 Sep 09:14`.
///
/// PURE. It is only a reference - which recording it points at is decided by
/// `NoteTimeMatcher` against the summary's window.
library;

class NoteTime {
  const NoteTime({
    required this.hour,
    required this.minute,
    this.weekday,
    this.day,
    this.month,
  });

  final int hour;
  final int minute;

  /// 1 (Monday) to 7 (Sunday), when the reply named a weekday.
  final int? weekday;

  /// Day of the month and month (1-12), when the reply named a date.
  final int? day;
  final int? month;

  static const List<String> weekdayNames = <String>[
    'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun', //
  ];

  static const List<String> monthNames = <String>[
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String _two(int value) => value.toString().padLeft(2, '0');

  /// `09:14` - what the chip shows.
  String get clock => '${_two(hour)}:${_two(minute)}';

  /// `09:14`, `Mon 09:14` or `14 Sep 09:14` - the saved form, and what
  /// [tryParse] reads back.
  String get label {
    if (day != null && month != null) {
      return '$day ${monthNames[month! - 1]} $clock';
    }
    if (weekday != null) return '${weekdayNames[weekday! - 1]} $clock';
    return clock;
  }

  static final RegExp _pattern = RegExp(
    r'^\s*(?:(mon|tue|wed|thu|fri|sat|sun)[a-z]*\.?,?\s+)?'
    r'(?:(\d{1,2})(?:st|nd|rd|th)?\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?,?\s+)?'
    r'(?:at\s+)?(\d{1,2})[:.](\d{2})\s*(am|pm|a\.m\.|p\.m\.)?\s*$',
    caseSensitive: false,
  );

  /// The note time [text] is, or null. The WHOLE text must be a time: this is
  /// used to decide whether a reply's field is a time at all.
  static NoteTime? tryParse(String text) {
    var cleaned = text.trim();
    // `[09:14]`, `(09:14)`, `09:14.` and a leading "note time" are all how
    // AI apps quote it.
    cleaned = cleaned.replaceAll(RegExp(r'^[\[(]+|[\])]+$'), '').trim();
    cleaned = cleaned.replaceFirst(
      RegExp(r'^(note\s*time|time|at|@)\s*[:\-]?\s*', caseSensitive: false),
      '',
    );
    cleaned = cleaned.replaceFirst(RegExp(r'[.,;]$'), '');
    final match = _pattern.firstMatch(cleaned);
    if (match == null) return null;
    var hour = int.parse(match.group(4)!);
    final minute = int.parse(match.group(5)!);
    final meridiem = match.group(6)?.toLowerCase().replaceAll('.', '');
    // A dot separator is only a time with a meridiem or two-digit hours:
    // "3.50" on its own is more likely a price.
    if (cleaned.contains('.') &&
        !cleaned.contains(':') &&
        meridiem == null &&
        match.group(4)!.length < 2) {
      return null;
    }
    if (meridiem != null) {
      if (hour < 1 || hour > 12) return null;
      if (meridiem == 'pm' && hour != 12) hour += 12;
      if (meridiem == 'am' && hour == 12) hour = 0;
    }
    if (hour > 23 || minute > 59) return null;
    final weekdayText = match.group(1)?.toLowerCase();
    final monthText = match.group(3)?.toLowerCase();
    final dayNumber = match.group(2) == null ? null : int.parse(match.group(2)!);
    int? monthNumber;
    if (monthText != null) {
      monthNumber = monthNames
              .indexWhere((name) => name.toLowerCase() == monthText) +
          1;
      if (dayNumber == null || dayNumber < 1 || dayNumber > 31) return null;
    }
    return NoteTime(
      hour: hour,
      minute: minute,
      weekday: weekdayText == null
          ? null
          : weekdayNames.indexWhere((n) => n.toLowerCase() == weekdayText) + 1,
      day: monthNumber == null ? null : dayNumber,
      month: monthNumber,
    );
  }

  /// Finds a time at the END of [text] - "Call Priya (10:58)", "... at 9:14
  /// am" - and returns it with the text before it. Null when there is none.
  static (String, NoteTime)? trailingIn(String text) {
    final match = RegExp(
      r'[\s(\[·|—–-]*(?:note\s*time\s*[:\-]?\s*|at\s+|@\s*)?'
      r'((?:(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*\.?,?\s+)?'
      r'(?:\d{1,2}\s+(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+)?'
      r'\d{1,2}:\d{2}\s*(?:am|pm)?)[)\]]?\s*\.?\s*$',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) return null;
    final time = tryParse(match.group(1)!);
    if (time == null) return null;
    return (text.substring(0, match.start).trim(), time);
  }

  @override
  bool operator ==(Object other) =>
      other is NoteTime &&
      other.hour == hour &&
      other.minute == minute &&
      other.weekday == weekday &&
      other.day == day &&
      other.month == month;

  @override
  int get hashCode => Object.hash(hour, minute, weekday, day, month);

  @override
  String toString() => 'NoteTime($label)';
}
