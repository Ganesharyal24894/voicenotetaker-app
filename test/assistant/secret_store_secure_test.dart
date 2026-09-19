// The keystore driver: the one place the sending account's password is
// written down.
//
// There is no keychain on a test host, so this exercises the two things the
// driver is actually responsible for: handing the key and the value to
// `flutter_secure_storage` unchanged, and NEVER letting a keystore failure
// escape. A password that cannot be read must leave the feature unconfigured,
// not take the app down and not appear in an error.
//
// The groups run in the order they are declared, and that order matters: the
// first two use the real method channel, and the third replaces the platform
// with the package's own in-memory one for the rest of the file.
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/email_sender.dart';
import 'package:voicenotetaker_app/drivers/secret_store.dart';
import 'package:voicenotetaker_app/drivers/secret_store_secure.dart';
import 'package:voicenotetaker_app/services/assistant/assistant_account_store.dart';

/// The account these tests save. The password is made up, as every password in
/// this repository is.
const SmtpAccount _account = SmtpAccount(
  address: 'giftinjsr@gmail.com',
  password: 'app-password-1234',
);

const MethodChannel _channel =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const SecretStore store = SecureSecretStore();
  const String key = AssistantAccountStore.key;

  void handler(Future<Object?> Function(MethodCall call)? reply) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, reply);
  }

  group('with no keystore behind it at all', () {
    // No mock handler and no plugin: every call raises
    // MissingPluginException, which is exactly what a platform with the
    // plugin missing would do.
    tearDown(() => handler(null));

    test('reading gives null rather than throwing', () async {
      await expectLater(store.read(key), completion(isNull));
    });

    test('writing and deleting are harmless', () async {
      await expectLater(store.write(key, 'a-secret'), completes);
      await expectLater(store.delete(key), completes);
    });

    test('an account store on top of it reads as not set up', () async {
      final accounts = AssistantAccountStore(secrets: store);
      expect(await accounts.load(), isNull);
    });
  });

  group('a keystore that refuses to open', () {
    setUp(() {
      handler((call) async => throw PlatformException(
            code: 'Failed',
            message: 'Keystore operation failed',
            // The real plugin puts the underlying error here. Nothing in the
            // driver may pass it on.
            details: 'android.security.KeyStoreException: the-password-maybe',
          ));
    });
    tearDown(() => handler(null));

    test('reading is "nothing set up yet", not a crash', () async {
      await expectLater(store.read(key), completion(isNull));
    });

    test('writing does not throw, so setup fails quietly rather than loudly',
        () async {
      await expectLater(store.write(key, 'a-secret'), completes);
    });

    test('deleting does not throw', () async {
      await expectLater(store.delete(key), completes);
    });

    test('the feature is simply unconfigured', () async {
      final accounts = AssistantAccountStore(secrets: store);
      await accounts.save(_account);
      expect(await accounts.load(), isNull);
    });
  });

  group('against the package own in-memory keystore', () {
    late Map<String, String> keystore;

    setUp(() {
      keystore = <String, String>{};
      FlutterSecureStorage.setMockInitialValues(keystore);
    });

    test('a value written is the value read back, byte for byte', () async {
      await store.write(key, '{"address":"me@example.com"}');
      expect(await store.read(key), '{"address":"me@example.com"}');
    });

    test('the key it is given is the key it uses', () async {
      await store.write(key, 'v');
      expect(await store.read('some.other.key'), isNull);
    });

    test('delete removes it and reading afterwards is null', () async {
      await store.write(key, 'v');
      await store.delete(key);
      expect(await store.read(key), isNull);
    });

    test('a second write replaces the first, leaving no copy', () async {
      await store.write(key, 'first');
      await store.write(key, 'second');
      expect(await store.read(key), 'second');
    });

    test('a whole account round-trips through the real driver', () async {
      final accounts = AssistantAccountStore(secrets: store);
      await accounts.save(_account);
      final loaded = await accounts.load();
      expect(loaded?.address, 'giftinjsr@gmail.com');
      expect(loaded?.password, 'app-password-1234');
      expect(loaded?.host, 'smtp.gmail.com');
      expect(loaded?.port, 465);
    });
  });
}
