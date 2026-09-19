/// Does this note begin with the wake phrase, and what was asked?
///
/// PURE: no I/O, no clock, no platform. The whole question of "did the user
/// address the assistant" lives here, so that it can be argued with in a test
/// instead of on a phone.
///
/// WHY IT HAS TO BE FUZZY. The transcript is whatever the on-device model
/// heard. "Instinct" is not in any of its lexicons: IndicConformer writes it
/// in Devanagari and spells it however it sounded, Parakeet writes it in Latin
/// and often splits or clips it. Every one of these is the same person saying
/// the same word:
///
///     Instinct, remind me at six.
///     instinc remind me at six
///     In stinct, remind me at six.
///     इंस्टिंक्ट, मुझे छह बजे याद दिलाना
///     इनस्टिंक्ट मुझे छह बजे याद दिलाना
///
/// An exact match would find none of them. So the first one, two or three
/// tokens are normalised, joined, and compared to the normalised phrase with a
/// Levenshtein distance.
///
/// WHY IT STILL HAS TO BE STRICT. This is the app's only outbound path. A note
/// that begins "In six minutes..." or "Instant coffee..." must never be
/// emailed to anyone. A bare distance of 2 is not enough on its own -
/// "instant" is two edits from "instinct" - so a candidate must ALSO share a
/// long prefix with the phrase. Speech errors bunch at the end of a word; the
/// beginning is what the listener actually heard.
library;

/// A transcript that began with the wake phrase, split in two.
class WakePhraseMatch {
  const WakePhraseMatch({
    required this.spoken,
    required this.instruction,
  });

  /// The raw leading text that was taken to be the wake phrase, exactly as the
  /// transcript spells it - "Instinct,", "in stinct", "इंस्टिंक्ट". Kept so a
  /// screen can show what was actually heard.
  final String spoken;

  /// The rest of the note, with the wake phrase and any comma after it
  /// removed. This is what gets emailed and what a title shows.
  final String instruction;

  /// False when the user said the wake phrase and nothing else. There is
  /// nothing to send, and nothing to show.
  bool get hasInstruction => instruction.isNotEmpty;

  @override
  String toString() => 'WakePhraseMatch($spoken | $instruction)';
}

/// Matches the wake phrase at the START of a transcript, and only there.
class WakePhraseDetector {
  const WakePhraseDetector({this.phrase = defaultPhrase});

  /// What the user says to address the assistant. A comma is how people write
  /// it and how they say it; [normalise] throws the punctuation away, so the
  /// default and "Instinct" behave identically.
  static const String defaultPhrase = 'Instinct,';

  /// How many edits a candidate may be from the phrase. Two: "instinc" is one
  /// deletion, "instinkt" is one substitution, and a Devanagari spelling is
  /// often both.
  static const int maxEdits = 2;

  /// The shortest prefix a candidate must share with the phrase, as a fraction
  /// of the phrase's length. 5 of the 8 letters of "instinct" - which passes
  /// "instinc" and "instinkt" and refuses "instant", whose agreement with the
  /// phrase runs out after four.
  static const double prefixFraction = 0.6;

  /// How many leading tokens may be joined into one candidate. Three, because
  /// a two-word phrase can be split by the recogniser into three.
  static const int maxTokens = 3;

  final String phrase;

  /// The wake phrase as this detector compares it: normalised, spaces removed.
  String get _target => normalise(phrase).replaceAll(' ', '');

  /// How many leading characters of [_target] a candidate must reproduce.
  int get _prefixNeeded {
    final needed = (_target.length * prefixFraction).ceil();
    // Never fewer than three: a one-letter agreement is not a wake phrase.
    return needed < 3 ? 3 : needed;
  }

  /// Whether this detector can match anything at all. False for a phrase the
  /// user emptied out, which must not turn every note into an instruction.
  bool get isUsable => _target.length >= 3;

