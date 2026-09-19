import 'dart:convert';

import '../../drivers/email_sender.dart';
import '../../drivers/secret_store.dart';

/// The sending account, kept entirely inside the platform keystore.
///
/// WHY ALL OF IT AND NOT JUST THE PASSWORD. The address, the host and the port
/// are not secrets on their own, but the four together are the credential: they
/// are what a reader would need to send mail as the user. Splitting them across
/// two stores would buy nothing and would leave two places to forget to clear
/// when the user taps "Remove account". One key, one JSON value, one delete.
///
/// NOTHING HERE IS EVER LOGGED. [SmtpAccount.toString] omits both the address
/// and the password on purpose, and no method in this file prints.
class AssistantAccountStore {
  const AssistantAccountStore({required SecretStore secrets})
      // A plain field behind a public name, as elsewhere in this app: the
      // parameter is the API and the field is private.
      // ignore: prefer_initializing_formals
      : _secrets = secrets;

  /// The one key this app puts in the keystore.
  static const String key = 'assistant.smtp.account.v1';

  final SecretStore _secrets;

  /// The saved account, or null when there is none - which is the state a
  /// fresh install is in, and the state that keeps the feature off.
  ///
  /// Never throws: a keystore that will not open, or a value that is not the
  /// JSON this build writes, reads as "not set up".
  Future<SmtpAccount?> load() async {
    final raw = await _secrets.read(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, Object?>) return null;
      final address = json['address'];
      final password = json['password'];
      if (address is! String || password is! String) return null;
      final host = json['host'];
      final port = json['port'];
      final account = SmtpAccount(
        address: address,
        password: password,
        host: host is String && host.isNotEmpty ? host : SmtpAccount.defaultHost,
        port: port is int && port > 0 ? port : SmtpAccount.defaultPort,
        useSsl: json['ssl'] is bool ? json['ssl']! as bool : true,
      );
      return account.isComplete ? account : null;
    } on Object {
      return null;
    }
  }

  Future<void> save(SmtpAccount account) => _secrets.write(
        key,
        jsonEncode(<String, Object?>{
          'address': account.address,
          'password': account.password,
          'host': account.host,
          'port': account.port,
          'ssl': account.useSsl,
        }),
      );

  /// Forgets the account. After this the feature cannot send anything, whether
  /// or not it is switched on.
  Future<void> clear() => _secrets.delete(key);
}
