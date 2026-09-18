import 'dart:async';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';

import '../drivers/share_sheet.dart';
import '../services/export/note_export_plan.dart';
import '../services/export/note_export_service.dart';

/// Where one export has got to.
enum ExportPhase {
  /// Choosing a range, or waiting for the count of one.
  choosing,

  /// Writing the zip.
  writing,

  /// Written, and waiting to be sent somewhere.
  ready,
}

/// "Export notes": one zip of the user's recordings and transcripts, handed to
/// the share sheet.
///
/// A controller rather than state in the sheet, for the reason every other
/// controller here exists: the work outlives a frame, and a widget that
/// `setState`s after it was disposed is the bug this shape prevents. The sheet
/// closing cancels the write and takes the half file with it.
///
/// NOTHING LEAVES THE PHONE BY ITSELF. The zip is written to the app's own
/// storage and then offered to the system share sheet; where it goes after
/// that is the user picking a destination. There is no upload and no network
/// call anywhere in this path.
class ExportController extends ChangeNotifier {
  ExportController({
    required NoteExportService exports,
    ShareSheet? shareSheet,
    DateTime Function()? now,
    // A plain field behind a public name: an initializing formal cannot be
    // used because the field is private and the parameter is part of the API.
    // ignore: prefer_initializing_formals
  })  : _exports = exports,
        _share = shareSheet,
        _now = now ?? DateTime.now;

  final NoteExportService _exports;
  final ShareSheet? _share;
  final DateTime Function() _now;

  ExportRange _range = ExportRange.today;
  ExportPhase _phase = ExportPhase.choosing;
  ExportPlan? _plan;
  ExportResult? _result;
  ExportFailure? _failure;
  int _written = 0;
  bool _cancelled = false;
  bool _disposed = false;

  /// The zip has been handed to the share sheet, so it is not ours to delete
  /// on the way out - see [close].
  bool _handedOver = false;

  /// The write in flight, so [close] can wait for it to stop rather than
  /// deleting the file out from under it.
  Future<void>? _running;

  /// Which range the sheet is showing.
  ExportRange get range => _range;

  ExportPhase get phase => _phase;

  /// What the chosen range holds, or null while it is being counted.
  ExportPlan? get plan => _plan;

  /// The finished zip, when there is one.
  ExportResult? get result => _result;

  /// Why the last attempt did not produce a zip, cleared when another starts.
  ExportFailure? get failure => _failure;

  /// Bytes of the zip written so far.
  int get bytesWritten => _written;

  /// `0.0 .. 1.0`, determinate from the first frame because the size of a
  /// stored zip is known before it is written.
  double get progress {
    final total = _plan?.zipBytes ?? 0;
    if (total <= 0) return 0;
    final value = _written / total;
    return value < 0 ? 0 : (value > 1 ? 1 : value);
  }

  /// Whether there is anywhere to send the zip. False on a platform with no
  /// share sheet wired in, which hides the button rather than offering one
  /// that does nothing.
  bool get canShare => _share != null;

  /// Counts what [range] holds. Called once when the sheet opens and again
  /// whenever the user picks a different range.
  Future<void> choose(ExportRange range) async {
    _range = range;
    _plan = null;
    _failure = null;
    _result = null;
    _phase = ExportPhase.choosing;
    _emit();
    final plan = await _exports.plan(range, now: _now());
    // A second tap while the first count was running: the answer that arrives
    // for a range nobody is looking at any more is dropped.
    if (_disposed || range != _range) return;
    _plan = plan;
    _emit();
  }

  /// Writes the zip for the chosen range.
  Future<void> run() async {
    final plan = _plan;
    if (plan == null || _phase == ExportPhase.writing) return;
    _cancelled = false;
    _failure = null;
    _written = 0;
    _phase = ExportPhase.writing;
    _emit();

    final running = _write(plan);
    _running = running;
    try {
      await running;
    } finally {
      if (identical(_running, running)) _running = null;
    }
  }

  Future<void> _write(ExportPlan plan) async {
    ExportResult result;
    try {
      result = await _exports.write(
        plan,
        onProgress: (written, total) {
          if (_disposed) return;
          _written = written;
          _emit();
        },
        isCancelled: () => _cancelled || _disposed,
      );
    } on Object {
      // `write` answers with a reason rather than throwing, but if anything
      // ever gets past it the screen must still leave the writing state.
      // A progress bar that never finishes and a Stop that does nothing is
      // the one outcome with no way out of it.
      result = const ExportResult.refused(ExportFailure.failed);
    }

    if (_disposed) return;
    _result = result;
    if (result.ok) {
      _phase = ExportPhase.ready;
    } else {
      _phase = ExportPhase.choosing;
      _failure = result.failure;
    }
    _emit();
  }

  /// Whether Stop has been tapped and the write has not unwound yet.
  bool get stopping => _cancelled && _phase == ExportPhase.writing;

  /// Stops a write in progress. The partial file is removed by the service.
  ///
  /// Notifies, so the button changes the moment it is tapped: the write
  /// notices at its next chunk boundary, and up to half a megabyte of copying
  /// with nothing on screen reads as a button that did not work.
  void cancel() {
    if (_phase != ExportPhase.writing || _cancelled) return;
    _cancelled = true;
    _emit();
  }

  /// Hands the zip to the share sheet. [origin] anchors the popover on an
  /// iPad; phones ignore it.
  Future<void> share({Rect? origin}) async {
    final path = _result?.path;
    final share = _share;
    if (path == null || share == null) return;
    _handedOver = true;
    await share.shareFiles(
      <String>[path],
      subject: 'voiceNotetaker notes',
      origin: origin,
    );
  }

  /// Removes the zip. It is a copy, and a copy of the whole library is not a
  /// thing to leave on a phone.
  Future<void> discard() => _exports.clearExports();

  /// Stops any write, removes the zip and disposes the controller, in that
  /// order. What the sheet calls when it closes.
  ///
  /// THE ORDER MATTERS. Deleting first would unlink a file a running write
  /// still holds open, and the write would then keep pouring bytes into an
  /// inode nobody can see until it noticed it had been cancelled. This waits
  /// for the write to stop before it sweeps.
  Future<void> close() async {
    _cancelled = true;
    final running = _running;
    if (running != null) {
      try {
        await running;
      } on Object {
        // `write` reports a failure rather than throwing it; anything that
        // does get past it still must not stop the sweep below.
      }
    }
    // NOT SWEPT ONCE IT HAS BEEN HANDED OVER. The share sheet gives the
    // receiving app a URL, not a copy, and AirDrop of a few hundred megabytes
    // carries on long after the sheet is dismissed. Deleting here would pull
    // the file out from under a transfer the user is watching. It goes the
    // next time Export notes is opened, which is what `showExportNotesSheet`
    // does on its way in.
    if (!_handedOver) await discard();
    dispose();
  }

  /// Idempotent: the sheet disposes the controller when it closes, and a
  /// caller that also holds one must not have to know that.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelled = true;
    super.dispose();
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }
}
