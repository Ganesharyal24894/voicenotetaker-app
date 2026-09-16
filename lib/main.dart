import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'controller/app_controller.dart';
import 'controller/summary_controller.dart';
import 'drivers/app_directories.dart';
import 'drivers/audio_player_just_audio.dart';
import 'drivers/background_mode_channel.dart';
import 'drivers/ble_transport_universal.dart';
import 'drivers/clipboard_text.dart';
import 'drivers/file_store.dart';
import 'drivers/haptics_channel.dart';
import 'drivers/phone_power_battery_plus.dart';
import 'drivers/platform_settings_channel.dart';
import 'drivers/share_sheet_share_plus.dart';
import 'drivers/speaker_diarizer_sherpa.dart';
import 'drivers/speech_recognizer_sherpa.dart';
import 'services/summary/day_summary_store.dart';
import 'services/transcription/speech_model_store.dart';
import 'services/transcription/transcription_service.dart';
import 'view/app_root.dart';
import 'view/theme.dart';

/// Entry point. Wires the concrete drivers into the controller and hands the
/// controller to the view layer; no logic lives here.
///
/// This is the single place that names a concrete driver implementation, which
/// is what makes `lib/drivers/` a genuine swap layer.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  const fileStore = IoFileStore();
  const directories = PathProviderAppDirectories();

  // Recordings go in the app's documents directory, which the OS keeps until
  // the app is uninstalled. They must not go anywhere cache-like: the system
  // is free to evict those, and a deleted voice note is not recoverable.
  final documents = await directories.documentsDirectory();

  // Speech models are app data, not the user's documents, and far too large
  // to bundle: they are installed into the support directory (for now by
  // `adb push`, later by a download) and loaded only for a transcription.
  final support = await directories.supportDirectory();

  // One object behind both seams: the radio, and pairing on that radio.
  final ble = UniversalBleTransport();

  final controller = AppController(
    transport: ble,
    pairing: ble,
    fileStore: fileStore,
    audioPlayer: JustAudioPlayer(),
    platformSettings: const MethodChannelPlatformSettings(),
    backgroundMode: const MethodChannelBackgroundMode(),
    // The not-saving alert's buzz. Android only in practice - see Haptics.
    haptics: const MethodChannelHaptics(),
    phonePower: BatteryPlusPhonePower(),
    // Android only: its foreground service keeps this isolate alive with the
    // screen off. iOS makes no such promise, so there transcription waits for
    // the app to be opened.
    backgroundTranscription: defaultTargetPlatform == TargetPlatform.android,
    // App data, not the user's documents: which device to reach, and whether
    // to keep listening.
    settingsDirectory: support,
    transcriptionService: TranscriptionService(
      fileStore: fileStore,
      models: SpeechModelStore(
        fileStore: fileStore,
        modelsDirectory: fileStore.join(support, 'models'),
      ),
      recognizer: SherpaOnnxSpeechRecognizer(),
      // Who spoke when, before the speech model is loaded, when
      // `models/diarization/` holds both files. Absent - which is the ordinary
      // case until they are pushed - and notes are transcribed with no speaker
      // labels, exactly as before.
      diarizer: SherpaOnnxSpeakerDiarizer(),
      // Cut windows in the pauses when `models/silero-vad/silero_vad.onnx` is
      // installed. Off unless built with --dart-define=STT_VAD=true, until
      // its CER and cost are measured; with the file absent it changes
      // nothing either way.
      useVoiceActivitySegmentation: const bool.fromEnvironment('STT_VAD'),
    ),
    recordingsDirectory: fileStore.join(documents, 'recordings'),
  );

  // The Today tab: summaries pasted from the user's AI app, kept in the
  // support directory beside the other app data.
  final summaries = SummaryController(
    loadTranscript: (recording) async {
      await controller.loadTranscript(recording);
      return controller.transcriptFor(recording);
    },
    store: DaySummaryStore(fileStore: fileStore, directory: support),
    clipboard: const SystemClipboardText(),
    shareSheet: const SharePlusShareSheet(),
  );

  runApp(VoiceNotetakerApp(controller: controller, summaries: summaries));
}

class VoiceNotetakerApp extends StatefulWidget {
  const VoiceNotetakerApp({required this.controller, this.summaries, super.key});

  final AppController controller;
  final SummaryController? summaries;

  @override
  State<VoiceNotetakerApp> createState() => _VoiceNotetakerAppState();
}

class _VoiceNotetakerAppState extends State<VoiceNotetakerApp> {
  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  /// Starts the controller, then tells it the app is on screen.
  ///
  /// Only when it really is: on Android the engine can also be started with no
  /// activity at all, by the always-listening service after the system killed
  /// the process, and nothing heavy may start then. A resume that arrives
  /// later reaches the controller through `AppRoot`.
  Future<void> _start() async {
    await widget.controller.initialise();
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      await widget.controller.appForegrounded();
    }
  }

  @override
  void dispose() {
    widget.summaries?.dispose();
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'voiceNotetaker',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(),
      home: AppRoot(controller: widget.controller, summaries: widget.summaries),
    );
  }
}
