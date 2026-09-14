import 'dart:ffi';
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

  /// Asks the native allocator to return freed memory to the operating
  /// system. Android only; true when the allocator accepted the request.
  ///
  /// WHY. Freeing a loaded speech model returns its memory to bionic's
  /// allocator, not to the kernel: on the phone about 350 MB stayed resident
  /// after every job. `mallopt(M_PURGE)` (bionic, API 28+) releases the free
  /// pages the allocator is holding. It is cheap and harmless when there is
  /// nothing to release, and elsewhere this does nothing.
  static bool releaseFreedNativeMemory() {
    if (!Platform.isAndroid) return false;
    try {
      final mallopt = DynamicLibrary.open('libc.so')
          .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'mallopt',
      );
      return mallopt(_mPurge, 0) == 1;
    } on Object {
      return false;
    }
  }

  /// `M_PURGE` from bionic's `<malloc.h>`.
  static const int _mPurge = -101;

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
