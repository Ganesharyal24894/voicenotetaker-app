import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/language_router.dart';

/// The Hindi/English router, on IndicConformer's real output for the owner's
/// recordings from the laptop evaluation (`route.py`, win8 windows).
void main() {
  const hi = WindowLanguage.hindi;
  const en = WindowLanguage.english;

  group('the word list', () {
    test('is route.py\'s, without थे and तो', () {
      final words = LanguageRouter.hindiFunctionWords;
      expect(words, hasLength(59));
      expect(words, containsAll(<String>['है', 'को', 'के', 'में', 'नहीं', 'एक']));
      expect(words.contains('थे'), isFalse);
      expect(words.contains('तो'), isFalse);
    });
  });

  group('tokenization', () {
    test('splits on any whitespace, as route.py does', () {
      expect(LanguageRouter.words('एंड  य\tदैट\nशुड '),
          <String>['एंड', 'य', 'दैट', 'शुड']);
      expect(LanguageRouter.words(''), isEmpty);
      expect(LanguageRouter.words('   '), isEmpty);
    });

    test('trims punctuation at the edges, and drops punctuation alone', () {
      expect(LanguageRouter.words('है, "को" — में। ?'),
          <String>['है', 'को', 'में']);
      expect(LanguageRouter.statsOf('नहीं!').hindiWords, 1);
    });

    test('keeps combining marks and numbers as words', () {
      expect(LanguageRouter.words('े डेलीना'), <String>['े', 'डेलीना']);
      final stats = LanguageRouter.statsOf('5 बजे 10 मिनट है');
      expect(stats.words, 5);
      expect(stats.hindiWords, 1);
    });

    test('density of nothing is zero', () {
      expect(LanguageStats.zero.density, 0);
    });
  });

  group('routing', () {
    test('an English note: IndicConformer\'s transliteration goes English', () {
      // voicenote-20260915-022908: "The case should be good to touch ..."
      expect(
        LanguageRouter.route(<String>['थेश शुड बे गुड तो थे चट', '']),
        <WindowLanguage>[en, hi],
      );
    });

    test('Hinglish windows stay Hindi', () {
      // 20260906-172325_s6, every window.
      expect(
        LanguageRouter.route(<String>[
          'मेरे को ऑडियो नोट बनाना है एंड अभी जो हम बोल रहे हैं वो मेरा टूडू लिस्ट है',
          'तो पहले मेरे को फ़ोन चार्ज करना है फिर लैपटॉप चार्ज करना है उसके बाद ऑफिस का फ',
          'थड़ा काम करना है एंड इलेक्ट्रिसिटी दिल के लिए कल जाना है',
        ]),
        <WindowLanguage>[hi, hi, hi],
      );
    });

    test('a mixed note routes window by window', () {
      // 20260906-180032_s11: English in windows 2 and 4.
      expect(
        LanguageRouter.route(<String>[
          'हेलो सो ई एम यूज़िंग दिस टू रिकॉर्ड मई नोट्स पहला जो मेरे को काम करना है दैट',
          'इ अः प्ले सोम विडियो एंड अः यू क्नो गेटिंग तो थे देतेइल्स ऑफ लेनेक्स्ट देविस ड्राइवर',
          'नेक्स्ट मेरे को ये करना है कि इसका रिज़ल्ट देखना है कैसा आता है',
          'एंड  य दैट शुड बीट',
        ]),
        <WindowLanguage>[hi, en, hi, en],
      );
    });

    test('an English-heavy Hinglish window just over the line stays Hindi', () {
      // stt-test-hinglish-16s window 1: 2 function words in 22, 0.09.
      final text = 'नमस्ते दोस्त मैं हूँ गुरु तुम्हारा नया दोस्त हाय दे आई एम '
          'गुरु एंड आई एम सो हैप्पी टू मीट यू चलो';
      expect(LanguageRouter.statsOf(text).density, closeTo(0.09, 0.01));
      expect(LanguageRouter.route(<String>[text]), <WindowLanguage>[hi]);
    });

    test('a short window follows a Hindi note', () {
      // 20260906-181928_s15: "टॉप लोकार रट चाहिए" has 4 words, no function
      // word, and sits in a Hindi note.
      expect(
        LanguageRouter.route(<String>[
          'तो मॉनव मेरा एक सोफ्त्वरे है देखने आया',
          'टॉप लोकार रट चाहिए',
          'नहीं जैसे मेरा वर्क है एकाउन्ट पि कर कुछ भी',
        ]),
        <WindowLanguage>[hi, hi, hi],
      );
    });

    test('a short window follows an English note', () {
      expect(
        LanguageRouter.route(<String>[
          'इ अः प्ले सोम विडियो एंड अः यू क्नो गेटिंग',
          'दैट शुड बीट',
        ]),
        <WindowLanguage>[en, en],
      );
    });

    test('a note too short to judge stays Hindi', () {
      // voicenote-20260910-042331: "चेक चेक" / "ठीक है", 4 words in all.
      expect(LanguageRouter.route(<String>['चेक चेक', 'ठीक है']),
          <WindowLanguage>[hi, hi]);
      // voicenote-20260914-031454: "हैलो".
      expect(LanguageRouter.route(<String>['हैलो']), <WindowLanguage>[hi]);
    });

    test('five words with no function word is English (the boundary)', () {
      // voicenote-20260910-045411: "hello one two three accha".
      expect(LanguageRouter.route(<String>['हैलो ओन टू थ्री अच्छा']),
          <WindowLanguage>[en]);
      // Four words are not enough on their own.
      expect(LanguageRouter.route(<String>['हैलो ओन टू थ्री']),
          <WindowLanguage>[hi]);
    });

    test('density exactly at 0.08 is Hindi; below is English', () {
      final hindi = <String>['है', ...List<String>.filled(11, 'क')].join(' ');
      expect(LanguageRouter.statsOf(hindi).density, closeTo(1 / 12, 1e-9));
      expect(LanguageRouter.route(<String>[hindi]), <WindowLanguage>[hi]);
      final english = <String>['है', ...List<String>.filled(12, 'क')].join(' ');
      expect(LanguageRouter.route(<String>[english]), <WindowLanguage>[en]);
      final exact = <String>['है', 'है', ...List<String>.filled(23, 'क')];
      expect(LanguageRouter.statsOf(exact.join(' ')).density, 0.08);
      expect(LanguageRouter.route(<String>[exact.join(' ')]),
          <WindowLanguage>[hi]);
    });

    test('silent windows stay Hindi even in an English note', () {
      expect(
        LanguageRouter.route(<String>[
          '',
          'इ अः प्ले सोम विडियो एंड अः यू क्नो गेटिंग',
          '  ',
          '। ,',
        ]),
        <WindowLanguage>[hi, en, hi, hi],
      );
    });

    test('numbers and punctuation do not make a Hindi window English', () {
      expect(
        LanguageRouter.route(<String>['मेरे को 5 बजे, 10 मिनट में जाना है।']),
        <WindowLanguage>[hi],
      );
    });

    test('nothing in, nothing out', () {
      expect(LanguageRouter.route(const <String>[]), isEmpty);
    });
  });

  group('the setting', () {
    test('reads back by name, and nothing else', () {
      for (final value in TranscriptionLanguage.values) {
        expect(TranscriptionLanguage.fromName(value.name), value);
      }
      expect(TranscriptionLanguage.fromName('Hindi'), isNull);
      expect(TranscriptionLanguage.fromName(null), isNull);
      expect(TranscriptionLanguage.fromName(1), isNull);
    });

    test('segment codes', () {
      expect(WindowLanguage.hindi.code, 'hi');
      expect(WindowLanguage.english.code, 'en');
    });
  });
}
