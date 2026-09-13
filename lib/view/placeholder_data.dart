// ---------------------------------------------------------------------------
// PLACEHOLDER STATE - NOT BACKED BY ANY SERVICE.
//
// Three things the design shows have no service behind them yet, and this file
// is the ONLY place the app pretends otherwise:
//
//   * a recordings library     - nothing enumerates and describes saved files
//   * playback                 - `drivers/audio_player.dart` is interface-only
//   * transcription            - not started
//
// Nothing here is invented behaviour: it is display data, clearly marked with
// `isPlaceholder`, so the screens can be built and reviewed against the mock.
// When the corresponding service lands, delete the constant it replaces - the
// screens already take their content as parameters.
// ---------------------------------------------------------------------------

import 'recording_entry.dart';

/// The sample library from `design/Main.dc.html`, anchored to "now" so the
/// Today / Yesterday grouping is exercised.
abstract final class PlaceholderData {
  /// Peak level is unknown - `CaptureStats` counts packets, not loudness.
  static const int? peakDbfs = null;

  /// The app's em dash for "no reading". Shown wherever a value the design
  /// has cannot be produced - ATT MTU, connection interval, PHY, throughput,
  /// jitter buffer - and also for readings that ARE wired to a service but
  /// that the device has not reported, such as the battery percentage on
  /// firmware without `fe05`.
  static const String unknownValue = '—';

  static List<RecordingEntry> library({DateTime? now}) {
    final today = now ?? DateTime.now();
    final midnight = DateTime(today.year, today.month, today.day);
    final yesterday = midnight.subtract(const Duration(days: 1));
    return <RecordingEntry>[
      RecordingEntry(
        title: 'Standup notes',
        recordedAt: midnight.add(const Duration(hours: 9, minutes: 14)),
        duration: const Duration(minutes: 4, seconds: 12),
        sizeBytes: 7900000,
        isPlaceholder: true,
      ),
      RecordingEntry(
        title: 'Idea — enclosure vents',
        recordedAt: midnight.add(const Duration(hours: 8, minutes: 2)),
        duration: const Duration(minutes: 1, seconds: 38),
        sizeBytes: 3100000,
        isPlaceholder: true,
      ),
      RecordingEntry(
        title: 'Call with supplier',
        recordedAt: yesterday.add(const Duration(hours: 16, minutes: 40)),
        duration: const Duration(minutes: 11, seconds: 3),
        sizeBytes: 21200000,
        isPlaceholder: true,
      ),
      RecordingEntry(
        title: 'Workshop walkthrough',
        recordedAt: yesterday.add(const Duration(hours: 11, minutes: 2)),
        duration: const Duration(minutes: 27, seconds: 55),
        sizeBytes: 53600000,
        isPlaceholder: true,
      ),
    ];
  }
}
