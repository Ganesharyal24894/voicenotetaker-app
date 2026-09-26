import 'dart:async';
import 'dart:typed_data';

import 'package:voicenotetaker_app/drivers/email_sender.dart';
import 'package:voicenotetaker_app/drivers/file_store.dart';
import 'package:voicenotetaker_app/drivers/haptics.dart';
import 'package:voicenotetaker_app/drivers/network_status.dart';
import 'package:voicenotetaker_app/drivers/secret_store.dart';
import 'package:voicenotetaker_app/model/assistant/assistant_message.dart';

/// An [EmailSender] that never opens a socket and remembers everything it was
/// asked to send.
///
/// The whole privacy claim rests on this: [sent] is every byte that would have
/// left the phone, and a test can assert there is nothing in it but the
/// instruction.
class RecordingEmailSender implements EmailSender {
  RecordingEmailSender({List<EmailResult>? results})
      : _results = <EmailResult>[...?results];

  final List<EmailResult> _results;

  /// Every message, oldest first.
  final List<AssistantMessage> sent = <AssistantMessage>[];

  /// The account each send was made with, for asserting the password never
  /// changes hands anywhere else.
  final List<SmtpAccount> accounts = <SmtpAccount>[];

  /// Completed by hand when [holdOpen] is set, so a test can look at the
  /// outbox WHILE a send is on the wire.
  Completer<void>? inFlight;
  bool holdOpen = false;

  /// What the next send answers. Consumed in order; the last one repeats.
  void willReturn(List<EmailResult> results) {
    _results
      ..clear()
      ..addAll(results);
  }

  int get sendCount => sent.length;

  @override
  Future<EmailResult> send(AssistantMessage message, SmtpAccount account) async {
    sent.add(message);
    accounts.add(account);
    if (holdOpen) {
      final gate = Completer<void>();
      inFlight = gate;
      await gate.future;
    }
    if (_results.isEmpty) return const EmailResult.sent();
    return _results.length == 1 ? _results.first : _results.removeAt(0);
  }
}

/// A [SecretStore] in memory that remembers every call it was asked to make.
///
/// The counters are the point: "a launch with the feature off does not open the
/// keystore" is a claim about calls that did NOT happen, and
/// [MemorySecretStore] cannot show that.
class RecordingSecretStore implements SecretStore {
  RecordingSecretStore([Map<String, String>? initial])
      : _values = <String, String>{...?initial};

  final Map<String, String> _values;

  final List<String> reads = <String>[];
  final List<String> writes = <String>[];
  final List<String> deletes = <String>[];

  /// What is held, for a test to assert on.
  Map<String, String> get values => Map<String, String>.unmodifiable(_values);

  /// Whether anything at all has been asked of the keystore.
  bool get wasTouched =>
      reads.isNotEmpty || writes.isNotEmpty || deletes.isNotEmpty;

  void forgetCalls() {
    reads.clear();
    writes.clear();
    deletes.clear();
  }

  @override
  Future<String?> read(String key) async {
    reads.add(key);
    return _values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writes.add(key);
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deletes.add(key);
    _values.remove(key);
  }
}

/// A [NetworkStatus] a test can switch by hand.
class FakeNetwork implements NetworkStatus {
  FakeNetwork([this.kind = NetworkKind.unmetered]);

  NetworkKind kind;
  final StreamController<NetworkKind> _changes =
      StreamController<NetworkKind>.broadcast();

  /// Whether anything is subscribed. "A feature that is off leaves no live
  /// connectivity subscription behind" is a claim about exactly this.
  bool get isWatched => _changes.hasListener;

  void go(NetworkKind next) {
    kind = next;
    _changes.add(next);
  }

  @override
  Future<NetworkKind> current() async => kind;

  @override
  Stream<NetworkKind> get changes => _changes.stream;

  Future<void> close() => _changes.close();
}

/// Counts buzzes.
class FakeHaptics implements Haptics {
  final List<BuzzPattern> buzzes = <BuzzPattern>[];

  @override
  Future<void> buzz(BuzzPattern pattern) async => buzzes.add(pattern);
}

/// A [FileStore] in a map. Only the handful of methods the assistant's stores
/// use do anything; the rest throw, so a test fails loudly if this feature
/// ever starts streaming files about.
class MemoryFileStore implements FileStore {
  final Map<String, Uint8List> files = <String, Uint8List>{};

  /// How many times each path was written, for asserting the outbox persists
  /// on every change.
  final Map<String, int> writes = <String, int>{};

  /// Paths whose writes throw, for "the disk is full" .
  final Set<String> unwritable = <String>{};

  /// Every path anything was asked about, in order - `read`, `stat` and
  /// `exists` alike. For asserting which files a launch does NOT open.
  final List<String> reads = <String>[];

  String? textOf(String path) {
    final bytes = files[path];
    return bytes == null ? null : String.fromCharCodes(bytes);
  }

  @override
  Future<void> writeBytes(String path, List<int> bytes) async {
    if (unwritable.contains(path)) {
      throw const FileSystemExceptionStub('no space');
    }
    files[path] = Uint8List.fromList(bytes);
    writes[path] = (writes[path] ?? 0) + 1;
  }

  @override
  Future<Uint8List> read(String path) async {
    reads.add(path);
    final bytes = files[path];
    if (bytes == null) throw const FileSystemExceptionStub('no such file');
    return bytes;
  }

  @override
  Future<FileInfo?> stat(String path) async {
    reads.add(path);
    final bytes = files[path];
    if (bytes == null) return null;
    return FileInfo(
      path: path,
      sizeBytes: bytes.length,
      modifiedAt: DateTime(2026, 1, 1),
    );
  }

  @override
  Future<bool> exists(String path) async {
    reads.add(path);
    return files.containsKey(path);
  }

  @override
  Future<void> delete(String path) async {
    files.remove(path);
  }

  @override
  String join(String directory, String name) =>
      directory.isEmpty ? name : '$directory/$name';

  @override
  Future<FileSink> openWrite(String path) => throw UnimplementedError();

  @override
  Future<FileSink> openAppend(String path) => throw UnimplementedError();

  @override
  Future<void> move(String from, String to) => throw UnimplementedError();

  @override
  Future<Uint8List> readRange(String path, int start, int end) =>
      throw UnimplementedError();

  @override
  Future<void> patchBytes(String path, int offset, List<int> bytes) =>
      throw UnimplementedError();

  @override
  Future<List<String>> list(String directory) => throw UnimplementedError();
}

/// A stand-in so the fake store can fail without importing `dart:io`.
class FileSystemExceptionStub implements Exception {
  const FileSystemExceptionStub(this.message);

  final String message;

  @override
  String toString() => 'FileSystemExceptionStub($message)';
}

/// A clock a test winds by hand.
class FakeClock {
  FakeClock([DateTime? start]) : now = start ?? DateTime(2026, 9, 18, 14, 32);

  DateTime now;

  DateTime call() => now;

  void advance(Duration by) => now = now.add(by);
}

/// The account the tests use. The password is obviously not a real one.
const SmtpAccount testAccount = SmtpAccount(
  address: 'giftinjsr@gmail.com',
  password: 'not-a-real-app-password',
);

const String testAssistant = 'bo1dx6@mail.instinct.com';
