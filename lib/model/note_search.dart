/// Matching a typed search against a note.
///
/// PURE. Case-insensitive for Latin script, and SAFE FOR DEVANAGARI: nothing
/// is stripped or folded that would change a Hindi word - no accent removal,
/// no ASCII-only lower-casing. The one normalisation beyond case is the nukta
/// letters, which a keyboard may type as one code point (ज़, U+095B) and the
/// speech model may write as two (ज + ़): both sides are decomposed so the
/// two spellings match.
abstract final class NoteSearch {
  /// Precomposed Devanagari letters and their canonical decompositions.
  static const Map<String, String> _decompose = <String, String>{
    'ऩ': 'ऩ', // ऩ
    'ऱ': 'ऱ', // ऱ
    'ऴ': 'ऴ', // ऴ
    'क़': 'क़', // क़
    'ख़': 'ख़', // ख़
    'ग़': 'ग़', // ग़
    'ज़': 'ज़', // ज़
    'ड़': 'ड़', // ड़
    'ढ़': 'ढ़', // ढ़
    'फ़': 'फ़', // फ़
    'य़': 'य़', // य़
  };

  static final RegExp _space = RegExp(r'\s+');

  /// [text] as it is compared: lower case, nukta letters decomposed, runs of
  /// whitespace collapsed, ends trimmed.
  static String normalize(String text) {
    final buffer = StringBuffer();
    for (final rune in text.toLowerCase().runes) {
      final char = String.fromCharCode(rune);
      buffer.write(_decompose[char] ?? char);
    }
    return buffer.toString().replaceAll(_space, ' ').trim();
  }

  /// True when [query] is blank, or appears in any of [fields].
  static bool matches(String query, Iterable<String> fields) {
    final needle = normalize(query);
    if (needle.isEmpty) return true;
    for (final field in fields) {
      if (normalize(field).contains(needle)) return true;
    }
    return false;
  }
}
