import 'dart:ui';

/// The platform share sheet, for text and for files.
///
/// Interface first: `share_plus` is named in `share_sheet_share_plus.dart`
/// and nowhere else.
abstract class ShareSheet {
  /// Opens the share sheet with [text].
  ///
  /// [origin] is where the sheet points from on an iPad, in global
  /// coordinates; phones ignore it.
  Future<void> shareText(String text, {String? subject, Rect? origin});

  /// Opens the share sheet with the files at [paths].
  ///
  /// The files must still exist when the sheet is dismissed: the platform
  /// hands the receiving app a URL, not a copy, and reads it when the user
  /// picks a destination. Nothing is uploaded by this call - the sheet is the
  /// user choosing where their own file goes, AirDrop and Files included.
  Future<void> shareFiles(
    List<String> paths, {
    String? subject,
    String? text,
    Rect? origin,
  });
}
