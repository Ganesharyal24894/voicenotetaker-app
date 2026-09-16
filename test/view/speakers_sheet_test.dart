import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/controller/speakers_controller.dart';
import 'package:voicenotetaker_app/model/speaker_names.dart';
import 'package:voicenotetaker_app/view/speaker_palette.dart';
import 'package:voicenotetaker_app/view/speakers_sheet.dart';
import 'package:voicenotetaker_app/view/theme.dart';
import 'package:voicenotetaker_app/view/widgets/common.dart';

import 'harness.dart';

const String _path = '/notes/2026-09-10T09-14-00.wav';

/// A [SpeakersController] the tests drive by hand.
///
/// It records every call the sheet makes, so the tests can check what the
/// sheet ASKED for rather than only what it drew - the calls are the contract
/// the diarization pipeline has to satisfy.
class FakeSpeakers extends ChangeNotifier implements SpeakersController {
  FakeSpeakers({List<String> labels = const <String>['S1', 'S2', 'S3']})
      : _labels = <String>[...labels];

  List<String> _labels;
  SpeakerNames names = SpeakerNames.empty;
  int? count;
  double? progress;

  /// Every call, newest last, as `name(arguments)`.
  final List<String> calls = <String>[];

  @override
  List<String> speakerLabelsFor(String recordingPath) => _labels;

  @override
  SpeakerNames speakerNamesFor(String recordingPath) => names;

  @override
  Future<void> renameSpeakers(
    String recordingPath,
    Map<String, String> names,
  ) async {
    calls.add('renameSpeakers($recordingPath, $names)');
    this.names = this.names.withChanges(names);
    notifyListeners();
  }

  @override
  Future<void> mergeSpeakers(
    String recordingPath,
    String from,
    String into,
  ) async {
    calls.add('mergeSpeakers($recordingPath, $from, $into)');
    _labels = <String>[
      for (final label in _labels)
        if (label != from) label,
    ];
    notifyListeners();
  }

  @override
  int? speakerCountFor(String recordingPath) => count;

  @override
  Future<void> setSpeakerCount(String recordingPath, int? count) async {
    calls.add('setSpeakerCount($recordingPath, $count)');
    this.count = count;
    notifyListeners();
  }

  @override
  double? detectionProgressFor(String recordingPath) => progress;
}

