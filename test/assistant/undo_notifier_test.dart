import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/controller/assistant_controller.dart';
import 'package:voicenotetaker_app/drivers/secret_store.dart';
import 'package:voicenotetaker_app/drivers/undo_notification.dart';
import 'package:voicenotetaker_app/model/assistant/assistant_send.dart';
import 'package:voicenotetaker_app/services/assistant/undo_notifier.dart';

import 'assistant_fakes.dart';

/// The Undo notification: up only while the app is away and the window is
/// open, down the moment either stops being true.
class FakeUndoNotifications implements UndoNotifications {
  final List<String> shown = <String>[];
  final List<DateTime> readyAts = <DateTime>[];
  int hides = 0;
  void Function(String noteId)? tap;

  /// How many times the platform channel was claimed. On Android [listen] sets
  /// a method-call handler and makes a `takePendingUndo` round trip, so "it was
  /// never called" is a real claim about a feature that is off.
  int listens = 0;

  bool get isUp => shown.length > hides;

  @override
  void listen(void Function(String noteId) onUndo) {
    listens++;
    tap = onUndo;
  }

  @override
  Future<void> show({
    required String noteId,
    required String instruction,
    required DateTime readyAt,
  }) async {
    shown.add(instruction);
    readyAts.add(readyAt);
  }

  @override
  Future<void> hide() async => hides++;
}

void main() {
  late MemoryFileStore files;
  late RecordingEmailSender sender;
  late MemorySecretStore secrets;
  late FakeNetwork network;
  late FakeClock clock;
  late FakeUndoNotifications notifications;

  const directory = '/support';
  const note = '/recordings/a.wav';
  const instruction = 'Move the Thursday review to Friday';

  setUp(() {
    files = MemoryFileStore();
    sender = RecordingEmailSender();
    secrets = MemorySecretStore();
    network = FakeNetwork();
    clock = FakeClock();
    notifications = FakeUndoNotifications();
  });

  tearDown(() async => network.close());

  Future<AssistantController> ready() async {
    final controller = AssistantController(
      fileStore: files,
      directory: directory,
      sender: sender,
      secrets: secrets,
      network: network,
      clock: clock.call,
    );
    addTearDown(controller.dispose);
    await controller.initialise();
    await controller.saveAccount(
      address: testAccount.address,
      password: testAccount.password,
    );
    await controller.setEnabled(true);
    return controller;
  }

  Future<AssistantSend?> speak(AssistantController controller) =>
      controller.noteTranscribed(
        noteId: note,
        transcript: 'Instinct, $instruction',
        spokenAt: clock.now,
      );

  test('nothing is posted while the app is on screen', () async {
    final controller = await ready();
    final notifier = AssistantUndoNotifier(
      assistant: controller,
      notifications: notifications,
    );
    addTearDown(notifier.dispose);

    await speak(controller);

    expect(notifications.shown, isEmpty);
  });

  test('with the app away it goes up, with the instruction and the deadline',
      () async {
    final controller = await ready();
    final notifier = AssistantUndoNotifier(
      assistant: controller,
      notifications: notifications,
    );
    addTearDown(notifier.dispose);
    notifier.setForeground(false);

    final entry = await speak(controller);

    expect(notifications.shown, <String>[instruction]);
    // The outbox's own deadline, not a second one that could drift.
    expect(notifications.readyAts.single, entry!.readyAt);
    expect(notifications.isUp, isTrue);
  });

  test('it is posted once, however often the controller notifies', () async {
    final controller = await ready();
    final notifier = AssistantUndoNotifier(
      assistant: controller,
      notifications: notifications,
    );
    addTearDown(notifier.dispose);
    notifier.setForeground(false);

    await speak(controller);
    // Any change at all - the settings screen's switch, a second note that is
    // not an instruction - must not post it again.
    await controller.setEnabled(true);
    await controller.noteTranscribed(
      noteId: '/recordings/b.wav',
      transcript: 'Nothing for the assistant here',
      spokenAt: clock.now,
    );

    expect(notifications.shown, hasLength(1));
  });

  test('coming back to the app takes it down', () async {
    final controller = await ready();
    final notifier = AssistantUndoNotifier(
      assistant: controller,
      notifications: notifications,
    );
    addTearDown(notifier.dispose);
    notifier.setForeground(false);
    await speak(controller);
    expect(notifications.isUp, isTrue);

    notifier.setForeground(true);

    expect(notifications.isUp, isFalse);
  });

  test('Undo on the notification stops the send', () async {
    final controller = await ready();
    final notifier = AssistantUndoNotifier(
      assistant: controller,
      notifications: notifications,
    );
    addTearDown(notifier.dispose);
    notifier.setForeground(false);
    await speak(controller);

    notifications.tap!(note);
    await pumpEventQueue();

    expect(controller.statusFor(note), AssistantSendStatus.notSent);
    expect(sender.sendCount, 0);
  });

  test('an Undo that arrives after the window changes nothing', () async {
    final controller = await ready();
    final notifier = AssistantUndoNotifier(
      assistant: controller,
      notifications: notifications,
    );
    addTearDown(notifier.dispose);
    notifier.setForeground(false);
    await speak(controller);

    // The window shut while the notification was still on the shade.
    clock.advance(const Duration(seconds: 30));
    notifications.tap!(note);
    await pumpEventQueue();

    expect(controller.statusFor(note), AssistantSendStatus.pendingUndo);
  });

  test('nothing is installed while the feature is off', () async {
    final controller = AssistantController(
      fileStore: files,
      directory: directory,
      sender: sender,
      secrets: secrets,
      network: network,
      clock: clock.call,
    );
    addTearDown(controller.dispose);
    await controller.initialise();

    final notifier = AssistantUndoNotifier(
      assistant: controller,
      notifications: notifications,
    );
    addTearDown(notifier.dispose);

    // The channel is not claimed and no `takePendingUndo` round trip is made
    // for a feature nobody has turned on.
    expect(notifications.listens, 0);
    expect(notifications.tap, isNull);

    await controller.setEnabled(true);

    expect(notifications.listens, 1);
    expect(notifications.tap, isNotNull);
  });

  test('it is claimed once, however often the switch is flipped', () async {
    final controller = await ready();
    final notifier = AssistantUndoNotifier(
      assistant: controller,
      notifications: notifications,
    );
    addTearDown(notifier.dispose);

    await controller.setEnabled(false);
    await controller.setEnabled(true);

    expect(notifications.listens, 1);
  });

  test('switching the feature off takes the notification down', () async {
    final controller = await ready();
    final notifier = AssistantUndoNotifier(
      assistant: controller,
      notifications: notifications,
    );
    addTearDown(notifier.dispose);
    notifier.setForeground(false);
    await speak(controller);
    expect(notifications.isUp, isTrue);

    await controller.setEnabled(false);

    expect(notifications.isUp, isFalse);
  });

  test('being disposed takes it down', () async {
    final controller = await ready();
    final notifier = AssistantUndoNotifier(
      assistant: controller,
      notifications: notifications,
    );
    notifier.setForeground(false);
    await speak(controller);

    notifier.dispose();
    await pumpEventQueue();

    expect(notifications.isUp, isFalse);
  });
}