  /// The match when [transcript] begins with the wake phrase, else null.
  ///
  /// Never throws, and never looks past the first [maxTokens] tokens: a note
  /// that says "instinct" in the middle of a sentence is a note.
  WakePhraseMatch? match(String transcript) {
    if (!isUsable) return null;
    final tokens = _leadingTokens(transcript);
    if (tokens.isEmpty) return null;

    // The CLOSEST run of leading tokens wins, longest first on a tie. Longest
    // alone is not enough: "in stinct" must beat "in", but "Instinct, go" must
    // NOT beat "Instinct," - joining the next token is within the edit budget
    // whenever that token is a letter or two, and the instruction would go out
    // with its first word eaten.
    var bestTake = 0;
    var bestDistance = maxEdits + 1;
    for (var take = tokens.length; take >= 1; take--) {
      final candidate = tokens
          .take(take)
          .map((token) => normalise(token.text).replaceAll(' ', ''))
          .join();
      if (candidate.isEmpty) continue;
      final distance = _distanceTo(candidate);
      if (distance == null) continue;
      if (distance < bestDistance) {
        bestDistance = distance;
        bestTake = take;
      }
    }
    if (bestTake == 0) return null;

    final end = tokens[bestTake - 1].end;
    return WakePhraseMatch(
      spoken: transcript.substring(tokens.first.start, end).trim(),
      instruction: _tidy(transcript.substring(end)),
    );
  }

  /// How far [candidate] is from the phrase, or null when it is not close
  /// enough to be the phrase at all.
  int? _distanceTo(String candidate) {
    final target = _target;
    // A candidate far longer than the phrase is a different word that happens
    // to start the same way ("instinctively", "instructions").
    if (candidate.length > target.length + maxEdits) return null;
    if (_commonPrefix(candidate, target) < _prefixNeeded) return null;
    final distance = levenshtein(candidate, target);
    return distance <= maxEdits ? distance : null;
  }

  /// The leading tokens of [transcript], with where each one ends, so that the
  /// instruction can be cut from the RAW text rather than rebuilt from the
  /// normalised one.
  List<_Token> _leadingTokens(String transcript) {
    final tokens = <_Token>[];
    var i = 0;
    while (i < transcript.length && tokens.length < maxTokens) {
      while (i < transcript.length && _isSpace(transcript.codeUnitAt(i))) {
        i++;
      }
      if (i >= transcript.length) break;
      final start = i;
      while (i < transcript.length && !_isSpace(transcript.codeUnitAt(i))) {
        i++;
      }
      tokens.add(_Token(transcript.substring(start, i), start, i));
    }
    return tokens;
  }

  static bool _isSpace(int unit) =>
      unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D;

  /// What is left of the note once the wake phrase is off the front: leading
  /// punctuation (the comma the user said, the danda a Hindi model writes) and
  /// whitespace removed, the first letter otherwise untouched.
  static String _tidy(String rest) {
    var i = 0;
    while (i < rest.length) {
      final unit = rest.codeUnitAt(i);
      if (_isSpace(unit) || _isStrippablePunctuation(unit)) {
        i++;
        continue;
      }
      break;
    }
    return rest.substring(i).trim();
  }

  static bool _isStrippablePunctuation(int unit) =>
      unit == 0x2C || // ,
      unit == 0x2E || // .
      unit == 0x21 || // !
      unit == 0x3F || // ?
      unit == 0x3A || // :
      unit == 0x3B || // ;
      unit == 0x2D || // -
      unit == 0x2013 || // en dash
      unit == 0x2014 || // em dash
      unit == 0x0964 || // danda
      unit == 0x0965; // double danda

  static int _commonPrefix(String a, String b) {
    final limit = a.length < b.length ? a.length : b.length;
    var i = 0;
    while (i < limit && a.codeUnitAt(i) == b.codeUnitAt(i)) {
      i++;
    }
    return i;
  }

  /// Lower-cased, punctuation-free, Devanagari folded to the Latin letters it
  /// sounds like, runs of whitespace collapsed to one space.
  ///
  /// Public because the tests compare against it and because a settings screen
  /// can use it to tell the user what their phrase will be heard as.
  static String normalise(String text) {
    final out = StringBuffer();
    var pendingSpace = false;
    for (final rune in text.runes) {
      // The virama: it joins two consonants and sounds like nothing at all.
      if (rune == 0x094D) continue;
      // Nukta, and the combining marks a keyboard can leave behind.
      if (rune == 0x093C || rune == 0x200C || rune == 0x200D) continue;
      // The danda: Devanagari's full stop, which IndicConformer writes at the
      // end of a sentence and sometimes right after the wake phrase. It
      // separates words exactly as a '.' does, and leaving it in would spend
      // one of the two edits the phrase is allowed on a punctuation mark.
      if (rune == 0x0964 || rune == 0x0965) {
        pendingSpace = true;
        continue;
      }
      final mapped = _devanagari[rune];
      if (mapped != null) {
        if (pendingSpace && out.isNotEmpty) out.write(' ');
        pendingSpace = false;
        out.write(mapped);
        continue;
      }
      if (rune < 0x80) {
        final lower = rune >= 0x41 && rune <= 0x5A ? rune + 0x20 : rune;
        final isLetter = lower >= 0x61 && lower <= 0x7A;
        final isDigit = lower >= 0x30 && lower <= 0x39;
        if (isLetter || isDigit) {
          if (pendingSpace && out.isNotEmpty) out.write(' ');
          pendingSpace = false;
          out.writeCharCode(lower);
          continue;
        }
        // Anything else - punctuation, a stray symbol - separates words.
        pendingSpace = true;
        continue;
      }
      // Some other script entirely. Kept as itself so a phrase in it can still
      // be compared, lower-cased where the language has a case.
      if (pendingSpace && out.isNotEmpty) out.write(' ');
      pendingSpace = false;
      out.write(String.fromCharCode(rune).toLowerCase());
    }
    return out.toString();
  }

