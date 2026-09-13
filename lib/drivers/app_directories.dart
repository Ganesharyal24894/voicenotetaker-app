import 'package:path_provider/path_provider.dart';

/// Raised when the platform cannot say where the app may write.
class AppDirectoriesException implements Exception {
  const AppDirectoriesException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() =>
      'AppDirectoriesException: $message${cause == null ? '' : ' ($cause)'}';
}

/// Where on this platform the app is allowed to keep files.
///
/// Interface first, like every other driver: the caller gets a plain path
/// string and never learns which package produced it, so swapping
/// `path_provider` out means writing one new class in this directory.
abstract class AppDirectories {
  /// Directory for files the app creates and the user owns.
  ///
  /// Must be a location the OS keeps until the app is uninstalled - a cache
  /// directory is not acceptable, because recordings there are evicted under
  /// storage pressure.
  Future<String> documentsDirectory();

  /// Directory for files the APP needs and the user never sees - downloaded
  /// speech models, for one.
  ///
  /// Kept until uninstall like [documentsDirectory], but not the user's
  /// documents: on iOS it is not exposed through the Files app, and on
  /// Android it is the app's private `files` directory, which is where
  /// `adb shell run-as` can place a model during development.
  Future<String> supportDirectory();
}

/// `path_provider` implementation.
///
/// On Android this is the app's private `app_flutter` directory, on iOS the
/// app's `Documents` directory; neither is a cache, so recordings survive a
/// restart and are only removed when the app is uninstalled.
class PathProviderAppDirectories implements AppDirectories {
  const PathProviderAppDirectories();

  @override
  Future<String> documentsDirectory() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      return directory.path;
    } on Object catch (error) {
      throw AppDirectoriesException(
        'the platform did not provide a documents directory',
        error,
      );
    }
  }

  @override
  Future<String> supportDirectory() async {
    try {
      final directory = await getApplicationSupportDirectory();
      return directory.path;
    } on Object catch (error) {
      throw AppDirectoriesException(
        'the platform did not provide a support directory',
        error,
      );
    }
  }
}
