import 'dart:io';

/// Resident memory of this process, read from `/proc/self/status`.
///
/// Linux and Android only; everywhere else every figure is `null`. Figures are
/// for the whole PROCESS - every isolate, the Flutter engine, native heaps -
/// which is what the operating system weighs when it decides what to kill.
abstract final class ProcessMemory {
  /// Current resident set size in kB (`VmRSS`).
  static int? residentKb() => _field('VmRSS');

  /// Highest resident set size since the process started (`VmHWM`).
  ///
  /// Lifetime, not per job: the kernel's reset (`clear_refs` = 5) is refused
  /// inside an Android app, verified on a Xiaomi running Android 12, so a
  /// per-job peak has to be found by sampling [residentKb] instead.
  static int? peakResidentKb() => _field('VmHWM');

  static int? _field(String name) {
    if (!(Platform.isAndroid || Platform.isLinux)) return null;
    try {
      for (final line in File('/proc/self/status').readAsLinesSync()) {
        if (line.startsWith('$name:')) {
          return int.tryParse(
            line.substring(name.length + 1).trim().split(RegExp(r'\s+')).first,
          );
        }
      }
    } on Object {
      return null;
    }
    return null;
  }
}
