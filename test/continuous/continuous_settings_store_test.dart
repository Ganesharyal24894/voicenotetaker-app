import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/services/continuous/continuous_settings_store.dart';

import '../view/harness.dart';

/// What always-listening remembers across a restart.
void main() {
  test('nothing saved reads as off, with no device', () async {
    final store = ContinuousSettingsStore(
      fileStore: MemoryFileStore(),
      directory: '/support',
    );
    final settings = await store.load();
    expect(settings.enabled, isFalse);
    expect(settings.deviceId, isNull);
  });

  test('saved settings come back', () async {
    final files = MemoryFileStore();
    final store = ContinuousSettingsStore(fileStore: files, directory: '/s');
    await store.save(const ContinuousSettings(
      enabled: true,
      deviceId: 'EB:6B:5E:4C:33:A3',
      deviceName: 'voiceNotetaker',
    ));

    final again =
        await ContinuousSettingsStore(fileStore: files, directory: '/s').load();
    expect(again.enabled, isTrue);
    expect(again.deviceId, 'EB:6B:5E:4C:33:A3');
    expect(again.deviceName, 'voiceNotetaker');
  });

  test('a damaged or foreign file reads as defaults, never throws', () async {
    final files = MemoryFileStore();
    final store = ContinuousSettingsStore(fileStore: files, directory: '/s');

    files.files[store.path] = utf8.encode('{not json');
    expect((await store.load()).enabled, isFalse);

    files.files[store.path] =
        utf8.encode(jsonEncode(<String, Object?>{'version': 9, 'enabled': true}));
    expect((await store.load()).enabled, isFalse);

    files.files[store.path] = utf8.encode(jsonEncode(
        <String, Object?>{'version': 1, 'enabled': 'yes', 'deviceId': 3}));
    final odd = await store.load();
    expect(odd.enabled, isFalse);
    expect(odd.deviceId, isNull);
  });

  test('copyWith keeps what it is not given', () {
    const base = ContinuousSettings(enabled: true, deviceId: 'a');
    expect(base.copyWith(deviceName: 'n').deviceId, 'a');
    expect(base.copyWith(enabled: false).enabled, isFalse);
  });
}
