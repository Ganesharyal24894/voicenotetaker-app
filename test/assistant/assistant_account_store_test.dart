import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/email_sender.dart';
import 'package:voicenotetaker_app/drivers/secret_store.dart';
import 'package:voicenotetaker_app/services/assistant/assistant_account_store.dart';

import 'assistant_fakes.dart';

const String _key = AssistantAccountStore.key;

/// A store over a keystore a test can look inside.
({AssistantAccountStore store, MemorySecretStore secrets}) _open([
  Map<String, String>? initial,
]) {
  final secrets = MemorySecretStore(initial);
  return (store: AssistantAccountStore(secrets: secrets), secrets: secrets);
}

/// A keystore already holding [raw] under the one key this app uses.
({AssistantAccountStore store, MemorySecretStore secrets}) _holding(String raw) =>
    _open(<String, String>{_key: raw});

void main() {
  group('an empty keystore', () {
    test('loads as no account at all', () async {
      expect(await _open().store.load(), isNull);
    });

    test('an empty string under the key is also no account', () async {
      expect(await _holding('').store.load(), isNull);
    });

    test('a value under some other key is ignored', () async {
      final it = _open(<String, String>{'something.else': '{"a":1}'});
      expect(await it.store.load(), isNull);
    });
  });

  group('save and load', () {
    test('round-trips every field', () async {
      final it = _open();
      const account = SmtpAccount(
        address: 'giftinjsr@gmail.com',
        password: 'not-a-real-app-password',
        host: 'smtp.example.org',
        port: 2525,
        useSsl: false,
      );
      await it.store.save(account);
      final back = await it.store.load();
      expect(back, isNotNull);
      expect(back!.address, 'giftinjsr@gmail.com');
      expect(back.password, 'not-a-real-app-password');
      expect(back.host, 'smtp.example.org');
      expect(back.port, 2525);
      expect(back.useSsl, isFalse);
    });

    test('the shared test account round-trips with its Gmail defaults',
        () async {
      final it = _open();
      await it.store.save(testAccount);
      final back = await it.store.load();
      expect(back, isNotNull);
      expect(back!.address, testAccount.address);
      expect(back.password, testAccount.password);
      expect(back.host, SmtpAccount.defaultHost);
      expect(back.port, SmtpAccount.defaultPort);
      expect(back.useSsl, isTrue);
    });

    test('a later save replaces the earlier account', () async {
      final it = _open();
      await it.store.save(testAccount);
      await it.store.save(testAccount.copyWith(address: 'other@example.org'));
      final back = await it.store.load();
      expect(back!.address, 'other@example.org');
      expect(it.secrets.values, hasLength(1));
    });
  });

  group('defaults fill in what an old value is missing', () {
    test('no host, port or ssl means Gmail over implicit TLS', () async {
      final it = _holding(jsonEncode(<String, Object?>{
        'address': 'giftinjsr@gmail.com',
        'password': 'not-a-real-app-password',
      }));
      final back = await it.store.load();
      expect(back, isNotNull);
      expect(back!.host, SmtpAccount.defaultHost);
      expect(back.host, 'smtp.gmail.com');
      expect(back.port, SmtpAccount.defaultPort);
      expect(back.port, 465);
      expect(back.useSsl, isTrue);
    });

    test('a blank or wrongly typed host, port or ssl falls back too', () async {
      final it = _holding(jsonEncode(<String, Object?>{
        'address': 'giftinjsr@gmail.com',
        'password': 'not-a-real-app-password',
        'host': '',
        'port': '465',
        'ssl': 'yes',
      }));
      final back = await it.store.load();
      expect(back!.host, SmtpAccount.defaultHost);
      expect(back.port, SmtpAccount.defaultPort);
      expect(back.useSsl, isTrue);
    });

    test('a port of zero or below falls back to the default', () async {
      final it = _holding(jsonEncode(<String, Object?>{
        'address': 'giftinjsr@gmail.com',
        'password': 'not-a-real-app-password',
        'port': 0,
      }));
      expect((await it.store.load())!.port, SmtpAccount.defaultPort);
    });

    test('ssl false is kept, because it was asked for', () async {
      final it = _holding(jsonEncode(<String, Object?>{
        'address': 'giftinjsr@gmail.com',
        'password': 'not-a-real-app-password',
        'ssl': false,
      }));
      expect((await it.store.load())!.useSsl, isFalse);
    });
  });

  group('clear', () {
    test('forgets the account and leaves nothing behind', () async {
      final it = _open();
      await it.store.save(testAccount);
      expect(it.secrets.values, hasLength(1));
      await it.store.clear();
      expect(it.secrets.values, isEmpty);
      expect(await it.store.load(), isNull);
    });

    test('clearing an empty keystore is harmless', () async {
      final it = _open();
      await it.store.clear();
      expect(await it.store.load(), isNull);
    });
  });

  group('junk in the keystore reads as not set up', () {
    test('not JSON at all', () async {
      expect(await _holding('giftinjsr@gmail.com / hunter2').store.load(),
          isNull);
      expect(await _holding('{').store.load(), isNull);
    });

    test('JSON that is not a map', () async {
      expect(await _holding('[]').store.load(), isNull);
      expect(await _holding('"an account"').store.load(), isNull);
      expect(await _holding('7').store.load(), isNull);
      expect(await _holding('null').store.load(), isNull);
    });

    test('a map with no address or no password', () async {
      expect(
        await _holding(jsonEncode(
                <String, Object?>{'password': 'not-a-real-app-password'}))
            .store
            .load(),
        isNull,
      );
      expect(
        await _holding(
                jsonEncode(<String, Object?>{'address': 'giftinjsr@gmail.com'}))
            .store
            .load(),
        isNull,
      );
      expect(await _holding('{}').store.load(), isNull);
    });

    test('an address or password of the wrong type', () async {
      expect(
        await _holding(jsonEncode(<String, Object?>{
          'address': 7,
          'password': 'not-a-real-app-password',
        })).store.load(),
        isNull,
      );
      expect(
        await _holding(jsonEncode(<String, Object?>{
          'address': 'giftinjsr@gmail.com',
          'password': null,
        })).store.load(),
        isNull,
      );
    });

    test('an incomplete account: no @, or an empty password', () async {
      expect(
        await _holding(jsonEncode(<String, Object?>{
          'address': 'giftinjsr',
          'password': 'not-a-real-app-password',
        })).store.load(),
        isNull,
      );
      expect(
        await _holding(jsonEncode(<String, Object?>{
          'address': 'giftinjsr@gmail.com',
          'password': '',
        })).store.load(),
        isNull,
      );
    });
  });

  group('the password lives in exactly one place', () {
    test('one key, one value, and the key is the documented one', () async {
      final it = _open();
      await it.store.save(testAccount);
      expect(it.secrets.values, hasLength(1));
      expect(it.secrets.values.keys.single, AssistantAccountStore.key);
      expect(AssistantAccountStore.key, 'assistant.smtp.account.v1');
    });

    test('no other entry in the keystore holds the password', () async {
      final it = _open(<String, String>{'unrelated': 'nothing secret here'});
      await it.store.save(testAccount);
      final holdingIt = <String>[
        for (final entry in it.secrets.values.entries)
          if (entry.value.contains(testAccount.password)) entry.key,
      ];
      expect(holdingIt, <String>[AssistantAccountStore.key]);
    });

    test('saving twice does not leave a second copy', () async {
      final it = _open();
      await it.store.save(testAccount);
      await it.store.save(testAccount.copyWith(password: 'another-one'));
      expect(it.secrets.values, hasLength(1));
      expect(it.secrets.values[_key], isNot(contains(testAccount.password)));
    });

    test('SmtpAccount.toString holds neither the password nor the address',
        () async {
      final printed = testAccount.toString();
      expect(printed, isNot(contains(testAccount.password)));
      expect(printed, isNot(contains(testAccount.address)));
      expect(printed, isNot(contains('giftinjsr')));
      expect(printed, contains(SmtpAccount.defaultHost));
    });

    test('a loaded account prints no more than a saved one', () async {
      final it = _open();
      await it.store.save(testAccount);
      final back = await it.store.load();
      expect(back, isNotNull);
      expect(back!.toString(), isNot(contains(testAccount.password)));
      expect(back.toString(), isNot(contains(testAccount.address)));
    });
  });
}