/// Opens the sheet the way the note screen does, over a screen with an Edit
/// affordance, and returns the fake it is driven by.
Future<FakeSpeakers> _open(
  WidgetTester tester, {
  FakeSpeakers? speakers,
}) async {
  final fake = speakers ?? FakeSpeakers();
  addTearDown(fake.dispose);
  await pumpScreen(
    tester,
    Scaffold(
      backgroundColor: AppColors.screen,
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => showSpeakersSheet(
              context,
              speakers: fake,
              recordingPath: _path,
            ),
            child: const Text('Edit'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Edit'));
  await tester.pumpAndSettle();
  return fake;
}

String _fieldText(WidgetTester tester, int index) =>
    tester.widget<TextField>(find.byType(TextField).at(index)).controller!.text;

String? _hintText(WidgetTester tester, int index) => tester
    .widget<TextField>(find.byType(TextField).at(index))
    .decoration
    ?.hintText;

bool _selected(WidgetTester tester, String label) => tester
    .widget<SegmentButton>(find.widgetWithText(SegmentButton, label))
    .selected;

void main() {
  group('Speakers sheet', () {
    testWidgets('a row per speaker: a dot, the default label, and Merge…',
        (tester) async {
      await _open(tester);

      expect(find.text('Speakers'), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(3));
      // The placeholder is the speaker's default label.
      expect(find.text('Speaker 1'), findsOneWidget);
      expect(find.text('Speaker 2'), findsOneWidget);
      expect(find.text('Speaker 3'), findsOneWidget);
      expect(find.text('Merge…'), findsNWidgets(3));
      expect(find.text('How many people spoke?'), findsOneWidget);
      expect(find.text(SpeakersSheet.countFootnote), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
    });

    testWidgets('a named speaker shows the name, not the label',
        (tester) async {
      final fake = FakeSpeakers()
        ..names = SpeakerNames.empty
            .withChanges(<String, String>{'S2': 'Priya'});
      await _open(tester, speakers: fake);

      // The field holds the name; "Speaker 2" is only its placeholder, and
      // a placeholder is not what the speaker is called any more.
      expect(_fieldText(tester, 1), 'Priya');
      expect(_hintText(tester, 1), 'Speaker 2');
      expect(_fieldText(tester, 0), '');
    });

    testWidgets('Done saves what was typed', (tester) async {
      final fake = await _open(tester);

      await tester.enterText(find.byType(TextField).at(1), 'Priya');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(fake.calls, <String>['renameSpeakers($_path, {S2: Priya})']);
      expect(fake.names.customName('S2'), 'Priya');
      // Done closes the sheet.
      expect(find.text('Speakers'), findsNothing);
    });

    testWidgets('a field saves itself when it loses focus', (tester) async {
      final fake = await _open(tester);

      await tester.enterText(find.byType(TextField).at(0), 'Me');
      // Moving to the next field is leaving the first.
      await tester.tap(find.byType(TextField).at(1));
      await tester.pumpAndSettle();

      expect(fake.calls, <String>['renameSpeakers($_path, {S1: Me})']);
      expect(fake.names.customName('S1'), 'Me');
      // Still open: blur saves, it does not close.
      expect(find.text('Speakers'), findsOneWidget);
    });

    testWidgets('an empty name reverts the speaker to its default label',
        (tester) async {
      final fake = FakeSpeakers()
        ..names =
            SpeakerNames.empty.withChanges(<String, String>{'S2': 'Priya'});
      await _open(tester, speakers: fake);

      await tester.enterText(find.byType(TextField).at(1), '   ');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(fake.calls, <String>['renameSpeakers($_path, {S2: })']);
      expect(fake.names.customName('S2'), isNull);
      expect(fake.names.labelFor('S2', <String>['S1', 'S2', 'S3']),
          'Speaker 2');
    });

    testWidgets('nothing typed saves nothing', (tester) async {
      final fake = await _open(tester);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(fake.calls, isEmpty);
    });

    testWidgets('a name typed and then swiped away is still saved',
        (tester) async {
      final fake = await _open(tester);

      await tester.enterText(find.byType(TextField).at(2), 'Arun');
      // Dismissed by the barrier rather than by Done.
      await tester.tapAt(const Offset(195, 60));
      await tester.pumpAndSettle();

      expect(find.text('Speakers'), findsNothing);
      expect(fake.names.customName('S3'), 'Arun');
    });
  });

  group('count', () {
    testWidgets('Auto is the selected segment until a number is chosen',
        (tester) async {
      await _open(tester);

      expect(find.text('Auto'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('4+'), findsOneWidget);
      expect(_selected(tester, 'Auto'), isTrue);
      expect(_selected(tester, '2'), isFalse);
      expect(_selected(tester, '3'), isFalse);
      expect(_selected(tester, '4+'), isFalse);
    });

    testWidgets('choosing a number asks the controller and sticks',
        (tester) async {
      final fake = await _open(tester);

      await tester.tap(find.text('3'));
      await tester.pumpAndSettle();

      expect(fake.calls, <String>['setSpeakerCount($_path, 3)']);
      expect(fake.count, 3);
      expect(_selected(tester, '3'), isTrue);
      expect(_selected(tester, 'Auto'), isFalse);
    });

    testWidgets('4+ means four or more, and says so out loud', (tester) async {
      final fake = await _open(tester);

      await tester.tap(find.text('4+'));
      await tester.pumpAndSettle();

      expect(fake.calls, <String>['setSpeakerCount($_path, 4)']);
      expect(
        find.bySemanticsLabel('How many people spoke: 4 or more'),
        findsOneWidget,
      );
    });

    testWidgets('choosing the count already chosen asks for nothing',
        (tester) async {
      final fake = FakeSpeakers()..count = 2;
      await _open(tester, speakers: fake);

      await tester.tap(find.text('2'));
      await tester.pumpAndSettle();

      expect(fake.calls, isEmpty);
    });

    testWidgets('a re-run says so, and never blocks the sheet from closing',
        (tester) async {
      final fake = FakeSpeakers()..progress = 0.42;
      await _open(tester, speakers: fake);

      // The honest version of the footnote: what is happening, and how far.
      expect(find.text(SpeakersSheet.countFootnote), findsNothing);
      expect(find.text('${SpeakersSheet.working} 42%'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, 0.42);

      // Done still works mid-re-run.
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('Speakers'), findsNothing);
    });

    testWidgets('progress appears and clears as the controller reports it',
        (tester) async {
      final fake = await _open(tester);

      expect(find.byType(LinearProgressIndicator), findsNothing);

      fake
        ..progress = 0
        ..notifyListeners();
      await tester.pump();
      expect(find.text('${SpeakersSheet.working} 0%'), findsOneWidget);

      fake
        ..progress = null
        ..notifyListeners();
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text(SpeakersSheet.countFootnote), findsOneWidget);
    });
  });

  group('merge', () {
    testWidgets('Merge… lists the others, and Cancel comes back',
        (tester) async {
      final fake = FakeSpeakers()
        ..names = SpeakerNames.empty
            .withChanges(<String, String>{'S1': 'Me', 'S2': 'Priya'});
      await _open(tester, speakers: fake);

      await tester.tap(find.text('Merge…').last);
      await tester.pumpAndSettle();

      expect(find.text('Merge Speaker 3 into…'), findsOneWidget);
      expect(find.text('Me'), findsOneWidget);
      expect(find.text('Priya'), findsOneWidget);
      // The speaker being merged is not one of its own targets.
      expect(find.text('Speaker 3'), findsNothing);
      expect(find.text('Their lines will show under one name.'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Speakers'), findsOneWidget);
      expect(fake.calls, isEmpty);
    });

    testWidgets('merging folds the speaker away and returns to the list',
        (tester) async {
      final fake = await _open(tester);

      await tester.tap(find.text('Merge…').last);
      await tester.pumpAndSettle();
      // The second option rather than the pre-selected first.
      await tester.tap(find.text('Speaker 2'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Merge'));
      await tester.pumpAndSettle();

      expect(fake.calls, <String>['mergeSpeakers($_path, S3, S2)']);
      expect(find.text('Speakers'), findsOneWidget);
      // Two speakers left, and no row for the one that went.
      expect(find.byType(TextField), findsNWidgets(2));
      expect(find.text('Speaker 3'), findsNothing);
    });

    testWidgets('the first other speaker is picked for you', (tester) async {
      final fake = await _open(tester);

      await tester.tap(find.text('Merge…').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Merge'));
      await tester.pumpAndSettle();

      expect(fake.calls, <String>['mergeSpeakers($_path, S3, S1)']);
    });

    testWidgets('the merge title uses the name the user gave',
        (tester) async {
      final fake = FakeSpeakers()
        ..names =
            SpeakerNames.empty.withChanges(<String, String>{'S3': 'Arun'});
      await _open(tester, speakers: fake);

      await tester.tap(find.text('Merge…').last);
      await tester.pumpAndSettle();

      expect(find.text('Merge Arun into…'), findsOneWidget);
    });

    testWidgets('one speaker left has nobody to merge into', (tester) async {
      await _open(tester, speakers: FakeSpeakers(labels: <String>['S1']));

      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Merge…'), findsNothing);
    });
  });

  group('reach', () {
    testWidgets('every control clears the 44px minimum', (tester) async {
      await _open(tester);

      for (final label in <String>[
        'Merge Speaker 1 into another speaker',
        'How many people spoke: work it out for me',
        'Done',
      ]) {
        final size = tester.getSize(find.bySemanticsLabel(label));
        expect(size.height, greaterThanOrEqualTo(44), reason: label);
      }
      // The name field is a tap target as much as a field: its well is the
      // 44px one, the bare TextField inside it is only as tall as its text.
      expect(
        tester
            .getSize(
              find
                  .ancestor(
                    of: find.byType(TextField).first,
                    matching: find.byType(Container),
                  )
                  .first,
            )
            .height,
        greaterThanOrEqualTo(44),
      );
    });

    testWidgets('speaker colours follow the label, not the row',
        (tester) async {
      final fake = await _open(tester);

      // S3 is third, so it wears the third colour.
      expect(SpeakerPalette.of('S3', fake.speakerLabelsFor(_path)),
          SpeakerPalette.colors[2]);

      await tester.tap(find.text('Merge…').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Merge'));
      await tester.pumpAndSettle();

      // S1 folded into S2: the two left keep their order, and S3 moves up a
      // place - the colour follows the position a label first speaks in.
      expect(fake.speakerLabelsFor(_path), <String>['S2', 'S3']);
      expect(SpeakerPalette.of('S3', fake.speakerLabelsFor(_path)),
          SpeakerPalette.colors[1]);
    });
  });
}
