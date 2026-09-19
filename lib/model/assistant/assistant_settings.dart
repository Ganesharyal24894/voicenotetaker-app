/// What the user chose about speaking to their assistant - everything except
/// the password.
///
/// PURE data, read and written by `services/assistant/assistant_settings_store`
/// as one small JSON file beside the app's other settings.
///
/// OFF BY DEFAULT. A fresh install has [enabled] false and no account, and in
/// that state nothing in this feature can reach the network at all.
library;

import 'wake_phrase.dart';

class AssistantSettings {
  const AssistantSettings({
    this.enabled = false,
    this.wakePhrase = WakePhraseDetector.defaultPhrase,
    this.assistantAddress = defaultAssistantAddress,
  });

  /// Where an instruction goes: the user's assistant's own mailbox. It replies
  /// to mail from any address once the address has been authorised once, from
  /// the user's chat with it - so there is no verification step on this side
  /// beyond the "send a test email" button.
  ///
  /// A default rather than a constant: the address is per-user, and the setup
  /// screen offers this one prefilled and lets it be changed.
  static const String defaultAssistantAddress = 'bo1dx6@mail.instinct.com';

  /// The Gmail account the user set aside for this. Prefilled in setup; the
  /// password that goes with it is asked for separately and never comes near
  /// this file.
  static const String defaultSenderAddress = 'giftinjsr@gmail.com';

  /// Whether a note that begins with the wake phrase is emailed at all.
  /// FALSE UNTIL THE USER TURNS IT ON, and turning it on without an account
  /// set up does nothing.
  final bool enabled;

  /// What the user says to address the assistant.
  final String wakePhrase;

  final String assistantAddress;

  /// The detector these settings imply.
  WakePhraseDetector get detector => WakePhraseDetector(phrase: wakePhrase);

  /// Whether the phrase and the address are usable. A screen can say "finish
  /// setting this up" without trying a send.
  bool get isComplete =>
      detector.isUsable && assistantAddress.contains('@');

  AssistantSettings copyWith({
    bool? enabled,
    String? wakePhrase,
    String? assistantAddress,
  }) =>
      AssistantSettings(
        enabled: enabled ?? this.enabled,
        wakePhrase: wakePhrase ?? this.wakePhrase,
        assistantAddress: assistantAddress ?? this.assistantAddress,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'version': 1,
        'enabled': enabled,
        'wakePhrase': wakePhrase,
        'assistantAddress': assistantAddress,
      };

  /// The settings in [json], or the defaults - which is to say OFF - when it
  /// is anything this build does not recognise. A file that cannot be read can
  /// only ever fail closed.
  static AssistantSettings fromJson(Object? json) {
    if (json is! Map<String, Object?> || json['version'] != 1) {
      return const AssistantSettings();
    }
    final phrase = json['wakePhrase'];
    final address = json['assistantAddress'];
    return AssistantSettings(
      enabled: json['enabled'] == true,
      wakePhrase: phrase is String && phrase.trim().isNotEmpty
          ? phrase
          : WakePhraseDetector.defaultPhrase,
      assistantAddress: address is String && address.isNotEmpty
          ? address
          : defaultAssistantAddress,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AssistantSettings &&
      other.enabled == enabled &&
      other.wakePhrase == wakePhrase &&
      other.assistantAddress == assistantAddress;

  @override
  int get hashCode => Object.hash(enabled, wakePhrase, assistantAddress);

  @override
  String toString() =>
      'AssistantSettings(enabled: $enabled, phrase: $wakePhrase)';
}
