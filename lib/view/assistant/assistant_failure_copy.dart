/// The sentence a failed send shows, in the feature's own copy.
///
/// WHY NOT ON THE ENUM. [AssistantFailure] is part of a pure model
/// (`lib/model/assistant/assistant_send.dart`): JSON in and out, no I/O and no
/// words a user reads. The sentences below name Gmail and "the mail server",
/// which is copy and belongs where the feature's other copy lives. The model
/// keeps the enum, the view keeps the words, and deleting the feature deletes
/// the words with it.
///
/// It is its own file rather than another block in `AssistantCopy`, because
/// `assistant_view.dart` is already far too long to add to.
library;

import '../../model/assistant/assistant_send.dart';

extension AssistantFailureMessage on AssistantFailure {
  /// One plain sentence for a screen. No error codes, no host names.
  String get message => switch (this) {
        AssistantFailure.notConfigured =>
          'Set up the sending account before speaking to your assistant.',
        AssistantFailure.signIn =>
          "Gmail didn't accept the app password. Add it again in Settings.",
        AssistantFailure.address =>
          "The assistant's email address was refused. Check it in Settings.",
        AssistantFailure.network =>
          'No connection. This will go as soon as you are back online.',
        AssistantFailure.server =>
          'The mail server would not take it just now. Trying again.',
        AssistantFailure.gaveUp =>
          "This didn't get through. Tap to try again.",
      };
}
