import 'dart:convert';

import '../../drivers/file_store.dart';

/// What always-listening remembers between launches.
class ContinuousSettings {
  const ContinuousSettings({
    this.enabled = false,
    this.deviceId,
    this.deviceName,
  });

  /// Whether the user turned always-listening on.
  final bool enabled;

  /// The device the app last connected to, so it can be reached again after
  /// a restart without a scan. Platform-scoped: a MAC on Android, a UUID on
  /// iOS.
  final String? deviceId;
  final String? deviceName;

  ContinuousSettings copyWith({
    bool? enabled,
    String? deviceId,
    String? deviceName,
  }) =>
      ContinuousSettings(
        enabled: enabled ?? this.enabled,
        deviceId: deviceId ?? this.deviceId,
        deviceName: deviceName ?? this.deviceName,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'version': 1,
        'enabled': enabled,
        'deviceId': deviceId,
        'deviceName': deviceName,
      };

  /// The settings in [json]; defaults for anything unreadable. Never throws.
  static ContinuousSettings fromJson(Object? json) {
    if (json is! Map<String, Object?> || json['version'] != 1) {
      return const ContinuousSettings();
    }
    final enabled = json['enabled'];
    final deviceId = json['deviceId'];
    final deviceName = json['deviceName'];
    return ContinuousSettings(
      enabled: enabled is bool && enabled,
      deviceId: deviceId is String && deviceId.isNotEmpty ? deviceId : null,
      deviceName: deviceName is String ? deviceName : null,
    );
  }
}

/// [ContinuousSettings] in one small JSON file.
///
/// Through [FileStore] rather than a preferences plugin: two fields do not
/// justify a new package, and this runs in tests against the in-memory store.
class ContinuousSettingsStore {
  ContinuousSettingsStore({
    required this._fileStore,
    required String directory,
  }) : path = _fileStore.join(directory, fileName);

  static const String fileName = 'continuous-settings.json';

  final FileStore _fileStore;
  final String path;

  /// The saved settings, or defaults when there are none or they are damaged.
  Future<ContinuousSettings> load() async {
    try {
      if (await _fileStore.stat(path) == null) {
        return const ContinuousSettings();
      }
      final bytes = await _fileStore.read(path);
      return ContinuousSettings.fromJson(jsonDecode(utf8.decode(bytes)));
    } on Object {
      return const ContinuousSettings();
    }
  }

  Future<void> save(ContinuousSettings settings) => _fileStore.writeBytes(
        path,
        utf8.encode(jsonEncode(settings.toJson())),
      );
}
