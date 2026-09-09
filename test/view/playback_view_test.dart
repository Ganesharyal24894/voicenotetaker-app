import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/view/placeholder_data.dart';
import 'package:voicenotetaker_app/view/playback_view.dart';
import 'package:voicenotetaker_app/view/recording_entry.dart';
import 'package:voicenotetaker_app/view/widgets/waveform.dart';

import 'harness.dart';

final RecordingEntry _entry =
    PlaceholderData.library(now: DateTime(2026, 9, 10, 18)).first;

void main() {
  testWidgets('builds with title, metadata, scrubber and transport',
      (tester) async {
    await pumpScreen(tester, PlaybackView(entry: _entry));

    expect(find.text('Standup notes'), findsOneWidget);
    expect(
      find.text('Today, 09:14 · 16 kHz mono · 7.9 MB'),
      findsOneWidget,
    );
    expect(find.byType(ScrubWaveform), findsOneWidget);
    expect(find.text('15s'), findsOneWidget);
    expect(find.text('30s'), findsOneWidget);
    expect(find.text('1.0×'), findsOneWidget);
    expect(find.text('Transcribe'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opens at the mock position with elapsed and remaining',
      (tester) async {
    await pumpScreen(tester, PlaybackView(entry: _entry));

    expect(find.text('01:52'), findsOneWidget);
    expect(find.text('−02:20'), findsOneWidget);
  });

  testWidgets('skip forward and back move the playhead', (tester) async {
    await pumpScreen(tester, PlaybackView(entry: _entry));

    await tester.tap(find.bySemanticsLabel('Skip forward 30 seconds'));
    await tester.pump();
    expect(find.text('02:22'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Skip back 15 seconds'));
    await tester.pump();
    expect(find.text('02:07'), findsOneWidget);
  });

  testWidgets('the transport is a placeholder and says so', (tester) async {
    await pumpScreen(tester, PlaybackView(entry: _entry));

    expect(find.bySemanticsLabel('Play'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Play'));
    await tester.pump();

    // The button flips to Pause, and the user is told nothing is playing
    // because no audio player driver exists yet.
    expect(find.bySemanticsLabel('Pause'), findsOneWidget);
    expect(find.textContaining('not wired up yet'), findsOneWidget);
  });

  testWidgets('the speed chip cycles', (tester) async {
    await pumpScreen(tester, PlaybackView(entry: _entry));

    await tester.tap(find.text('1.0×'));
    await tester.pump();
    expect(find.text('1.5×'), findsOneWidget);
  });

  testWidgets('tapping the waveform seeks', (tester) async {
    await pumpScreen(tester, PlaybackView(entry: _entry));

    final box = tester.getRect(find.byType(ScrubWaveform));
    await tester.tapAt(Offset(box.left + box.width * 0.75, box.center.dy));
    await tester.pump();

    expect(find.text('03:09'), findsOneWidget);
  });

  testWidgets('transcription is a placeholder and says so', (tester) async {
    await pumpScreen(tester, PlaybackView(entry: _entry));

    await tester.tap(find.text('Transcribe'));
    await tester.pump();

    expect(find.text('Transcription is not available yet.'), findsOneWidget);
  });

  testWidgets('every transport control clears the 44px minimum',
      (tester) async {
    await pumpScreen(tester, PlaybackView(entry: _entry));

    for (final label in <String>[
      'Skip back 15 seconds',
      'Play',
      'Skip forward 30 seconds',
      'Playback speed',
      'Transcribe',
      'Back to recordings',
    ]) {
      final size = tester.getSize(find.bySemanticsLabel(label));
      expect(size.width, greaterThanOrEqualTo(44), reason: label);
      expect(size.height, greaterThanOrEqualTo(44), reason: label);
    }
  });
}
