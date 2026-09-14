import 'dart:ui';

/// The platform share sheet, for text.
///
/// Interface first: `share_plus` is named in `share_sheet_share_plus.dart`
/// and nowhere else.
abstract class ShareSheet {
  /// Opens the share sheet with [text].
  ///
  /// [origin] is where the sheet points from on an iPad, in global
  /// coordinates; phones ignore it.
  Future<void> shareText(String text, {String? subject, Rect? origin});
}
