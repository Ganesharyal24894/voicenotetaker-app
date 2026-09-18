import 'package:flutter/foundation.dart';

import '../model/model_download.dart';
import 'app_controller.dart';

/// What a screen that installs speech models needs from the app, and nothing
/// else.
///
/// THE SEAM BETWEEN THE SCREEN AND THE DOWNLOADER, written the same way
/// `SpeakersController` is: every method here has the name and the signature
/// of the [AppController] method behind it, so [AppControllerModels] is plain
/// delegation and the two cannot disagree.
///
/// One status per FEATURE, not per file: the screen asks "does this phone
/// understand Hindi", never "is encoder.int8.onnx there".
abstract interface class ModelsController implements Listenable {
  /// Every model set this build can install, in the order to list them.
  List<ModelInstallStatus> get modelStatuses;

  /// Where one feature's model stands: installed, not installed, downloading
  /// with a progress fraction, or failed with a line saying why.
  ModelInstallStatus modelStatusFor(ModelFeature feature);

  /// Bytes the installed models take up, for a "Storage" line.
  int get installedModelBytes;

  /// Whether the user has allowed downloads on mobile data. False until they
  /// say otherwise, and remembered across restarts.
  bool get downloadOnMobileData;

  Future<void> setDownloadOnMobileData(bool allowed);

  /// Starts (or resumes) the download of one feature's model. Does nothing
  /// when that set is already downloading.
  Future<void> downloadModel(ModelFeature feature);

  /// Stops it and keeps what has arrived, so asking again carries on.
  Future<void> cancelModelDownload(ModelFeature feature);

  /// Removes the set from the phone and frees its bytes.
  Future<void> deleteModel(ModelFeature feature);

  /// Re-reads the disk. Cheap; for a screen being opened.
  Future<void> refreshModels();
}

/// [ModelsController] over the real [AppController]. Plain delegation.
class AppControllerModels implements ModelsController {
  AppControllerModels(this._app);

  final AppController _app;

  @override
  void addListener(VoidCallback listener) => _app.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _app.removeListener(listener);

  @override
  List<ModelInstallStatus> get modelStatuses => _app.modelStatuses;

  @override
  ModelInstallStatus modelStatusFor(ModelFeature feature) =>
      _app.modelStatusFor(feature);

  @override
  int get installedModelBytes => _app.installedModelBytes;

  @override
  bool get downloadOnMobileData => _app.downloadOnMobileData;

  @override
  Future<void> setDownloadOnMobileData(bool allowed) =>
      _app.setDownloadOnMobileData(allowed);

  @override
  Future<void> downloadModel(ModelFeature feature) =>
      _app.downloadModel(feature);

  @override
  Future<void> cancelModelDownload(ModelFeature feature) =>
      _app.cancelModelDownload(feature);

  @override
  Future<void> deleteModel(ModelFeature feature) => _app.deleteModel(feature);

  @override
  Future<void> refreshModels() => _app.refreshModels();
}
