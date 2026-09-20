import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/speaker_names.dart';
import 'package:voicenotetaker_app/model/transcript.dart';
import 'package:voicenotetaker_app/model/transcript_paragraphs.dart';
import 'package:voicenotetaker_app/model/transcription.dart';

TranscriptSegment _seg(int from, int to, String text, [String? speaker]) =>
    TranscriptSegment(
      start: Duration(seconds: from),
      end: Duration(seconds: to),
      text: text,
      speaker: speaker,
    );

Transcript _transcript(List<TranscriptSegment> segments) => Transcript(
      languageCode: 'hi',
      modelId: 'm',
      createdAt: DateTime.utc(2026, 9, 14),
      audioDuration: segments.isEmpty ? Duration.zero : segments.last.end,
      segments: segments,
    );

void main() {
  group('speakers in the saved transcript - backward compatible', () {
    test('a transcript saved before speakers existed still loads', () {
      // Exactly what version 1 wrote, byte for byte, with no speaker key.
      const older = '{"version":1,"language":"hi","model":"m",'
          '"createdAt":"2026-09-14T00:00:00.000Z","audioMs":16000,'
          '"segments":[{"startMs":0,"endMs":8000,"text":"हाँ सुनो"},'
          '{"startMs":8000,"endMs":16000,"text":"ठीक है"}]}';

      final loaded = Transcript.fromJson(jsonDecode(older));

      expect(loaded, isNotNull);
      expect(loaded!.text, 'हाँ सुनो ठीक है');
      expect(loaded.segments.every((s) => s.speaker == null), isTrue);
      expect(TranscriptLayout.speakers(loaded), isEmpty);
    });

    test('no speaker writes no key at all', () {
      final json = _transcript(<TranscriptSegment>[_seg(0, 8, 'हाँ')]).toJson();
      final segment = (json['segments']! as List<Object?>).single!
          as Map<String, Object?>;

      expect(segment.containsKey('speaker'), isFalse);
      expect(json['version'], 1);
    });

    test('speakers survive a round trip', () {
      final original = _transcript(<TranscriptSegment>[
        _seg(0, 8, 'हाँ', 'S1'),
        _seg(8, 16, 'ठीक', 'S2'),
      ]);

      final loaded =
          Transcript.fromJson(jsonDecode(jsonEncode(original.toJson())))!;

      expect(loaded.segments.map((s) => s.speaker), <String>['S1', 'S2']);
    });

    test('a speaker of the wrong type costs the speaker, not the transcript',
        () {
      final loaded = Transcript.fromJson(jsonDecode(
        '{"version":1,"language":"hi","model":"m",'
        '"createdAt":"2026-09-14T00:00:00.000Z","audioMs":8000,'
        '"segments":[{"startMs":0,"endMs":8000,"text":"हाँ","speaker":7}]}',
      ));

      expect(loaded, isNotNull);
      expect(loaded!.segments.single.speaker, isNull);
    });
  });

  group('paragraphs', () {
    test('without speakers, segments run together up to 30 s', () {
      final paragraphs = TranscriptLayout.paragraphs(_transcript(
        <TranscriptSegment>[
          _seg(0, 8, 'एक'),
          _seg(8, 16, 'दो'),
          _seg(16, 24, 'तीन'),
          _seg(24, 32, 'चार'),
          _seg(32, 40, 'पाँच'),
        ],
      ));

      expect(paragraphs.map((p) => p.text), <String>['एक दो तीन', 'चार पाँच']);
      expect(paragraphs[1].start, const Duration(seconds: 24));
      expect(paragraphs.every((p) => p.speaker == null), isTrue);
    });

    test('a pause of 2 s or more starts a new paragraph', () {
      final paragraphs = TranscriptLayout.paragraphs(_transcript(
        <TranscriptSegment>[_seg(0, 5, 'एक'), _seg(7, 10, 'दो')],
      ));

      expect(paragraphs.map((p) => p.text), <String>['एक', 'दो']);
    });

    test('silent segments are skipped and never make a paragraph', () {
      final paragraphs = TranscriptLayout.paragraphs(_transcript(
        <TranscriptSegment>[
          _seg(0, 8, ' '),
          _seg(8, 9, 'हाँ'),
          _seg(9, 10, ''),
        ],
      ));

      expect(paragraphs, hasLength(1));
      expect(paragraphs.single.start, const Duration(seconds: 8));
    });

    test('a change of speaker starts a new paragraph', () {
      final paragraphs = TranscriptLayout.paragraphs(_transcript(
        <TranscriptSegment>[
          _seg(0, 4, 'हाँ', 'S1'),
          _seg(4, 8, 'सुनो', 'S1'),
          _seg(8, 12, 'ठीक', 'S2'),
          _seg(12, 14, 'फिर', 'S1'),
        ],
      ));

      expect(paragraphs.map((p) => '${p.speaker}:${p.text}'),
          <String>['S1:हाँ सुनो', 'S2:ठीक', 'S1:फिर']);
    });

    test('speakers are listed in the order they first speak', () {
      final transcript = _transcript(<TranscriptSegment>[
        _seg(0, 4, '', 'S3'),
        _seg(4, 8, 'हाँ', 'S2'),
        _seg(8, 12, 'ठीक', 'S1'),
        _seg(12, 14, 'फिर', 'S2'),
      ]);

      expect(TranscriptLayout.speakers(transcript), <String>['S2', 'S1']);
    });
  });

  group('the paragraph at a position', () {
    final paragraphs = TranscriptLayout.paragraphs(_transcript(
      <TranscriptSegment>[
        _seg(2, 8, 'एक'),
        _seg(20, 28, 'दो'),
        _seg(40, 44, 'तीन'),
      ],
    ));

    test('nothing before the first paragraph starts', () {
      expect(TranscriptLayout.paragraphAt(paragraphs, Duration.zero), isNull);
    });

    test('inside a paragraph, that paragraph', () {
      expect(
        TranscriptLayout.paragraphAt(paragraphs, const Duration(seconds: 2)),
        0,
      );
      expect(
        TranscriptLayout.paragraphAt(paragraphs, const Duration(seconds: 25)),
        1,
      );
    });

    test('in a pause, the one just heard - no flicker between sentences', () {
      expect(
        TranscriptLayout.paragraphAt(paragraphs, const Duration(seconds: 12)),
        0,
      );
      expect(
        TranscriptLayout.paragraphAt(paragraphs, const Duration(seconds: 90)),
        2,
      );
    });

    test('no paragraphs, no answer', () {
      expect(
        TranscriptLayout.paragraphAt(
          const <TranscriptParagraph>[],
          const Duration(seconds: 3),
        ),
        isNull,
      );
    });
  });

  group('copy text', () {
    test('without speakers: timestamps and words', () {
      final text = TranscriptLayout.plainText(
        _transcript(<TranscriptSegment>[_seg(0, 5, 'एक'), _seg(42, 45, 'दो')]),
        SpeakerNames.empty,
      );

      expect(text, '[00:00] एक\n[00:42] दो');
    });

    test('with speakers: their given names, or Speaker N', () {
      final text = TranscriptLayout.plainText(
        _transcript(<TranscriptSegment>[
          _seg(0, 5, 'हाँ', 'S1'),
          _seg(5, 9, 'ठीक', 'S2'),
        ]),
        const SpeakerNames(<String, String>{'S2': 'Priya'}),
      );

      expect(text, '[00:00] Speaker 1: हाँ\n[00:05] Priya: ठीक');
    });
  });

  test('words are counted on whitespace, Hindi included', () {
    expect(
      TranscriptLayout.wordCount(_transcript(<TranscriptSegment>[
        _seg(0, 4, 'हाँ, सुनो  कल'),
        _seg(4, 8, ''),
        _seg(8, 9, 'ठीक है'),
      ])),
      5,
    );
    expect(TranscriptLayout.wordCount(_transcript(const [])), 0);
  });

  test('timestamps pass an hour cleanly', () {
    expect(TranscriptLayout.timestamp(const Duration(seconds: 42)), '00:42');
    expect(
      TranscriptLayout.timestamp(const Duration(hours: 1, minutes: 2, seconds: 7)),
      '1:02:07',
    );
  });
}
