/// Presentation-only formatting helpers.
///
/// These live in `view/` on purpose: they turn model values into the exact
/// strings the mock shows and have no meaning below this layer.
abstract final class Fmt {
  static String _two(int value) => value.toString().padLeft(2, '0');

  /// The recording timer: `02:47`, or `1:02:47` once an hour has passed.
  /// Minutes are always two digits so the tabular figures do not reflow.
  static String timer(Duration d) {
    final seconds = d.inSeconds.abs();
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final secs = seconds % 60;
    if (hours > 0) return '$hours:${_two(minutes)}:${_two(secs)}';
    return '${_two(minutes)}:${_two(secs)}';
  }

  /// A recording's length as the lists show it: `4:12`, `27:55`.
  static String duration(Duration d) {
    final seconds = d.inSeconds.abs();
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final secs = seconds % 60;
    if (hours > 0) return '$hours:${_two(minutes)}:${_two(secs)}';
    return '$minutes:${_two(secs)}';
  }

  /// Wall-clock time of day: `09:14`.
  static String timeOfDay(DateTime at) => '${_two(at.hour)}:${_two(at.minute)}';

  /// `Today`, `Yesterday`, `Mon`, or `12 Mar` for anything older than a week.
  static String day(DateTime at, {DateTime? now}) {
    final today = _midnight(now ?? DateTime.now());
    final then = _midnight(at);
    final days = today.difference(then).inDays;
    if (days == 0) return 'Today';
    if (days == 1) return 'Yesterday';
    if (days > 1 && days < 7) return _weekdays[then.weekday - 1];
    return '${then.day} ${_months[then.month - 1]}';
  }

  /// `Today, 09:14`.
  static String dayAndTime(DateTime at, {DateTime? now}) =>
      '${day(at, now: now)}, ${timeOfDay(at)}';

  /// File size as a phone shows it: `7.9 MB`, `812 kB`.
  static String bytes(int count) {
    if (count < 1000) return '$count B';
    if (count < 1000000) return '${(count / 1000).round()} kB';
    if (count < 1000000000) {
      return '${(count / 1000000).toStringAsFixed(1)} MB';
    }
    return '${(count / 1000000000).toStringAsFixed(2)} GB';
  }

  /// Signal strength as the device cards show it: `-54 dBm`, with a real minus
  /// sign (U+2212) exactly as the mock uses.
  static String rssi(int? dbm) =>
      dbm == null ? '— dBm' : '−${dbm.abs()} dBm';

  /// One device-test measurement with its unit: `−62.4 dBFS`, `0.41%`,
  /// `1.8 s`, `312`.
  ///
  /// A null [value] is `—` with the unit kept - `— dBm`, exactly as
  /// [rssi] renders an absent signal. NEVER `0`: "no reading" and "a reading of
  /// zero" are different facts, and this is the last place they could be
  /// collapsed.
  ///
  /// Precision is chosen by unit so the same quantity reads the same way
  /// everywhere it appears - on the card and in the export.
  static String measurement(num? value, String unit) {
    final suffix = unit.isEmpty ? '' : (unit == '%' ? unit : ' $unit');
    if (value == null) return '—$suffix';
    final decimals = switch (unit) {
      'dBFS' => 1,
      's' => 1,
      '°C' => 1,
      '%' => 2,
      _ => 0,
    };
    final text = value.toDouble().toStringAsFixed(decimals);
    // A real minus sign (U+2212), the same one [rssi] uses: these sit in
    // tabular columns next to each other.
    return '${text.replaceFirst('-', '−')}$suffix';
  }

  /// The same measurement with the decimal dropped: `−39 dBFS`, `— dBFS`.
  ///
  /// FOR THE ONE FIGURE A CARD LEADS WITH, and nowhere else. The acoustic
  /// readings move about a decibel from one sample of a batch to the next, so
  /// the tenth in `−39.2 dBFS` is noise wearing the clothes of precision: it
  /// invites somebody to read a change the next run would not reproduce.
  /// [measurement] keeps the tenth, and it is what the details and the export
  /// still use - nothing is lost, it is just not the first thing shown.
  ///
  /// Only the decibel units round; anything else defers to [measurement],
  /// because `0.41%` rounded to a whole number is `0%`, which is not the same
  /// fact.
  static String headline(num? value, String unit) {
    if (unit != 'dBFS' && unit != 'dBm') return measurement(value, unit);
    final suffix = unit.isEmpty ? '' : ' $unit';
    if (value == null) return '—$suffix';
    final text = value.toDouble().toStringAsFixed(0);
    // `(-0.4).toStringAsFixed(0)` is `-0`, and a signed zero reads as a
    // measurement rather than as rounding.
    final signed = text == '-0' ? '0' : text.replaceFirst('-', '−');
    return '$signed$suffix';
  }

  /// `16 kHz mono` / `48 kHz stereo`.
  static String streamSummary(int sampleRateHz, int channels) {
    final khz = sampleRateHz / 1000;
    final rate =
        khz == khz.roundToDouble() ? khz.round().toString() : khz.toString();
    return '$rate kHz ${channels == 1 ? 'mono' : 'stereo'}';
  }

  static DateTime _midnight(DateTime at) => DateTime(at.year, at.month, at.day);

  static const List<String> _weekdays = <String>[
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];

  static const List<String> _months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
}
