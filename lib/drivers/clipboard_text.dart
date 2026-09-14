import 'package:flutter/services.dart';

/// Plain text in and out of the phone's clipboard.
///
/// Interface first, like every other driver, so the summary flow is tested
/// against a fake and never touches the real clipboard.
abstract class ClipboardText {
  /// The clipboard's text, or null when it holds none.
  Future<String?> read();

  Future<void> write(String text);
}

/// The Flutter framework's clipboard, on Android and iOS alike.
class SystemClipboardText implements ClipboardText {
  const SystemClipboardText();

  @override
  Future<String?> read() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text;
  }

  @override
  Future<void> write(String text) => Clipboard.setData(ClipboardData(text: text));
}
