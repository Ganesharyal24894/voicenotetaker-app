/// Which language each transcribed window is in, Hindi or English.
///
/// PURE: text in, decisions out. Ported from the laptop evaluation
/// (`route.py`, see `doc/agentFindings/on-device-stt.md`), where it separated
/// the owner's Hinglish notes from English ones.
library;

/// The user's choice of transcription language. Persisted by name.
enum TranscriptionLanguage {
  /// Hindi everywhere, and English where a window sounds English. Default.
  auto,

  /// IndicConformer for everything: what the app did before routing.
  hindi,

  /// Parakeet for everything; IndicConformer is not loaded.
  english;

  /// The setting saved as [name], or null for anything else.
  static TranscriptionLanguage? fromName(Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

/// A window's language, as the router decides it.
enum WindowLanguage {
  hindi('hi'),
  english('en');

  const WindowLanguage(this.code);

  /// BCP-47, as saved in a transcript segment.
  final String code;
}

/// Word counts of one text.
class LanguageStats {
  const LanguageStats({required this.words, required this.hindiWords});

  static const LanguageStats zero = LanguageStats(words: 0, hindiWords: 0);

  final int words;

  /// How many of [words] are Hindi function words.
  final int hindiWords;

  /// Hindi function words per word; 0 for no words.
  double get density => words == 0 ? 0 : hindiWords / words;

  LanguageStats operator +(LanguageStats other) => LanguageStats(
        words: words + other.words,
        hindiWords: hindiWords + other.hindiWords,
      );

  @override
  String toString() => 'LanguageStats($hindiWords/$words)';
}

/// Tells English windows from Hindi ones in IndicConformer's output.
///
/// WHY IT WORKS. IndicConformer writes English speech as Devanagari
/// transliteration ("थे केश शुड बे गुड"), which reads like Hindi to a script
/// check but has none of Hindi's grammar. Hindi - and Hinglish, where English
/// nouns sit in Hindi sentences - is full of short function words (है, को,
/// में, नहीं). So the share of those words separates the two.
///
/// THE RULES.
///   1. A window with at least [minWords] words is English when its density
///      is below [englishBelow], Hindi otherwise.
///   2. A shorter window with at least one word follows the whole note: the
///      note is English when it has at least [minWords] words in all and its
///      density is below [englishBelow].
///   3. A window with no words stays Hindi: there is nothing to re-decode.
abstract final class LanguageRouter {
  /// From `route.py`, exactly. थे and तो are left out on purpose: they are
  /// how IndicConformer spells English "the" and "to".
  static final Set<String> hindiFunctionWords = Set<String>.unmodifiable(
    'है हैं था थी हो को के की का में से पे पर और कि जो वो ये यह वह नहीं क्या '
            'हम मैं मेरे मेरा मेरी आप तुम कुछ भी करना करके कर रहा रहे रही गया '
            'लिए बाद फिर अभी सकते सकता जाना होगा हूँ हुआ या अगर लेकिन क्योंकि '
            'उसके इसको उनके हमारा बहुत सब एक'
        .split(' '),
  );

  static const double englishBelow = 0.08;
  static const int minWords = 5;

  static final RegExp _space = RegExp(r'\s+');

  /// Anything that is not a letter, a combining mark or a digit, at either
  /// end of a token: `है,` counts as `है`, and `—` is not a word.
  static final RegExp _edge = RegExp(
    r'^[^\p{L}\p{M}\p{N}]+|[^\p{L}\p{M}\p{N}]+$',
    unicode: true,
  );

  /// The words of [text]: split on whitespace as `route.py` does, with
  /// punctuation trimmed from each end and punctuation-only tokens dropped.
  /// Numbers are words.
  static List<String> words(String text) => <String>[
        for (final token in text.split(_space))
          if (token.replaceAll(_edge, '') case final word when word.isNotEmpty)
            word,
      ];

  static LanguageStats statsOf(String text) {
    final all = words(text);
    return LanguageStats(
      words: all.length,
      hindiWords: all.where(hindiFunctionWords.contains).length,
    );
  }

  static bool _isEnglish(LanguageStats stats) =>
      stats.words >= minWords && stats.density < englishBelow;

  /// The language of each window, from IndicConformer's text for it.
  static List<WindowLanguage> route(List<String> windowTexts) {
    final stats = <LanguageStats>[for (final text in windowTexts) statsOf(text)];
    final note = stats.fold(LanguageStats.zero, (sum, s) => sum + s);
    final noteEnglish = _isEnglish(note);
    return <WindowLanguage>[
      for (final window in stats)
        if (window.words == 0)
          WindowLanguage.hindi
        else if (window.words >= minWords)
          _isEnglish(window) ? WindowLanguage.english : WindowLanguage.hindi
        else
          noteEnglish ? WindowLanguage.english : WindowLanguage.hindi,
    ];
  }
}
