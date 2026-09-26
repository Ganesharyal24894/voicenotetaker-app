import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/assistant/assistant_send.dart';
import 'package:voicenotetaker_app/view/assistant/assistant_failure_copy.dart';

/// The sentence a failed send shows. It used to live on the enum, in a pure
/// model; the words are the view's, so the test is here with the other copy
/// tests.
void main() {
  test('every reason has a plain sentence with no code, host or address', () {
    for (final value in AssistantFailure.values) {
      expect(value.message, isNotEmpty, reason: value.name);
      expect(value.message, isNot(contains('@')), reason: value.name);
      expect(value.message, isNot(contains('.com')), reason: value.name);
      expect(value.message, isNot(contains('smtp')), reason: value.name);
      expect(value.message, isNot(matches(RegExp(r'\d'))), reason: value.name);
    }
  });

  test('the words are exactly what they were, moved and not rewritten', () {
    expect(
      AssistantFailure.notConfigured.message,
      'Set up the sending account before speaking to your assistant.',
    );
    expect(
      AssistantFailure.signIn.message,
      "Gmail didn't accept the app password. Add it again in Settings.",
    );
    expect(
      AssistantFailure.address.message,
      "The assistant's email address was refused. Check it in Settings.",
    );
    expect(
      AssistantFailure.network.message,
      'No connection. This will go as soon as you are back online.',
    );
    expect(
      AssistantFailure.server.message,
      'The mail server would not take it just now. Trying again.',
    );
    expect(
      AssistantFailure.gaveUp.message,
      "This didn't get through. Tap to try again.",
    );
  });
}
