import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'controller/app_controller.dart';
import 'controller/assistant_controller.dart';
import 'controller/export_controller.dart';
import 'controller/summary_controller.dart';
import 'drivers/app_directories.dart';
import 'drivers/audio_player_just_audio.dart';
import 'drivers/background_mode_channel.dart';
import 'drivers/ble_transport_universal.dart';
import 'drivers/clipboard_text.dart';
import 'drivers/disk_space_channel.dart';
import 'drivers/download_client.dart';
import 'drivers/email_sender_mailer.dart';
import 'drivers/file_store.dart';
import 'drivers/hashing_crypto.dart';
import 'drivers/haptics_channel.dart';
import 'drivers/network_status_connectivity.dart';
import 'drivers/opus_library_native.dart';
import 'drivers/phone_power_battery_plus.dart';
import 'drivers/secret_store_secure.dart';
import 'drivers/platform_settings_channel.dart';
import 'drivers/share_sheet_share_plus.dart';
import 'drivers/speaker_diarizer_sherpa.dart';
import 'drivers/speech_recognizer_sherpa.dart';
import 'drivers/undo_notification_channel.dart';
import 'services/assistant/undo_notifier.dart';
import 'services/codec/frame_decoder.dart';
import 'services/export/note_export_service.dart';
import 'services/summary/day_summary_store.dart';
import 'services/transcription/model_download_service.dart';
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

  // Asked once. Three things below hang off it, and the reasons differ - see
  // each one.
  final android = defaultTargetPlatform == TargetPlatform.android;

  // Where the models are expected, and the one object that knows how to put
  // them there. `adb push` still works and is what development uses; this is
  // the only way an iPhone ever gets them.
  final modelStore = SpeechModelStore(
    fileStore: fileStore,
    modelsDirectory: fileStore.join(support, 'models'),
  );

  // "Instinct, ...": a note that begins with the wake phrase is emailed to the
  // user's assistant. OFF until the user turns it on and puts in a sending
  // account; with it off, nothing here opens a socket, reads the keystore or
  // touches the outbox - see `AssistantController.initialise`.
  //
  // BUILT BEFORE THE RECORDER, because the recorder is handed a closure over
  // it. A `late` field filled in afterwards would make the order a runtime
  // matter: deleting one half of the pair would fail with a
  // LateInitializationError on the first transcribed note instead of failing
  // to compile.
  final assistant = AssistantController(
    fileStore: fileStore,
    // App data, beside the other settings - and the outbox, which must
    // survive the app being killed.
    directory: support,
    // The one thing in this app that sends. See `MailerEmailSender` for why
    // SMTP and not a provider's API.
    sender: const MailerEmailSender(),
    // Keychain on iOS, hardware-backed keystore on Android. The app password
    // never goes in a settings file.
    secrets: const SecureSecretStore(),
    // So an instruction spoken underground goes out when the phone surfaces,
    // instead of failing to the user.
    network: ConnectivityPlusNetworkStatus(),
    // Android only, for the same reason as below: iOS cannot vibrate from the
    // background, and the settings screen says so rather than pretending.
    haptics: android ? const MethodChannelHaptics() : null,
  );
  unawaited(assistant.initialise());

  final controller = AppController(
    transport: ble,
    pairing: ble,
    fileStore: fileStore,
    audioPlayer: JustAudioPlayer(),
    platformSettings: const MethodChannelPlatformSettings(),
    // BOTH PHONES, and the two halves answer on the same channel: Android's
    // in `EngineHolder.kt`, the iPhone's in `AppDelegate.swift`. Each does
    // what its OS actually allows and says so honestly when asked - a
    // foreground service and a vibration on Android, a local notification and
    // a `BGProcessingTask` window on iOS. See `BackgroundMode`.
    backgroundMode: MethodChannelBackgroundMode(),
    // ANDROID ONLY, AND SAID SO HERE RATHER THAN DISCOVERED AT RUNTIME.
    //
    // An iPhone in a pocket cannot be made to vibrate by an app that is not on
    // screen; there is no API for it. Wiring this everywhere would not crash -
    // the driver swallows the MissingPluginException - it would do something
    // worse: the alert would believe it had a way to reach the wearer and buzz
    // into a vibrator that is not there. Null instead, and on iOS the local
    // notification `backgroundMode` posts is the whole alert.
    haptics: android ? const MethodChannelHaptics() : null,
    phonePower: BatteryPlusPhonePower(),
    // Codec 2 on `fe03`. Wired here so every stream - a manual recording,
    // always-listening, the mic check - opens its decoder in the one place
    // that knows how, and none of them can disagree about Opus. libopus is
    // compiled into the app by packages/opus_native, and nothing calls into it
    // until the device actually reports Opus.
    decoders: const FrameDecoders(opus: NativeOpusLibrary()),
    // Android only: its foreground service keeps this isolate alive with the
    // screen off, so a queued transcript simply carries on running. iOS makes
    // no such promise - there the queue runs when the app is opened, or inside
    // a `BGProcessingTask` window if the system grants one.
    backgroundTranscription: android,
    // App data, not the user's documents: which device to reach, and whether
    // to keep listening.
    settingsDirectory: support,
    // Downloads the model files onto the phone, resumably and verified. It
    // runs only while the app is on screen - see `ModelDownloadService`.
    modelDownloads: ModelDownloadService(
      fileStore: fileStore,
      models: modelStore,
      client: IoDownloadClient(),
      hashing: const CryptoHashing(),
      network: ConnectivityPlusNetworkStatus(),
      diskSpace: const MethodChannelDiskSpace(),
    ),
    transcriptionService: TranscriptionService(
      fileStore: fileStore,
      models: modelStore,
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
    // THE APP'S ONLY OUTBOUND PATH STARTS HERE, and only when the user has
    // turned it on and set up a sending account. Everything about whether a
    // note is an instruction, and whether anything is sent, is behind this
    // one call - see `doc/assistant-instructions.md`.
    //
    // AN ANONYMOUS HOOK, by design: `AppController` knows it hands every
    // finished transcript to something, and nothing about what. Deleting the
    // assistant is deleting this argument.
    onTranscriptSaved: (path, recordedAt, transcript) => unawaited(
      assistant.noteTranscribed(
        noteId: path,
        // The words, not the audio and not the file.
        transcript: transcript.text,
        spokenAt: recordedAt,
      ),
    ),
  );

  // The Undo notification, for the five seconds before an instruction goes
  // when the app is not on screen. ANDROID ONLY: an iPhone gets the in-app
  // banner on the next glance and nothing else, for the same reason it gets
  // no buzz - see `doc/assistant-instructions.md`.
  final undoNotifier = android
      ? AssistantUndoNotifier(
          assistant: assistant,
          notifications: MethodChannelUndoNotifications(),
        )
      : null;

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

  // "Export notes": one zip of the recordings directory, handed to the share
  // sheet. The zip is written to the SUPPORT directory, not to documents:
  // it is a copy made to be sent somewhere and then deleted, and a second
  // copy of the whole library sitting in the user's Files app beside the real
  // one is a way to lose track of which is which.
  final exports = NoteExportService(
    fileStore: fileStore,
    recordingsDirectory: fileStore.join(documents, 'recordings'),
    exportsDirectory: fileStore.join(support, 'exports'),
    // Asked before a multi-hundred-megabyte zip is started, so an export that
    // cannot fit says so first instead of filling the phone and failing.
    diskSpace: const MethodChannelDiskSpace(),
  );

  runApp(VoiceNotetakerApp(
    controller: controller,
    summaries: summaries,
    assistant: assistant,
    undoNotifier: undoNotifier,
    newExportController: () => ExportController(
      exports: exports,
      shareSheet: const SharePlusShareSheet(),
    ),
  ));
}

class VoiceNotetakerApp extends StatefulWidget {
  const VoiceNotetakerApp({
    required this.controller,
    this.summaries,
    this.assistant,
    this.undoNotifier,
    this.newExportController,
    super.key,
  });

  final AppController controller;
  final SummaryController? summaries;

  /// "Speak to your assistant". Null on a build with the feature left out; the
  /// settings screen and the Undo banner read everything they need from it.
  final AssistantController? assistant;

  /// Posts the Undo notification while the app is away. Android only.
  final AssistantUndoNotifier? undoNotifier;

  /// Makes the controller behind "Export notes", one per opening of the sheet.
  final ExportController Function()? newExportController;

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
    widget.undoNotifier?.dispose();
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
      home: AppRoot(
        controller: widget.controller,
        summaries: widget.summaries,
        assistant: widget.assistant,
        undoNotifier: widget.undoNotifier,
        newExportController: widget.newExportController,
      ),
    );
  }
}
