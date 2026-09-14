import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/controller/summary_controller.dart';
import 'package:voicenotetaker_app/view/home/summary_scope.dart';
import 'package:voicenotetaker_app/view/home_view.dart';
import 'package:voicenotetaker_app/view/recording_entry.dart';

import '../summary/fakes.dart';
import 'harness.dart';

/// A [SummaryController] over [harness]'s controller, with fake clipboard and
/// share sheet and a pinned clock.
SummaryController summariesFor(
  ViewHarness harness, {
  FakeClipboard? clipboard,
  FakeShareSheet? share,
  DateTime? now,
}) =>
    SummaryController(
      loadTranscript: (recording) async {
        await harness.controller.loadTranscript(recording);
        return harness.controller.transcriptFor(recording);
      },
      clipboard: clipboard ?? FakeClipboard(),
      shareSheet: share ?? FakeShareSheet(),
      clock: now == null ? null : () => now,
    );

/// Home as `AppRoot` mounts it: rebuilt on every controller notification, with
/// the summaries reachable through [SummaryScope].
Widget homeFor(
  ViewHarness harness, {
  SummaryController? summaries,
  VoidCallback? onOpenDiagnostics,
  VoidCallback? onOpenLibrary,
  ValueChanged<RecordingEntry>? onOpenRecording,
  VoidCallback? onConnect,
}) {
  final scope = summaries ?? summariesFor(harness);
  return SummaryScope(
    summaries: scope,
    child: ListenableBuilder(
      listenable: harness.controller,
      builder: (context, _) => HomeView(
        controller: harness.controller,
        summaries: scope,
        onOpenLibrary: onOpenLibrary ?? () {},
        onOpenRecording: onOpenRecording ?? (_) {},
        onOpenDiagnostics: onOpenDiagnostics,
        onConnect: onConnect,
      ),
    ),
  );
}

/// The header's status line, which opens the recorder sheet.
Finder recorderStatusLine() => find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.hint == 'Recorder settings',
    );
