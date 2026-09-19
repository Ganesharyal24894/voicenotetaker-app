import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/controller/assistant_controller.dart';
import 'package:voicenotetaker_app/drivers/secret_store.dart';
import 'package:voicenotetaker_app/model/assistant/assistant_send.dart';
import 'package:voicenotetaker_app/model/recording_info.dart';

import '../view/harness.dart';
import 'assistant_fakes.dart' as fakes;

/// The one seam between the recorder and the assistant, end to end:
/// `AppController.transcribe()` -> `onTranscriptSaved` ->
/// `AssistantController.noteTranscribed`, wired exactly as `main.dart` wires
/// it.
///
/// Every other assistant test stops at the controller. This one proves the
/// hook is actually joined up, which is the difference between a feature that
/// works and one that only passes its own tests.
void main() {
  setUpAll(registerViewFallbacks);

  late fakes.MemoryFileStore files;
  late fakes.RecordingEmailSender sender;
  late MemorySecretStore secrets;
  late fakes.FakeNetwork network;

  setUp(() {
    files = fakes.MemoryFileStore();
    sender = fakes.RecordingEmailSender();
    secrets = MemorySecretStore();
    network = fakes.FakeNetwork();
  });

  tearDown(() async => network.close());

  /// A recorder and an assistant, joined the way `main.dart` joins them.
  Future<(ViewHarness, AssistantController, RecordingInfo, List<Future<void>>)>
      wired({
    required String said,
    bool enabled = true,
  }) async {
    final heard = <Future<void>>[];
    late final AssistantController assistant;
    final harness = ViewHarness(
      recognizer: ScriptedRecognizer()..texts = <int, String>{0: said},
      onTranscriptSaved: (path, recordedAt, transcript) => heard.add(
        assistant.noteTranscribed(
          noteId: path,
          transcript: transcript.text,
          spokenAt: recordedAt,
        ),
      ),
    );
    addTearDown(harness.dispose);

    assistant = AssistantController(
      fileStore: files,
      directory: '/support',
      sender: sender,
      secrets: secrets,
      network: network,
    );
    addTearDown(assistant.dispose);
    await assistant.initialise();
    await assistant.saveAccount(
      address: fakes.testAccount.address,
      password: fakes.testAccount.password,
    );
    await assistant.setEnabled(enabled);

    await harness.seedRecording(length: const Duration(seconds: 20));
    return (harness, assistant, harness.controller.recordings.single, heard);
  }

  test('a finished transcript that begins with the wake phrase is queued, '
      'with the phrase stripped', () async {
    final (harness, assistant, info, heard) = await wired(
      said: 'Instinct, move the Thursday review to Friday',
    );

    await harness.controller.transcribe(info);
    await Future.wait(heard);

    expect(heard, hasLength(1));
    expect(assistant.statusFor(info.path), AssistantSendStatus.pendingUndo);
    expect(
      assistant.entryFor(info.path)!.instruction,
      'move the Thursday review to Friday',
    );
    // NOTHING HAS LEFT THE PHONE. The undo window is still open.
    expect(sender.sendCount, 0);
  });

  test('the transcript on disk keeps the wake phrase; only the title drops it',
      () async {
    final (harness, assistant, info, heard) = await wired(
      said: 'Instinct, move the Thursday review to Friday',
    );

    await harness.controller.transcribe(info);
    await Future.wait(heard);

    final transcript = harness.controller.transcriptFor(info)!;
    expect(transcript.text, 'Instinct, move the Thursday review to Friday');
    expect(
      assistant.titleFor(transcript.text),
      'move the Thursday review to Friday',
    );
  });

  test('an instruction note is not swept away as an empty note', () async {
    final (harness, assistant, info, heard) = await wired(
      said: 'Instinct, book a cab for six in the morning',
    );

    await harness.controller.transcribe(info);
    await Future.wait(heard);
    // The sweep runs after every transcribe; give it its turn.
    await pumpEventQueue();

    expect(
      harness.controller.recordings.map((note) => note.path),
      contains(info.path),
    );
    expect(await harness.fileStore.exists(info.path), isTrue);
    expect(assistant.statusFor(info.path), AssistantSendStatus.pendingUndo);
  });

  test('an ordinary note is offered and goes nowhere', () async {
    final (harness, assistant, info, heard) = await wired(
      said: 'Move the Thursday review to Friday',
    );

    await harness.controller.transcribe(info);
    await Future.wait(heard);

    expect(heard, hasLength(1));
    expect(assistant.statusFor(info.path), AssistantSendStatus.notSent);
    expect(sender.sendCount, 0);
  });

  test('with the feature off, a wake phrase does nothing at all', () async {
    final (harness, assistant, info, heard) = await wired(
      said: 'Instinct, move the Thursday review to Friday',
      enabled: false,
    );

    await harness.controller.transcribe(info);
    await Future.wait(heard);

    expect(assistant.statusFor(info.path), AssistantSendStatus.notSent);
    expect(sender.sendCount, 0);
  });
}
