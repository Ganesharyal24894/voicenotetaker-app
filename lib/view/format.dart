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
