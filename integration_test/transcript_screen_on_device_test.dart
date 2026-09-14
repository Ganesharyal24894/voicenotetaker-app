import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:voicenotetaker_app/controller/app_controller.dart';
import 'package:voicenotetaker_app/drivers/app_directories.dart';
import 'package:voicenotetaker_app/drivers/audio_player_just_audio.dart';
import 'package:voicenotetaker_app/drivers/ble_transport_universal.dart';
import 'package:voicenotetaker_app/drivers/file_store.dart';
import 'package:voicenotetaker_app/drivers/process_memory.dart';
import 'package:voicenotetaker_app/drivers/speech_recognizer_sherpa.dart';
import 'package:voicenotetaker_app/model/transcript.dart';
import 'package:voicenotetaker_app/services/transcription/speech_model_store.dart';
import 'package:voicenotetaker_app/services/transcription/transcription_service.dart';
import 'package:voicenotetaker_app/view/playback_view.dart';
import 'package:voicenotetaker_app/view/recording_entry.dart';
import 'package:voicenotetaker_app/view/theme.dart';

/// The transcript feature on the phone, through the REAL playback screen, the
/// real controller, the real engine and the owner's real recordings. PHONE
/// ONLY.
///
/// It exists because the screen that opens a recording is only reachable with
/// the recorder connected, and MIUI refuses `adb shell input` - so the screen
/// is opened here, on the recording named by `STT_MATCH` (default: the
/// longest), and Transcribe is tapped in-process. The screen stays up for
/// `STT_HOLD_S` seconds (default 30) after the transcript is shown, printing
/// resident memory every second as `STT ui ...` lines, so screenshots and
/// memory can be taken from the host while it runs.
///
/// ```sh
/// flutter test integration_test/transcript_screen_on_device_test.dart \
///   -d <id> --no-uninstall
/// ```
///
/// `--no-uninstall` IS NOT OPTIONAL - see the warning in
/// `doc/agentFindings/on-device-stt.md`. The transcript it produces is saved
/// beside the recording, exactly as a tap in the app would save it; delete
/// `<recording>.transcript.json` to see the untranscribed state again.
/// `STT_PURGE=false` turns off the allocator purge, for comparison.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('transcribe a recording from its playback screen',
      (tester) async {
    const fileStore = IoFileStore();
    const directories = PathProviderAppDirectories();
    final documents = await directories.documentsDirectory();
    final support = await directories.supportDirectory();
    const purge = bool.fromEnvironment('STT_PURGE', defaultValue: true);

    final controller = AppController(
      transport: UniversalBleTransport(),
      fileStore: fileStore,
      audioPlayer: JustAudioPlayer(),
      transcriptionService: TranscriptionService(
        fileStore: fileStore,
        models: SpeechModelStore(
          fileStore: fileStore,
          modelsDirectory: fileStore.join(support, 'models'),
        ),
        recognizer: const SherpaOnnxSpeechRecognizer(returnFreedMemory: purge),
      ),
      recordingsDirectory: fileStore.join(documents, 'recordings'),
    );
    await tester.runAsync(controller.refreshLibrary);

    const match = String.fromEnvironment('STT_MATCH');
    final candidates = controller.recordings
        .where((r) => r.name.contains(match))
        .toList()
      ..sort((a, b) => (b.duration ?? Duration.zero)
          .compareTo(a.duration ?? Duration.zero));
    expect(candidates, isNotEmpty);
    final recording = candidates.first;
    debugPrint('STT ui purge=$purge recording ${recording.name}');

    void rss(String label) =>
        debugPrint('STT ui $label rss ${ProcessMemory.residentKb()} kB');

    Future<void> live(Duration duration) async {
      final end = DateTime.now().add(duration);
      while (DateTime.now().isBefore(end)) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
    }

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(),
        debugShowCheckedModeBanner: false,
        home: PlaybackView(
          controller: controller,
          entry: RecordingEntry.fromInfo(recording),
          recording: recording,
        ),
      ),
    );
    await live(const Duration(seconds: 2));
    // The screen starts the recording playing; silence it, the owner is not
    // here to listen.
    await tester.runAsync(controller.stopPlayback);
    await live(const Duration(seconds: 1));

    debugPrint('STT ui state ${controller.transcriptStatusFor(recording)}');
    if (controller.transcriptStatusFor(recording) != TranscriptStatus.none) {
      debugPrint('STT ui already has a transcript - showing it');
    } else {
      rss('idle');
      debugPrint('STT ui SHOT idle');
      await live(const Duration(seconds: 4));
      await tester.tap(find.bySemanticsLabel('Transcribe'));
      debugPrint('STT ui tapped');
      var seconds = 0;
      while (controller.isTranscribing) {
        await live(const Duration(seconds: 1));
        rss('running ${++seconds}s '
            '${controller.transcriptionDone}/${controller.transcriptionTotal}');
      }
      rss('released');
    }
    debugPrint('STT ui state ${controller.transcriptStatusFor(recording)}');
    debugPrint('STT ui text ${controller.transcriptFor(recording)?.text}');
    debugPrint('STT ui SHOT done');

    const hold = int.fromEnvironment('STT_HOLD_S', defaultValue: 30);
    for (var s = 1; s <= hold; s++) {
      await live(const Duration(seconds: 1));
      rss('after ${s}s');
    }
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 20)));
}
