import 'dart:ui';

import 'package:share_plus/share_plus.dart';

import 'share_sheet.dart';

/// [ShareSheet] over `share_plus`: `ACTION_SEND` on Android,
/// `UIActivityViewController` on iOS.
class SharePlusShareSheet implements ShareSheet {
  const SharePlusShareSheet();

  @override
  Future<void> shareText(String text, {String? subject, Rect? origin}) async {
    await SharePlus.instance.share(
      ShareParams(text: text, subject: subject, sharePositionOrigin: origin),
    );
  }
}