  /// Edit distance, iterative with one row - the strings here are words, but
  /// there is no reason to allocate a matrix for them.
  static int levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    var previous = List<int>.generate(b.length + 1, (i) => i);
    final current = List<int>.filled(b.length + 1, 0);
    for (var i = 1; i <= a.length; i++) {
      current[0] = i;
      final aUnit = a.codeUnitAt(i - 1);
      for (var j = 1; j <= b.length; j++) {
        final cost = aUnit == b.codeUnitAt(j - 1) ? 0 : 1;
        final deletion = previous[j] + 1;
        final insertion = current[j - 1] + 1;
        final substitution = previous[j - 1] + cost;
        var best = deletion < insertion ? deletion : insertion;
        if (substitution < best) best = substitution;
        current[j] = best;
      }
      previous = List<int>.of(current);
    }
    return previous[b.length];
  }

  /// Devanagari folded to the Latin letters the syllable sounds like, so that
  /// "इंस्टिंक्ट" and "instinct" end up one substitution apart instead of
  /// eight. Deliberately rough: it is a comparison key, not a transliteration
  /// anyone would read.
  ///
  /// Independent vowels and vowel signs both map to their vowel; consonants
  /// carry their inherent "a" only when the virama is absent, which is why
  /// consonants map to the bare consonant here and never to "ka", "ta". The
  /// distance is measured against a normalised English word, which has no
  /// inherent vowels either.
  static const Map<int, String> _devanagari = <int, String>{
    0x0905: 'a', 0x0906: 'a', 0x0907: 'i', 0x0908: 'i', 0x0909: 'u',
    0x090A: 'u', 0x090F: 'e', 0x0910: 'e', 0x0913: 'o', 0x0914: 'o',
    0x093E: 'a', 0x093F: 'i', 0x0940: 'i', 0x0941: 'u', 0x0942: 'u',
    0x0947: 'e', 0x0948: 'e', 0x094B: 'o', 0x094C: 'o',
    // Anusvara and chandrabindu: the nasal that "इंस्टिंक्ट" spells with a dot.
    0x0902: 'n', 0x0901: 'n', 0x0903: 'h',
    0x0915: 'k', 0x0916: 'k', 0x0917: 'g', 0x0918: 'g', 0x0919: 'n',
    0x091A: 'c', 0x091B: 'c', 0x091C: 'j', 0x091D: 'j', 0x091E: 'n',
    0x091F: 't', 0x0920: 't', 0x0921: 'd', 0x0922: 'd', 0x0923: 'n',
    0x0924: 't', 0x0925: 't', 0x0926: 'd', 0x0927: 'd', 0x0928: 'n',
    0x092A: 'p', 0x092B: 'f', 0x092C: 'b', 0x092D: 'b', 0x092E: 'm',
    0x092F: 'y', 0x0930: 'r', 0x0932: 'l', 0x0933: 'l', 0x0935: 'v',
    0x0936: 's', 0x0937: 's', 0x0938: 's', 0x0939: 'h',
    0x0958: 'k', 0x0959: 'k', 0x095A: 'g', 0x095B: 'j', 0x095C: 'd',
    0x095D: 'd', 0x095E: 'f', 0x095F: 'y',
    // Devanagari digits, so a phrase with one in it still compares.
    0x0966: '0', 0x0967: '1', 0x0968: '2', 0x0969: '3', 0x096A: '4',
    0x096B: '5', 0x096C: '6', 0x096D: '7', 0x096E: '8', 0x096F: '9',
  };
}

class _Token {
  const _Token(this.text, this.start, this.end);

  final String text;
  final int start;
  final int end;
}
