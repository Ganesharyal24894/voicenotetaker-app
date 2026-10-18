import 'package:flutter/foundation.dart';

import '../../model/firmware_update_state.dart';

/// What the update screen needs that the service's state does not carry:
/// when sending started, how fast it is going, and the last percent seen -
/// so a failure can say "The connection dropped at 61%".
///
/// IT OUTLIVES THE SCREEN. `AppRoot` keeps one for the app's lifetime, so
/// leaving the screen mid-transfer and coming back keeps the estimate and the
/// percent instead of starting from nothing.
class UpdateProgress {
  UpdateProgress(this._state, {DateTime Function()? now})
      : _now = now ?? DateTime.now {
    _state.addListener(_onState);
    _onState();
  }

  final ValueListenable<UpdateState> _state;
  final DateTime Function() _now;

  DateTime? _startedAt;
  int _startPercent = 0;
  int? _lastPercent;

  /// The estimate stays hidden until this much has been sent: the first
  /// seconds of a transfer say little about its rate.
  static const int estimateAfterPercent = 10;

  /// The last percent seen while sending, kept through a failure.
  int? get lastPercent => _lastPercent;

  void _onState() {
    switch (_state.value) {
      case UpdateTransferring(:final percent):
        if (_startedAt == null) {
          _startedAt = _now();
          _startPercent = percent;
        }
        _lastPercent = percent;
      case UpdateFailed():
        // Kept for the failure's wording; the next run starts afresh.
        _startedAt = null;
      case UpdateConfirming():
        break;
      default:
        _startedAt = null;
        _lastPercent = null;
    }
  }

  /// Roughly how long sending has left, from the rate seen so far. Null until
  /// [estimateAfterPercent] is through, and whenever nothing is being sent.
  Duration? get remaining {
    final started = _startedAt;
    final percent = _lastPercent;
    if (started == null || percent == null) return null;
    if (percent < estimateAfterPercent) return null;
    final sent = percent - _startPercent;
    if (sent <= 0) return null;
    final elapsed = _now().difference(started);
    final perPercent = elapsed.inMilliseconds / sent;
    return Duration(milliseconds: (perPercent * (100 - percent)).round());
  }

  void dispose() => _state.removeListener(_onState);
}
