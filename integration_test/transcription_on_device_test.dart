import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:voicenotetaker_app/drivers/app_directories.dart';
import 'package:voicenotetaker_app/drivers/file_store.dart';
import 'package:voicenotetaker_app/drivers/process_memory.dart';
import 'package:voicenotetaker_app/drivers/speech_recognizer_sherpa.dart';
import 'package:voicenotetaker_app/services/transcription/speech_model_store.dart';
import 'package:voicenotetaker_app/services/transcription/transcription_service.dart';

/// On-device speech-to-text measurement. PHONE ONLY.
///
/// Wires the service exactly as `main.dart` does - same directories, same
/// driver - and transcribes every WAV in the recordings directory at 2 and 4
/// threads, printing each result. Requires the model to be installed first
/// (see `doc/agentFindings/on-device-stt.md`):
///
/// ```sh
/// flutter test integration_test/transcription_on_device_test.dart -d <id> \
///   --no-uninstall
/// ```
///
/// `--no-uninstall` IS NOT OPTIONAL: without it `flutter test` uninstalls the
/// app afterwards and deletes every recording on the phone with it.
///
/// Optional `--dart-define`s: `STT_THREADS=1,2,4` (default `2,4`),
/// `STT_MATCH=<substring of the file name>`, `STT_PASSES=<n>` (default 2), and
/// `STT_IDLE_S=<seconds>` to keep sampling resident memory after the last job,
/// which is how "is the model's memory really given back?" is answered.
///
/// Timings come out of `debugPrint` as `STT ...` lines. The test asserts only
/// that every file produced a result; the numbers are for a person to read.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('transcribe the saved recordings on this phone', (tester) async {
    const fileStore = IoFileStore();
    const directories = PathProviderAppDirectories();
    final documents = await directories.documentsDirectory();
    final support = await directories.supportDirectory();
    final recordings = fileStore.join(documents, 'recordings');

    final service = TranscriptionService(
      fileStore: fileStore,
      models: SpeechModelStore(
        fileStore: fileStore,
        modelsDirectory: fileStore.join(support, 'models'),
      ),
      recognizer: const SherpaOnnxSpeechRecognizer(),
    );

    final status = await service.modelStatus();
    debugPrint(
      'STT model ${status.availability.name} in ${status.directory} '
      '${status.problems}',
    );
    expect(status.isReady, isTrue, reason: status.problems.join('; '));

    final wavs = (await fileStore.list(recordings))
        .where((path) => path.endsWith('.wav'))
        .where(
          (path) => path.contains(const String.fromEnvironment('STT_MATCH')),
        )
        .toList();
    final threadCounts = const String.fromEnvironment(
      'STT_THREADS',
      defaultValue: '2,4',
    ).split(',').map(int.parse).toList();
    expect(wavs, isNotEmpty);

    const passes = int.fromEnvironment('STT_PASSES', defaultValue: 2);
    for (var pass = 1; pass <= passes; pass++) {
      for (final wav in wavs) {
        for (final threads in threadCounts) {
          // runAsync: the real isolate and real file I/O must not run inside
          // the test binding's fake-async zone.
          final result = await tester.runAsync(
            () => service.transcribe(wav, numThreads: threads),
          );
          expect(result, isNotNull);
          debugPrint(
            'STT pass $pass $result '
            'rtf=${result!.realTimeFactor?.toStringAsFixed(3)}',
          );
          debugPrint('STT text: ${result.text}');
        }
      }
    }

    const idleSeconds = int.fromEnvironment('STT_IDLE_S');
    for (var waited = 0; waited <= idleSeconds; waited += 5) {
      debugPrint('STT idle ${waited}s rss ${ProcessMemory.residentKb()} kB');
      if (waited < idleSeconds) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 5)),
        );
      }
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}
