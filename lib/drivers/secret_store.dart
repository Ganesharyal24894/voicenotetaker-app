/// Where a password is allowed to live.
///
/// The app already has a [FileStore] and writes its settings as small JSON
/// files. A sending account's password may NOT go there: the files sit in the
/// app's own directory, which is readable on a rooted phone, is included in
/// `adb backup`-style copies, and is plain text in a crash-time device dump.
/// The same goes for `SharedPreferences`, which is an XML file with no
/// protection at all on Android.
///
/// So the password goes behind this seam, and the only implementation puts it
/// in the platform's keystore: the iOS/macOS Keychain, and on Android an
/// AES key held in the hardware-backed `AndroidKeyStore` that encrypts the
/// value before `EncryptedSharedPreferences` writes it. Neither is readable by
/// another app, and neither comes out in a backup.
///
/// Abstract, like every other driver, so the outbox's tests never touch a
/// keychain.
library;

/// A handful of named secrets.
abstract class SecretStore {
  /// The value under [key], or null when there is none. Never throws: a
  /// keystore that cannot be opened reads as empty, which leaves the feature
  /// unconfigured rather than crashing the app.
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

/// A [SecretStore] in memory: for tests, and for a platform with no keystore
/// wired in. Nothing written here survives the process, which is the point.
class MemorySecretStore implements SecretStore {
  MemorySecretStore([Map<String, String>? initial])
      : _values = <String, String>{...?initial};

  final Map<String, String> _values;

  /// What is held, for a test to assert on.
  Map<String, String> get values => Map<String, String>.unmodifiable(_values);

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}
