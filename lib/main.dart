import 'package:flutter/material.dart';

import 'controller/app_controller.dart';
import 'drivers/app_directories.dart';
import 'drivers/audio_player_just_audio.dart';
import 'drivers/ble_transport_universal.dart';
import 'drivers/file_store.dart';
import 'drivers/platform_settings_channel.dart';
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

  final controller = AppController(
    transport: UniversalBleTransport(),
    fileStore: fileStore,
    audioPlayer: JustAudioPlayer(),
    platformSettings: const MethodChannelPlatformSettings(),
    recordingsDirectory: fileStore.join(documents, 'recordings'),
  );

  runApp(VoiceNotetakerApp(controller: controller));
}

class VoiceNotetakerApp extends StatefulWidget {
  const VoiceNotetakerApp({required this.controller, super.key});

  final AppController controller;

  @override
  State<VoiceNotetakerApp> createState() => _VoiceNotetakerAppState();
}

class _VoiceNotetakerAppState extends State<VoiceNotetakerApp> {
  @override
  void initState() {
    super.initState();
    widget.controller.initialise();
  }

  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'voiceNotetaker',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(),
      home: AppRoot(controller: widget.controller),
    );
  }
}
