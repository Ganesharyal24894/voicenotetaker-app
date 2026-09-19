/// [SecretStore] in the platform's own keystore.
///
/// `flutter_secure_storage` (BSD-3-Clause) is the one package here that is
/// allowed to hold the sending account's password. On Android it encrypts with
/// an AES-GCM key wrapped by an RSA key that lives in the hardware-backed
/// `AndroidKeyStore` and never leaves it; on iOS it is the Keychain. Named in
/// this file and nowhere else.
library;

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secret_store.dart';

class SecureSecretStore implements SecretStore {
  const SecureSecretStore();

  /// Defaults, which on this version are already AES-GCM under a keystore-held
  /// RSA key. Spelled out rather than left implicit because "what protects the
  /// password" is not a thing to discover from a changelog.
  static const AndroidOptions _android = AndroidOptions();

  /// `first_unlock`, not the default `unlocked`: an instruction can be queued
  /// and sent while the phone is in a pocket, and a Keychain item that is
  /// unreadable with the screen locked would turn every one of those into a
  /// sign-in failure. The item still needs the device to have been unlocked
  /// once since it was powered on, and it is not synchronised to iCloud.
  static const IOSOptions _ios = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock,
  );

  FlutterSecureStorage get _storage =>
      const FlutterSecureStorage(aOptions: _android, iOptions: _ios);

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } on PlatformException {
      // A keystore that will not open reads as "nothing set up yet", which
      // leaves the feature off. It must never take the app down.
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } on PlatformException {
      // Nothing is logged: the value IS the password.
    } on MissingPluginException {
      // Nothing.
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } on PlatformException {
      // Nothing.
    } on MissingPluginException {
      // Nothing.
    }
  }
}
